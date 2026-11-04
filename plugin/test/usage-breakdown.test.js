import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, chmodSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const records = lines => lines.map(line => JSON.stringify(line)).join("\n") + "\n";
const usage = (report, program) => report.programs.find(value => value.program === program).tokenUsage;
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-breakdown-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"), CODEX_HOME: join(root, "codex"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const run = (name, args = []) => spawnSync(process.execPath, [join(plugin, "src", name), ...args], { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const query = () => { const result = run("usage-query.js", ["--tz", "UTC"]); assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout); };
  const finish = async () => { for (let i = 0; i < 400; i++) { const report = query(); if (!report.refreshing) return report; await sleep(15); } assert.fail("worker did not finish"); };
  const transcript = (program, name, lines, project = "-work-project") => {
    const path = program === "claude" ? join(env.CLAUDE_CONFIG_DIR, "projects", project, name + ".jsonl")
      : join(env.CODEX_HOME, "sessions/2026/10/23", "rollout-" + name + ".jsonl");
    mkdirSync(join(path, ".."), { recursive: true }); writeFileSync(path, records(lines)); return path;
  };
  const stale = () => { const path = join(cache(), "buckets.json"); const snapshot = JSON.parse(readFileSync(path)); snapshot.generatedAt = new Date(Date.now() - 61_000).toISOString(); writeFileSync(path, JSON.stringify(snapshot)); };
  t.after(() => { try { const lock = JSON.parse(readFileSync(join(cache(), "worker.lock"))); if (lock.pid !== process.pid) process.kill(lock.pid, "SIGKILL"); } catch { /* Worker ended. */ } rmSync(root, { recursive: true, force: true }); });
  return { root, env, query, finish, cache, transcript, stale };
}
function claude(id, input, { output = 0, model = "claude-opus-4-5", cwd, timestamp = new Date().toISOString() } = {}) {
  return { type: "assistant", sessionId: "session", requestId: "request-" + id, timestamp, ...(cwd ? { cwd } : {}), message: { id, model, usage: { input_tokens: input, output_tokens: output } } };
}
function codex(id, input, { output = 0, model = "gpt-5.3-codex", cwd = "/work/codex", timestamp = new Date().toISOString() } = {}) {
  return [
    { type: "session_meta", timestamp, payload: { id, cwd } },
    { type: "turn_context", timestamp, payload: { model } },
    { type: "token_usage_record", timestamp, payload: { thread_id: id, response_id: "response-" + id, usage: { input_tokens: input, output_tokens: output } } },
  ];
}

test("Claude models and directories preserve priced subtotals, unknown tokens and cwd fallback", async t => {
  const f = fixture(t);
  f.transcript("claude", "one", [{ type: "user", cwd: "/work/shared" }, claude("one", 100, { output: 10 }), claude("unknown", 7, { model: "unknown-model" })]);
  f.transcript("claude", "two", [claude("two", 50, { output: 5, cwd: "/work/other" })]);
  f.transcript("claude", "fallback", [claude("fallback", 9, { model: "unknown-model" })], "-work-fallback");
  const result = usage(await f.finish(), "claude");
  assert.equal(result.totals.last30Days.tokens.total, 181);
  assert.deepEqual(result.directories.map(value => [value.path, value.tokens.total]), [["/work/shared", 117], ["/work/other", 55], ["/work/fallback", 9]]);
  assert.equal(result.directories[0].unpricedTokens, 7);
  assert.ok(Math.abs(result.directories[0].estimatedCostUSD - 0.00075) < 1e-12);
  assert.equal(result.directories[2].estimatedCostUSD, null);
  assert.deepEqual(result.models.map(value => [value.model, value.priced, value.tokens.total]), [["claude-opus-4-5", true, 165], ["unknown-model", false, 16]]);
  assert.ok(Math.abs(result.models[0].estimatedCostUSD - 0.001125) < 1e-12);
  assert.equal(result.models[1].estimatedCostUSD, null);
  assert.equal(result.models[1].unpricedTokens, 16);
});

for (const program of ["claude", "codex"]) {
  test(`${program} directories combine models and return only the top ten within thirty days`, async t => {
    const f = fixture(t);
    const make = (id, count, options) => program === "claude" ? [claude(id, count, options)] : codex(id, count, options);
    for (let index = 1; index <= 12; index++) {
      f.transcript(program, `directory-${index}`, make(`directory-${index}`, index, { cwd: `/work/${index}` }));
    }
    f.transcript(program, "mixed", make("mixed", 3, { model: "unknown-model", cwd: "/work/12" }));
    f.transcript(program, "old", make("old", 999, { cwd: "/work/old", timestamp: new Date(Date.now() - 30 * 86_400_000).toISOString() }));
    const report = usage(await f.finish(), program);
    assert.equal(report.totals.today.tokens.total, 81);
    assert.equal(report.totals.last30Days.tokens.total, 81);
    assert.deepEqual(report.directories.map(value => [value.path, value.tokens.total]), [["/work/12", 15], ...Array.from({ length: 9 }, (_, index) => [`/work/${11 - index}`, 11 - index])]);
    assert.equal(report.directories[0].unpricedTokens, 3);
    assert.ok(report.directories[0].estimatedCostUSD > 0);
    assert.deepEqual(report.models.map(value => [value.priced, value.tokens.total, value.unpricedTokens]), [[true, 78, 0], [false, 3, 3]]);
    assert.equal(report.models[1].estimatedCostUSD, null);
    assert.ok(Math.abs(report.models[0].estimatedCostUSD - report.totals.last30Days.estimatedCostUSD) < 1e-12);
  });
}

test("a fresh pre-breakdown snapshot migrates through the journal without rereading Transcripts", async t => {
  const f = fixture(t);
  const paths = [f.transcript("claude", "saved", [claude("saved", 50, { cwd: "/work/claude" })]),
    f.transcript("codex", "saved", codex("saved", 60, { cwd: "/work/codex" }))];
  const original = await f.finish();
  const path = join(f.cache(), "buckets.json");
  const snapshot = JSON.parse(readFileSync(path));
  delete snapshot.breakdownsVersion;
  snapshot.buckets = snapshot.buckets.filter(bucket => !("directory" in bucket));
  writeFileSync(path, JSON.stringify(snapshot));
  for (const transcript of paths) chmodSync(transcript, 0);
  assert.equal(f.query().refreshing, true);
  const migrated = await f.finish();
  for (const program of ["claude", "codex"]) assert.deepEqual(usage(migrated, program), usage(original, program));
  assert.equal(JSON.parse(readFileSync(path)).breakdownsVersion, 1);
});

test("replacing a streamed Claude contribution moves its directory without double counting", async t => {
  const f = fixture(t);
  const first = claude("stream", 10, { cwd: "/work/original" });
  const path = f.transcript("claude", "stream", [first]);
  await f.finish();
  appendFileSync(path, records([{ ...first, cwd: "/work/final", message: { ...first.message, usage: { input_tokens: 20, output_tokens: 5 } } }]));
  f.stale();
  const result = usage(await f.finish(), "claude");
  assert.equal(result.totals.today.tokens.total, 25);
  assert.deepEqual(result.directories.map(value => [value.path, value.tokens.total]), [["/work/final", 25]]);
  assert.equal(result.models[0].tokens.total, 25);
  assert.equal(result.directories[0].estimatedCostUSD, result.models[0].estimatedCostUSD);
  f.stale();
  assert.deepEqual(usage(await f.finish(), "claude"), result);
});
