import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, symlinkSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const codexLimits = report => report.programs.find(program => program.program === "codex").usageLimits;

function fixture(t, mode = "success") {
  const root = mkdtempSync(join(tmpdir(), "heeler-codex-limits-"));
  const bin = join(root, "bin");
  const env = { PATH: `${bin}:/usr/bin:/bin`, HOME: join(root, "home"), CODEX_HOME: join(root, "codex-home"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing",
    https_proxy: "http://proxy.invalid:3128", NO_PROXY: "localhost", CODEX_CA_CERTIFICATE: join(root, "ca.pem") };
  mkdirSync(bin, { recursive: true });
  mkdirSync(env.CODEX_HOME);
  symlinkSync(process.execPath, join(bin, "node"));
  const requests = join(root, "requests.jsonl");
  const expires = Math.floor(Date.now() / 1000) + (mode === "expired" ? -60 : mode === "near-reset" ? 2 : 3600);
  const executable = join(bin, "codex");
  if (mode !== "missing") writeFileSync(executable, `#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const readline = require('node:readline');
assert.deepEqual(process.argv.slice(2), ['-s', 'read-only', '-a', 'never', 'app-server']);
assert.equal(process.env.CODEX_HOME, ${JSON.stringify(env.CODEX_HOME)});
assert.equal(process.env.HOME, ${JSON.stringify(env.HOME)});
for (const name of ['https_proxy', 'NO_PROXY', 'CODEX_CA_CERTIFICATE']) assert.equal(process.env[name], ${JSON.stringify(env)}[name], name);
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
const mode = ${JSON.stringify(mode)};
let initialized = false;
readline.createInterface({input: process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  fs.appendFileSync(${JSON.stringify(requests)}, line + '\\n');
  if (request.method === 'initialize') send({id: request.id, result: {userAgent: 'fixture'}});
  else if (request.method === 'initialized') initialized = true;
  else if (request.method === 'account/read') {
    assert.equal(initialized, true);
    // Codex 0.48.0 to 0.56 declare account/read but do not implement it.
    if (mode === 'legacy') return send({id: request.id, error: {code: -32603, message: 'account/read is not implemented yet'}});
    if (mode === 'unknown-bare') return send({id: request.id, error: {code: -32600, message: 'Invalid request'}});
    const account = mode === 'signed-out' || mode === 'third-party' ? null : {type: mode === 'api-key' ? 'apiKey' : 'chatgpt', email: 'private-account@example.invalid', planType: 'plus'};
    send({id: request.id, result: {account, requiresOpenaiAuth: mode !== 'third-party'}});
  } else if (request.method === 'account/rateLimits/read') {
    assert.equal(Object.hasOwn(request, 'params'), false);
    if (mode === 'timeout') return;
    if (mode === 'unknown') return send({id: request.id, error: {code: -32601, message: 'unknown method'}});
    if (mode === 'unknown-variant') return send({id: request.id, error: {code: -32600, message: 'Invalid request: unknown variant \`account/rateLimits/read\`, expected one of \`initialize\`'}});
    if (mode === 'unknown-bare') return send({id: request.id, error: {code: -32600, message: 'Invalid request'}});
    if (mode === 'invalid-params') return send({id: request.id, error: {code: -32600, message: 'Invalid request: invalid type: string, expected a boolean'}});
    if (mode === 'error') return send({id: request.id, error: {code: -32000, message: 'private-account@example.invalid private failure'}});
    if (mode === 'malformed') return send({id: request.id, result: {unexpected: true}});
    const reset = mode === 'near-reset' ? Math.floor(Date.now() / 1000) + 2 : ${expires};
    const primary = mode === 'legacy' ? {used_percent: 18, window_minutes: 10080, resets_at: reset} : {usedPercent: 18, windowDurationMins: 10080, resetsAt: reset};
    const result = {rateLimits: {primary, secondary: null}, rateLimitsByLimitId: {other: {primary: {usedPercent: 99, windowDurationMins: 1, resetsAt: ${expires}}}}};
    const reply = () => send({id: request.id, result});
    if (mode === 'slow') setTimeout(reply, 1000); else reply();
  } else assert.fail('unexpected request');
});
`, { mode: 0o755 });
  const hook = spawnSync(process.execPath, [join(plugin, "src/sidebar-hook.js")], { env, encoding: "utf8" });
  assert.equal(hook.status, 0, hook.stderr);
  const query = () => {
    const result = spawnSync(process.execPath, [join(plugin, "src/usage-query.js"), "--tz", "UTC"], {
      env: { HERDR_PLUGIN_CONFIG_DIR: env.HERDR_PLUGIN_CONFIG_DIR, HOME: join(root, "wrong-home"), PATH: "/usr/bin:/bin" },
      encoding: "utf8", timeout: 10_000,
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const finish = async () => {
    for (let count = 0; count < 500; count++) { const report = query(); if (!report.refreshing) return report; await sleep(25); }
    assert.fail("worker did not finish");
  };
  const transcript = records => {
    const directory = join(env.CODEX_HOME, "sessions/2026/10/23");
    mkdirSync(directory, { recursive: true });
    const path = join(directory, "rollout-limits.jsonl");
    writeFileSync(path, [{type: "session_meta", timestamp: new Date().toISOString(), payload: {id: "limits", cwd: "/work/project"}}, ...records].map(record => JSON.stringify(record)).join("\n") + "\n");
    return path;
  };
  t.after(() => {
    try { const lock = JSON.parse(readFileSync(join(cache(), "worker.lock"))); process.kill(lock.pid, "SIGKILL"); } catch { /* Finished worker. */ }
    rmSync(root, { recursive: true, force: true });
  });
  const stale = () => {
    const path = join(cache(), "buckets.json");
    const snapshot = JSON.parse(readFileSync(path));
    snapshot.generatedAt = new Date(Date.now() - 61_000).toISOString();
    writeFileSync(path, JSON.stringify(snapshot));
  };
  return { root, env, query, finish, cache, transcript, expires, requests, executable, stale, bin };
}

test("Codex limits use the recorded npm-style executable environment and default weekly group", async t => {
  const f = fixture(t);
  const report = await f.finish();
  assert.deepEqual(codexLimits(report), { state: "ok", source: "service", plan: "plus", observedAt: codexLimits(report).observedAt,
    windows: [{id: "primary", durationMinutes: 10080, usedPercent: 18, resetsAt: new Date(f.expires * 1000).toISOString(), expired: false}] });
  assert.equal(Number.isFinite(Date.parse(codexLimits(report).observedAt)), true);
  assert.equal(JSON.stringify(report).includes("private-account"), false);
  assert.equal(readFileSync(join(f.cache(), "limits.json"), "utf8").includes("private-account"), false);
  assert.deepEqual(readFileSync(f.requests, "utf8").trim().split("\n").map(line => JSON.parse(line).method), ["initialize", "initialized", "account/read", "account/rateLimits/read"]);
});

const rolloutLimits = (timestamp, primary, extra = {}) => ({ type: "event_msg", timestamp,
  payload: { type: "token_count", info: null, rate_limits: { primary, secondary: null, ...extra } } });

test("Codex without account/read still reads its snake-case limits without a plan", async t => {
  const f = fixture(t, "legacy");
  const limits = codexLimits(await f.finish());
  assert.equal(limits.source, "service");
  assert.equal(Object.hasOwn(limits, "plan"), false);
  assert.equal(limits.windows[0].usedPercent, 18);
  assert.equal(limits.windows[0].durationMinutes, 10080);
  assert.deepEqual(readFileSync(f.requests, "utf8").trim().split("\n").map(line => JSON.parse(line).method), ["initialize", "initialized", "account/read", "account/rateLimits/read"]);
});

for (const [mode, state, reason] of [["missing", "unavailable", "programMissing"], ["unknown", "unavailable", "programTooOld"],
  ["unknown-variant", "unavailable", "programTooOld"], ["unknown-bare", "unavailable", "programTooOld"], ["invalid-params", "error", "requestFailed"],
  ["signed-out", "unavailable", "notSignedIn"], ["error", "error", "requestFailed"], ["malformed", "error", "invalidResponse"], ["timeout", "error", "timeout"]]) {
  for (const fallback of [false, true]) test(`${mode} ${fallback ? "uses the latest default rollout snapshot" : "reports a filtered failure without a snapshot"}`, async t => {
    const f = fixture(t, mode);
    const observedAt = new Date(Date.now() - 60_000).toISOString();
    if (fallback) f.transcript([
      rolloutLimits(new Date(Date.now() - 120_000).toISOString(), {used_percent: 4, window_minutes: 300, resets_at: f.expires}),
      rolloutLimits(observedAt, {used_percent: 32, window_minutes: 10080, resets_at: f.expires}, {limit_id: "codex", plan_type: "pro"}),
      rolloutLimits(new Date().toISOString(), {used_percent: 99, window_minutes: 60, resets_at: f.expires}, {limit_id: "other"}),
    ]);
    const report = await f.finish();
    const limits = codexLimits(report);
    if (fallback) {
      assert.equal(limits.state, "ok");
      assert.equal(limits.source, "lastSession");
      assert.equal(limits.observedAt, observedAt);
      assert.equal(limits.plan, "pro");
      assert.equal(limits.windows[0].usedPercent, 32);
    } else assert.deepEqual(limits, {state, reason});
    assert.equal(JSON.stringify(report).includes("private-account"), false);
  });
}

for (const mode of ["api-key", "third-party"]) test(`${mode} accounts without plan limits never reuse a previous session's limits`, async t => {
  const f = fixture(t, mode);
  f.transcript([rolloutLimits(new Date().toISOString(), {used_percent: 33, window_minutes: 300, resets_at: f.expires})]);
  assert.deepEqual(codexLimits(await f.finish()), {state: "unavailable", reason: "noPlanLimits"});
  assert.equal(readFileSync(f.requests, "utf8").includes("account/rateLimits/read"), false);
});

test("rollout relative resets expire and absent reset times remain unknown", async t => {
  const f = fixture(t, "missing");
  const observedAt = new Date(Date.now() - 120_000).toISOString();
  f.transcript([rolloutLimits(observedAt, {used_percent: 88, window_minutes: 300, resets_in_seconds: 60}, {
    secondary: {used_percent: 25, window_minutes: 10080},
  })]);
  const limits = codexLimits(await f.finish());
  assert.deepEqual(limits.windows, [
    {id: "primary", durationMinutes: 300, usedPercent: null, resetsAt: new Date(Date.parse(observedAt) + 60_000).toISOString(), expired: true},
    {id: "secondary", durationMinutes: 10080, usedPercent: 25, resetsAt: null, expired: false},
  ]);
});

test("incremental scans retain and replace their newest rollout reading", async t => {
  const f = fixture(t, "missing");
  const path = f.transcript([rolloutLimits(new Date(Date.now() - 120_000).toISOString(), {used_percent: 7, window_minutes: 300, resets_at: f.expires})]);
  assert.equal(codexLimits(await f.finish()).windows[0].usedPercent, 7);
  appendFileSync(path, JSON.stringify(rolloutLimits(new Date(Date.now() - 60_000).toISOString(), {used_percent: 11, window_minutes: 300, resets_at: f.expires})) + "\n");
  f.stale();
  assert.equal(codexLimits(await f.finish()).windows[0].usedPercent, 11);
  f.stale();
  assert.equal(codexLimits(await f.finish()).windows[0].usedPercent, 11);
});

test("refreshing remains true through the program request and fresh readings are not requested twice", async t => {
  const f = fixture(t, "slow");
  f.query();
  for (let i = 0; i < 100; i++) {
    try { if (readFileSync(f.requests, "utf8").includes("account/rateLimits/read")) break; } catch { /* Starting. */ }
    await sleep(10);
  }
  const duringRequest = f.query();
  assert.equal(duringRequest.refreshing, true);
  assert.equal(duringRequest.scan.state, "complete");
  assert.equal(codexLimits(await f.finish()).state, "ok");
  assert.equal(f.query().refreshing, false);
  assert.equal(readFileSync(f.requests, "utf8").trim().split("\n").length, 4);
});

test("a recorded executable whose interpreter no longer runs is unavailable", async t => {
  const f = fixture(t);
  rmSync(join(f.bin, "node"));
  assert.deepEqual(codexLimits(await f.finish()), {state: "unavailable", reason: "programMissing"});
});

test("service readings expire without inventing a new window's usage", async t => {
  const f = fixture(t, "expired");
  const limits = codexLimits(await f.finish());
  assert.equal(limits.source, "service");
  assert.equal(limits.windows[0].expired, true);
  assert.equal(limits.windows[0].usedPercent, null);
});

test("a cached service window expires at query time without a second program request", async t => {
  const f = fixture(t, "near-reset");
  assert.equal(codexLimits(await f.finish()).windows[0].expired, false);
  await sleep(2500);
  const report = f.query();
  assert.equal(report.refreshing, false);
  assert.equal(codexLimits(report).windows[0].expired, true);
  assert.equal(codexLimits(report).windows[0].usedPercent, null);
  assert.equal(readFileSync(f.requests, "utf8").trim().split("\n").length, 4);
});

test("deleting the only fallback Transcript clears its cached limits", async t => {
  const f = fixture(t, "missing");
  const path = f.transcript([rolloutLimits(new Date().toISOString(), {used_percent: 7, window_minutes: 300, resets_at: f.expires})]);
  assert.equal(codexLimits(await f.finish()).source, "lastSession");
  rmSync(path);
  f.stale();
  assert.deepEqual(codexLimits(await f.finish()), {state: "unavailable", reason: "programMissing"});
});

test("a pre-limits checkpoint rescans unchanged Transcripts to find the fallback", async t => {
  const f = fixture(t, "missing");
  f.transcript([rolloutLimits(new Date().toISOString(), {used_percent: 7, window_minutes: 300, resets_at: f.expires})]);
  await f.finish();
  const path = join(f.cache(), "buckets.json");
  const snapshot = JSON.parse(readFileSync(path));
  delete snapshot.limitsVersion;
  delete snapshot.usageLimits;
  writeFileSync(path, JSON.stringify(snapshot));
  assert.equal(f.query().refreshing, true);
  assert.equal(codexLimits(await f.finish()).windows[0].usedPercent, 7);
});

test("the rollout fallback skips newer snapshots without any window", async t => {
  const f = fixture(t, "missing");
  f.transcript([
    rolloutLimits(new Date(Date.now() - 120_000).toISOString(), {used_percent: 7, window_minutes: 300, resets_at: f.expires}),
    rolloutLimits(new Date(Date.now() - 60_000).toISOString(), null),
  ]);
  const limits = codexLimits(await f.finish());
  assert.equal(limits.source, "lastSession");
  assert.equal(limits.windows.length, 1);
  assert.equal(limits.windows[0].usedPercent, 7);
});
