#!/usr/bin/env node
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { usageReport } from "./usage/query.js";

try {
  const { values } = parseArgs({
    options: { tz: { type: "string" }, "claude-limits": { type: "boolean", default: false } },
    allowPositionals: false,
  });
  const configDirectory = process.env.HERDR_PLUGIN_CONFIG_DIR;
  console.log(JSON.stringify(usageReport({
    timeZone: values.tz,
    claudeLimits: values["claude-limits"],
    runtimeDirectory: configDirectory,
    accountDirectory: configDirectory,
    worker: {
      path: fileURLToPath(new URL("./usage-worker.js", import.meta.url)),
      args: ["--config", configDirectory],
      // The worker asks this herdr server to read Claude Code's limits.
      env: process.env.HERDR_SOCKET_PATH ? { HERDR_SOCKET_PATH: process.env.HERDR_SOCKET_PATH } : {},
    },
  })));
} catch {
  // Never echo arguments or Host configuration into the response.
  console.error("usage-query: invalid query");
  process.exitCode = 1;
}
