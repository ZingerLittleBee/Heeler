import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync, utimesSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { cacheDirectory, reserveWorker, releaseWorker, startTimeFromStat } from "../src/usage/cache.js";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };

// A Host without `ps` or procfs: every start-time lookup fails as it would there.
const withoutProcessStart = `
import { createRequire, syncBuiltinESMExports } from "node:module";
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const fs = require("node:fs");
const { spawnSync } = childProcess;
const { readFileSync } = fs;
const missing = () => Object.assign(new Error("ENOENT"), { code: "ENOENT" });
childProcess.spawnSync = (file, ...rest) => /(^|\\/)ps$/.test(String(file))
  ? { pid: 0, output: [], stdout: "", stderr: "", status: null, signal: null, error: missing() } : spawnSync(file, ...rest);
fs.readFileSync = (file, ...rest) => { if (String(file).startsWith("/proc/")) throw missing(); return readFileSync(file, ...rest); };
syncBuiltinESMExports();
`;

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-worker-lock-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const preload = join(root, "without-process-start.mjs");
  writeFileSync(preload, withoutProcessStart);
  // A full disk: opening still creates a file, but no byte reaches the state directory.
  const diskFull = join(root, "disk-full.mjs");
  writeFileSync(diskFull, `
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
const state = ${JSON.stringify(env.HERDR_PLUGIN_STATE_DIR + "/")};
const { openSync, closeSync, writeSync, writeFileSync } = fs;
const full = () => Object.assign(new Error("ENOSPC: no space left on device"), { code: "ENOSPC" });
const inState = target => typeof target !== "number" && String(target).startsWith(state);
const descriptors = new Set();
fs.openSync = (target, ...rest) => { const fd = openSync(target, ...rest); if (inState(target)) descriptors.add(fd); return fd; };
fs.closeSync = fd => { descriptors.delete(fd); return closeSync(fd); };
fs.writeSync = (fd, ...rest) => { if (descriptors.has(fd)) throw full(); return writeSync(fd, ...rest); };
fs.writeFileSync = (target, data, options) => {
  if (typeof target === "number" ? descriptors.has(target) : inState(target)) {
    if (typeof target !== "number") closeSync(openSync(target, (typeof options === "object" && options?.flag) || "w", 0o600));
    throw full();
  }
  return writeFileSync(target, data, options);
};
syncBuiltinESMExports();
`);
  const launches = join(root, "codex-launches");
  const spawned = [];
  assert.equal(spawnSync(process.execPath, [join(plugin, "src", "sidebar-hook.js")], { env, encoding: "utf8" }).status, 0);
  const runtimePath = join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  const release = join(root, "codex-release");
  /** Record each Codex launch; the first one stays in its limits read for `hang` ms or until released. */
  const codexStub = hang => {
    const executable = join(root, "codex-stub");
    writeFileSync(executable, `#!${process.execPath}
const fs = require('node:fs');
const first = !fs.existsSync(${JSON.stringify(launches)});
fs.appendFileSync(${JSON.stringify(launches)}, process.pid + '\\n');
const started = Date.now();
const wait = () => !first || fs.existsSync(${JSON.stringify(release)}) || Date.now() - started >= ${hang} ? process.exit(1) : setTimeout(wait, 10);
wait();
`, { mode: 0o755 });
    const runtime = JSON.parse(readFileSync(runtimePath, "utf8"));
    runtime.codex = executable;
    writeFileSync(runtimePath, JSON.stringify(runtime));
  };
  const codexLaunches = () => existsSync(launches) ? readFileSync(launches, "utf8").trim().split("\n").map(Number) : [];
  const query = ({ processStart = true, full = false } = {}) => {
    const result = spawnSync(process.execPath, [...(processStart ? [] : ["--import", preload]), ...(full ? ["--import", diskFull] : []),
      join(plugin, "src", "usage-query.js"), "--tz", "UTC"],
      { env, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const lock = () => { try { return JSON.parse(readFileSync(join(cache(), "worker.lock"), "utf8")); } catch { return null; } };
  const finish = async options => {
    for (let i = 0; i < 300; i++) {
      const report = query(options);
      if (!report.refreshing) return report;
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
  /** A long-lived process that stands in for a running owner. */
  const sleeper = () => {
    const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    spawned.push(child.pid);
    return child.pid;
  };
  t.after(() => {
    for (const pid of [...spawned, ...codexLaunches(), lock()?.pid]) {
      if (pid && pid !== process.pid && alive(pid)) try { process.kill(pid, "SIGKILL"); } catch { /* Already gone. */ }
    }
    rmSync(root, { recursive: true, force: true });
  });
  const releaseCodex = () => writeFileSync(release, "");
  return { root, env, query, cache, lock, finish, stale, sleeper, codexStub, codexLaunches, releaseCodex };
}

test("the Linux start time is field 22 even when the command name holds spaces and parentheses", () => {
  const fields = ["S", "1", "4242", "4242", "0", "-1", "4194560", "120", "0", "0", "0", "10", "5", "0", "0", "20", "0", "11", "0", "987654", "123456"];
  assert.equal(startTimeFromStat(`4242 (node) ${fields.join(" ")} 789\n`), "987654");
  assert.equal(startTimeFromStat(`4242 (a) b (c) ) ${fields.join(" ")}\n`), "987654");
  assert.equal(startTimeFromStat("4242 (zombie) Z 1"), null);
  assert.equal(startTimeFromStat("not a stat line"), null);
});

test("without any start-time source a running worker keeps its lock and no second worker starts", async t => {
  const f = fixture(t);
  // The worker stays in its limits read until the test releases it.
  f.codexStub(30_000);
  assert.equal(f.query({ processStart: false }).refreshing, true);
  for (let i = 0; i < 300 && f.codexLaunches().length === 0; i++) await sleep(10);
  const first = f.lock();
  assert.ok(first, "the worker holds its lock during the limits read");
  assert.equal(first.processStart, null);
  assert.notEqual(first.pid, process.pid);
  for (let i = 0; i < 3; i++) {
    assert.equal(f.query({ processStart: false }).refreshing, true);
    const current = f.lock();
    assert.equal(current?.token, first.token);
    assert.equal(current?.pid, first.pid);
    await sleep(50);
  }
  f.releaseCodex();
  assert.equal((await f.finish({ processStart: false })).refreshing, false);
  assert.equal(f.codexLaunches().length, 1);
});

test("without any start-time source a dead or silent worker's lock is still reclaimed", async t => {
  const f = fixture(t);
  await f.finish();
  const path = join(f.cache(), "worker.lock");
  const owner = f.sleeper();
  const lock = { pid: owner, processStart: null, token: "no-start-time", heartbeat: Date.now() };
  for (const changes of [{ pid: 99999999 }, { heartbeat: Date.now() - 11 * 60_000 }]) {
    f.stale();
    writeFileSync(path, JSON.stringify({ ...lock, ...changes }));
    assert.equal(f.query({ processStart: false }).refreshing, true);
    assert.notEqual(f.lock()?.token, lock.token);
    assert.equal((await f.finish({ processStart: false })).scan.state, "complete");
  }
  f.stale();
  writeFileSync(path, JSON.stringify(lock));
  assert.equal(f.query({ processStart: false }).refreshing, true);
  assert.equal(f.lock()?.token, lock.token);
  rmSync(path);
});

test("an abandoned admission without a start time is reclaimed by pid or age", t => {
  const f = fixture(t);
  const directory = join(f.root, "admission");
  mkdirSync(directory);
  const admissionPath = join(directory, "worker-start.lock");
  const admission = changes => writeFileSync(admissionPath, JSON.stringify({ pid: 99999999, processStart: null, token: "abandoned", heartbeat: Date.now(), ...changes }));
  const reclaim = () => {
    // The reclaiming query proceeds with its own reservation at once.
    const lock = reserveWorker(directory);
    assert.ok(lock);
    assert.equal(existsSync(admissionPath), false);
    releaseWorker(directory, lock.token);
  };
  admission();
  reclaim();
  // A live owner holds admission only briefly; past ten seconds it is abandoned too.
  admission({ pid: f.sleeper() });
  assert.equal(reserveWorker(directory), null);
  assert.equal(existsSync(admissionPath), true);
  const old = (Date.now() - 11_000) / 1000;
  utimesSync(admissionPath, old, old);
  reclaim();
});

test("a worker that dies during the Codex limits read leaves the read throttled", async t => {
  const f = fixture(t);
  f.codexStub(30_000);
  assert.equal(f.query().refreshing, true);
  for (let i = 0; i < 300 && f.codexLaunches().length === 0; i++) await sleep(10);
  assert.equal(f.codexLaunches().length, 1);
  const worker = f.lock().pid;
  process.kill(worker, "SIGKILL");
  process.kill(f.codexLaunches()[0], "SIGKILL");
  for (let i = 0; i < 300 && alive(worker); i++) await sleep(10);
  const report = await f.finish();
  assert.equal(f.codexLaunches().length, 1);
  assert.equal(report.programs.find(program => program.program === "codex").usageLimits.state, "error");
});

const cannotStart = Array(2).fill({ state: "error", reason: "The background refresh could not start." });

test("a cache directory the query cannot write serves a current report and fails a stale one", { skip: process.getuid?.() === 0 && "root ignores directory modes" }, async t => {
  const f = fixture(t);
  const cached = await f.finish();
  chmodSync(f.cache(), 0o500);
  let current;
  let stale;
  try {
    current = f.query();
    f.stale();
    stale = f.query();
  } finally { chmodSync(f.cache(), 0o700); }
  assert.deepEqual(current.programs, cached.programs);
  assert.equal(stale.refreshing, false);
  assert.deepEqual(stale.programs.map(program => program.tokenUsage), cannotStart);
  assert.deepEqual(stale.programs.map(program => program.usageLimits), cached.programs.map(program => program.usageLimits));
  assert.equal(existsSync(join(f.cache(), "worker.lock")), false);
});

test("a state directory the query cannot write fails the refresh before any cache exists", { skip: process.getuid?.() === 0 && "root ignores directory modes" }, t => {
  const f = fixture(t);
  const usage = join(f.env.HERDR_PLUGIN_STATE_DIR, "usage");
  mkdirSync(usage, { recursive: true });
  chmodSync(usage, 0o500);
  let report;
  try { report = f.query(); } finally { chmodSync(usage, 0o700); }
  assert.equal(report.refreshing, false);
  assert.deepEqual(report.programs.map(program => program.tokenUsage), cannotStart);
  // No run will read the limits, so they are not reported as being read.
  assert.deepEqual(report.programs.map(program => program.usageLimits), [{ state: "disabled" }, { state: "error", reason: "requestFailed" }]);
  assert.deepEqual(readdirSync(usage), []);
});

test("a full disk fails the refresh at once and leaves no empty lock behind", async t => {
  const f = fixture(t);
  const cached = await f.finish();
  f.stale();
  for (let i = 0; i < 3; i++) {
    const report = f.query({ full: true });
    assert.equal(report.refreshing, false);
    assert.deepEqual(report.programs.map(program => program.tokenUsage), cannotStart);
    assert.deepEqual(report.programs.map(program => program.usageLimits), cached.programs.map(program => program.usageLimits));
    assert.deepEqual(readdirSync(f.cache()).filter(name => name.endsWith(".lock") || name.endsWith(".tmp")), []);
  }
  // Once space is free, the next query starts the refresh.
  assert.equal(f.query().refreshing, true);
  assert.deepEqual((await f.finish()).programs.map(program => program.tokenUsage.state), ["noData", "noData"]);
});

test("a worker that keeps failing stops the refresh with an error until the back-off ends", async t => {
  const f = fixture(t);
  const directory = cacheDirectory(JSON.parse(readFileSync(join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json"), "utf8")));
  const failurePath = join(directory, "failure.json");
  // Every run fails: the contribution log cannot be created.
  mkdirSync(join(directory, "keys.log"), { recursive: true });
  let report;
  for (let i = 0; i < 200; i++) {
    report = f.query();
    if (!report.refreshing) break;
    await sleep(20);
  }
  assert.equal(report.refreshing, false);
  assert.deepEqual(report.programs.map(program => program.tokenUsage.state), ["error", "error"]);
  // No run reads the limits during the back-off, so they are not shown as being read.
  assert.deepEqual(report.programs.map(program => program.usageLimits), [{ state: "disabled" }, { state: "error", reason: "requestFailed" }]);
  const failure = JSON.parse(readFileSync(failurePath, "utf8"));
  assert.equal(failure.failures, 3);
  // Within the back-off no further worker starts.
  assert.equal(f.query().refreshing, false);
  assert.equal(existsSync(join(directory, "worker.lock")), false);
  assert.equal(JSON.parse(readFileSync(failurePath, "utf8")).failures, 3);
  // After it, one retry runs; its success clears the failures.
  rmSync(join(directory, "keys.log"), { recursive: true });
  writeFileSync(failurePath, JSON.stringify({ ...failure, at: Date.now() - 11 * 60_000 }));
  assert.equal(f.query().refreshing, true);
  report = await f.finish();
  assert.equal(existsSync(failurePath), false);
  assert.deepEqual(report.programs.map(program => program.tokenUsage.state), ["noData", "noData"]);
});

test("each abandoned worker lock counts as one failed refresh", t => {
  const f = fixture(t);
  const directory = join(f.root, "abandoned");
  mkdirSync(directory);
  for (let run = 1; run <= 3; run++) {
    writeFileSync(join(directory, "worker.lock"), JSON.stringify({ pid: 99999999, processStart: null, token: `crashed-${run}`, heartbeat: Date.now() }));
    const lock = reserveWorker(directory);
    assert.ok(lock);
    releaseWorker(directory, lock.token);
    assert.equal(JSON.parse(readFileSync(join(directory, "failure.json"), "utf8")).failures, run);
  }
});
