import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { readJSON, writeJSON } from "./cache.js";
import { failed, READING, REQUEST, strings } from "./claude-limits.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/**
 * Reads through the plugin's `usage-claude-limits` action, which herdr's
 * server runs in its own session. On macOS, Claude Code keeps its sign-in in
 * the login keychain, which the SSH session that runs a Usage query cannot
 * use. Null when herdr cannot invoke the action, so the caller reads in place.
 * The request names an added Account's directory, or none for the Default.
 */
export async function readClaudeLimitsInServer(runtime, directory, version, { account, socketPath, wait = () => sleep(100) }) {
  if (typeof runtime.herdr !== "string" || !runtime.herdr.startsWith("/")) return null;
  const token = randomUUID();
  writeJSON(join(directory, REQUEST), { token, version: Array.isArray(version) ? version : null,
    directory: account.isDefault ? null : account.directory });
  const invoked = await new Promise(resolve => execFile(runtime.herdr,
    ["plugin", "action", "invoke", "usage-claude-limits", "--plugin", "heeler"], {
      cwd: directory, env: { ...strings(runtime.env), ...(typeof socketPath === "string" ? { HERDR_SOCKET_PATH: socketPath } : {}) },
      timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
    }, error => resolve(!error)));
  if (!invoked) { rmSync(join(directory, REQUEST), { force: true }); return null; }
  // The action's own request is bounded by 15 seconds after a 5-second version check.
  for (let attempt = 0; attempt < 250; attempt++) {
    const answer = readJSON(join(directory, READING));
    if (answer?.token === token && typeof answer.reading?.state === "string") return answer.reading;
    await wait();
  }
  return failed("timeout");
}
