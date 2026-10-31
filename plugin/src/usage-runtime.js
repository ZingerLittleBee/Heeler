import { isAbsolute } from "node:path";
import { writeUsageRuntime } from "./usage/runtime-record.js";

export { readUsageRuntime } from "./usage/runtime-record.js";

/** Record only the environment that locates programs, accounts and Transcripts. */
export function recordUsageRuntime(configDir) {
  const stateDir = process.env.HERDR_PLUGIN_STATE_DIR;
  // Older callers can still refresh sidebar state, without inventing Usage roots.
  if (!stateDir || !process.env.HOME) return;
  writeUsageRuntime(process.env, {
    configDir,
    stateDir,
    node: process.execPath,
    herdr: isAbsolute(process.env.HERDR_BIN_PATH ?? "") ? process.env.HERDR_BIN_PATH : null,
  });
}
