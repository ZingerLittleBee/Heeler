import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  configuredHostKeys,
  fingerprintPublicKeyLine,
  readHostKeyFingerprint,
} from "../src/host-key.js";

// Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
const ED25519_PUB =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC vector";
const ED25519_FP = "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg";

// A second, independent key used as the "key sshd actually presents" in the
// decoy tests (generated the same way; fingerprint confirmed via ssh-keygen).
const REAL_PUB =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPKIxtzX/9KSvoRqTXLNT7m+3bH6FDNWo8yoWFKmqmJV real";
const REAL_FP = "SHA256:FRSpPJp1w5dJZXFwrMGXXCDzN+A+TQZ6dUuNbG8zjmk";

// A scratch machine: <root>/etc/ssh as the conventional key directory and
// <root>/sshd_config as the sshd configuration, both disposable.
function makeMachine() {
  const root = mkdtempSync(join(tmpdir(), "pair-hostkey-"));
  const sshDir = join(root, "etc", "ssh");
  mkdirSync(sshDir, { recursive: true });
  return { root, sshDir, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

function noConfigs() {
  return ["/nonexistent-sshd-config"];
}

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
      const result = readHostKeyFingerprint(dir, { sshdConfigs: noConfigs() });
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
      const result = readHostKeyFingerprint(dir, { sshdConfigs: noConfigs() });
      assert.equal(result.fingerprint, ED25519_FP);
      assert.equal(result.path, join(dir, "ssh_host_rsa_key.pub"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("returns null when no host key exists", () => {
    const dir = mkdtempSync(join(tmpdir(), "pair-hostkey-"));
    try {
      assert.equal(readHostKeyFingerprint(dir, { sshdConfigs: noConfigs() }), null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("ignores a stale /etc/ssh decoy when sshd_config declares another HostKey", () => {
    // The reported pairing failure: sshd presents HostKey from a custom
    // directory while /etc/ssh still holds a different ed25519 key.
    const machine = makeMachine();
    try {
      writeFileSync(join(machine.sshDir, "ssh_host_ed25519_key.pub"), `${ED25519_PUB}\n`);
      const customDir = join(machine.root, "opt", "sunk", "etc", "ssh");
      mkdirSync(customDir, { recursive: true });
      writeFileSync(join(customDir, "ssh_host_ed25519_key.pub"), `${REAL_PUB}\n`);
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(
        sshdConfig,
        `HostKey ${join(customDir, "ssh_host_ed25519_key")}\nPasswordAuthentication no\n`,
      );
      const result = readHostKeyFingerprint(machine.sshDir, { sshdConfigs: [sshdConfig] });
      assert.notEqual(result, null);
      assert.equal(result.fingerprint, REAL_FP);
      assert.equal(result.path, join(customDir, "ssh_host_ed25519_key.pub"));
    } finally {
      machine.cleanup();
    }
  });

  test("skips a configured HostKey with no readable .pub and takes the next one", () => {
    const machine = makeMachine();
    try {
      const missingDir = join(machine.root, "missing", "etc", "ssh");
      const customDir = join(machine.root, "opt", "sunk", "etc", "ssh");
      mkdirSync(customDir, { recursive: true });
      writeFileSync(join(customDir, "ssh_host_ed25519_key.pub"), `${REAL_PUB}\n`);
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(
        sshdConfig,
        `HostKey ${join(missingDir, "ssh_host_ed25519_key")}\n` +
          `HostKey ${join(customDir, "ssh_host_ed25519_key")}\n`,
      );
      const result = readHostKeyFingerprint(machine.sshDir, { sshdConfigs: [sshdConfig] });
      assert.notEqual(result, null);
      assert.equal(result.fingerprint, REAL_FP);
      assert.equal(result.path, join(customDir, "ssh_host_ed25519_key.pub"));
    } finally {
      machine.cleanup();
    }
  });

  test("HEELER_SSH_HOST_KEY overrides config and /etc/ssh", () => {
    const machine = makeMachine();
    try {
      writeFileSync(join(machine.sshDir, "ssh_host_ed25519_key.pub"), `${ED25519_PUB}\n`);
      const customDir = join(machine.root, "opt", "sunk", "etc", "ssh");
      mkdirSync(customDir, { recursive: true });
      writeFileSync(join(customDir, "ssh_host_ed25519_key.pub"), `${REAL_PUB}\n`);
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(
        sshdConfig,
        `HostKey ${join(machine.root, "elsewhere", "ssh_host_ed25519_key")}\n`,
      );
      const env = {
        HEELER_SSH_HOST_KEY: join(customDir, "ssh_host_ed25519_key"),
      };
      const result = readHostKeyFingerprint(machine.sshDir, { env, sshdConfigs: [sshdConfig] });
      assert.notEqual(result, null);
      assert.equal(result.fingerprint, REAL_FP);
      assert.equal(result.path, join(customDir, "ssh_host_ed25519_key.pub"));
    } finally {
      machine.cleanup();
    }
  });

  test("HEELER_SSH_HOST_KEY accepts the .pub path itself", () => {
    const machine = makeMachine();
    try {
      const customDir = join(machine.root, "opt", "sunk", "etc", "ssh");
      mkdirSync(customDir, { recursive: true });
      writeFileSync(join(customDir, "ssh_host_ed25519_key.pub"), `${REAL_PUB}\n`);
      const env = { HEELER_SSH_HOST_KEY: join(customDir, "ssh_host_ed25519_key.pub") };
      const result = readHostKeyFingerprint(machine.sshDir, { env, sshdConfigs: noConfigs() });
      assert.notEqual(result, null);
      assert.equal(result.fingerprint, REAL_FP);
      assert.equal(result.path, join(customDir, "ssh_host_ed25519_key.pub"));
    } finally {
      machine.cleanup();
    }
  });

  test("a blank HEELER_SSH_HOST_KEY is ignored, not fatal", () => {
    const machine = makeMachine();
    try {
      writeFileSync(join(machine.sshDir, "ssh_host_ed25519_key.pub"), `${ED25519_PUB}\n`);
      const result = readHostKeyFingerprint(machine.sshDir, {
        env: { HEELER_SSH_HOST_KEY: "   " },
        sshdConfigs: noConfigs(),
      });
      assert.equal(result.fingerprint, ED25519_FP);
    } finally {
      machine.cleanup();
    }
  });

  test("fails instead of pinning a decoy when the configured HostKey's .pub is unreadable", () => {
    // sshd_config declares a HostKey whose public half cannot be read; the
    // stale /etc/ssh key must NOT be pinned (that is the reported bug), so
    // discovery fails and the popup tells the user to set the override.
    const machine = makeMachine();
    try {
      writeFileSync(join(machine.sshDir, "ssh_host_ed25519_key.pub"), `${ED25519_PUB}\n`);
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(
        sshdConfig,
        `HostKey ${join(machine.root, "missing", "ssh_host_ed25519_key")}\n`,
      );
      assert.equal(readHostKeyFingerprint(machine.sshDir, { sshdConfigs: [sshdConfig] }), null);
    } finally {
      machine.cleanup();
    }
  });
});

suite("configuredHostKeys", () => {
  test("collects HostKey lines from sshd_config and Include'd *.conf files", () => {
    const machine = makeMachine();
    try {
      const dropIn = join(machine.root, "sshd_config.d");
      mkdirSync(dropIn);
      writeFileSync(join(dropIn, "10-custom.conf"), `HostKey /opt/sunk/etc/ssh/ssh_host_ed25519_key\n`);
      writeFileSync(join(dropIn, "20-later.conf"), `Port 2222\n`);
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(
        sshdConfig,
        `# comment line\nHostKey /etc/ssh/ssh_host_rsa_key\nInclude ${join(dropIn, "*.conf")}\n`,
      );
      assert.deepEqual(configuredHostKeys([sshdConfig]), [
        "/etc/ssh/ssh_host_rsa_key",
        "/opt/sunk/etc/ssh/ssh_host_ed25519_key",
      ]);
    } finally {
      machine.cleanup();
    }
  });

  test("includes a drop-in directory lexically and dedupes repeated files", () => {
    const machine = makeMachine();
    try {
      const dropIn = join(machine.root, "sshd_config.d");
      mkdirSync(dropIn);
      writeFileSync(join(dropIn, "10-a.conf"), "HostKey /keys/a\n");
      writeFileSync(join(dropIn, "20-b.conf"), "HostKey /keys/b\n");
      writeFileSync(join(dropIn, "ignored.txt"), "HostKey /keys/nope\n");
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(sshdConfig, `Include ${dropIn}\nInclude ${join(dropIn, "10-a.conf")}\n`);
      assert.deepEqual(configuredHostKeys([sshdConfig]), ["/keys/a", "/keys/b"]);
    } finally {
      machine.cleanup();
    }
  });

  test("resolves a relative Include against the including file's directory", () => {
    const machine = makeMachine();
    try {
      const dropIn = join(machine.root, "sshd_config.d");
      mkdirSync(dropIn);
      writeFileSync(join(dropIn, "10-a.conf"), "HostKey /keys/a\n");
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(sshdConfig, "Include sshd_config.d\n");
      assert.deepEqual(configuredHostKeys([sshdConfig]), ["/keys/a"]);
    } finally {
      machine.cleanup();
    }
  });

  test("returns [] when no config exists", () => {
    assert.deepEqual(configuredHostKeys(noConfigs()), []);
  });

  test("case-insensitive keyword, inline comments, and missing values", () => {
    const machine = makeMachine();
    try {
      const sshdConfig = join(machine.root, "sshd_config");
      writeFileSync(
        sshdConfig,
        "hostkey /keys/lower\nHOSTKEY /keys/upper\nhostkey\nHostKey /keys/x # trailing comment\n",
      );
      assert.deepEqual(configuredHostKeys([sshdConfig]), [
        "/keys/lower",
        "/keys/upper",
        "/keys/x",
      ]);
    } finally {
      machine.cleanup();
    }
  });
});
