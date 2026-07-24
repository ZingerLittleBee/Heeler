// Pairing Code v1 envelope (ADR 0007).
//
// Wire format: "HERDR-PAIR:<version>:<base64url(JSON, no padding)>".
// The JSON payload uses short wire keys; see README.md for the schema and
// test-vectors/pairing-code-v1.json for the cross-implementation vectors.
// Unknown payload fields are ignored (additive metadata); breaking changes
// bump the version, which both implementations must honor.

export const PAIRING_CODE_PREFIX = "HERDR-PAIR";
export const PAIRING_CODE_VERSION = 1;

const BOOTSTRAP_SEED_BYTES = 32;
// OpenSSH fingerprint: "SHA256:" + unpadded standard base64 of a 32-byte digest.
const FINGERPRINT_PATTERN = /^SHA256:[A-Za-z0-9+/]{43}$/;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;

export class PairingCodeError extends Error {
  /**
   * @param {"bad_prefix"|"unsupported_version"|"bad_encoding"|"bad_payload"} code
   * @param {string} message
   */
  constructor(code, message) {
    super(message);
    this.name = "PairingCodeError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new PairingCodeError(code, message);
}

/**
 * Validate the in-memory payload shape shared by encode and decode.
 *
 * @param {object} payload
 * @param {string[]} payload.addresses candidate addresses in try-order
 * @param {number} payload.port SSH port
 * @param {string} payload.username SSH username
 * @param {string} payload.hostKeyFingerprint OpenSSH SHA256 host key fingerprint
 * @param {Buffer} [payload.bootstrapSeed] raw Ed25519 seed of the Bootstrap Key
 * @param {number} [payload.expiresAt] unix-seconds expiry of the Bootstrap Key
 */
function validatePayload(payload) {
  const { addresses, port, username, hostKeyFingerprint, bootstrapSeed, expiresAt } = payload;

  if (!Array.isArray(addresses) || addresses.length === 0) {
    fail("bad_payload", "addresses must be a non-empty array");
  }
  for (const address of addresses) {
    if (typeof address !== "string" || address.length === 0 || /\s/.test(address)) {
      fail("bad_payload", `invalid address: ${JSON.stringify(address)}`);
    }
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    fail("bad_payload", `port must be an integer in 1..65535, got ${port}`);
  }
  if (typeof username !== "string" || username.length === 0 || /\s/.test(username)) {
    fail("bad_payload", "username must be a non-empty string without whitespace");
  }
  if (typeof hostKeyFingerprint !== "string" || !FINGERPRINT_PATTERN.test(hostKeyFingerprint)) {
    fail("bad_payload", "hostKeyFingerprint must be an OpenSSH SHA256 fingerprint");
  }
  if ((bootstrapSeed === undefined) !== (expiresAt === undefined)) {
    fail("bad_payload", "bootstrapSeed and expiresAt must be present together");
  }
  if (bootstrapSeed !== undefined && bootstrapSeed.length !== BOOTSTRAP_SEED_BYTES) {
    fail("bad_payload", `bootstrapSeed must be ${BOOTSTRAP_SEED_BYTES} bytes`);
  }
  if (expiresAt !== undefined && (!Number.isInteger(expiresAt) || expiresAt <= 0)) {
    fail("bad_payload", "expiresAt must be a positive unix-seconds integer");
  }
}

/**
 * Encode a Pairing Code payload into its canonical v1 string.
 *
 * Key order is fixed so the same payload always yields the same code; the
 * shared vectors assert on the exact string.
 */
export function encodePairingCode(payload) {
  validatePayload(payload);
  const wire = {
    addrs: payload.addresses,
    port: payload.port,
    user: payload.username,
    fp: payload.hostKeyFingerprint,
  };
  if (payload.bootstrapSeed !== undefined) {
    wire.seed = payload.bootstrapSeed.toString("base64url");
    wire.exp = payload.expiresAt;
  }
  const body = Buffer.from(JSON.stringify(wire), "utf8").toString("base64url");
  return `${PAIRING_CODE_PREFIX}:${PAIRING_CODE_VERSION}:${body}`;
}

function decodeBase64UrlStrict(text, what, errorCode) {
  if (!BASE64URL_PATTERN.test(text) || text.length % 4 === 1) {
    fail(errorCode, `${what} is not unpadded base64url`);
  }
  return Buffer.from(text, "base64url");
}

/**
 * Decode and validate a scanned Pairing Code string.
 *
 * @returns {{addresses: string[], port: number, username: string,
 *            hostKeyFingerprint: string, bootstrapSeed?: Buffer, expiresAt?: number}}
 * @throws {PairingCodeError} with a step-taxonomy code:
 *   bad_prefix | unsupported_version | bad_encoding | bad_payload
 */
export function decodePairingCode(code) {
  if (typeof code !== "string" || !code.startsWith(`${PAIRING_CODE_PREFIX}:`)) {
    fail("bad_prefix", `expected "${PAIRING_CODE_PREFIX}:<version>:<payload>"`);
  }
  const rest = code.slice(PAIRING_CODE_PREFIX.length + 1);
  const separator = rest.indexOf(":");
  if (separator === -1) {
    fail("bad_prefix", "missing version separator");
  }
  const version = rest.slice(0, separator);
  if (version !== String(PAIRING_CODE_VERSION)) {
    fail("unsupported_version", `unsupported Pairing Code version "${version}"`);
  }

  const body = decodeBase64UrlStrict(rest.slice(separator + 1), "payload", "bad_encoding");
  let wire;
  try {
    wire = JSON.parse(body.toString("utf8"));
  } catch {
    fail("bad_encoding", "payload is not valid JSON");
  }
  if (typeof wire !== "object" || wire === null || Array.isArray(wire)) {
    fail("bad_payload", "payload must be a JSON object");
  }

  const payload = {
    addresses: wire.addrs,
    port: wire.port,
    username: wire.user,
    hostKeyFingerprint: wire.fp,
  };
  if (wire.seed !== undefined) {
    if (typeof wire.seed !== "string") {
      fail("bad_payload", "seed must be a base64url string");
    }
    payload.bootstrapSeed = decodeBase64UrlStrict(wire.seed, "seed", "bad_payload");
  }
  if (wire.exp !== undefined) {
    payload.expiresAt = wire.exp;
  }
  validatePayload(payload);
  return payload;
}
