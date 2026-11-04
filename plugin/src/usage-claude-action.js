#!/usr/bin/env node
import { readUsageRuntime } from "./usage-runtime.js";
import { cacheDirectory } from "./usage/cache.js";
import { answerClaudeLimitsRequest } from "./usage/claude-limits.js";
import { readClaudeAccounts } from "./usage/accounts.js";

// The usage worker invokes this action through herdr, so Claude Code runs in
// the server's session, where macOS lets it use the login keychain.
try {
  const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  const runtime = readUsageRuntime(configDir);
  if (runtime) await answerClaudeLimitsRequest(runtime, cacheDirectory(runtime), readClaudeAccounts(configDir, runtime));
} catch {
  process.exitCode = 1;
}
