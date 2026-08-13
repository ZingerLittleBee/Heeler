// Pairing Code envelopes (ADRs 0007 and 0014).
//
// Wire format: "HERDR-PAIR:<version>:<base64url(JSON, no padding)>".
// The JSON payload uses short wire keys; see README.md for the schema and
// test-vectors/pairing-code-v1.json for the cross-implementation vectors.
// Unknown payload fields are ignored (additive metadata); breaking changes
// bump the version, which both implementations must honor.

import { isIP } from "node:net";
import { TextDecoder } from "node:util";

export const PAIRING_CODE_PREFIX = "HERDR-PAIR";
export const PAIRING_CODE_VERSION = 1;
export const PAIRING_CODE_V2_VERSION = 2;

const BOOTSTRAP_SEED_BYTES = 32;
const FINGERPRINT_BYTES = 32;
const IPV6_BYTES = 16;
const V2_MAGIC = Buffer.from("HP", "ascii");
const V2_BOOTSTRAP_FLAG = 0x01;
const V2_KNOWN_FLAGS = V2_BOOTSTRAP_FLAG;
const ADDRESS_TYPE_HOSTNAME = 0x00;
const ADDRESS_TYPE_IPV4 = 0x04;
const ADDRESS_TYPE_IPV6 = 0x06;
// OpenSSH fingerprint: "SHA256:" + unpadded standard base64 of a 32-byte digest.
const FINGERPRINT_PATTERN = /^SHA256:[A-Za-z0-9+/]{43}$/;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: true });

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

function encodeUtf8(text, what) {
  const bytes = Buffer.from(text, "utf8");
  try {
    if (UTF8_DECODER.decode(bytes) !== text) {
      fail("bad_payload", `${what} is not valid Unicode`);
    }
  } catch {
    fail("bad_payload", `${what} is not valid Unicode`);
  }
  return bytes;
}

function ipv6ToBytes(address) {
  let expanded = address;
  const lastColon = expanded.lastIndexOf(":");
  const tail = expanded.slice(lastColon + 1);
  if (tail.includes(".")) {
    const octets = tail.split(".").map(Number);
    const high = (octets[0] << 8) | octets[1];
    const low = (octets[2] << 8) | octets[3];
    expanded = `${expanded.slice(0, lastColon + 1)}${high.toString(16)}:${low.toString(16)}`;
  }

  const halves = expanded.split("::");
  const left = halves[0] === "" ? [] : halves[0].split(":");
  const right = halves.length === 1 || halves[1] === "" ? [] : halves[1].split(":");
  const missing = halves.length === 2 ? 8 - left.length - right.length : 0;
  const groups = [...left, ...Array(missing).fill("0"), ...right].map((group) =>
    Number.parseInt(group, 16),
  );
  const bytes = Buffer.alloc(IPV6_BYTES);
  groups.forEach((group, index) => bytes.writeUInt16BE(group, index * 2));
  return bytes;
}

function bytesToIPv6(bytes) {
  const groups = Array.from({ length: 8 }, (_, index) => bytes.readUInt16BE(index * 2));
  let bestStart = -1;
  let bestLength = 0;
  for (let index = 0; index < groups.length; ) {
    if (groups[index] !== 0) {
      index += 1;
      continue;
    }
    let end = index;
    while (end < groups.length && groups[end] === 0) {
      end += 1;
    }
    if (end - index > bestLength) {
      bestStart = index;
      bestLength = end - index;
    }
    index = end;
  }

  // Canonical v2 text is lowercase hexadecimal without leading zeroes. The
  // longest run of at least two zero groups is compressed; ties use the first.
  if (bestLength >= 2) {
    const before = groups.slice(0, bestStart).map((group) => group.toString(16)).join(":");
    const after = groups
      .slice(bestStart + bestLength)
      .map((group) => group.toString(16))
      .join(":");
    return `${before}::${after}`;
  }
  return groups.map((group) => group.toString(16)).join(":");
}

function encodeAddress(address) {
  const type = isIP(address);
  if (type === ADDRESS_TYPE_IPV4) {
    return Buffer.from([ADDRESS_TYPE_IPV4, ...address.split(".").map(Number)]);
  }
  if (type === ADDRESS_TYPE_IPV6 && !address.includes("%")) {
    return Buffer.concat([Buffer.from([ADDRESS_TYPE_IPV6]), ipv6ToBytes(address)]);
  }

  const hostname = encodeUtf8(address, "hostname");
  if (hostname.length > 0xff) {
    fail("bad_payload", "hostname UTF-8 encoding must be at most 255 bytes");
  }
  return Buffer.concat([Buffer.from([ADDRESS_TYPE_HOSTNAME, hostname.length]), hostname]);
}

/**
 * Encode a Pairing Code payload into the compact binary v2 envelope.
 *
 * @returns {Buffer} bytes intended for a QR byte-mode segment
 */
export function encodePairingCodeV2(payload) {
  validatePayload(payload);
  if (payload.addresses.length > 0xff) {
    fail("bad_payload", "addresses must contain at most 255 entries");
  }

  const username = encodeUtf8(payload.username, "username");
  if (username.length > 0xff) {
    fail("bad_payload", "username UTF-8 encoding must be at most 255 bytes");
  }
  if (payload.expiresAt !== undefined && payload.expiresAt > 0xffffffff) {
    fail("bad_payload", "expiresAt must fit in an unsigned 32-bit integer");
  }

  const flags = payload.bootstrapSeed === undefined ? 0 : V2_BOOTSTRAP_FLAG;
  const header = Buffer.alloc(7);
  V2_MAGIC.copy(header, 0);
  header[2] = PAIRING_CODE_V2_VERSION;
  header[3] = flags;
  header.writeUInt16BE(payload.port, 4);
  header[6] = username.length;

  const fingerprintText = payload.hostKeyFingerprint.slice("SHA256:".length);
  const fingerprint = Buffer.from(fingerprintText, "base64");
  if (fingerprint.toString("base64").replace(/=+$/, "") !== fingerprintText) {
    fail("bad_payload", "hostKeyFingerprint must use canonical unpadded base64");
  }
  const chunks = [header, username, fingerprint];
  if (payload.bootstrapSeed !== undefined) {
    const expiresAt = Buffer.alloc(4);
    expiresAt.writeUInt32BE(payload.expiresAt);
    chunks.push(Buffer.from(payload.bootstrapSeed), expiresAt);
  }
  chunks.push(Buffer.from([payload.addresses.length]));
  chunks.push(...payload.addresses.map(encodeAddress));
  return Buffer.concat(chunks);
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

function decodeUtf8(bytes, what) {
  try {
    return UTF8_DECODER.decode(bytes);
  } catch {
    fail("bad_encoding", `${what} is not valid UTF-8`);
  }
}

/**
 * Decode and validate a compact binary Pairing Code v2 envelope.
 *
 * @param {Buffer|Uint8Array} bytes
 * @returns {{addresses: string[], port: number, username: string,
 *            hostKeyFingerprint: string, bootstrapSeed?: Buffer, expiresAt?: number}}
 * @throws {PairingCodeError} with a step-taxonomy code:
 *   bad_prefix | unsupported_version | bad_encoding | bad_payload
 */
export function decodePairingCodeV2(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    fail("bad_encoding", "Pairing Code v2 must be a byte array");
  }
  const envelope = Buffer.from(bytes);
  let offset = 0;

  function take(length, what) {
    if (offset + length > envelope.length) {
      fail("bad_encoding", `truncated Pairing Code v2 ${what}`);
    }
    const value = envelope.subarray(offset, offset + length);
    offset += length;
    return value;
  }

  function readUInt8(what) {
    return take(1, what)[0];
  }

  if (envelope.length < V2_MAGIC.length) {
    fail("bad_encoding", "truncated Pairing Code v2 magic");
  }
  if (!take(V2_MAGIC.length, "magic").equals(V2_MAGIC)) {
    fail("bad_prefix", "expected Pairing Code v2 magic HP");
  }
  const version = readUInt8("version");
  if (version !== PAIRING_CODE_V2_VERSION) {
    fail("unsupported_version", `unsupported Pairing Code version "${version}"`);
  }
  const flags = readUInt8("flags");
  if ((flags & ~V2_KNOWN_FLAGS) !== 0) {
    fail("bad_encoding", "Pairing Code v2 has reserved flags set");
  }

  const port = take(2, "port").readUInt16BE(0);
  if (port === 0) {
    fail("bad_payload", "port must be in 1..65535");
  }
  const usernameLength = readUInt8("username length");
  if (usernameLength === 0) {
    fail("bad_payload", "username must not be empty");
  }
  const username = decodeUtf8(take(usernameLength, "username"), "username");
  const fingerprint = take(FINGERPRINT_BYTES, "host key fingerprint");
  const hostKeyFingerprint = `SHA256:${fingerprint.toString("base64").replace(/=+$/, "")}`;

  let bootstrapSeed;
  let expiresAt;
  if ((flags & V2_BOOTSTRAP_FLAG) !== 0) {
    bootstrapSeed = Buffer.from(take(BOOTSTRAP_SEED_BYTES, "bootstrap seed"));
    expiresAt = take(4, "expiry").readUInt32BE(0);
  }

  const addressCount = readUInt8("address count");
  if (addressCount === 0) {
    fail("bad_payload", "addresses must not be empty");
  }
  const addresses = [];
  for (let index = 0; index < addressCount; index += 1) {
    const type = readUInt8(`address ${index + 1} type`);
    if (type === ADDRESS_TYPE_IPV4) {
      addresses.push([...take(4, `address ${index + 1}`)].join("."));
    } else if (type === ADDRESS_TYPE_IPV6) {
      addresses.push(bytesToIPv6(take(IPV6_BYTES, `address ${index + 1}`)));
    } else if (type === ADDRESS_TYPE_HOSTNAME) {
      const length = readUInt8(`address ${index + 1} hostname length`);
      if (length === 0) {
        fail("bad_payload", "hostname must not be empty");
      }
      addresses.push(decodeUtf8(take(length, `address ${index + 1} hostname`), "hostname"));
    } else {
      fail("bad_encoding", `unknown Pairing Code v2 address type ${type}`);
    }
  }
  if (offset !== envelope.length) {
    fail("bad_encoding", "Pairing Code v2 has trailing bytes");
  }

  const payload = { addresses, port, username, hostKeyFingerprint };
  if (bootstrapSeed !== undefined) {
    payload.bootstrapSeed = bootstrapSeed;
    payload.expiresAt = expiresAt;
  }
  validatePayload(payload);
  return payload;
}
