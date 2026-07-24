// Strict validation of a submitted Device Key public line (ADR 0007).
//
// The Enrollment accept entrypoint runs as an sshd forced command and appends
// whatever passes this parser to authorized_keys, so the rules are strict:
// exactly one bare "ssh-ed25519 <blob> [comment]" line, the wire blob must be
// a well-formed Ed25519 public key, and the comment must be printable ASCII.
// Anything else is rejected without consuming the Bootstrap Key.

import { fingerprintPublicKeyLine } from "./host-key.js";

const KEY_TYPE = "ssh-ed25519";
const ED25519_KEY_BYTES = 32;
const MAX_LINE_LENGTH = 1024;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
// Space through tilde: printable ASCII only, no tabs or control characters.
const COMMENT_PATTERN = /^[\x20-\x7e]+$/;

export class DeviceKeyError extends Error {
  constructor(message) {
    super(message);
    this.name = "DeviceKeyError";
  }
}

function fail(message) {
  throw new DeviceKeyError(message);
}

function readSshString(buffer, offset) {
  if (offset + 4 > buffer.length) {
    fail("truncated key blob");
  }
  const length = buffer.readUInt32BE(offset);
  const end = offset + 4 + length;
  if (end > buffer.length) {
    fail("truncated key blob");
  }
  return { value: buffer.subarray(offset + 4, end), end };
}

/**
 * Parse and strictly validate a submitted Device Key public line.
 *
 * @param {string} input the raw submission (one line, whitespace tolerated)
 * @returns {{line: string, fingerprint: string}} the canonical authorized_keys
 *   line and its OpenSSH SHA256 fingerprint
 * @throws {DeviceKeyError} on anything that is not a bare Ed25519 public line
 */
export function parseDeviceKeyLine(input) {
  if (typeof input !== "string") {
    fail("submission must be text");
  }
  if (input.length > MAX_LINE_LENGTH) {
    fail(`submission exceeds ${MAX_LINE_LENGTH} characters`);
  }
  const line = input.trim();
  if (line.length === 0) {
    fail("submission is empty");
  }
  if (/[\n\r]/.test(line)) {
    fail("submission must be a single line");
  }

  const [keyType, blobText, ...commentWords] = line.split(" ");
  if (keyType !== KEY_TYPE) {
    fail(`key type must be ${KEY_TYPE}`);
  }
  if (blobText === undefined || !BASE64_PATTERN.test(blobText)) {
    fail("key blob is not base64");
  }

  const blob = Buffer.from(blobText, "base64");
  const type = readSshString(blob, 0);
  if (type.value.toString("utf8") !== KEY_TYPE) {
    fail("key blob type disagrees with the line type");
  }
  const key = readSshString(blob, type.end);
  if (key.value.length !== ED25519_KEY_BYTES) {
    fail(`Ed25519 public key must be ${ED25519_KEY_BYTES} bytes`);
  }
  if (key.end !== blob.length) {
    fail("key blob has trailing bytes");
  }

  const comment = commentWords.join(" ");
  if (comment.length > 0 && !COMMENT_PATTERN.test(comment)) {
    fail("comment must be printable ASCII");
  }

  // Re-emit the blob from the decoded bytes so authorized_keys only ever
  // receives canonical base64, whatever padding the submission used.
  const canonicalBlob = blob.toString("base64");
  const canonical =
    comment.length > 0 ? `${KEY_TYPE} ${canonicalBlob} ${comment}` : `${KEY_TYPE} ${canonicalBlob}`;
  return { line: canonical, fingerprint: fingerprintPublicKeyLine(canonical).fingerprint };
}
