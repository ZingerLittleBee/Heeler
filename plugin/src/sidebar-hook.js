#!/usr/bin/env node
// Startup hooks record the runtime and refresh the sidebar without invoking herdr.
import { recordUsageRuntime } from "./usage-runtime.js";
import { refreshSidebarSnapshot } from "./sidebar-config.js";

try {
  const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  if (!configDir) throw new Error("HERDR_PLUGIN_CONFIG_DIR is not set");
  refreshSidebarSnapshot(configDir);
  recordUsageRuntime(configDir);
} catch (error) {
  console.error(`sidebar-hook: ${error.code ?? error.message}`);
  process.exitCode = 1;
}
