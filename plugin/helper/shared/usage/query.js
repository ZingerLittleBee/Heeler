import { spawn } from "node:child_process";
import { join } from "node:path";
import { cacheDirectory, readJSON, writeJSON, activeLock, reserveWorker, releaseWorker, processStart, refreshFailures } from "./cache.js";
import { reportFromSnapshot } from "./buckets.js";
import { checkpointCurrent } from "./checkpoint.js";
import { readUsageRuntime } from "./runtime-record.js";
import { claudeAccounts, readAccountFile } from "./accounts.js";
import { accountSuggestions } from "./account-suggestions.js";
import { agentDirectories } from "./agent-directories.js";

/**
 * Start one detached worker unless another holds the lock; true while one runs.
 * Throws when no worker can start (an unwritable cache, a full disk).
 */
function startWorker(runtime, directory, claudeLimits, worker) {
  const lock = reserveWorker(directory);
  if (!lock) return Boolean(activeLock(directory));
  try {
    const child = spawn(runtime.node, [worker.path, ...worker.args, "--lock-token", lock.token, ...(claudeLimits ? ["--claude-limits"] : [])], {
      detached: true, stdio: "ignore", env: {
        ...Object.fromEntries(Object.entries(runtime.env).filter(([, value]) => typeof value === "string")),
        ...worker.env,
      },
    });
    child.on("error", () => { try { releaseWorker(directory, lock.token); } catch { /* The lock goes stale. */ } });
    if (!child.pid) throw new Error("The worker did not start.");
    lock.pid = child.pid;
    lock.processStart = processStart(child.pid);
    writeJSON(join(directory, "worker.lock"), lock);
    child.unref();
    return true;
  } catch (error) {
    // A worker that never sees its pid in the lock exits on its own.
    try { releaseWorker(directory, lock.token); } catch { /* The lock goes stale. */ }
    throw error;
  }
}

/**
 * The `usage` v1 report, starting a worker when the snapshot wants one. Throws on
 * a time zone it cannot use. `runtimeDirectory` holds the runtime record,
 * `accountDirectory` the Account file, and `worker` says how to start the
 * worker: its `path`, the `args` naming those directories, and any added `env`.
 */
export function usageReport({ timeZone, claudeLimits, runtimeDirectory, accountDirectory, worker }) {
  if (!timeZone || !/^[A-Za-z_+-]+(?:\/[A-Za-z0-9_+-]+)*$/.test(timeZone)) {
    throw new Error("invalid time zone");
  }
  new Intl.DateTimeFormat("en", { timeZone }).format();
  const runtime = readUsageRuntime(runtimeDirectory);
  if (!runtime) return { version: 1, runtime: "missing" };
  const directory = cacheDirectory(runtime);
  const snapshot = readJSON(join(directory, "buckets.json"));
  const failures = refreshFailures(directory);
  const accountFile = readAccountFile(accountDirectory);
  const accounts = claudeAccounts(runtime, accountFile);
  const counted = accounts.filter(account => account.state === "ok").map(account => account.id);
  // An Account added, removed or back since the last run is counted at once.
  const accountsChanged = !Array.isArray(snapshot?.countedAccounts) || snapshot.countedAccounts.length !== counted.length
    || !counted.every(id => snapshot.countedAccounts.includes(id));
  const stale = !snapshot?.complete || !checkpointCurrent(snapshot?.checkpoint) || accountsChanged
    || snapshot?.breakdownsVersion !== 1 || !(Date.now() - Date.parse(snapshot.generatedAt) <= 60_000);
  let refreshing = false;
  let startFailed = false;
  try {
    refreshing = Boolean(activeLock(directory));
    // Claude Code's next read is the earliest over the Accounts the last run
    // counted; an Account added since then makes the snapshot stale.
    if (!refreshing && !failures.paused && (stale
        || snapshot.limitsVersion !== 1 || !snapshot.nextLimitsAt || Date.now() >= snapshot.nextLimitsAt
        || (claudeLimits && (!snapshot.nextClaudeLimitsAt || Date.now() >= snapshot.nextClaudeLimitsAt)))) {
      refreshing = startWorker(runtime, directory, claudeLimits, worker);
    }
  } catch {
    // The cache cannot be written (read-only, a full disk), so no worker runs.
    refreshing = false;
    startFailed = true;
  }
  // Cached aggregates that no refresh will bring up to date are reported as
  // a failing refresh instead, keeping a program's own scan error.
  const failed = failures.failing ? "The background refresh failed repeatedly."
    : startFailed && stale ? "The background refresh could not start." : null;
  const served = failed ? { ...snapshot, errors: { claude: failed, codex: failed,
    ...Object.fromEntries(counted.map(id => [`claude:${id}`, failed])), ...snapshot?.errors } } : snapshot;
  // Suggestions are checked against the Account file as it is now, not as the last run saw it.
  const suggestions = accountSuggestions({ agents: agentDirectories(runtime.stateDir), accounts, ignored: accountFile.ignored,
    candidates: Array.isArray(snapshot?.claudeCandidates) ? snapshot.claudeCandidates : [] });
  return reportFromSnapshot(served, timeZone, refreshing, Date.now(), claudeLimits, { accounts, suggestions });
}
