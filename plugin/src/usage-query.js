#!/usr/bin/env node
import { parseArgs } from "node:util";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { cacheDirectory, readJSON, writeJSON, activeLock, reserveWorker, releaseWorker, processStart, refreshFailures } from "./usage/cache.js";
import { reportFromSnapshot } from "./usage/buckets.js";
import { checkpointCurrent } from "./usage/checkpoint.js";
import { readUsageRuntime } from "./usage-runtime.js";
import { claudeAccounts, readAccountFile } from "./usage/accounts.js";
import { accountSuggestions } from "./usage/account-suggestions.js";
import { agentDirectories } from "./usage/claude-agents.js";

/**
 * Start one detached worker unless another holds the lock; true while one runs.
 * Throws when no worker can start (an unwritable cache, a full disk).
 */
function startWorker(runtime, directory, claudeLimits) {
  const lock = reserveWorker(directory);
  if (!lock) return Boolean(activeLock(directory));
  try {
    const worker = spawn(runtime.node, [fileURLToPath(new URL("./usage-worker.js", import.meta.url)), "--config", process.env.HERDR_PLUGIN_CONFIG_DIR, "--lock-token", lock.token, ...(claudeLimits ? ["--claude-limits"] : [])], {
      detached: true, stdio: "ignore", env: {
        ...Object.fromEntries(Object.entries(runtime.env).filter(([, value]) => typeof value === "string")),
        // The worker asks this herdr server to read Claude Code's limits.
        ...(process.env.HERDR_SOCKET_PATH ? { HERDR_SOCKET_PATH: process.env.HERDR_SOCKET_PATH } : {}),
      },
    });
    worker.on("error", () => { try { releaseWorker(directory, lock.token); } catch { /* The lock goes stale. */ } });
    if (!worker.pid) throw new Error("The worker did not start.");
    lock.pid = worker.pid;
    lock.processStart = processStart(worker.pid);
    writeJSON(join(directory, "worker.lock"), lock);
    worker.unref();
    return true;
  } catch (error) {
    // A worker that never sees its pid in the lock exits on its own.
    try { releaseWorker(directory, lock.token); } catch { /* The lock goes stale. */ }
    throw error;
  }
}

try {
  const { values } = parseArgs({
    options: { tz: { type: "string" }, "claude-limits": { type: "boolean", default: false } },
    allowPositionals: false,
  });
  const timeZone = values.tz;
  if (!timeZone || !/^[A-Za-z_+-]+(?:\/[A-Za-z0-9_+-]+)*$/.test(timeZone)) {
    throw new Error("invalid time zone");
  }
  new Intl.DateTimeFormat("en", { timeZone }).format();
  const runtime = readUsageRuntime(process.env.HERDR_PLUGIN_CONFIG_DIR);
  let report = { version: 1, runtime: "missing" };
  if (runtime) {
    const directory = cacheDirectory(runtime);
    const snapshot = readJSON(join(directory, "buckets.json"));
    const failures = refreshFailures(directory);
    const accountFile = readAccountFile(process.env.HERDR_PLUGIN_CONFIG_DIR);
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
          || (values["claude-limits"] && (!snapshot.nextClaudeLimitsAt || Date.now() >= snapshot.nextClaudeLimitsAt)))) {
        refreshing = startWorker(runtime, directory, values["claude-limits"]);
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
    const served = failed ? { ...snapshot, errors: { claude: failed, codex: failed, ...snapshot?.errors } } : snapshot;
    // Suggestions are checked against the Account file as it is now, not as the last run saw it.
    const suggestions = accountSuggestions({ agents: agentDirectories(runtime.stateDir), accounts, ignored: accountFile.ignored,
      candidates: Array.isArray(snapshot?.claudeCandidates) ? snapshot.claudeCandidates : [] });
    report = reportFromSnapshot(served, timeZone, refreshing, Date.now(), values["claude-limits"], { accounts, suggestions });
  }
  console.log(JSON.stringify(report));
} catch {
  // Never echo arguments or Host configuration into the response.
  console.error("usage-query: invalid query");
  process.exitCode = 1;
}
