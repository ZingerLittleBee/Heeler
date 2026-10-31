// Shared AES-256-GCM envelope sealer.
//
// Both the notification envelope (`HERDR-NOTIFY:1`) and the Live Activity
// envelope (`HERDR-ACTIVITY:1`) use the same framing `{v,kid,n,ct}` and the
// same key-id derivation. Domain separation is the AAD the caller passes.

import { createCipheriv, createHash, randomBytes } from "node:crypto";

export const ENVELOPE_VERSION = 1;
export const KEY_BYTES = 32;
export const NONCE_BYTES = 12;
const KEY_ID_BYTES = 8;

/**
 * Derive the cleartext key id for a raw 32-byte Notification Key: the first
 * 8 bytes of SHA-256 over the key, unpadded base64url. Both ends derive it,
 * so it never needs to be stored or exchanged separately.
 *
 * @param {Buffer} key
 * @returns {string}
 */
export function deriveKeyId(key) {
  if (!Buffer.isBuffer(key) || key.length !== KEY_BYTES) {
    throw new TypeError(`Notification Key must be a ${KEY_BYTES}-byte Buffer`);
  }
  return createHash("sha256").update(key).digest().subarray(0, KEY_ID_BYTES).toString("base64url");
}

/**
 * Seal a UTF-8 plaintext string under AES-256-GCM and return the canonical
 * envelope JSON string `{"v":1,"kid":...,"n":...,"ct":...}`.
 *
 * @param {string} plaintextString
 * @param {Buffer} key raw 32-byte Notification Key
 * @param {Buffer} aadBuffer additional authenticated data
 * @param {{nonce?: Buffer}} [options] injectable 12-byte nonce (tests only;
 *   production must use the random default)
 * @returns {string}
 */
export function sealEnvelope(plaintextString, key, aadBuffer, { nonce } = {}) {
  const keyId = deriveKeyId(key);
  if (nonce === undefined) {
    nonce = randomBytes(NONCE_BYTES);
  } else if (!Buffer.isBuffer(nonce) || nonce.length !== NONCE_BYTES) {
    throw new TypeError(`nonce must be a ${NONCE_BYTES}-byte Buffer`);
  }
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aadBuffer);
  const ciphertext = Buffer.concat([
    cipher.update(plaintextString, "utf8"),
    cipher.final(),
    cipher.getAuthTag(),
  ]);
  return JSON.stringify({
    v: ENVELOPE_VERSION,
    kid: keyId,
    n: nonce.toString("base64url"),
    ct: ciphertext.toString("base64url"),
  });
}
