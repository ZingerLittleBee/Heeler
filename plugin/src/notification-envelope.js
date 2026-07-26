// Notification envelope v1 (ADR 0008).
//
// The encrypted Agent Notification payload carried from the notify hook
// through the Push Relay and APNs to the app's service extension. Wire
// format: a compact JSON object `{"v":1,"kid":...,"n":...,"ct":...}` whose
// `ct` is the AES-256-GCM ciphertext (plus tag) of a compact JSON plaintext
// `{"pane":...,"kind":...,"status":...,"ts":...}` plus the optional display
// fields `project` and `title`. See README.md for the
// schema and test-vectors/notification-payload-v1.json for the
// cross-implementation vectors: this side proves the encrypt direction, the
// Swift side proves the decrypt direction. Breaking changes bump the
// version, which both implementations must honor together.

import { createCipheriv, createHash, randomBytes } from "node:crypto";

export const NOTIFICATION_ENVELOPE_VERSION = 1;

// Additional authenticated data binding the ciphertext to envelope v1, so a
// re-framed ciphertext under a different version fails authentication.
const AAD = Buffer.from(`HERDR-NOTIFY:${NOTIFICATION_ENVELOPE_VERSION}`, "utf8");

const KEY_BYTES = 32;
const NONCE_BYTES = 12;
const KEY_ID_BYTES = 8;

export class NotificationEnvelopeError extends Error {
  /**
   * @param {"bad_envelope"|"unsupported_version"|"decrypt_failed"|"bad_payload"} code
   * @param {string} message
   */
  constructor(code, message) {
    super(message);
    this.name = "NotificationEnvelopeError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new NotificationEnvelopeError(code, message);
}

/**
 * Derive the cleartext key id for a raw 32-byte Notification Key: the first
 * 8 bytes of SHA-256 over the key, unpadded base64url. Both ends derive it,
 * so it never needs to be stored or exchanged separately.
 *
 * @param {Buffer} key
 * @returns {string}
 */
export function notificationKeyId(key) {
  if (!Buffer.isBuffer(key) || key.length !== KEY_BYTES) {
    throw new TypeError(`Notification Key must be a ${KEY_BYTES}-byte Buffer`);
  }
  return createHash("sha256").update(key).digest().subarray(0, KEY_ID_BYTES).toString("base64url");
}

// Hard ceiling for the display-only strings. The notify hook trims to
// something shorter still (see DISPLAY_LIMIT there); this is the contract's
// backstop keeping an APNs payload well inside its 4 KB budget once the
// ciphertext is base64url'd.
const DISPLAY_FIELD_MAX = 256;

/**
 * Validate the notification payload shape. `project` and `title` are the
 * optional display fields: omit them (or pass null) and the app renders one
 * step less specific.
 *
 * @param {object} payload
 * @param {string} payload.paneId herdr pane id the Agent lives in
 * @param {string} payload.agentKind agent kind as herdr reports it
 * @param {string} payload.status the new Agent Status (lenient open set)
 * @param {number} payload.timestamp unix-seconds of the status transition
 * @param {string|null} [payload.project] workspace label the Agent runs in
 * @param {string|null} [payload.title] Agent terminal title, glyphs stripped
 */
function validatePayload(payload) {
  const { paneId, agentKind, status, timestamp } = payload;
  if (typeof paneId !== "string" || paneId.length === 0) {
    fail("bad_payload", "paneId must be a non-empty string");
  }
  if (typeof agentKind !== "string" || agentKind.length === 0) {
    fail("bad_payload", "agentKind must be a non-empty string");
  }
  if (typeof status !== "string" || status.length === 0) {
    fail("bad_payload", "status must be a non-empty string");
  }
  if (!Number.isInteger(timestamp) || timestamp <= 0) {
    fail("bad_payload", `timestamp must be a positive unix-seconds integer, got ${timestamp}`);
  }
  for (const field of ["project", "title"]) {
    const value = payload[field];
    if (value === undefined || value === null) continue;
    if (typeof value !== "string") fail("bad_payload", `${field} must be a string when present`);
    if (value.length > DISPLAY_FIELD_MAX) {
      fail("bad_payload", `${field} must be at most ${DISPLAY_FIELD_MAX} characters`);
    }
  }
}

/**
 * Encrypt a notification payload into its canonical v1 envelope string.
 *
 * Key order in both JSON objects is fixed so the same inputs always yield
 * the same envelope; the shared vectors assert on the exact string.
 *
 * @param {object} payload see {@link validatePayload}
 * @param {Buffer} key raw 32-byte Notification Key
 * @param {{nonce?: Buffer}} [options] injectable 12-byte nonce (tests only;
 *   production must use the random default)
 * @returns {string} the canonical envelope JSON string
 * @throws {NotificationEnvelopeError} with code `bad_payload`
 */
export function encryptNotificationEnvelope(payload, key, { nonce } = {}) {
  const keyId = notificationKeyId(key);
  if (nonce === undefined) {
    nonce = randomBytes(NONCE_BYTES);
  } else if (!Buffer.isBuffer(nonce) || nonce.length !== NONCE_BYTES) {
    throw new TypeError(`nonce must be a ${NONCE_BYTES}-byte Buffer`);
  }
  validatePayload(payload);

  // Empty display fields are omitted rather than sent blank, so the encoding
  // stays canonical whichever way the Host failed to resolve them.
  const plaintext = JSON.stringify({
    pane: payload.paneId,
    kind: payload.agentKind,
    status: payload.status,
    ts: payload.timestamp,
    ...(payload.project ? { project: payload.project } : {}),
    ...(payload.title ? { title: payload.title } : {}),
  });
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(AAD);
  const ciphertext = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
    cipher.getAuthTag(),
  ]);

  return JSON.stringify({
    v: NOTIFICATION_ENVELOPE_VERSION,
    kid: keyId,
    n: nonce.toString("base64url"),
    ct: ciphertext.toString("base64url"),
  });
}
