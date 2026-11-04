import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, appendFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const at = (delta = 0) => new Date(Date.now() - 60_000 + delta).toISOString();
const line = (type, payload, timestamp = at()) => ({ type, payload, timestamp });
const meta = (id, extra = {}, timestamp) => line("session_meta", { id, cwd: "/work/codex", ...extra }, timestamp);
const usage = (input, output = 0, extra = {}) => ({ input_tokens: input, output_tokens: output, ...extra });
const record = (thread, response, tokens, timestamp) => line("token_usage_record", { thread_id: thread, response_id: response, usage: tokens }, timestamp);
const count = (total, last, timestamp) => line("event_msg", { type: "token_count", info: { total_token_usage: total, ...(last ? { last_token_usage: last } : {}) } }, timestamp);
const settings = (thread, timestamp, model = "gpt-test") => line("event_msg", { type: "thread_settings_applied", thread_id: thread, thread_settings: { model, service_tier: "priority" } }, timestamp);
const codex = report => report.programs.find(p => p.program === "codex").tokenUsage;
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-codex-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CODEX_HOME: join(root, "codex"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const run = (name, args = []) => spawnSync(process.execPath, [join(plugin, "src", name), ...args], { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  const query = () => {
    const result = run("usage-query.js", ["--tz", "UTC"]);
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  t.after(() => {
    try { const lock = JSON.parse(readFileSync(join(cache(), "worker.lock"))); if (lock.pid !== process.pid) process.kill(lock.pid, "SIGKILL"); } catch { /* Already finished. */ }
    rmSync(root, { recursive: true, force: true });
  });
  const transcript = (id, records, area = "sessions/2026/10/23") => {
    const path = join(env.CODEX_HOME, area, `rollout-${id}.jsonl`);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, records.map(r => JSON.stringify(r)).join("\n") + "\n");
    return path;
  };
  const finish = async () => {
    for (let i = 0; i < 300; i++) { const report = query(); if (!report.refreshing) return report; await sleep(20); }
    assert.fail("worker did not finish");
  };
  const stale = () => { const path = join(cache(), "buckets.json"); const snapshot = JSON.parse(readFileSync(path)); snapshot.generatedAt = new Date(Date.now() - 61_000).toISOString(); writeFileSync(path, JSON.stringify(snapshot)); };
  return { root, env, query, cache, transcript, finish, stale };
}

test("Codex own responses, compaction and cumulative updates count exactly once", async t => {
  const f = fixture(t);
  f.transcript("own", [meta("own"), settings("own"),
    record("own", "response-1", usage(100, 10, { cached_input_tokens: 40, cache_write_input_tokens: 60, reasoning_output_tokens: 4 })),
    count(usage(100, 10)),
    record("own", "compaction", usage(20, 5)),
    count(usage(100, 10)), // Limit update repeats the preceding total while a response waits.
    count(usage(120, 15), usage(20, 5)),
    record("other", "copied", usage(900, 900)),
  ]);
  f.transcript("duplicate", [meta("own"), record("own", "response-1", usage(100, 10, { cached_input_tokens: 40, cache_write_input_tokens: 60, reasoning_output_tokens: 4 }))]);
  const report = await f.finish();
  assert.equal(codex(report).state, "ok");
  assert.deepEqual(codex(report).totals.today.tokens, { input: 20, cacheRead: 40, cacheWrite: 60, output: 15, reasoning: 4, total: 135 });
});

test("old cumulative files use deltas, ignore repeats, then switch to response records", async t => {
  const f = fixture(t);
  f.transcript("upgrade", [meta("upgrade"), settings("upgrade"), count(usage(10, 2)), count(usage(10, 2)),
    count(usage(15, 3)), record("upgrade", "first-modern", usage(7, 4)), count(usage(22, 7), usage(7, 4)),
    count(usage(22, 7)), count(usage(22, 7), usage(9, 9)),
  ]);
  assert.deepEqual(codex(await f.finish()).totals.today.tokens, { input: 22, cacheRead: 0, cacheWrite: 0, output: 7, reasoning: 0, total: 29 });
});

test("forks and subagents exclude inherited counts before their leading own-thread marker", async t => {
  const f = fixture(t);
  for (const [id, extra] of [["fork", { forked_from_id: "missing-parent" }], ["child", { session_id: "parent" }]]) {
    f.transcript(id, [meta(id, extra, at(0)), settings("parent", at(100)),
      record("parent", "inherited-record", usage(1000), at(200)), count(usage(100), usage(100), at(300)),
      settings(id, at(400)), count(usage(110), usage(10), at(500)),
    ]);
  }
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 20);
});

test("an old fork matches a present parent's copied prefix even within one burst", async t => {
  const f = fixture(t);
  f.transcript("parent", [meta("parent", {}, at(0)), record("parent", "parent-response", usage(100), at(50)), count(usage(100), usage(100), at(100))]);
  f.transcript("fork", [meta("fork", { forked_from_id: "parent" }, at(1000)),
    record("parent", "parent-response", usage(100), at(1050)),
    count(usage(100), usage(100), at(1100)), count(usage(110), usage(10), at(1200))]);
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 110);
});

test("an old fork without its parent excludes only the leading burst, not a later resume marker", async t => {
  const f = fixture(t);
  f.transcript("old", [meta("old", { forked_from_id: "gone", cli_version: "0.999.0" }, at(0)),
    count(usage(100), usage(100), at(100)), count(usage(110), usage(10), at(3000)),
    settings("old", at(5000)), count(usage(130), usage(20), at(5100))]);
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 30);
});

test("old multi-agent replay waits for either trigger-turn record kind", async t => {
  const f = fixture(t);
  for (const [id, kind] of [["metadata", "inter_agent_communication_metadata"], ["message", "inter_agent_communication"]]) {
    f.transcript(id, [meta(id, { session_id: "root" }, at(0)), count(usage(100), usage(100), at(100)),
      count(usage(110), usage(10), at(3000)), line(kind, { trigger_turn: true }, at(3100)),
      count(usage(117), usage(7), at(3200))]);
  }
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 14);
});

test("referenced fork and revert histories contain only their own counted events", async t => {
  const f = fixture(t);
  f.transcript("base", [meta("base"), count(usage(20), usage(20))]);
  f.transcript("reference", [meta("reference", { forked_from_id: "base", history_base: { thread_id: "base" } }), count(usage(5), usage(5))]);
  f.transcript("revert", [meta("base", { history_base: { thread_id: "base" } }), record("base", "after-revert", usage(3))]);
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 28);
});

test("a read inside the leading burst keeps pending counts until the own-thread marker arrives", async t => {
  const f = fixture(t);
  const timestamp = Date.now() + 2000;
  const path = f.transcript("partial", [meta("partial", { forked_from_id: "missing" }, new Date(timestamp).toISOString()),
    count(usage(100), usage(100), new Date(timestamp + 100).toISOString())]);
  f.query();
  let saved;
  for (let i = 0; i < 100; i++) {
    try { saved = Object.values(JSON.parse(readFileSync(join(f.cache(), "files.json")))).find(file => file.carry.threadId === "partial"); } catch { /* First batch. */ }
    if (saved?.carry.pending.length) break;
    await sleep(10);
  }
  assert.equal(saved.carry.pending.length, 1);
  assert.equal(saved.carry.previousTotal.input_tokens, 100);
  assert.equal(f.query().scan.state, "partial");
  appendFileSync(path, [settings("partial", new Date(timestamp + 200).toISOString()), count(usage(110), usage(10), new Date(timestamp + 300).toISOString())].map(r => JSON.stringify(r)).join("\n") + "\n");
  const report = await f.finish();
  assert.equal(codex(report).totals.last30Days.tokens.total, 10);
  assert.equal(report.scan.state, "complete");
});

test("the clock can close an old fork's pending burst without a later record", async t => {
  const f = fixture(t);
  const timestamp = Date.now() + 400;
  f.transcript("clock", [meta("clock", { forked_from_id: "gone" }, new Date(timestamp).toISOString()),
    count(usage(100), usage(100), new Date(timestamp + 10).toISOString())]);
  const report = await f.finish();
  assert.equal(report.scan.state, "complete");
  assert.equal(codex(report).state, "noData");
  const saved = Object.values(JSON.parse(readFileSync(join(f.cache(), "files.json"))));
  assert.equal(saved[0].carry.leadingClosed, true);
  assert.deepEqual(saved[0].carry.pending, []);
});

test("a forked subagent does not read its parent file while a fork without a marker does", async t => {
  const f = fixture(t);
  f.transcript("parent", [meta("parent", {}, at(0)), count(usage(100), usage(100), at(100))]);
  f.transcript("subagent", [meta("subagent", { session_id: "root", forked_from_id: "parent" }, at(1000)),
    count(usage(100), usage(100), at(1100)), line("inter_agent_communication_metadata", { trigger_turn: true }, at(3000)),
    count(usage(107), usage(7), at(3100))]);
  const opened = join(f.root, "opened");
  const preload = join(f.root, "count-reads.mjs");
  writeFileSync(preload, `import fs from 'node:fs';import {syncBuiltinESMExports} from 'node:module';
const original=fs.createReadStream;
fs.createReadStream=function(path,...args){fs.appendFileSync(${JSON.stringify(opened)},String(path)+'\\n');return original.call(this,path,...args);};syncBuiltinESMExports();`);
  const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const node = join(f.root, "recorded-node");
  writeFileSync(node, `#!/bin/sh\nexec ${shellQuote(process.execPath)} --import ${shellQuote(preload)} "$@"\n`);
  chmodSync(node, 0o700);
  const runtimePath = join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  const runtime = JSON.parse(readFileSync(runtimePath));
  runtime.node = node;
  writeFileSync(runtimePath, JSON.stringify(runtime));
  writeFileSync(join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime-node"), node + "\n");
  const reads = () => readFileSync(opened, "utf8").trim().split("\n").filter(path => path.endsWith("/rollout-parent.jsonl")).length;
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 107);
  // Its header and its own read; no third read to match the subagent's prefix.
  assert.equal(reads(), 2);
  f.transcript("fork", [meta("fork", { forked_from_id: "parent" }, at(5000)), count(usage(100), usage(100), at(5100)),
    count(usage(104), usage(4), at(5200))]);
  f.stale();
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 111);
  assert.equal(reads(), 3);
});

test("a trigger inside an old subagent burst starts own usage when no own-thread marker exists", async t => {
  const f = fixture(t);
  f.transcript("trigger", [meta("trigger", { session_id: "root" }, at(0)), count(usage(100), usage(100), at(100)),
    line("inter_agent_communication_metadata", { trigger_turn: true }, at(200)), count(usage(109), usage(9), at(300))]);
  assert.equal(codex(await f.finish()).totals.today.tokens.total, 9);
});

test("Codex plain and native compressed archives contribute through the real worker", { skip: !zlib.createZstdDecompress }, async t => {
  const f = fixture(t);
  f.transcript("plain", [meta("plain"), count(usage(3), usage(3))], "archived_sessions");
  const path = f.transcript("compressed", [meta("compressed"), record("compressed", "compressed-response", usage(7))], "archived_sessions");
  writeFileSync(path + ".zst", zlib.zstdCompressSync(readFileSync(path)));
  rmSync(path);
  const report = await f.finish();
  assert.equal(codex(report).totals.today.tokens.total, 10);
  assert.equal(report.scan.skippedArchives, 0);
});

test("the worker uses recorded-PATH zstd or reports skipped archives when native zstd is absent", async t => {
  for (const external of [true, false]) {
    const f = fixture(t);
    const path = f.transcript("compat", [meta("compat"), count(usage(9), usage(9))], "archived_sessions");
    // The stub decoder copies its fixture input; the native decoder is tested above.
    writeFileSync(path + ".zst", readFileSync(path));
    rmSync(path);
    const bin = join(f.root, "bin");
    mkdirSync(bin);
    if (external) {
      const executable = join(bin, "zstd");
      writeFileSync(executable, `#!${process.execPath}\nconst fs=require('node:fs'); if(process.argv[2]!=='-dc'||process.argv[3]!=='--')process.exit(2); process.stdout.write(fs.readFileSync(process.argv[4]));\n`);
      chmodSync(executable, 0o700);
    }
    const preload = join(f.root, "node-without-zstd.mjs");
    writeFileSync(preload, "import zlib from 'node:zlib'; Object.defineProperty(zlib,'createZstdDecompress',{value:undefined});\n");
    const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
    const node = join(f.root, "recorded-node");
    writeFileSync(node, `#!/bin/sh\nexec ${shellQuote(process.execPath)} --import ${shellQuote(preload)} "$@"\n`);
    chmodSync(node, 0o700);
    const runtimePath = join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
    const runtime = JSON.parse(readFileSync(runtimePath));
    runtime.node = node;
    runtime.env.PATH = bin;
    writeFileSync(runtimePath, JSON.stringify(runtime));
    writeFileSync(join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime-node"), node + "\n");
    const report = await f.finish();
    assert.equal(report.scan.skippedArchives, external ? 0 : 1);
    assert.equal(codex(report).state, external ? "ok" : "noData");
    if (external) assert.equal(codex(report).totals.today.tokens.total, 9);
  }
});
