#!/usr/bin/env node
import { readUsageRuntime } from "./usage-runtime.js";
import { cacheDirectory } from "./usage/cache.js";
import { answerAgyLimitsRequest } from "./usage/agy-limits.js";

// The usage worker invokes this action through herdr, so Antigravity CLI runs in
// the server's session, where macOS lets it use the login keychain.
try {
  const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  const runtime = readUsageRuntime(configDir);
  if (runtime) await answerAgyLimitsRequest(runtime, cacheDirectory(runtime));
} catch {
  process.exitCode = 1;
}
