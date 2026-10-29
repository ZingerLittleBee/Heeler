import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeAccounts, readAccountFile } from "../src/usage/accounts.js";
import { usageRoots } from "../src/usage/cache.js";

test("the Default Account is the directory Claude Code uses, without ~/.claude when CLAUDE_CONFIG_DIR is recorded", () => {
  const env = { HOME: "/home/u", CLAUDE_CONFIG_DIR: null, XDG_CONFIG_HOME: null, CODEX_HOME: null };
  assert.deepEqual(usageRoots({ env }).claude, ["/home/u/.claude", "/home/u/.config/claude"]);
  assert.deepEqual(usageRoots({ env: { ...env, CLAUDE_CONFIG_DIR: "/data/claude", XDG_CONFIG_HOME: "/xdg" } }).claude, ["/data/claude", "/xdg/claude"]);
  // A relative value is resolved against the recorded HOME, and a repeat folds away.
  assert.deepEqual(usageRoots({ env: { ...env, CLAUDE_CONFIG_DIR: ".config/claude" } }).claude, ["/home/u/.config/claude"]);
  const [account] = claudeAccounts({ env: { ...env, CLAUDE_CONFIG_DIR: "/data/claude" } }, { defaultName: "Work", accounts: [] });
  assert.deepEqual(account, { id: "default", isDefault: true, name: "Work", directory: "/data/claude", roots: ["/data/claude", "/home/u/.config/claude"], state: "ok" });
});

test("an Account file that is missing, malformed or of another version adds no Account, and broken entries are skipped", t => {
  const root = mkdtempSync(join(tmpdir(), "heeler-account-file-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const empty = { defaultName: null, accounts: [], ignored: [] };
  assert.deepEqual(readAccountFile(root), empty);
  const path = join(root, "usage-accounts.json");
  const entry = { id: "7f3c9a2e", directory: "/home/u/.claude-2", name: "claude-2" };
  for (const contents of ["not json", "[]", JSON.stringify({ version: 2, claude: { accounts: [entry] } }), JSON.stringify({ version: 1, claude: [] })]) {
    writeFileSync(path, contents);
    assert.deepEqual(readAccountFile(root), empty);
  }
  writeFileSync(path, JSON.stringify({ version: 1, claude: { defaultName: "Main", ignored: ["/home/u/.claude-old", "relative", 7], accounts: [
    entry,
    { ...entry, name: "same id" },
    { ...entry, id: "default", name: "reserved" },
    { ...entry, id: "short", name: "short id" },
    { ...entry, id: "has space!", name: "bad id" },
    { ...entry, id: "a".repeat(33), name: "long id" },
    { ...entry, id: "relative1", directory: "home/u/.claude-3", name: "relative" },
    { ...entry, id: "noname01", name: " " },
    { ...entry, id: "samename", name: "claude-2" },
    { ...entry, id: "sameasdf", name: "Main" },
    "not an entry",
    { id: "work_1-A", directory: "/Volumes/x/.claude", name: "work" },
  ] } }));
  assert.deepEqual(readAccountFile(root), { defaultName: "Main", ignored: ["/home/u/.claude-old"],
    accounts: [entry, { id: "work_1-A", directory: "/Volumes/x/.claude", name: "work" }] });
});

test("added Accounts are missing, duplicate by real path, over the limit or ok, in file order", t => {
  const root = mkdtempSync(join(tmpdir(), "heeler-account-states-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const directory = name => { const path = join(root, name); mkdirSync(path, { recursive: true }); return path; };
  const primary = directory("claude");
  symlinkSync(primary, join(root, "link-to-default"));
  const one = directory("one");
  symlinkSync(one, join(root, "link-to-one"));
  writeFileSync(join(root, "a-file"), "");
  const entries = [
    ["missing1", join(root, "gone")], ["notadir1", join(root, "a-file")], ["default1", join(root, "link-to-default")],
    ["legacy01", join(directory("home/.config/claude"), ".")],
    ["account1", one], ["again001", join(root, "link-to-one")], ["account2", directory("two")], ["account3", directory("three")],
    ["account4", directory("four")], ["account5", join(root, "four")],
  ];
  const accounts = claudeAccounts({ env: { HOME: home, CLAUDE_CONFIG_DIR: primary } },
    { defaultName: null, accounts: entries.map(([id, path]) => ({ id, directory: path, name: id })) });
  assert.deepEqual(accounts.map(account => [account.id, account.state]), [["default", "ok"],
    ["missing1", "missing"], ["notadir1", "missing"], ["default1", "duplicate"], ["legacy01", "duplicate"],
    ["account1", "ok"], ["again001", "duplicate"], ["account2", "ok"], ["account3", "ok"], ["account4", "overLimit"], ["account5", "duplicate"]]);
  // The directory stays as chosen: Claude Code keys its keychain item by that string.
  assert.deepEqual(accounts[6], { id: "again001", isDefault: false, name: "again001", directory: join(root, "link-to-one"), roots: [join(root, "link-to-one")], state: "duplicate" });
});
