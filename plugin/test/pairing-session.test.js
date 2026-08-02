import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  beginPairing,
  endPairing,
  enrolledPath,
  expirePairing,
  pendingPath,
  readEnrollment,
  recordEnrollment,
  sweepExpiredStateFiles,
  PAIRING_TTL_SECONDS,
} from "../src/pairing-session.js";
import { authorizedKeysPath, parseBootstrapLine, editAuthorizedKeys } from "../src/authorized-keys.js";
import { publicLineFromSeed } from "../src/bootstrap-key.js";

const ACCEPT_SCRIPT = fileURLToPath(new URL("../src/pair-accept.js", import.meta.url));
const USER_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";
const NOW = 1753305600;

let home;
let stateDir;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "pair-home-"));
  stateDir = join(home, "plugin-state");
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

function readKeys() {
  return readFileSync(authorizedKeysPath(home), "utf8");
}

suite("beginPairing", () => {
  test("writes a restricted bootstrap line and matching pending state", async () => {
    const session = await beginPairing({ home, stateDir, now: NOW });

    assert.equal(session.seed.length, 32);
    assert.equal(session.expiresAt, NOW + PAIRING_TTL_SECONDS);
    assert.equal(session.publicLine, publicLineFromSeed(session.seed));

    const lines = readKeys().trimEnd().split("\n");
    assert.equal(lines.length, 1);
    const line = lines[0];
    assert.ok(line.startsWith('restrict,command="'), "line must start with restrict,command=");
    assert.ok(line.includes(`'${process.execPath}'`), "command must pin the node binary");
    assert.ok(line.includes(`'${ACCEPT_SCRIPT}'`), "command must point at pair-accept.js");
    assert.ok(line.includes(`--state-dir '${stateDir}'`), "command must carry the state dir");
    assert.ok(line.includes(`--pairing-id ${session.pairingId}`), "command must carry the id");
    assert.ok(line.includes(session.publicLine), "line must carry the bootstrap public key");
    assert.deepEqual(parseBootstrapLine(line), {
      pairingId: session.pairingId,
      expiresAt: session.expiresAt,
    });

    const pending = JSON.parse(readFileSync(pendingPath(stateDir, session.pairingId), "utf8"));
    assert.equal(pending.pairingId, session.pairingId);
    assert.equal(pending.expiresAt, session.expiresAt);
    assert.equal(pending.publicLine, session.publicLine);
    assert.equal(statSync(pendingPath(stateDir, session.pairingId)).mode & 0o777, 0o600);
  });

  test("keeps existing authorized_keys entries", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    await beginPairing({ home, stateDir, now: NOW });
    assert.ok(readKeys().startsWith(`${USER_LINE}\n`));
  });

  test("rejects a state dir the forced command cannot quote", async () => {
    await assert.rejects(
      beginPairing({ home, stateDir: join(home, "state'dir"), now: NOW }),
    );
  });
});

const DEVICE_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce heeler";
const DEVICE_FINGERPRINT = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";

suite("enrollment record", () => {
  test("round-trips fingerprint, line, and expiry, written 0600", () => {
    recordEnrollment({
      stateDir,
      pairingId: "abc123",
      expiresAt: NOW,
      fingerprint: DEVICE_FINGERPRINT,
      line: DEVICE_LINE,
    });
    assert.deepEqual(readEnrollment(stateDir, "abc123"), {
      pairingId: "abc123",
      expiresAt: NOW,
      fingerprint: DEVICE_FINGERPRINT,
      line: DEVICE_LINE,
    });
    assert.equal(statSync(enrolledPath(stateDir, "abc123")).mode & 0o777, 0o600);
  });

  test("readEnrollment is null when there is no record", () => {
    assert.equal(readEnrollment(stateDir, "missing"), null);
  });
});

suite("sweepExpiredStateFiles", () => {
  // Real clock: the sweep's fallback for unreadable files compares mtime.
  const now = Math.floor(Date.now() / 1000);

  function enrolledRecord(pairingId, expiresAt) {
    recordEnrollment({
      stateDir,
      pairingId,
      expiresAt,
      fingerprint: DEVICE_FINGERPRINT,
      line: DEVICE_LINE,
    });
  }

  test("removes expired pending and stale enrolled records, keeps live ones", async () => {
    const dead = await beginPairing({ home, stateDir, now: now - 10 * PAIRING_TTL_SECONDS });
    const live = await beginPairing({ home, stateDir, now });
    enrolledRecord("stale", now - 10 * PAIRING_TTL_SECONDS);
    enrolledRecord("fresh", now + PAIRING_TTL_SECONDS);

    assert.equal(sweepExpiredStateFiles(stateDir, now), 2);

    assert.equal(existsSync(pendingPath(stateDir, dead.pairingId)), false);
    assert.equal(existsSync(pendingPath(stateDir, live.pairingId)), true);
    assert.equal(readEnrollment(stateDir, "stale"), null);
    assert.notEqual(readEnrollment(stateDir, "fresh"), null);
  });

  test("keeps an enrolled record inside its grace window", () => {
    // Just past its ceremony's expiry: a live popup may not have read it yet.
    enrolledRecord("graceful", now - 1);
    assert.equal(sweepExpiredStateFiles(stateDir, now), 0);
    assert.notEqual(readEnrollment(stateDir, "graceful"), null);
  });

  test("ages out unreadable state files by mtime", () => {
    mkdirSync(join(stateDir, "pending"), { recursive: true });
    const stale = join(stateDir, "pending", "garbage-old.json");
    writeFileSync(stale, "not json");
    utimesSync(stale, now - 3600, now - 3600);
    const fresh = join(stateDir, "pending", "garbage-new.json");
    writeFileSync(fresh, "not json");

    assert.equal(sweepExpiredStateFiles(stateDir, now), 1);
    assert.equal(existsSync(stale), false);
    assert.equal(existsSync(fresh), true);
  });

  test("is a no-op when the state dir does not exist yet", () => {
    assert.equal(sweepExpiredStateFiles(join(home, "no-such-state")), 0);
  });
});

suite("expirePairing", () => {
  test("removes the bootstrap line and pending state when nothing enrolled", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    const session = await beginPairing({ home, stateDir, now: NOW });

    const record = await expirePairing({ home, stateDir, pairingId: session.pairingId });

    assert.equal(record, null);
    assert.equal(readKeys(), `${USER_LINE}\n`);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
  });

  test("returns the enrollment record and touches nothing when a device enrolled", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    const session = await beginPairing({ home, stateDir, now: NOW });
    recordEnrollment({
      stateDir,
      pairingId: session.pairingId,
      expiresAt: session.expiresAt,
      fingerprint: DEVICE_FINGERPRINT,
      line: DEVICE_LINE,
    });
    const keysBefore = readKeys();

    const record = await expirePairing({ home, stateDir, pairingId: session.pairingId });

    assert.equal(record?.fingerprint, DEVICE_FINGERPRINT);
    assert.equal(record?.line, DEVICE_LINE);
    assert.equal(readKeys(), keysBefore);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), true);
    assert.equal(existsSync(enrolledPath(stateDir, session.pairingId)), true);
  });
});

suite("endPairing", () => {
  test("removes the bootstrap line, the pending state, and the enrollment record", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    const session = await beginPairing({ home, stateDir, now: NOW });
    recordEnrollment({
      stateDir,
      pairingId: session.pairingId,
      fingerprint: DEVICE_FINGERPRINT,
      line: DEVICE_LINE,
    });
    await endPairing({ home, stateDir, pairingId: session.pairingId });
    assert.equal(readKeys(), `${USER_LINE}\n`);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
    assert.equal(existsSync(enrolledPath(stateDir, session.pairingId)), false);
  });

  test("is idempotent", async () => {
    const session = await beginPairing({ home, stateDir, now: NOW });
    await endPairing({ home, stateDir, pairingId: session.pairingId });
    await endPairing({ home, stateDir, pairingId: session.pairingId });
    assert.equal(readKeys(), "");
  });
});
