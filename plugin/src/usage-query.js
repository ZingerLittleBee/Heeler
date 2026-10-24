#!/usr/bin/env node
import { parseArgs } from "node:util";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { cacheDirectory, readJSON, writeJSON, activeLock, reserveWorker, releaseWorker, processStart } from "./usage/cache.js";
import { reportFromSnapshot } from "./usage/buckets.js";
import { pricingFingerprint } from "./usage/pricing.js";
import { readUsageRuntime } from "./usage-runtime.js";

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
    let refreshing = Boolean(activeLock(directory));
    if (!refreshing && (!snapshot?.complete || snapshot?.checkpoint?.pricingFingerprint !== pricingFingerprint
        || snapshot?.breakdownsVersion !== 1 || Date.now() - Date.parse(snapshot.generatedAt) > 60_000
        || snapshot.limitsVersion !== 1 || !snapshot.nextLimitsAt || Date.now() >= snapshot.nextLimitsAt
        || (values["claude-limits"] && (!snapshot.nextClaudeLimitsAt || Date.now() >= snapshot.nextClaudeLimitsAt)))) {
      const lock = reserveWorker(directory);
      if (lock) {
        try {
          const worker = spawn(runtime.node, [fileURLToPath(new URL("./usage-worker.js", import.meta.url)), "--config", process.env.HERDR_PLUGIN_CONFIG_DIR, "--lock-token", lock.token, ...(values["claude-limits"] ? ["--claude-limits"] : [])], {
            detached: true, stdio: "ignore", env: Object.fromEntries(Object.entries(runtime.env).filter(([, value]) => typeof value === "string")),
          });
          worker.on("error", () => releaseWorker(directory, lock.token));
          if (worker.pid) {
            lock.pid = worker.pid;
            lock.processStart = processStart(worker.pid);
            writeJSON(join(directory, "worker.lock"), lock);
            worker.unref();
            refreshing = true;
          } else { releaseWorker(directory, lock.token); }
        } catch { releaseWorker(directory, lock.token); }
      } else { refreshing = true; }
    }
    report = reportFromSnapshot(snapshot, timeZone, refreshing, Date.now(), values["claude-limits"]);
  }
  console.log(JSON.stringify(report));
} catch {
  // Never echo arguments or Host configuration into the response.
  console.error("usage-query: invalid query");
  process.exitCode = 1;
}
