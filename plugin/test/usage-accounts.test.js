import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { appendFileSync, chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { claudeAccounts, readAccountFile } from "../src/usage/accounts.js";
import { usageRoots } from "../src/usage/cache.js";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const asRoot = process.getuid?.() === 0 && "root ignores directory modes";
const records = lines => lines.map(line => JSON.stringify(line)).join("\n") + "\n";
const assistant = (id, input, extra = {}) => ({ type: "assistant", sessionId: "session", requestId: `request-${id}`, timestamp: new Date().toISOString(),
  cwd: "/work/project", message: { id, model: "claude-test", usage: { input_tokens: input } }, ...extra });
const claudeOf = report => report.programs.find(program => program.program === "claude");
const total = usage => usage?.totals?.last30Days.tokens.total ?? 0;
const totals = report => [total(claudeOf(report).tokenUsage), ...claudeOf(report).accounts.map(account => account.tokenUsage && total(account.tokenUsage))];

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-accounts-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"), CODEX_HOME: join(root, "codex"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const run = (name, args = []) => spawnSync(process.execPath, [join(plugin, "src", name), ...args], { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  const caches = () => readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"));
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", caches()[0]);
  const query = () => { const result = run("usage-query.js", ["--tz", "UTC"]); assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout); };
  const finish = async () => { for (let i = 0; i < 400; i++) { const report = query(); if (!report.refreshing) return report; await sleep(15); } assert.fail("worker did not finish"); };
  const stale = () => { const path = join(cache(), "buckets.json"); const snapshot = JSON.parse(readFileSync(path)); snapshot.generatedAt = new Date(Date.now() - 61_000).toISOString(); writeFileSync(path, JSON.stringify(snapshot)); };
  const generation = () => JSON.parse(readFileSync(join(cache(), "buckets.json"))).checkpoint.generation;
  const transcript = (base, name, lines) => {
    const path = join(base, "projects", "-work-project", name);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, records(lines));
    return path;
  };
  const accounts = (entries, extra = {}) => writeFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "usage-accounts.json"),
    JSON.stringify({ version: 1, claude: { defaultName: null, accounts: entries, ...extra } }));
  t.after(() => {
    try { const lock = JSON.parse(readFileSync(join(cache(), "worker.lock"))); if (lock.pid !== process.pid) process.kill(lock.pid, "SIGKILL"); } catch { /* Worker ended. */ }
    rmSync(root, { recursive: true, force: true });
  });
  return { root, env, caches, cache, query, finish, stale, generation, transcript, accounts };
}

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
    // Ids key plain objects such as limits.json's entries.
    ...["__proto__", "toString", "constructor", "hasOwnProperty"].map(id => ({ ...entry, id, name: id })),
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

test("per-Account totals add up to the program's, and a record copied into two Accounts counts once in each", async t => {
  const f = fixture(t);
  const shared = assistant("shared", 5);
  f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("own", 10), shared]);
  const second = join(f.root, "second");
  // Within one Account, copies still count once: in another session, and as a replay.
  f.transcript(second, "second.jsonl", [shared, { ...shared, sessionId: "copy" }, assistant("other", 7)]);
  f.transcript(second, "replay.jsonl", [{ ...shared, requestId: "replayed", isSidechain: true, message: { ...shared.message, usage: { input_tokens: 900 } } }]);
  f.accounts([{ id: "secondid", directory: second, name: "second" }]);
  const report = await f.finish();
  assert.deepEqual(totals(report), [27, 15, 12]);
  const [primary, added] = claudeOf(report).accounts;
  assert.deepEqual(primary.tokenUsage.models.map(model => [model.model, model.tokens.total]), [["claude-test", 15]]);
  assert.deepEqual(added.tokenUsage.directories.map(directory => [directory.path, directory.tokens.total]), [["/work/project", 12]]);
  assert.equal(claudeOf(report).tokenUsage.daily.at(-1).tokens.total, 27);
  assert.deepEqual(added, { id: "secondid", isDefault: false, name: "second", directory: second, state: "ok",
    tokenUsage: added.tokenUsage, usageLimits: { state: "disabled" } });
  assert.deepEqual(primary.usageLimits, { state: "disabled" });
  // A rebuild from scratch gives the same split.
  rmSync(f.cache(), { recursive: true });
  assert.deepEqual(totals(await f.finish()), [27, 15, 12]);
});

test("an Account added, missing, returning and removed changes the totals without a rebuild or a new cache directory", { skip: asRoot }, async t => {
  const f = fixture(t);
  const primary = f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("primary", 12)]);
  assert.deepEqual(totals(await f.finish()), [12, 12]);
  const [cache] = f.caches();
  // A rebuild would read this Transcript again and count it unreadable.
  chmodSync(primary, 0);
  const extra = join(f.root, "extra");
  f.transcript(extra, "extra.jsonl", [assistant("extra-record", 22)]);
  const step = async expected => {
    // The query notices the changed Accounts itself; no stale snapshot is needed.
    assert.equal(f.query().refreshing, true);
    const report = await f.finish();
    assert.deepEqual(totals(report), expected);
    assert.equal(report.scan.unreadableFiles, 0);
    assert.deepEqual(f.caches(), [cache]);
    return report;
  };
  f.accounts([{ id: "extra-id", directory: extra, name: "extra" }]);
  const added = await step([34, 12, 22]);
  const generation = f.generation();
  assert.equal(claudeOf(added).accounts[1].state, "ok");
  renameSync(extra, extra + "-away");
  const missing = await step([12, 12, undefined]);
  assert.deepEqual(claudeOf(missing).accounts[1], { id: "extra-id", isDefault: false, name: "extra", directory: extra, state: "missing" });
  // Leaving rewrites the log without the Account's records.
  assert.notEqual(f.generation(), generation);
  assert.equal(readFileSync(join(f.cache(), "keys.log"), "utf8").includes("extra-record"), false);
  renameSync(extra + "-away", extra);
  await step([34, 12, 22]);
  f.accounts([]);
  const removed = await step([12, 12]);
  assert.deepEqual(claudeOf(removed).accounts.map(account => account.id), ["default"]);
  f.stale();
  assert.deepEqual(totals(await f.finish()), [12, 12]);
  // Added again under a new id, it is read from the start.
  f.accounts([{ id: "extra-id-2", directory: extra, name: "extra" }]);
  await step([34, 12, 22]);
});

test("a duplicate or over-limit Account adds nothing and reports only its state", async t => {
  const f = fixture(t);
  f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("primary", 12)]);
  const link = join(f.root, "link");
  symlinkSync(f.env.CLAUDE_CONFIG_DIR, link);
  const directories = ["a", "b", "c", "d"].map(name => {
    const path = join(f.root, name);
    f.transcript(path, `${name}.jsonl`, [assistant(`record-${name}`, 1)]);
    return path;
  });
  f.accounts([{ id: "linkedid", directory: link, name: "linked" }, ...directories.map(path => ({ id: `account-${path.at(-1)}`, directory: path, name: path.at(-1) }))]);
  const report = await f.finish();
  assert.deepEqual(totals(report), [15, 12, undefined, 1, 1, 1, undefined]);
  assert.deepEqual(claudeOf(report).accounts[1], { id: "linkedid", isDefault: false, name: "linked", directory: link, state: "duplicate" });
  assert.deepEqual(claudeOf(report).accounts[5], { id: "account-d", isDefault: false, name: "d", directory: directories[3], state: "overLimit" });
});

test("a Transcript two Accounts reach stays with the one that counted it while that one cannot be listed", { skip: asRoot }, async t => {
  const f = fixture(t);
  // Both Accounts' `projects/` link to one tree outside either.
  const shared = join(f.root, "shared-projects");
  const streamed = assistant("streamed", 3);
  const path = join(shared, "-work-project", "streamed.jsonl");
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, records([streamed]));
  const second = join(f.root, "second");
  for (const directory of [f.env.CLAUDE_CONFIG_DIR, second]) {
    mkdirSync(directory, { recursive: true });
    symlinkSync(shared, join(directory, "projects"));
  }
  f.accounts([{ id: "secondid", directory: second, name: "second" }]);
  assert.deepEqual(totals(await f.finish()), [3, 3, 0]);
  // Claude Code streams a larger snapshot of the request while it cannot be read.
  appendFileSync(path, records([{ ...streamed, message: { ...streamed.message, usage: { input_tokens: 9 } } }]));
  let unlisted;
  try {
    chmodSync(path, 0);
    f.stale();
    await f.finish();
    chmodSync(path, 0o600);
    chmodSync(f.env.CLAUDE_CONFIG_DIR, 0);
    f.stale();
    unlisted = await f.finish();
  } finally {
    chmodSync(path, 0o600);
    chmodSync(f.env.CLAUDE_CONFIG_DIR, 0o700);
  }
  assert.deepEqual(totals(unlisted), [3, 0, 0]);
  assert.equal(claudeOf(unlisted).accounts[0].tokenUsage.state, "error");
  f.stale();
  assert.deepEqual(totals(await f.finish()), [9, 9, 0]);
});

test("an unreadable directory that two Accounts reach is counted once", { skip: asRoot }, async t => {
  const f = fixture(t);
  f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("primary", 10)]);
  const locked = join(f.env.CLAUDE_CONFIG_DIR, "projects", "-locked");
  mkdirSync(locked);
  const linked = join(f.root, "linked");
  mkdirSync(linked);
  symlinkSync(join(f.env.CLAUDE_CONFIG_DIR, "projects"), join(linked, "projects"));
  f.accounts([{ id: "linkedid", directory: linked, name: "linked" }]);
  let report;
  try {
    chmodSync(locked, 0);
    report = await f.finish();
  } finally { chmodSync(locked, 0o700); }
  assert.deepEqual(totals(report), [10, 10, 0]);
  assert.equal(report.scan.unreadableFiles, 1);
});

test("a malformed Account file leaves the Default Account as before, and ~/.claude counts only once added", async t => {
  const f = fixture(t);
  f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("primary", 12)]);
  const home = join(f.env.HOME, ".claude");
  f.transcript(home, "home.jsonl", [assistant("home", 8)]);
  writeFileSync(join(f.env.HERDR_PLUGIN_CONFIG_DIR, "usage-accounts.json"), "{ not json");
  const before = await f.finish();
  assert.deepEqual(totals(before), [12, 12]);
  assert.deepEqual(claudeOf(before).accounts.map(({ tokenUsage, usageLimits, ...account }) => account),
    [{ id: "default", isDefault: true, name: null, directory: f.env.CLAUDE_CONFIG_DIR, state: "ok" }]);
  f.accounts([{ id: "home-dir", directory: home, name: "claude" }], { defaultName: "work" });
  const after = await f.finish();
  assert.deepEqual(totals(after), [20, 12, 8]);
  assert.equal(claudeOf(after).accounts[0].name, "work");
});

test("an Account whose Transcripts cannot be listed reports its own error while the others add up", { skip: asRoot }, async t => {
  const f = fixture(t);
  f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("primary", 12)]);
  const extra = join(f.root, "extra");
  f.transcript(extra, "extra.jsonl", [assistant("extra", 22)]);
  f.accounts([{ id: "extra-id", directory: extra, name: "extra" }]);
  assert.deepEqual(totals(await f.finish()), [34, 12, 22]);
  const projects = [join(extra, "projects"), join(f.env.CLAUDE_CONFIG_DIR, "projects")];
  let one;
  let both;
  try {
    chmodSync(projects[0], 0);
    f.stale();
    one = await f.finish();
    chmodSync(projects[1], 0);
    f.stale();
    both = await f.finish();
  } finally { for (const path of projects) chmodSync(path, 0o700); }
  const reason = "Could not read the Claude Code Transcripts.";
  // Its known records stay counted in the Host total, as for an unreadable root.
  assert.equal(claudeOf(one).tokenUsage.state, "ok");
  assert.equal(total(claudeOf(one).tokenUsage), 34);
  assert.deepEqual(claudeOf(one).accounts.map(account => account.tokenUsage.state), ["ok", "error"]);
  assert.equal(claudeOf(one).accounts[1].tokenUsage.reason, reason);
  assert.deepEqual(claudeOf(both).tokenUsage, { state: "error", reason });
  assert.deepEqual(claudeOf(both).accounts.map(account => account.tokenUsage.state), ["error", "error"]);
  f.stale();
  assert.deepEqual(totals(await f.finish()), [34, 12, 22]);
});

test("an Account added after a run that failed is not counted yet, unless no refresh can start", { skip: asRoot }, async t => {
  const f = fixture(t);
  f.transcript(f.env.CLAUDE_CONFIG_DIR, "default.jsonl", [assistant("primary", 12)]);
  const projects = join(f.env.CLAUDE_CONFIG_DIR, "projects");
  const directory = name => { const path = join(f.root, name); f.transcript(path, `${name}.jsonl`, [assistant(name, 5)]); return path; };
  const states = report => claudeOf(report).accounts.map(account => account.tokenUsage.state);
  const added = [{ id: "added-one", directory: directory("one"), name: "one" }];
  let changed;
  let counted;
  let unstarted;
  try {
    chmodSync(projects, 0);
    assert.equal(claudeOf(await f.finish()).tokenUsage.state, "error");
    f.accounts(added);
    // Served from the failed run's snapshot while the new run counts the Account.
    changed = f.query();
    counted = await f.finish();
    chmodSync(f.cache(), 0o500);
    f.accounts([...added, { id: "added-two", directory: directory("two"), name: "two" }]);
    unstarted = f.query();
  } finally {
    chmodSync(projects, 0o700);
    chmodSync(f.cache(), 0o700);
  }
  assert.equal(changed.refreshing, true);
  assert.deepEqual(states(changed), ["error", "noData"]);
  assert.deepEqual(states(counted), ["error", "ok"]);
  assert.equal(unstarted.refreshing, false);
  assert.deepEqual(claudeOf(unstarted).accounts.map(account => account.tokenUsage.reason), ["Could not read the Claude Code Transcripts.",
    "The background refresh could not start.", "The background refresh could not start."]);
});
