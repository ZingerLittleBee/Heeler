import { afterEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULT_SSH_PORT, readPairingConfig } from "../src/pairing-config.js";

let configDir;

afterEach(() => {
  if (configDir) rmSync(configDir, { recursive: true, force: true });
  configDir = undefined;
});

function writeConfig(config) {
  configDir = mkdtempSync(join(tmpdir(), "pairing-config-"));
  mkdirSync(configDir, { recursive: true });
  writeFileSync(join(configDir, "pair.json"), JSON.stringify(config));
}

suite("pairing config", () => {
  test("defaults to port 22 when pair.json is absent", () => {
    configDir = mkdtempSync(join(tmpdir(), "pairing-config-"));

    assert.deepEqual(readPairingConfig(configDir), { sshPort: DEFAULT_SSH_PORT });
  });

  test("defaults when the config directory is unset", () => {
    assert.deepEqual(readPairingConfig(undefined), { sshPort: DEFAULT_SSH_PORT });
  });

  test("preserves an explicit OpenSSH port", () => {
    writeConfig({ ssh_port: 2222 });

    assert.equal(readPairingConfig(configDir).sshPort, 2222);
  });

  test("rejects a non-integer, zero, or out-of-range port", () => {
    for (const ssh_port of [22.5, 0, -1, 65536, "2222", null]) {
      writeConfig({ ssh_port });
      assert.equal(readPairingConfig(configDir).sshPort, DEFAULT_SSH_PORT);
      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("ignores unrelated fields", () => {
    writeConfig({ ssh_port: 2222, relay_url: "https://example.com" });

    assert.deepEqual(readPairingConfig(configDir), { sshPort: 2222 });
  });

  test("defaults when pair.json is corrupt", () => {
    configDir = mkdtempSync(join(tmpdir(), "pairing-config-"));
    writeFileSync(join(configDir, "pair.json"), "{not json");

    assert.deepEqual(readPairingConfig(configDir), { sshPort: DEFAULT_SSH_PORT });
  });
});
