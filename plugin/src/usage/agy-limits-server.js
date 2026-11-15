import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { readJSON, writeJSON } from "./cache.js";
import { failed, strings } from "./claude-limits.js";
import { AGY_READING, AGY_REQUEST, agyAtOrBefore } from "./agy-limits.js";
import { agyExecutable } from "./runtime-record.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/**
 * Reads through the plugin's `usage-agy-limits` action, which herdr's server
 * runs in its own session so macOS lets Antigravity CLI read its login keychain
 * item. Null when herdr cannot invoke the action or `agy` cannot read limits.
 */
export async function readAgyLimitsInServer(runtime, directory, version, { socketPath, wait = () => sleep(100) }) {
  if (typeof runtime.herdr !== "string" || !runtime.herdr.startsWith("/")
      || !agyExecutable(runtime) || !Array.isArray(version) || agyAtOrBefore(version)) return null;
  const token = randomUUID();
  writeJSON(join(directory, AGY_REQUEST), { token, version: Array.isArray(version) ? version : null });
  const invoked = await new Promise(resolve => execFile(runtime.herdr,
    ["plugin", "action", "invoke", "usage-agy-limits", "--plugin", "heeler"], {
      cwd: directory, env: { ...strings(runtime.env), ...(typeof socketPath === "string" ? { HERDR_SOCKET_PATH: socketPath } : {}) },
      timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
    }, error => resolve(!error)));
  if (!invoked) { rmSync(join(directory, AGY_REQUEST), { force: true }); return null; }
  for (let attempt = 0; attempt < 250; attempt++) {
    const answer = readJSON(join(directory, AGY_READING));
    if (answer?.token === token && typeof answer.reading?.state === "string") return answer.reading;
    await wait();
  }
  return failed("timeout");
}
