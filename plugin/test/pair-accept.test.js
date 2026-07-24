// Lifecycle tests for the Enrollment accept entrypoint (ADR 0007).
//
// pair-accept.js runs as an sshd forced command, so these tests exercise it
// the same way: a real child process with a faked minimal environment and a
// temp HOME. Real sshd semantics (restrict, forced command, StrictModes) are
// covered by the app-side e2e suite against localhost sshd.

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { beginPairing, expirePairing, pendingPath, readEnrollment } from "../src/pairing-session.js";
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

// Async counterpart to runAccept: spawn without blocking so two accepts can
// race against the same pairing in a single event loop.
function runAcceptAsync(pairingId, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [ACCEPT_SCRIPT, "--state-dir", stateDir, "--pairing-id", pairingId],
      { env: { HOME: home, PATH: process.env.PATH } },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
    child.stdin.end(input);
  });
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
    // The popup reads this record to show the enrolled fingerprint and revoke;
    // the expiry lets the startup sweep age out records a killed popup left.
    assert.deepEqual(readEnrollment(stateDir, session.pairingId), {
      pairingId: session.pairingId,
      expiresAt: session.expiresAt,
      fingerprint: DEVICE_FINGERPRINT,
      line: DEVICE_LINE,
    });
  });

  test("a rejected submission leaves no enrollment record", async () => {
    const session = await beginPairing({ home, stateDir });
    runAccept(session.pairingId, "ssh-rsa AAAAB3nope\n");
    assert.equal(readEnrollment(stateDir, session.pairingId), null);
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

  test("expiring after an enroll returns the record instead of expiring", async () => {
    const session = await beginPairing({ home, stateDir });
    const accept = runAccept(session.pairingId, `${DEVICE_LINE}\n`);
    assert.equal(accept.status, 0, accept.stderr);

    const record = await expirePairing({ home, stateDir, pairingId: session.pairingId });

    assert.equal(record?.fingerprint, DEVICE_FINGERPRINT);
    assert.ok(readKeys().includes(DEVICE_LINE));
    // The record survives so the popup can still offer the revoke.
    assert.notEqual(readEnrollment(stateDir, session.pairingId), null);
  });

  test("expiring before the accept runs consumes the pairing", async () => {
    const session = await beginPairing({ home, stateDir });

    const record = await expirePairing({ home, stateDir, pairingId: session.pairingId });
    assert.equal(record, null);

    const result = runAccept(session.pairingId, `${DEVICE_LINE}\n`);
    assert.equal(result.status, 1);
    assert.equal(result.stdout.trim(), "HERDR-ENROLL:ERR:unknown_pairing");
    assert.equal(readKeys().includes(DEVICE_LINE), false);
    assert.equal(readEnrollment(stateDir, session.pairingId), null);
  });

  test("an expiry racing an accept never enrolls a device silently", async () => {
    const session = await beginPairing({ home, stateDir });

    const [result, record] = await Promise.all([
      runAcceptAsync(session.pairingId, `${DEVICE_LINE}\n`),
      expirePairing({ home, stateDir, pairingId: session.pairingId }),
    ]);

    if (readKeys().includes(DEVICE_LINE)) {
      // The accept won: the popup's locked expiry check must have seen the
      // record, or it would render "expired" over a silently enrolled device.
      assert.equal(result.stdout.trim(), `HERDR-ENROLL:OK:${DEVICE_FINGERPRINT}`);
      assert.equal(record?.fingerprint, DEVICE_FINGERPRINT);
    } else {
      // The expiry won: nothing enrolled, no record, the accept rejected.
      assert.equal(record, null);
      assert.equal(result.status, 1);
      assert.equal(readEnrollment(stateDir, session.pairingId), null);
    }
    assert.equal(bootstrapLinesIn(readKeys()).length, 0);
  });

  test("two concurrent accepts enroll the Device Key exactly once", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    const session = await beginPairing({ home, stateDir });

    const [a, b] = await Promise.all([
      runAcceptAsync(session.pairingId, `${DEVICE_LINE}\n`),
      runAcceptAsync(session.pairingId, `${DEVICE_LINE}\n`),
    ]);

    // Exactly one winner enrolls; the loser sees the pairing already consumed.
    const outcomes = [a.stdout.trim(), b.stdout.trim()].sort();
    assert.deepEqual(outcomes, [
      "HERDR-ENROLL:ERR:unknown_pairing",
      `HERDR-ENROLL:OK:${DEVICE_FINGERPRINT}`,
    ]);

    // One Device Key line, no leftover bootstrap line.
    assert.equal(readKeys(), `${USER_LINE}\n${DEVICE_LINE}\n`);
    assert.equal(bootstrapLinesIn(readKeys()).length, 0);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
  });
});
