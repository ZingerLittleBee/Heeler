import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, writeFileSync, renameSync, rmSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

export const DAY = 86_400_000;
export const RETENTION = 31 * DAY;
/**
 * The roots this environment names. Claude Code's are the Default Account's:
 * the directory Claude Code uses, first, with the legacy XDG one folded in.
 * Added Accounts are not roots, so adding one never moves the cache.
 */
export function usageRoots(runtime) {
  const env = runtime.env;
  const home = env.HOME;
  const absolute = value => resolve(home, value);
  return {
    claude: [...new Set([env.CLAUDE_CONFIG_DIR || join(home, ".claude"), join(env.XDG_CONFIG_HOME || join(home, ".config"), "claude")].map(absolute))],
    codex: [absolute(env.CODEX_HOME || join(home, ".codex"))],
  };
}
export function cacheDirectory(runtime) {
  const roots = usageRoots(runtime);
  const key = createHash("sha256").update(JSON.stringify(roots)).digest("hex").slice(0, 20);
  return join(runtime.stateDir, "usage", key);
}
export function readJSON(path) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return null; }
}
export function writeJSON(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, JSON.stringify(value) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(temporary, path);
  } finally { rmSync(temporary, { force: true }); }
}
/** Linux `/proc/<pid>/stat` field 22: the start time in clock ticks since boot. */
export function startTimeFromStat(text) {
  // The command name (field 2) may contain spaces and parentheses.
  const end = text.lastIndexOf(")");
  if (end < 0) return null;
  const start = text.slice(end + 1).trim().split(/\s+/)[22 - 3];
  return /^\d+$/.test(start ?? "") ? start : null;
}
/** An opaque start time that tells a reused pid apart, or null when unavailable. */
export function processStart(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return null;
  if (process.platform === "linux") {
    // Minimal images and BusyBox lack a usable `ps -p`; procfs is always there.
    try { return startTimeFromStat(readFileSync(`/proc/${pid}/stat`, "utf8")); } catch { return null; }
  }
  const result = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart="], { encoding: "utf8", timeout: 1000 });
  return result.status === 0 ? result.stdout.trim() || null : null;
}
function pidExists(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === "EPERM"; }
}
/** Compare start times when both are known; otherwise a live pid keeps its record. */
function ownerRunning(record) {
  const current = processStart(record.pid);
  if (current !== null && record.processStart) return current === record.processStart;
  return pidExists(record.pid);
}
export function activeLock(directory, now = Date.now()) {
  const lock = readJSON(join(directory, "worker.lock"));
  if (!lock || !Number.isFinite(lock.heartbeat) || now - lock.heartbeat > 10 * 60_000) return null;
  return ownerRunning(lock) ? lock : null;
}
/**
 * Create a file that must not exist yet. A write that fails (a full disk)
 * removes the file it created, so no empty lock outlives the error.
 */
function createExclusive(path, contents) {
  const descriptor = openSync(path, "wx", 0o600);
  let written = false;
  try {
    writeFileSync(descriptor, contents);
    written = true;
  } finally {
    try { closeSync(descriptor); } finally { if (!written) rmSync(path, { force: true }); }
  }
}
const pause = milliseconds => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
/**
 * Reserve the next worker run, or return null when a worker already holds the
 * lock or another query keeps admission past a short wait. Throws when the
 * cache cannot be written.
 */
export function reserveWorker(directory) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, "worker.lock");
  const admissionPath = join(directory, "worker-start.lock");
  const admission = { pid: process.pid, processStart: processStart(process.pid), token: randomUUID(), heartbeat: Date.now() };
  // Serialize stale-lock reclamation as well as creation. Otherwise two queries
  // could both decide to remove the old lock and one could remove the new one.
  // Admission lasts milliseconds: wait for a live holder, so the lock it
  // writes decides whether a worker is running.
  for (let attempt = 0; ; attempt++) {
    try {
      createExclusive(admissionPath, JSON.stringify(admission));
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    if (attempt >= 50) return null;
    const previous = readJSON(admissionPath);
    let age;
    try { age = Date.now() - statSync(admissionPath).mtimeMs; } catch { continue; /* Another query finished admission. */ }
    // A dead owner or an old file was abandoned.
    if (age > 10_000 || (previous && !ownerRunning(previous))) {
      if (!previous || readJSON(admissionPath)?.token === previous.token) rmSync(admissionPath, { force: true });
      continue;
    }
    pause(10);
  }
  try {
    if (activeLock(directory)) return null;
    // Workers release their lock even when they fail; one left behind ended a
    // run that crashed or hung.
    if (existsSync(path)) {
      try { recordFailure(directory); } catch { /* The lock write below reports it. */ }
    }
    rmSync(path, { force: true });
    createExclusive(path, JSON.stringify(admission));
    return admission;
  } finally {
    if (readJSON(admissionPath)?.token === admission.token) rmSync(admissionPath, { force: true });
  }
}
const FAILURE_LIMIT = 3;
const FAILURE_BACKOFF = 10 * 60_000;
/** Count one refresh that ended without its final snapshot. */
export function recordFailure(directory, now = Date.now()) {
  const path = join(directory, "failure.json");
  const failures = readJSON(path)?.failures;
  writeJSON(path, { failures: (Number.isSafeInteger(failures) && failures > 0 ? failures : 0) + 1, at: now });
}
export function clearFailures(directory) {
  rmSync(join(directory, "failure.json"), { force: true });
}
/** After repeated failures the report says so, and no worker starts until the back-off ends. */
export function refreshFailures(directory, now = Date.now()) {
  const record = readJSON(join(directory, "failure.json"));
  const failing = Number.isSafeInteger(record?.failures) && record.failures >= FAILURE_LIMIT;
  const age = now - record?.at;
  return { failing, paused: failing && age >= 0 && age < FAILURE_BACKOFF };
}
export function releaseWorker(directory, token) {
  const path = join(directory, "worker.lock");
  if (readJSON(path)?.token === token) rmSync(path, { force: true });
}
