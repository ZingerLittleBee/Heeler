import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, statSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { cacheDirectory } from "../src/usage/cache.js";
import { pricingFingerprint } from "../src/usage/pricing.js";

const plugin = fileURLToPath(new URL("..", import.meta.url));

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-usage-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const configDir = join(root, "config with ' quotes");
  const bin = join(root, "bin");
  mkdirSync(bin);
  for (const name of ["codex", "claude"]) {
    writeFileSync(join(bin, name), "#!/bin/sh\nexit 99\n", { mode: 0o700 });
  }
  const env = {
    PATH: bin,
    HOME: join(root, "home"),
    USER: "herdr-account",
    CLAUDE_CONFIG_DIR: join(root, "claude,one"),
    CODEX_HOME: join(root, "codex"),
    XDG_CONFIG_HOME: join(root, "xdg"),
    HERDR_PLUGIN_CONFIG_DIR: configDir,
    HERDR_PLUGIN_STATE_DIR: join(root, "state"),
    HERDR_BIN_PATH: "/missing-herdr-not-needed",
    HERDR_PLUGIN_EVENT_JSON: JSON.stringify({ data: { pane_id: "pane:1", agent_status: "working" } }),
    ANTHROPIC_API_KEY: "must-not-be-recorded",
  };
  function run(entry, args = [], overrides = {}) {
    return spawnSync(process.execPath, [join(plugin, "src", entry), ...args], {
      env: { ...env, ...overrides }, encoding: "utf8", timeout: 10_000,
    });
  }
  return { root, configDir, bin, env, run };
}

test("startup records only the runtime environment in private atomic files", (t) => {
  const f = fixture(t);
  const result = f.run("sidebar-hook.js");
  assert.equal(result.status, 0, result.stderr);
  const runtime = JSON.parse(readFileSync(join(f.configDir, "runtime.json"), "utf8"));
  assert.equal(runtime.version, 1);
  assert.ok(Number.isFinite(Date.parse(runtime.recordedAt)));
  assert.equal(runtime.node, process.execPath);
  assert.equal(runtime.codex, join(f.bin, "codex"));
  assert.equal(runtime.claude, join(f.bin, "claude"));
  assert.deepEqual(runtime.env, Object.fromEntries(["PATH", "HOME", "USER", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME"].map(key => [key, f.env[key]])));
  assert.equal(runtime.stateDir, f.env.HERDR_PLUGIN_STATE_DIR);
  assert.equal(JSON.stringify(runtime).includes("must-not-be-recorded"), false);
  assert.equal(readFileSync(join(f.configDir, "runtime-node"), "utf8"), process.execPath + "\n");
  for (const name of ["runtime.json", "runtime-node"]) {
    assert.equal(statSync(join(f.configDir, name)).mode & 0o777, 0o600);
  }
});

test("status hooks bootstrap and repair runtime files without rewriting unchanged records", (t) => {
  const f = fixture(t);
  let result = f.run("activity-hook.js");
  assert.equal(result.status, 0, result.stderr);
  const runtimePath = join(f.configDir, "runtime.json");
  const nodePath = join(f.configDir, "runtime-node");
  const before = [runtimePath, nodePath].map(path => statSync(path));
  result = f.run("activity-hook.js");
  assert.equal(result.status, 0, result.stderr);
  for (const [index, path] of [runtimePath, nodePath].entries()) {
    const after = statSync(path);
    assert.equal(after.ino, before[index].ino);
    assert.equal(after.mtimeMs, before[index].mtimeMs);
  }
  rmSync(nodePath);
  result = f.run("activity-hook.js");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(nodePath, "utf8"), process.execPath + "\n");
  assert.equal(statSync(runtimePath).ino, before[0].ino);
  result = f.run("activity-hook.js", [], { CODEX_HOME: join(f.root, "new account") });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(readFileSync(runtimePath, "utf8")).env.CODEX_HOME, join(f.root, "new account"));
});

test("query emits only a versioned missing-runtime state before the first hook", (t) => {
  const f = fixture(t);
  const result = f.run("usage-query.js", ["--tz", "Asia/Shanghai"]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { version: 1, runtime: "missing" });
});

test("an activity hook upgrades a runtime recorded before USER was included", (t) => {
  const f = fixture(t);
  assert.equal(f.run("sidebar-hook.js").status, 0);
  const path = join(f.configDir, "runtime.json");
  const previous = JSON.parse(readFileSync(path, "utf8"));
  delete previous.env.USER;
  writeFileSync(path, JSON.stringify(previous));
  const result = f.run("activity-hook.js");
  assert.equal(result.status, 0, result.stderr);
  const current = JSON.parse(readFileSync(path, "utf8"));
  assert.equal(current.env.USER, f.env.USER);
  assert.equal(current.version, previous.version);
  assert.equal(current.stateDir, previous.stateDir);
});

test("query returns the empty cache without exposing runtime paths", async (t) => {
  const f = fixture(t);
  assert.equal(f.run("sidebar-hook.js").status, 0);
  let result;
  let report;
  for (let attempt = 0; attempt < 100; attempt++) {
    result = f.run("usage-query.js", ["--tz", "Asia/Shanghai", "--claude-limits"]);
    assert.equal(result.status, 0, result.stderr);
    report = JSON.parse(result.stdout);
    if (!report.refreshing) break;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(report.refreshing, false);
  assert.ok(Number.isFinite(Date.parse(report.scan.coveredThrough)));
  report.scan.coveredThrough = "2026-10-23T12:34:56.000Z";
  assert.ok(Number.isFinite(Date.parse(report.generatedAt)));
  report.generatedAt = "2026-10-23T12:34:56.000Z";
  const expected = {
    version: 1,
    pricingVersion: JSON.parse(readFileSync(new URL("../src/usage/pricing.json", import.meta.url))).pricingVersion,
    generatedAt: "2026-10-23T12:34:56.000Z",
    timeZone: "Asia/Shanghai",
    runtime: "recorded",
    refreshing: false,
    scan: { state: "complete", coveredFrom: null, coveredThrough: "2026-10-23T12:34:56.000Z", skippedArchives: 0 },
    programs: [
      { program: "claude", tokenUsage: { state: "noData" }, usageLimits: { state: "error", reason: "requestFailed" } },
      { program: "codex", tokenUsage: { state: "noData" }, usageLimits: { state: "error", reason: "requestFailed" } },
    ],
  };
  assert.deepEqual(report, expected);
  assert.equal(result.stdout.includes(f.root), false);

});

test("query treats missing bootstrap, corrupt and incomplete records as runtime missing", (t) => {
  const f = fixture(t);
  assert.equal(f.run("sidebar-hook.js").status, 0);
  rmSync(join(f.configDir, "runtime-node"));
  let result = f.run("usage-query.js", ["--tz", "UTC"]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { version: 1, runtime: "missing" });
  for (const contents of ["not json", '{"version":1}', '{"version":2}']) {
    writeFileSync(join(f.configDir, "runtime.json"), contents);
    result = f.run("usage-query.js", ["--tz", "UTC"]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { version: 1, runtime: "missing" });
  }
});

test("query rejects invalid arguments without reflecting them into output", (t) => {
  const f = fixture(t);
  for (const args of [[], ["--tz", "Not/A_Zone"], ["--tz", "UTC; secret"], ["--tz", "UTC", "--other"]]) {
    const result = f.run("usage-query.js", args);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr, "usage-query: invalid query\n");
  }
});

test("missing programs and optional environment variables are recorded as null", (t) => {
  const f = fixture(t);
  const result = f.run("sidebar-hook.js", [], {
    PATH: join(f.root, "empty-bin"), USER: undefined, CLAUDE_CONFIG_DIR: undefined,
    CODEX_HOME: undefined, XDG_CONFIG_HOME: undefined,
  });
  assert.equal(result.status, 0, result.stderr);
  const runtime = JSON.parse(readFileSync(join(f.configDir, "runtime.json"), "utf8"));
  assert.equal(runtime.codex, null);
  assert.equal(runtime.claude, null);
  assert.equal(runtime.env.USER, null);
  assert.equal(runtime.env.CLAUDE_CONFIG_DIR, null);
  assert.equal(runtime.env.CODEX_HOME, null);
  assert.equal(runtime.env.XDG_CONFIG_HOME, null);
});

test("an absent PATH does not discover programs in the hook working directory", (t) => {
  const f = fixture(t);
  const result = spawnSync(process.execPath, [join(plugin, "src", "sidebar-hook.js")], {
    cwd: f.bin, env: { ...f.env, PATH: undefined }, encoding: "utf8", timeout: 10_000,
  });
  assert.equal(result.status, 0, result.stderr);
  const runtime = JSON.parse(readFileSync(join(f.configDir, "runtime.json"), "utf8"));
  assert.equal(runtime.env.PATH, null);
  assert.equal(runtime.codex, null);
  assert.equal(runtime.claude, null);
});

test("a cached 30-day report with 60480 buckets completes within the SSH deadline", (t) => {
  const f = fixture(t);
  assert.equal(f.run("sidebar-hook.js").status, 0);
  const runtime = JSON.parse(readFileSync(join(f.configDir, "runtime.json"), "utf8"));
  const directory = cacheDirectory(runtime);
  mkdirSync(directory, { recursive: true });
  const now = Date.now();
  const today = new Date(now).toISOString().slice(0, 10);
  const start = Date.parse(today + "T00:00:00Z") - 29 * 86_400_000;
  const buckets = [];
  for (let hour = 0; hour < 30 * 24; hour++) {
    const timestamp = new Date(start + hour * 3_600_000).toISOString();
    for (const [program, input] of [["claude", 1], ["codex", 2]]) {
      for (let index = 0; index < 21; index++) {
        for (const dimension of [{ model: `model-${index}` }, { directory: `/project-${index}` }]) {
          buckets.push({ timestamp, program, ...dimension,
            tokens: { input, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: input },
            estimatedCostUSD: input * 0.25, unpricedTokens: 0 });
        }
      }
    }
  }
  assert.equal(buckets.length, 60480);
  writeFileSync(join(directory, "buckets.json"), JSON.stringify({
    complete: true, generatedAt: new Date(now).toISOString(), coveredThrough: new Date(now).toISOString(),
    checkpoint: { pricingFingerprint }, breakdownsVersion: 1, limitsVersion: 1,
    nextLimitsAt: now + 60_000, buckets,
  }));
  // Exercise the real query process, including JSON decoding and encoding, under
  // the same eight-second budget as the app's remote watchdog.
  const started = performance.now();
  const result = spawnSync(process.execPath, [join(plugin, "src", "usage-query.js"), "--tz", "UTC"], {
    env: f.env, encoding: "utf8", timeout: 8000,
  });
  t.diagnostic(`60480-bucket cached query: ${(performance.now() - started).toFixed(1)} ms`);
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.refreshing, false);
  assert.equal(report.scan.coveredFrom, new Date(start).toISOString().slice(0, 10));
  for (const [index, { tokenUsage }] of report.programs.entries()) {
    const hourly = 21 * (index + 1);
    assert.equal(tokenUsage.state, "ok");
    assert.equal(tokenUsage.totals.today.tokens.total, hourly * 24);
    assert.equal(tokenUsage.totals.last7Days.tokens.total, hourly * 24 * 7);
    assert.equal(tokenUsage.totals.last30Days.tokens.total, hourly * 24 * 30);
    assert.equal(tokenUsage.totals.last30Days.estimatedCostUSD, hourly * 24 * 30 * 0.25);
    assert.equal(tokenUsage.daily.length, 30);
    assert.ok(tokenUsage.daily.every(day => day.tokens.total === hourly * 24));
    assert.equal(tokenUsage.models.length, 21);
    assert.ok(tokenUsage.models.every(model => model.tokens.total === (index + 1) * 24 * 30));
    assert.equal(tokenUsage.directories.length, 10);
    assert.ok(tokenUsage.directories.every(entry => entry.tokens.total === (index + 1) * 24 * 30));
  }
});
