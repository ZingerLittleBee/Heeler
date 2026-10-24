import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, utimesSync, statSync, symlinkSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixture(t, claudeLimits = false) {
  const root = mkdtempSync(join(tmpdir(), "heeler-worker-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude,one"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const run = (name, args = []) => spawnSync(process.execPath, [join(plugin, "src", name), ...args], { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  if (claudeLimits) {
    const executable = join(root, "claude-stub");
    writeFileSync(executable, `#!${process.execPath}
const readline = require('node:readline');
readline.createInterface({input: process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  const response = request.request.subtype === 'initialize' ? {} : {
    subscription_type: 'max', rate_limits_available: true, rate_limits: {
      five_hour: {utilization: 12, resets_at: null},
      seven_day: {utilization: null, resets_at: null},
      seven_day_opus: {utilization: 23, resets_at: null},
      seven_day_sonnet: {utilization: 34, resets_at: null},
      model_scoped: [{display_name: 'Custom model', utilization: 56, resets_at: '2020-01-01T00:00:00Z'}],
    }
  };
  process.stdout.write(JSON.stringify({type:'control_response', response:{request_id:request.request_id, subtype:'success', response}})+'\\n');
});
`, {mode: 0o755});
    const path = join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
    const runtime = JSON.parse(readFileSync(path)); runtime.claude = executable;
    writeFileSync(path, JSON.stringify(runtime));
  }
  const query = (tz = "UTC") => {
    const result = run("usage-query.js", ["--tz", tz, ...(claudeLimits ? ["--claude-limits"] : [])]);
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  t.after(() => {
    try {
      const lock = JSON.parse(readFileSync(join(cache(), "worker.lock"), "utf8"));
      if (lock.pid !== process.pid) process.kill(lock.pid, "SIGKILL");
    } catch { /* Worker already finished. */ }
    rmSync(root, { recursive: true, force: true });
  });
  const transcript = (name, records, base = env.CLAUDE_CONFIG_DIR) => {
    const path = join(base, "projects", "-work-project", name);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, records.map(r => JSON.stringify(r)).join("\n") + "\n");
    return path;
  };
  const finish = async (tz = "UTC") => {
    for (let i = 0; i < 300; i++) {
      const result = query(tz);
      if (!result.refreshing) return result;
      await sleep(20);
    }
    assert.fail("worker did not finish");
  };
  const stale = () => {
    const path = join(cache(), "buckets.json");
    const snapshot = JSON.parse(readFileSync(path, "utf8"));
    snapshot.generatedAt = new Date(Date.now() - 61_000).toISOString();
    writeFileSync(path, JSON.stringify(snapshot));
  };
  return { root, env, query, cache, transcript, finish, stale };
}
function assistant(id, tokens = 10, extra = {}) {
  return { type: "assistant", sessionId: "session", timestamp: new Date().toISOString(), cwd: "/work/project",
    requestId: `request-${id}`, message: { id, model: "claude-test", usage: { input_tokens: tokens, output_tokens: 2 } }, ...extra };
}
const claude = report => report.programs.find(p => p.program === "claude").tokenUsage;

test("query starts a detached scan and returns Claude normalized usage", async t => {
  const f = fixture(t);
  f.transcript("one.jsonl", [assistant("one")]);
  const first = f.query();
  assert.equal(first.refreshing, true);
  const report = await f.finish();
  assert.equal(report.scan.state, "complete");
  assert.equal(claude(report).state, "ok");
  assert.deepEqual(claude(report).totals.today.tokens, { input: 10, cacheRead: 0, cacheWrite: 0, output: 2, reasoning: 0, total: 12 });
  assert.equal(claude(report).daily.length, 30);
  assert.equal(claude(report).totals.last30Days.tokens.total, 12);
  assert.equal(report.programs[1].tokenUsage.state, "noData");
});

test("Claude copies, streamed snapshots, parent replays and cache splits count once across roots", async t => {
  const f = fixture(t);
  const timestamp = new Date().toISOString();
  const original = assistant("shared", 10, { timestamp });
  const larger = { ...original, message: { ...original.message, usage: { input_tokens: 10, cache_read_input_tokens: 20, cache_creation_input_tokens: 99, cache_creation: { ephemeral_5m_input_tokens: 3, ephemeral_1h_input_tokens: 7 }, output_tokens: 5, iterations: [{ type: "advisor_message", input_tokens: 5000 }], speed: "fast" } } };
  f.transcript("original.jsonl", [original, larger, original, { ...larger, sessionId: "copy" }, assistant("synthetic", 900, { message: { id: "synthetic", model: "<synthetic>", usage: { input_tokens: 900 } } })]);
  f.transcript("session/subagents/replay.jsonl", [{ ...larger, isSidechain: true, requestId: "replay-request" }, assistant("child", 4, { isSidechain: true }), assistant("fallback", 6, { requestId: undefined, timestamp }), assistant("fallback", 6, { requestId: undefined, timestamp })], join(f.env.HOME, ".claude"));
  f.transcript("legacy.jsonl", [assistant("legacy", 8, { message: { id: "legacy", model: "claude-test", usage: { input_tokens: 8, cache_creation_input_tokens: 9, cache_creation: {}, output_tokens: 2 } } })], join(f.env.HOME, ".config", "claude"));
  const report = await f.finish();
  assert.deepEqual(claude(report).totals.last30Days.tokens, { input: 28, cacheRead: 20, cacheWrite: 19, output: 11, reasoning: 0, total: 78 });
  const log = readFileSync(join(f.cache(), "keys.log"), "utf8");
  assert.ok(log.includes('"speed":"fast"'));
  assert.ok(log.includes('"write1h":7'));
});

test("a sidechain replay read before its original gives the same totals", async t => {
  const f = fixture(t);
  const g = fixture(t);
  const original = assistant("replay", 10);
  const replay = assistant("replay", 500, { timestamp: original.timestamp, requestId: "replayed", isSidechain: true });
  f.transcript("forward.jsonl", [original, replay]);
  g.transcript("reverse.jsonl", [replay, original]);
  assert.equal(claude(await f.finish()).totals.last30Days.tokens.total, 12);
  assert.deepEqual(claude(await f.finish()), claude(await g.finish()));
});

test("a parent copied into another session still suppresses that session's replay", async t => {
  const f = fixture(t);
  const original = assistant("cross-session", 10);
  f.transcript("copy.jsonl", [original, { ...original, sessionId: "copy" }, { ...original, sessionId: "copy", requestId: "replay", isSidechain: true }]);
  assert.equal(claude(await f.finish()).totals.today.tokens.total, 12);
});

test("root identity stays stable when missing roots appear and old siblings are removed", async t => {
  const f = fixture(t);
  const empty = await f.finish();
  assert.equal(claude(empty).state, "noData");
  const original = f.cache();
  const sibling = join(f.env.HERDR_PLUGIN_STATE_DIR, "usage", "unused");
  mkdirSync(sibling);
  writeFileSync(join(sibling, "buckets.json"), "{}");
  const old = new Date(Date.now() - 32 * 86_400_000);
  utimesSync(join(sibling, "buckets.json"), old, old);
  f.transcript("new.jsonl", [assistant("new")]);
  f.stale();
  assert.equal(claude(await f.finish()).totals.today.tokens.total, 12);
  assert.equal(f.cache(), original);
  assert.deepEqual(readdirSync(join(f.env.HERDR_PLUGIN_STATE_DIR, "usage")), [original.split("/").at(-1)]);
  assert.equal(statSync(original).mode & 0o777, 0o700);
});

test("symlinked Claude roots are scanned once and old records are excluded", async t => {
  const f = fixture(t);
  f.transcript("one.jsonl", [assistant("one"), assistant("old", 1000, { timestamp: new Date(Date.now() - 32 * 86_400_000).toISOString() })]);
  mkdirSync(f.env.HOME, { recursive: true });
  symlinkSync(f.env.CLAUDE_CONFIG_DIR, join(f.env.HOME, ".claude"));
  assert.equal(claude(await f.finish()).totals.last30Days.tokens.total, 12);
  const log = readFileSync(join(f.cache(), "keys.log"), "utf8");
  assert.equal(log.includes('"message-old"'), false);
});

test("queries observe a partial scan without starting another worker", async t => {
  const f = fixture(t);
  const timestamp = new Date().toISOString();
  for (let file = 0; file < 12; file++) f.transcript(`${file}.jsonl`, Array.from({ length: 1500 }, (_, i) => assistant(`${file}-${i}`, 1, { timestamp })));
  assert.equal(f.query().refreshing, true);
  let pid;
  let sawPartial = false;
  for (let i = 0; i < 300; i++) {
    const report = f.query();
    if (!report.refreshing) break;
    const lockPath = join(f.cache(), "worker.lock");
    let lock;
    try { lock = JSON.parse(readFileSync(lockPath, "utf8")); } catch { continue; }
    if (!pid) pid = lock.pid;
    assert.equal(lock.pid, pid);
    assert.notEqual(pid, process.pid);
    if (report.scan.state === "partial" && claude(report).state === "ok") sawPartial = true;
    await sleep(10);
  }
  assert.equal(sawPartial, true);
  assert.equal(claude(await f.finish()).totals.today.tokens.total, 54_000);
});

test("fresh heartbeats keep a long-running lock and dead or reused pids are reclaimed", async t => {
  const f = fixture(t);
  await f.finish();
  f.stale();
  const start = spawnSync("/bin/ps", ["-p", String(process.pid), "-o", "lstart="], { encoding: "utf8" }).stdout.trim();
  const lockPath = join(f.cache(), "worker.lock");
  const lock = { pid: process.pid, processStart: start, token: "long-running-fixture", heartbeat: Date.now(), createdAt: Date.now() - 20 * 60_000 };
  writeFileSync(lockPath, JSON.stringify(lock));
  assert.equal(f.query().refreshing, true);
  assert.equal(JSON.parse(readFileSync(lockPath)).token, lock.token);
  for (const changes of [{ pid: 99999999 }, { processStart: "different process" }, { heartbeat: Date.now() - 11 * 60_000 }]) {
    writeFileSync(lockPath, JSON.stringify({ ...lock, ...changes }));
    assert.equal(f.query().refreshing, true);
    assert.equal(claude(await f.finish()).state, "noData");
    f.stale();
  }
  rmSync(lockPath, { force: true });
});

test("query folds UTC quarter-hours into Nepal days and the spring DST day", async t => {
  const f = fixture(t);
  await f.finish();
  const frozen = Date.parse("2026-03-09T12:00:00Z");
  const clock = join(f.root, "clock.mjs");
  writeFileSync(clock, `const OriginalDate = Date; globalThis.Date = class extends OriginalDate { constructor(...args) { super(...(args.length ? args : [${frozen}])); } static now() { return ${frozen}; } };`);
  const start = spawnSync("/bin/ps", ["-p", String(process.pid), "-o", "lstart="], { encoding: "utf8" }).stdout.trim();
  writeFileSync(join(f.cache(), "worker.lock"), JSON.stringify({ pid: process.pid, processStart: start, heartbeat: frozen, token: "clock-fixture" }));
  const queryBuckets = (tz, entries) => {
    writeFileSync(join(f.cache(), "buckets.json"), JSON.stringify({ complete: true, generatedAt: new Date(frozen).toISOString(), coveredThrough: new Date(frozen).toISOString(), buckets: entries.map(([timestamp, input]) => ({ timestamp: Date.parse(timestamp), program: "claude", model: "claude-test", tokens: { input, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: input } })) }));
    const result = spawnSync(process.execPath, ["--import", clock, join(plugin, "src", "usage-query.js"), "--tz", tz], { env: f.env, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
    return claude(JSON.parse(result.stdout));
  };
  const nepal = queryBuckets("Asia/Kathmandu", [["2026-03-08T18:00:00Z", 2], ["2026-03-08T18:15:00Z", 3]]);
  assert.equal(nepal.totals.today.tokens.total, 3);
  assert.equal(nepal.daily.find(day => day.date === "2026-03-08").tokens.total, 2);
  const dst = queryBuckets("America/New_York", [["2026-03-08T04:45:00Z", 1], ["2026-03-08T05:00:00Z", 2], ["2026-03-09T03:45:00Z", 5], ["2026-03-09T04:00:00Z", 9]]);
  assert.equal(dst.daily.find(day => day.date === "2026-03-07").tokens.total, 1);
  assert.equal(dst.daily.find(day => day.date === "2026-03-08").tokens.total, 7);
  assert.equal(dst.totals.today.tokens.total, 9);
  assert.equal(dst.totals.last7Days.tokens.total, 17);
});

test("the shared v1 vector comes from the worker's Claude and Codex aggregation", async t => {
  const f = fixture(t, true);
  f.transcript("vector.jsonl", [assistant("vector", 1200, { message: { id: "vector", model: "claude-opus-4-5", usage: { input_tokens: 1200, cache_read_input_tokens: 830000, cache_creation_input_tokens: 41000, output_tokens: 9800 } } })]);
  const codexDirectory = join(f.env.HOME, ".codex", "sessions", "2026", "10", "23");
  mkdirSync(codexDirectory, { recursive: true });
  const timestamp = new Date().toISOString();
  writeFileSync(join(codexDirectory, "rollout-vector.jsonl"), [
    { type: "session_meta", timestamp, payload: { id: "vector-codex", cwd: "/work/codex" } },
    { type: "turn_context", timestamp, payload: { model: "gpt-5.3-codex" } },
    { type: "token_usage_record", timestamp, payload: { thread_id: "vector-codex", response_id: "vector-response", usage: { input_tokens: 220, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 30, reasoning_output_tokens: 10 } } },
    { type: "event_msg", timestamp, payload: { type: "token_count", info: null, rate_limits: {
      limit_id: "codex", plan_type: "plus",
      primary: { used_percent: 18, window_minutes: 10080, resets_at: Math.floor(Date.now() / 1000) + 3600 },
      secondary: { used_percent: 60, window_minutes: 300, resets_at: Math.floor(Date.now() / 1000) - 3600 },
    } } },
  ].map(line => JSON.stringify(line)).join("\n") + "\n");
  const report = await f.finish("Asia/Shanghai");
  const expected = { input: 1200, cacheRead: 830000, cacheWrite: 41000, output: 9800, reasoning: 0, total: 882000 };
  assert.deepEqual(claude(report).totals.today.tokens, expected);
  assert.equal(claude(report).daily.length, 30);
  assert.deepEqual(claude(report).models.map(model => [model.model, model.priced, model.tokens.total]), [["claude-opus-4-5", true, 882000]]);
  assert.deepEqual(claude(report).directories.map(directory => [directory.path, directory.tokens.total]), [["/work/project", 882000]]);
  assert.deepEqual(report.programs[1].tokenUsage.models.map(model => [model.model, model.priced, model.tokens.total]), [["gpt-5.3-codex", true, 250]]);
  assert.deepEqual(report.programs[1].tokenUsage.directories.map(directory => [directory.path, directory.tokens.total]), [["/work/codex", 250]]);
  assert.ok(Math.abs(claude(report).totals.today.estimatedCostUSD - 0.92225) < 1e-10);
  assert.ok(Math.abs(report.programs[1].tokenUsage.totals.today.estimatedCostUSD - 0.000742) < 1e-12);
  assert.deepEqual(report.programs[1].tokenUsage.totals.today.tokens, { input: 120, cacheRead: 40, cacheWrite: 60, output: 30, reasoning: 10, total: 250 });
  const claudeLimits = report.programs[0].usageLimits;
  assert.equal(claudeLimits.state, "ok");
  assert.equal(claudeLimits.plan, "max");
  assert.deepEqual(claudeLimits.windows.map(window => [window.id, window.usedPercent, window.expired]),
    [["fiveHour", 12, false], ["sevenDayOpus", 23, false], ["sevenDaySonnet", 34, false], ["claude:model:Custom model", null, true]]);
  claudeLimits.observedAt = "2026-10-23T12:34:50.000Z";
  const limits = report.programs[1].usageLimits;
  assert.equal(limits.source, "lastSession");
  assert.deepEqual(limits.windows.map(window => [window.id, window.durationMinutes, window.usedPercent, window.expired]),
    [["primary", 10080, 18, false], ["secondary", 300, null, true]]);
  limits.observedAt = "2026-10-23T12:34:50.000Z";
  limits.windows[0].resetsAt = "2026-10-28T00:00:00.000Z";
  limits.windows[1].resetsAt = "2026-10-22T00:00:00.000Z";
  report.generatedAt = report.scan.coveredThrough = "2026-10-23T12:34:56.000Z";
  report.scan.coveredFrom = "2026-10-23";
  for (const program of report.programs) {
    for (const [index, day] of program.tokenUsage.daily.entries()) day.date = new Date(Date.parse("2026-10-23T12:00:00Z") - (29 - index) * 86_400_000).toISOString().slice(0, 10);
  }
  const path = join(plugin, "test-vectors", "usage-v1.json");
  if (process.env.UPDATE_USAGE_VECTOR === "1") writeFileSync(path, JSON.stringify(report, null, 2) + "\n");
  assert.deepEqual(report, JSON.parse(readFileSync(path, "utf8")));
});

test("an unreadable Transcript finishes with a filtered error instead of refreshing forever", async t => {
  const f = fixture(t);
  const path = f.transcript("private.jsonl", [assistant("unreadable")]);
  chmodSync(path, 0);
  t.after(() => { try { chmodSync(path, 0o600); } catch { /* Fixture removed. */ } });
  const report = await f.finish();
  assert.equal(report.refreshing, false);
  assert.equal(claude(report).state, "error");
  assert.equal(claude(report).reason, "Could not read the Claude Code Transcripts.");
  assert.equal(JSON.stringify(report).includes(f.root), false);
});

test("a corrupt abandoned worker lock can be reclaimed", async t => {
  const f = fixture(t);
  await f.finish();
  f.stale();
  writeFileSync(join(f.cache(), "worker.lock"), "broken");
  assert.equal(f.query().refreshing, true);
  assert.equal((await f.finish()).scan.state, "complete");
});
