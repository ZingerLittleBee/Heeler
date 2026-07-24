// Bootstrap Key material (ADR 0007).
//
// A Bootstrap Key is an ephemeral Ed25519 keypair: its raw 32-byte seed rides
// inside the Pairing Code, its public half becomes a restricted
// authorized_keys line. Only the seed and the public line ever exist outside
// this process; the private key object is discarded after derivation.

import { createPrivateKey, createPublicKey, generateKeyPairSync } from "node:crypto";

const SEED_BYTES = 32;
const KEY_TYPE = "ssh-ed25519";

// PKCS8 DER prefix for an Ed25519 private key; the raw seed follows directly.
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

function sshString(buffer) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(buffer.length);
  return Buffer.concat([length, buffer]);
}

/** OpenSSH public key line ("ssh-ed25519 <base64 blob>") for a raw public key. */
function publicLineFromRawPublicKey(rawPublicKey) {
  const blob = Buffer.concat([sshString(Buffer.from(KEY_TYPE, "utf8")), sshString(rawPublicKey)]);
  return `${KEY_TYPE} ${blob.toString("base64")}`;
}

function rawPublicKeyOf(publicKey) {
  // JWK "x" is the raw Ed25519 public key, base64url.
  return Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url");
}

/**
 * Derive the OpenSSH public key line from a raw 32-byte Ed25519 seed.
 * Matches what `ssh-keygen -y` prints for the same key.
 */
export function publicLineFromSeed(seed) {
  if (!Buffer.isBuffer(seed) || seed.length !== SEED_BYTES) {
    throw new Error(`Bootstrap Key seed must be ${SEED_BYTES} bytes`);
  }
  const privateKey = createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]),
    format: "der",
    type: "pkcs8",
  });
  return publicLineFromRawPublicKey(rawPublicKeyOf(createPublicKey(privateKey)));
}

/**
 * Generate a fresh Bootstrap Key.
 *
 * @returns {{seed: Buffer, publicLine: string}}
 */
export function generateBootstrapKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  // JWK "d" is the raw Ed25519 seed, base64url.
  const seed = Buffer.from(privateKey.export({ format: "jwk" }).d, "base64url");
  return { seed, publicLine: publicLineFromRawPublicKey(rawPublicKeyOf(publicKey)) };
}
