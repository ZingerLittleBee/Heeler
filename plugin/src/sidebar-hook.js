#!/usr/bin/env node
// Startup hooks have no event JSON, state directory, or CLI dependency.
import { refreshSidebarSnapshot } from "./sidebar-config.js";

try {
  const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  if (!configDir) throw new Error("HERDR_PLUGIN_CONFIG_DIR is not set");
  refreshSidebarSnapshot(configDir);
} catch (error) {
  console.error(`sidebar-hook: ${error.code ?? error.message}`);
  process.exitCode = 1;
}
