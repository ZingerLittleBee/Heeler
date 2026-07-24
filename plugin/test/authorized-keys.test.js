import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  authorizedKeysPath,
  bootstrapLine,
  editAuthorizedKeys,
  removeBootstrapLine,
  sweepExpiredBootstrapLines,
  appendDeviceKeyLine,
} from "../src/authorized-keys.js";

const PUBLIC_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce";
const USER_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";

let home;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "pair-ak-"));
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

function readKeys() {
  return readFileSync(authorizedKeysPath(home), "utf8");
}

function mode(path) {
  return statSync(path).mode & 0o777;
}

suite("bootstrapLine", () => {
  test("carries restrict, the forced command, and the marker comment", () => {
    const line = bootstrapLine({
      publicLine: PUBLIC_LINE,
      pairingId: "abc123",
      expiresAt: 1753305600,
      command: "'/usr/local/bin/node' '/plug/src/pair-accept.js' --pairing-id abc123",
    });
    assert.equal(
      line,
      `restrict,command="'/usr/local/bin/node' '/plug/src/pair-accept.js' --pairing-id abc123" ${PUBLIC_LINE} herdr-pairing:abc123:exp:1753305600`,
    );
  });

  test("rejects a command containing a double quote or newline", () => {
    for (const command of ['echo "hi"', "line1\nline2"]) {
      assert.throws(() =>
        bootstrapLine({ publicLine: PUBLIC_LINE, pairingId: "a", expiresAt: 1, command }),
      );
    }
  });
});

suite("editAuthorizedKeys", () => {
  test("creates ~/.ssh and authorized_keys with StrictModes-safe permissions", async () => {
    await editAuthorizedKeys(home, (lines) => [...lines, USER_LINE]);
    assert.equal(readKeys(), `${USER_LINE}\n`);
    assert.equal(mode(join(home, ".ssh")), 0o700);
    assert.equal(mode(authorizedKeysPath(home)), 0o600);
  });

  test("preserves existing content, order, and file mode", async () => {
    mkdirSync(join(home, ".ssh"), { mode: 0o700 });
    writeFileSync(authorizedKeysPath(home), `# comment\n\n${USER_LINE}\n`);
    chmodSync(authorizedKeysPath(home), 0o644);
    await editAuthorizedKeys(home, (lines) => [...lines, PUBLIC_LINE]);
    assert.equal(readKeys(), `# comment\n\n${USER_LINE}\n${PUBLIC_LINE}\n`);
    assert.equal(mode(authorizedKeysPath(home)), 0o644);
  });

  test("serializes concurrent edits", async () => {
    const appends = Array.from({ length: 8 }, (_, i) =>
      editAuthorizedKeys(home, (lines) => [...lines, `${PUBLIC_LINE} key-${i}`]),
    );
    await Promise.all(appends);
    const lines = readKeys().trimEnd().split("\n");
    assert.equal(lines.length, 8);
    for (let i = 0; i < 8; i += 1) {
      assert.ok(lines.includes(`${PUBLIC_LINE} key-${i}`), `missing key-${i}`);
    }
  });
});

suite("removeBootstrapLine", () => {
  test("removes only the line with the given pairing id", async () => {
    const mine = bootstrapLine({
      publicLine: PUBLIC_LINE,
      pairingId: "mine",
      expiresAt: 2000000000,
      command: "cmd",
    });
    const other = bootstrapLine({
      publicLine: PUBLIC_LINE,
      pairingId: "other",
      expiresAt: 2000000000,
      command: "cmd",
    });
    await editAuthorizedKeys(home, () => [USER_LINE, mine, other]);
    await removeBootstrapLine(home, "mine");
    assert.equal(readKeys(), `${USER_LINE}\n${other}\n`);
  });

  test("is a no-op when the file does not exist", async () => {
    await removeBootstrapLine(home, "mine");
    assert.equal(existsSync(authorizedKeysPath(home)), false);
  });
});

suite("sweepExpiredBootstrapLines", () => {
  test("removes expired pairing lines, keeps live ones and user lines", async () => {
    const now = 1753305600;
    const expired = bootstrapLine({
      publicLine: PUBLIC_LINE,
      pairingId: "old",
      expiresAt: now - 1,
      command: "cmd",
    });
    const live = bootstrapLine({
      publicLine: PUBLIC_LINE,
      pairingId: "new",
      expiresAt: now + 60,
      command: "cmd",
    });
    await editAuthorizedKeys(home, () => [USER_LINE, expired, live]);
    const removed = await sweepExpiredBootstrapLines(home, now);
    assert.equal(removed, 1);
    assert.equal(readKeys(), `${USER_LINE}\n${live}\n`);
  });

  test("is a no-op when the file does not exist", async () => {
    assert.equal(await sweepExpiredBootstrapLines(home, 1753305600), 0);
    assert.equal(existsSync(authorizedKeysPath(home)), false);
  });
});

suite("appendDeviceKeyLine", () => {
  test("appends the line", async () => {
    await editAuthorizedKeys(home, () => [USER_LINE]);
    await appendDeviceKeyLine(home, `${PUBLIC_LINE} phone`);
    assert.equal(readKeys(), `${USER_LINE}\n${PUBLIC_LINE} phone\n`);
  });

  test("does not duplicate an already-authorized key", async () => {
    await editAuthorizedKeys(home, () => [`${PUBLIC_LINE} phone`]);
    await appendDeviceKeyLine(home, `${PUBLIC_LINE} renamed-phone`);
    assert.equal(readKeys(), `${PUBLIC_LINE} phone\n`);
  });
});
