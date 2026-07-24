import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { fingerprintPublicKeyLine, readHostKeyFingerprint } from "../src/host-key.js";

// Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
const ED25519_PUB =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC vector";
const ED25519_FP = "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg";

suite("fingerprintPublicKeyLine", () => {
  test("matches ssh-keygen -lf output", () => {
    assert.deepEqual(fingerprintPublicKeyLine(ED25519_PUB), {
      keyType: "ssh-ed25519",
      fingerprint: ED25519_FP,
    });
  });

  test("accepts a line without a comment", () => {
    const [keyType, blob] = ED25519_PUB.split(" ");
    assert.equal(fingerprintPublicKeyLine(`${keyType} ${blob}`).fingerprint, ED25519_FP);
  });

  test("rejects garbage", () => {
    for (const line of ["", "ssh-ed25519", "ssh-ed25519 !!!", "just words here"]) {
      assert.throws(() => fingerprintPublicKeyLine(line));
    }
  });
});

suite("readHostKeyFingerprint", () => {
  test("prefers ed25519 over other host keys", () => {
    const dir = mkdtempSync(join(tmpdir(), "pair-hostkey-"));
    try {
      writeFileSync(join(dir, "ssh_host_rsa_key.pub"), `${ED25519_PUB}\n`);
      writeFileSync(join(dir, "ssh_host_ed25519_key.pub"), `${ED25519_PUB}\n`);
      const result = readHostKeyFingerprint(dir);
      assert.equal(result.fingerprint, ED25519_FP);
      assert.equal(result.path, join(dir, "ssh_host_ed25519_key.pub"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("falls back to the next key type when ed25519 is missing", () => {
    const dir = mkdtempSync(join(tmpdir(), "pair-hostkey-"));
    try {
      writeFileSync(join(dir, "ssh_host_rsa_key.pub"), `${ED25519_PUB}\n`);
      const result = readHostKeyFingerprint(dir);
      assert.equal(result.fingerprint, ED25519_FP);
      assert.equal(result.path, join(dir, "ssh_host_rsa_key.pub"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("returns null when no host key exists", () => {
    const dir = mkdtempSync(join(tmpdir(), "pair-hostkey-"));
    try {
      assert.equal(readHostKeyFingerprint(dir), null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
