import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { beginPairing, endPairing, pendingPath, PAIRING_TTL_SECONDS } from "../src/pairing-session.js";
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

suite("endPairing", () => {
  test("removes the bootstrap line and the pending state", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    const session = await beginPairing({ home, stateDir, now: NOW });
    await endPairing({ home, stateDir, pairingId: session.pairingId });
    assert.equal(readKeys(), `${USER_LINE}\n`);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
  });

  test("is idempotent", async () => {
    const session = await beginPairing({ home, stateDir, now: NOW });
    await endPairing({ home, stateDir, pairingId: session.pairingId });
    await endPairing({ home, stateDir, pairingId: session.pairingId });
    assert.equal(readKeys(), "");
  });
});
