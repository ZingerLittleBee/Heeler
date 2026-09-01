// Live Activity content envelope v1 (docs/agents/live-activity-contract.md).
//
// Same AES-256-GCM framing as the notification envelope, sealed under AAD
// `HERDR-ACTIVITY:1` so the two ciphertexts cannot be opened as each other.
// Canonical plaintext is compact JSON with object keys in ascending
// alphabetical order at every level. This side proves the seal direction
// against test-vectors/live-activity-content-v1.json.

import { createDecipheriv } from "node:crypto";

import { ENVELOPE_VERSION, NONCE_BYTES, deriveKeyId, sealEnvelope } from "./seal-envelope.js";

export const ACTIVITY_ENVELOPE_VERSION = ENVELOPE_VERSION;
export const ACTIVITY_AAD = Buffer.from(`HERDR-ACTIVITY:${ACTIVITY_ENVELOPE_VERSION}`, "utf8");

const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const GCM_TAG_BYTES = 16;

export class ActivityEnvelopeError extends Error {
  /**
   * @param {"bad_envelope"|"unsupported_version"|"decrypt_failed"|"bad_payload"} code
   * @param {string} message
   */
  constructor(code, message) {
    super(message);
    this.name = "ActivityEnvelopeError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new ActivityEnvelopeError(code, message);
}

function decodeBase64Url(text, what) {
  if (typeof text !== "string" || !BASE64URL_PATTERN.test(text) || text.length % 4 === 1) {
    fail("bad_envelope", `${what} is not unpadded base64url`);
  }
  return Buffer.from(text, "base64url");
}

/**
 * Canonical compact JSON for an activity plaintext object. Keys are emitted
 * in ascending alphabetical order at every level; empty titles are omitted.
 *
 * @param {object} plaintext
 * @returns {string}
 */
export function canonicalActivityPlaintext(plaintext) {
  const agents = Array.isArray(plaintext?.agents) ? plaintext.agents : [];
  return JSON.stringify({
    agents: agents.map((agent) => {
      const entry = {};
      entry.kind = agent.kind;
      if (typeof agent.name === "string" && agent.name.length > 0) {
        entry.name = agent.name;
      }
      entry.pane = agent.pane;
      entry.status = agent.status;
      if (typeof agent.title === "string" && agent.title.length > 0) {
        entry.title = agent.title;
      }
      if (typeof agent.workspace === "string" && agent.workspace.length > 0) {
        entry.workspace = agent.workspace;
      }
      return entry;
    }),
    host: plaintext.host,
    v: plaintext.v,
  });
}

/**
 * Encrypt an activity plaintext object into its canonical v1 envelope string.
 *
 * @param {object} plaintext `{agents, host, v}` already in canonical form
 * @param {Buffer} key raw 32-byte Notification Key
 * @param {{nonce?: Buffer}} [options] injectable 12-byte nonce (tests only)
 * @returns {string}
 */
export function encryptActivityEnvelope(plaintext, key, { nonce } = {}) {
  return sealEnvelope(canonicalActivityPlaintext(plaintext), key, ACTIVITY_AAD, { nonce });
}

export function activityKeyId(key) {
  return deriveKeyId(key);
}

/**
 * Open an activity envelope and return the plaintext object.
 *
 * @param {string} envelope
 * @param {Buffer} key
 * @returns {object}
 */
export function decryptActivityEnvelope(envelope, key) {
  deriveKeyId(key);
  let wire;
  try {
    wire = JSON.parse(envelope);
  } catch {
    fail("bad_envelope", "envelope is not JSON");
  }
  if (typeof wire !== "object" || wire === null || Array.isArray(wire)) {
    fail("bad_envelope", "envelope must be a JSON object");
  }
  if (!Number.isInteger(wire.v)) {
    fail("bad_envelope", "envelope version must be an integer");
  }
  if (wire.v !== ACTIVITY_ENVELOPE_VERSION) {
    fail("unsupported_version", `unsupported activity envelope version ${wire.v}`);
  }
  if (typeof wire.kid !== "string" || wire.kid.length === 0) {
    fail("bad_envelope", "kid missing");
  }
  const nonce = decodeBase64Url(wire.n, "nonce");
  const ct = decodeBase64Url(wire.ct, "ciphertext");
  if (nonce.length !== NONCE_BYTES) {
    fail("bad_envelope", `nonce must be ${NONCE_BYTES} bytes`);
  }
  if (ct.length < GCM_TAG_BYTES) {
    fail("bad_envelope", "ciphertext shorter than the GCM tag");
  }
  let raw;
  try {
    const decipher = createDecipheriv("aes-256-gcm", key, nonce);
    decipher.setAAD(ACTIVITY_AAD);
    decipher.setAuthTag(ct.subarray(ct.length - GCM_TAG_BYTES));
    raw = Buffer.concat([
      decipher.update(ct.subarray(0, ct.length - GCM_TAG_BYTES)),
      decipher.final(),
    ]);
  } catch {
    fail("decrypt_failed", "activity envelope failed authentication");
  }
  let payload;
  try {
    payload = JSON.parse(raw.toString("utf8"));
  } catch {
    fail("bad_payload", "plaintext is not JSON");
  }
  validateActivityPlaintext(payload);
  return payload;
}

function validateActivityPlaintext(payload) {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    fail("bad_payload", "plaintext must be a JSON object");
  }
  if (payload.v !== ACTIVITY_ENVELOPE_VERSION) {
    fail("bad_payload", `plaintext version must be ${ACTIVITY_ENVELOPE_VERSION}`);
  }
  if (typeof payload.host !== "string" || payload.host.length === 0) {
    fail("bad_payload", "host must be a non-empty string");
  }
  if (!Array.isArray(payload.agents)) {
    fail("bad_payload", "agents must be an array");
  }
  for (const agent of payload.agents) {
    if (typeof agent !== "object" || agent === null || Array.isArray(agent)) {
      fail("bad_payload", "agent entry must be an object");
    }
    if (typeof agent.status !== "string" || agent.status.length === 0) {
      fail("bad_payload", "agent status must be a non-empty string");
    }
  }
}
