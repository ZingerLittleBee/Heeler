import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { parseDeviceKeyLine, DeviceKeyError } from "../src/device-key.js";

// Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
const BLOB = "AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce";
const FINGERPRINT = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";

function assertRejects(input) {
  assert.throws(
    () => parseDeviceKeyLine(input),
    (error) => error instanceof DeviceKeyError,
    `expected rejection for ${JSON.stringify(input)}`,
  );
}

suite("parseDeviceKeyLine", () => {
  test("accepts a bare ed25519 line", () => {
    const parsed = parseDeviceKeyLine(`ssh-ed25519 ${BLOB}`);
    assert.equal(parsed.line, `ssh-ed25519 ${BLOB}`);
    assert.equal(parsed.fingerprint, FINGERPRINT);
  });

  test("accepts a comment and keeps it in the canonical line", () => {
    const parsed = parseDeviceKeyLine(`ssh-ed25519 ${BLOB} heeler iPhone`);
    assert.equal(parsed.line, `ssh-ed25519 ${BLOB} heeler iPhone`);
    assert.equal(parsed.fingerprint, FINGERPRINT);
  });

  test("trims surrounding whitespace and a trailing newline", () => {
    const parsed = parseDeviceKeyLine(`  ssh-ed25519 ${BLOB} phone\n`);
    assert.equal(parsed.line, `ssh-ed25519 ${BLOB} phone`);
  });

  test("rejects non-ed25519 key types", () => {
    assertRejects(`ssh-rsa ${BLOB}`);
    assertRejects(`ecdsa-sha2-nistp256 ${BLOB}`);
  });

  test("rejects authorized_keys options smuggled before the key", () => {
    assertRejects(`restrict,command="evil" ssh-ed25519 ${BLOB}`);
    assertRejects(`command="evil" ssh-ed25519 ${BLOB}`);
  });

  test("rejects a blob whose inner type disagrees with the outer type", () => {
    // Wire blob says ssh-rsa inside; outer says ssh-ed25519.
    const key = Buffer.alloc(32, 7);
    const type = Buffer.from("ssh-rsa", "utf8");
    const parts = [];
    for (const chunk of [type, key]) {
      const length = Buffer.alloc(4);
      length.writeUInt32BE(chunk.length);
      parts.push(length, chunk);
    }
    assertRejects(`ssh-ed25519 ${Buffer.concat(parts).toString("base64")}`);
  });

  test("rejects a blob with the wrong key length", () => {
    const key = Buffer.alloc(31, 7);
    const type = Buffer.from("ssh-ed25519", "utf8");
    const parts = [];
    for (const chunk of [type, key]) {
      const length = Buffer.alloc(4);
      length.writeUInt32BE(chunk.length);
      parts.push(length, chunk);
    }
    assertRejects(`ssh-ed25519 ${Buffer.concat(parts).toString("base64")}`);
  });

  test("rejects a blob with trailing bytes", () => {
    const raw = Buffer.concat([Buffer.from(BLOB, "base64"), Buffer.from([1])]);
    assertRejects(`ssh-ed25519 ${raw.toString("base64")}`);
  });

  test("rejects malformed input", () => {
    assertRejects("");
    assertRejects("   \n");
    assertRejects("ssh-ed25519");
    assertRejects("ssh-ed25519 !!!not-base64!!!");
    assertRejects("just some words");
  });

  test("rejects embedded newlines (no second authorized_keys line)", () => {
    assertRejects(`ssh-ed25519 ${BLOB} a\nssh-ed25519 ${BLOB} b`);
  });

  test("rejects comments with control or non-ASCII characters", () => {
    assertRejects(`ssh-ed25519 ${BLOB} bad\tcomment`);
    assertRejects(`ssh-ed25519 ${BLOB} bad\u0007comment`);
    assertRejects(`ssh-ed25519 ${BLOB} téléphone`);
  });

  test("rejects an overlong line", () => {
    assertRejects(`ssh-ed25519 ${BLOB} ${"x".repeat(2000)}`);
  });
});
