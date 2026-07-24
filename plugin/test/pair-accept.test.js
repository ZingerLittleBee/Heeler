// Lifecycle tests for the Enrollment accept entrypoint (ADR 0007).
//
// pair-accept.js runs as an sshd forced command, so these tests exercise it
// the same way: a real child process with a faked minimal environment and a
// temp HOME. Real sshd semantics (restrict, forced command, StrictModes) are
// covered by the app-side e2e suite against localhost sshd.

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { beginPairing, pendingPath } from "../src/pairing-session.js";
import { authorizedKeysPath, editAuthorizedKeys, parseBootstrapLine } from "../src/authorized-keys.js";

const ACCEPT_SCRIPT = fileURLToPath(new URL("../src/pair-accept.js", import.meta.url));

// Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
const DEVICE_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce herdr-mobile";
const DEVICE_FINGERPRINT = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";
const USER_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";

let home;
let stateDir;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "pair-accept-"));
  stateDir = join(home, "plugin-state");
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

function runAccept(pairingId, input) {
  const result = spawnSync(
    process.execPath,
    [ACCEPT_SCRIPT, "--state-dir", stateDir, "--pairing-id", pairingId],
    { input, encoding: "utf8", env: { HOME: home, PATH: process.env.PATH }, timeout: 15_000 },
  );
  assert.equal(result.error, undefined);
  return result;
}

function readKeys() {
  return readFileSync(authorizedKeysPath(home), "utf8");
}

function bootstrapLinesIn(content) {
  return content
    .trimEnd()
    .split("\n")
    .filter((line) => parseBootstrapLine(line) !== null);
}

suite("pair-accept", () => {
  test("enrolls a valid Device Key and self-revokes the bootstrap line", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    const session = await beginPairing({ home, stateDir });

    const result = runAccept(session.pairingId, `${DEVICE_LINE}\n`);

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), `HERDR-ENROLL:OK:${DEVICE_FINGERPRINT}`);
    assert.equal(readKeys(), `${USER_LINE}\n${DEVICE_LINE}\n`);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
  });

  test("an invalid submission does not consume the bootstrap line; retry works", async () => {
    const session = await beginPairing({ home, stateDir });

    const invalid = runAccept(session.pairingId, "ssh-rsa AAAAB3nope\n");
    assert.equal(invalid.status, 1);
    assert.equal(invalid.stdout.trim(), "HERDR-ENROLL:ERR:invalid_key");
    assert.equal(bootstrapLinesIn(readKeys()).length, 1);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), true);

    const retry = runAccept(session.pairingId, `${DEVICE_LINE}\n`);
    assert.equal(retry.status, 0, retry.stderr);
    assert.equal(readKeys(), `${DEVICE_LINE}\n`);
  });

  test("an empty submission is rejected without consuming the line", async () => {
    const session = await beginPairing({ home, stateDir });
    const result = runAccept(session.pairingId, "");
    assert.equal(result.status, 1);
    assert.equal(result.stdout.trim(), "HERDR-ENROLL:ERR:no_input");
    assert.equal(bootstrapLinesIn(readKeys()).length, 1);
  });

  test("an expired pairing removes its line and rejects", async () => {
    const past = Math.floor(Date.now() / 1000) - 600;
    const session = await beginPairing({ home, stateDir, now: past });

    const result = runAccept(session.pairingId, `${DEVICE_LINE}\n`);

    assert.equal(result.status, 1);
    assert.equal(result.stdout.trim(), "HERDR-ENROLL:ERR:expired");
    assert.equal(bootstrapLinesIn(readKeys()).length, 0);
    assert.equal(readKeys().includes(DEVICE_LINE), false);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
  });

  test("an unknown pairing id is rejected", async () => {
    await beginPairing({ home, stateDir });
    const result = runAccept("deadbeef0000", `${DEVICE_LINE}\n`);
    assert.equal(result.status, 1);
    assert.equal(result.stdout.trim(), "HERDR-ENROLL:ERR:unknown_pairing");
  });

  test("the bootstrap line is single use", async () => {
    const session = await beginPairing({ home, stateDir });

    const first = runAccept(session.pairingId, `${DEVICE_LINE}\n`);
    assert.equal(first.status, 0, first.stderr);

    const second = runAccept(session.pairingId, `${DEVICE_LINE}\n`);
    assert.equal(second.status, 1);
    assert.equal(second.stdout.trim(), "HERDR-ENROLL:ERR:unknown_pairing");
    assert.equal(readKeys(), `${DEVICE_LINE}\n`);
  });

  test("re-enrolling an already-authorized Device Key succeeds without a duplicate", async () => {
    const first = await beginPairing({ home, stateDir });
    runAccept(first.pairingId, `${DEVICE_LINE}\n`);

    const second = await beginPairing({ home, stateDir });
    const result = runAccept(second.pairingId, `${DEVICE_LINE}\n`);

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), `HERDR-ENROLL:OK:${DEVICE_FINGERPRINT}`);
    assert.equal(readKeys(), `${DEVICE_LINE}\n`);
  });
});
