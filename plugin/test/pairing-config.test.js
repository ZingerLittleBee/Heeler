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

function makeConfigDir() {
  configDir = mkdtempSync(join(tmpdir(), "pairing-config-"));
  return configDir;
}

function writeRawConfig(contents) {
  writeFileSync(join(makeConfigDir(), "pair.json"), contents);
}

function writeConfig(config) {
  writeRawConfig(JSON.stringify(config));
}

suite("pairing config", () => {
  test("defaults to port 22 when pair.json is absent", () => {
    assert.deepEqual(readPairingConfig(makeConfigDir()), {
      sshPort: DEFAULT_SSH_PORT,
      warning: null,
    });
  });

  test("defaults when the config directory is unset", () => {
    assert.deepEqual(readPairingConfig(undefined), {
      sshPort: DEFAULT_SSH_PORT,
      warning: null,
    });
  });

  test("preserves an explicit OpenSSH port", () => {
    writeConfig({ ssh_port: 2222 });

    assert.deepEqual(readPairingConfig(configDir), { sshPort: 2222, warning: null });
  });

  test("warns instead of silently falling back on an unusable port", () => {
    for (const ssh_port of [22.5, 0, -1, 65536, "2222", null]) {
      writeConfig({ ssh_port });

      const { sshPort, warning } = readPairingConfig(configDir);
      assert.equal(sshPort, DEFAULT_SSH_PORT);
      assert.match(warning, /ssh_port/);
      assert.ok(
        warning.includes(JSON.stringify(ssh_port)),
        `warning should quote the rejected value: ${warning}`,
      );

      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("ignores unrelated fields", () => {
    writeConfig({ ssh_port: 2222, relay_url: "https://example.com" });

    assert.deepEqual(readPairingConfig(configDir), { sshPort: 2222, warning: null });
  });

  test("stays quiet when pair.json omits ssh_port", () => {
    writeConfig({ relay_url: "https://example.com" });

    assert.deepEqual(readPairingConfig(configDir), {
      sshPort: DEFAULT_SSH_PORT,
      warning: null,
    });
  });

  test("warns when pair.json is corrupt", () => {
    writeRawConfig("{not json");

    const { sshPort, warning } = readPairingConfig(configDir);
    assert.equal(sshPort, DEFAULT_SSH_PORT);
    assert.match(warning, /not valid JSON/);
  });

  test("warns when pair.json holds something other than an object", () => {
    for (const contents of ["null", "[]", '"2222"']) {
      writeRawConfig(contents);

      const { sshPort, warning } = readPairingConfig(configDir);
      assert.equal(sshPort, DEFAULT_SSH_PORT);
      assert.match(warning, /not a JSON object/);

      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("warns when pair.json cannot be read", () => {
    // A directory in pair.json's place fails with EISDIR, standing in for the
    // unreadable-file cases (EACCES) that a test cannot create as root.
    mkdirSync(join(makeConfigDir(), "pair.json"));

    const { sshPort, warning } = readPairingConfig(configDir);
    assert.equal(sshPort, DEFAULT_SSH_PORT);
    assert.match(warning, /could not be read/);
  });
});
