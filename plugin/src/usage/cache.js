import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

export const DAY = 86_400_000;
export const RETENTION = 31 * DAY;
export function usageRoots(runtime) {
  const env = runtime.env;
  const home = env.HOME;
  const absolute = value => resolve(home, value);
  return {
    claude: [...new Set([env.CLAUDE_CONFIG_DIR, join(home, ".claude"), join(env.XDG_CONFIG_HOME || join(home, ".config"), "claude")].filter(Boolean).map(absolute))].sort(),
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
export function processStart(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return null;
  const result = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart="], { encoding: "utf8", timeout: 1000 });
  return result.status === 0 ? result.stdout.trim() || null : null;
}
export function activeLock(directory, now = Date.now()) {
  const lock = readJSON(join(directory, "worker.lock"));
  if (!lock || !Number.isFinite(lock.heartbeat) || now - lock.heartbeat > 10 * 60_000) return null;
  return processStart(lock.pid) === lock.processStart && lock.processStart ? lock : null;
}
export function reserveWorker(directory) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, "worker.lock");
  const admissionPath = join(directory, "worker-start.lock");
  const admission = { pid: process.pid, processStart: processStart(process.pid), token: randomUUID(), heartbeat: Date.now() };
  // Serialize stale-lock reclamation as well as creation. Otherwise two queries
  // could both decide to remove the old lock and one could remove the new one.
  try { writeFileSync(admissionPath, JSON.stringify(admission), { flag: "wx", mode: 0o600 }); }
  catch (error) {
    if (error.code !== "EEXIST") throw error;
    const previous = readJSON(admissionPath);
    if (previous && processStart(previous.pid) !== previous.processStart) {
      if (readJSON(admissionPath)?.token === previous.token) rmSync(admissionPath, { force: true });
    } else if (!previous) {
      try {
        if (Date.now() - statSync(admissionPath).mtimeMs > 10_000) rmSync(admissionPath, { force: true });
      } catch { /* Another query finished admission. */ }
    }
    return null;
  }
  try {
    if (activeLock(directory)) return null;
    rmSync(path, { force: true });
    writeFileSync(path, JSON.stringify(admission), { flag: "wx", mode: 0o600 });
    return admission;
  } finally {
    if (readJSON(admissionPath)?.token === admission.token) rmSync(admissionPath, { force: true });
  }
}
export function releaseWorker(directory, token) {
  const path = join(directory, "worker.lock");
  if (readJSON(path)?.token === token) rmSync(path, { force: true });
}
