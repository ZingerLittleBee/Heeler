#!/usr/bin/env node
import { readClaudeLimitsInServer } from "./usage/claude-limits-server.js";
import { runUsageWorker } from "./usage/worker.js";

try {
  await runUsageWorker({
    // On macOS, herdr's server can use the login keychain, and this session cannot.
    readClaudeLimitsElsewhere: process.platform === "darwin"
      ? (runtime, directory, version, options) => readClaudeLimitsInServer(runtime, directory, version, {
        ...options, socketPath: process.env.HERDR_SOCKET_PATH })
      : null,
  });
} catch { process.exitCode = 1; }
