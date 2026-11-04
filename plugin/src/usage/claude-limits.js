import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { rmSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { readJSON, writeJSON } from "./cache.js";
import { runLimitsRequest } from "./limits-process.js";

const unavailable = reason => ({ state: "unavailable", reason });
const failed = reason => ({ state: "error", reason });
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const strings = env => Object.fromEntries(Object.entries(env).filter(([, value]) => typeof value === "string"));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const knownWindows = { five_hour: ["fiveHour", 300], seven_day: ["sevenDay", 10080],
  seven_day_opus: ["sevenDayOpus", 10080], seven_day_sonnet: ["sevenDaySonnet", 10080] };

function readingFrom(body) {
  if (!object(body)) return failed("invalidResponse");
  if (body.rate_limits_available === false) return unavailable("noPlanLimits");
  if (body.rate_limits_available !== true || !object(body.rate_limits)) return failed("invalidResponse");
  const windows = [];
  const add = (id, durationMinutes, window, label) => {
    if (!object(window) || window.utilization == null) return;
    if (!Number.isFinite(window.utilization) || window.utilization < 0) throw new Error("invalid utilization");
    const reset = window.resets_at;
    const milliseconds = reset === null ? null : typeof reset === "string" ? Date.parse(reset)
      : Number.isFinite(reset) ? reset * 1000 : NaN;
    if (milliseconds !== null && !Number.isFinite(new Date(milliseconds).getTime())) throw new Error("invalid reset");
    windows.push({ id, durationMinutes, usedPercent: window.utilization,
      resetsAt: milliseconds === null ? null : new Date(milliseconds).toISOString(), expired: false, ...(label ? { label } : {}) });
  };
  try {
    for (const [key, window] of Object.entries(body.rate_limits)) {
      if (key === "model_scoped" || key === "extra_usage" || key === "spend") continue;
      if (!object(window) || !Object.hasOwn(window, "utilization") || !Object.hasOwn(window, "resets_at")) continue;
      // Claude Code shows a meter it has no name for only by the label the
      // service sends; an unlabelled code-named one stays hidden there too.
      const known = knownWindows[key];
      const label = typeof window.label === "string" && window.label ? window.label : null;
      if (known) add(known[0], known[1], window);
      else if (label) add(`claude:${key}`, null, window, label);
    }
    if (Array.isArray(body.rate_limits.model_scoped)) for (const window of body.rate_limits.model_scoped) {
      if (typeof window?.display_name === "string" && window.display_name) add(`claude:model:${window.display_name}`, null, window, window.display_name);
    }
  } catch { return failed("invalidResponse"); }
  return { state: "ok", source: "service", observedAt: new Date().toISOString(),
    ...(typeof body.subscription_type === "string" ? { plan: body.subscription_type } : {}), windows };
}

// Claude Code 2.1.12 and earlier leave an unknown control request unanswered,
// so get_usage would only time out. Later versions answer it with an error.
const LAST_SILENT_VERSION = [2, 1, 12];
const atOrBefore = (version, limit) => {
  for (let index = 0; index < limit.length; index++) if (version[index] !== limit[index]) return version[index] < limit[index];
  return true;
};

/**
 * The version of the recorded `claude`. A version that supports `get_usage` is
 * remembered per installed executable, keyed by the file it resolves to. A
 * version too old or unknown is asked again at every allowed read: the
 * recorded file may be a shim or wrapper that an update leaves unchanged.
 */
export async function claudeVersion(runtime, directory, known) {
  if (typeof runtime.claude !== "string" || !runtime.claude.startsWith("/")) return null;
  let identity;
  try {
    const file = statSync(runtime.claude);
    identity = [file.dev, file.ino, file.size, file.mtimeMs].join(":");
  } catch { return null; }
  if (known?.identity === identity && Array.isArray(known.version) && !atOrBefore(known.version, LAST_SILENT_VERSION)) return known;
  const version = await new Promise(resolve => execFile(runtime.claude, ["--version"], {
    cwd: directory, env: strings(runtime.env),
    timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
  }, (error, stdout) => {
    const match = error ? null : /^\s*(\d+)\.(\d+)\.(\d+)/.exec(stdout);
    resolve(match ? match.slice(1).map(Number) : null);
  }));
  return { identity, version };
}

/**
 * The runtime that reads one Account. Claude Code hashes any `CLAUDE_CONFIG_DIR`,
 * even `~/.claude`, into its macOS keychain service name, so each Account runs
 * as the `claude` that signs in to it: the Default Account with the recorded
 * environment unchanged, an added `~/.claude` without the variable, as a plain
 * `claude`, and any other added Account with its directory.
 */
export function accountRuntime(runtime, account) {
  if (account.isDefault) return runtime;
  const plain = resolve(account.directory) === resolve(runtime.env.HOME, ".claude");
  return { ...runtime, env: { ...runtime.env, CLAUDE_CONFIG_DIR: plain ? null : account.directory } };
}

/**
 * `limits.json`'s Claude entries by Account id, for the Accounts still counted:
 * an Account that left takes its throttle and readings with it. A 0.7.x file
 * kept one entry for the Host (its `nextAllowedAt` a number), which is dropped.
 */
export function claudeLimitsEntries(value, accounts) {
  if (!object(value) || typeof value.nextAllowedAt === "number") return {};
  return Object.fromEntries(accounts.filter(({ id }) => object(value[id])).map(({ id }) => [id, value[id]]));
}

/** The earliest next read over the Accounts, or undefined while one is due now. */
export function nextClaudeRead(entries, accounts) {
  const next = accounts.map(({ id }) => entries[id]?.nextAllowedAt);
  return next.every(Number.isFinite) ? Math.min(...next) : undefined;
}

/** Ask Claude Code to handle its own sign-in. No prompt or user message is sent. */
export async function readClaudeLimits(runtime, directory, version = null) {
  if (typeof runtime.claude !== "string" || !runtime.claude.startsWith("/")) return unavailable("programMissing");
  if (Array.isArray(version) && atOrBefore(version, LAST_SILENT_VERSION)) return unavailable("programTooOld");
  const reading = await requestClaudeLimits(runtime, directory);
  // Claude Code that cannot use its keychain item answers as if the sign-in
  // had no plan limits.
  if (process.platform === "darwin" && reading.state === "unavailable" && reading.reason === "noPlanLimits"
      && !(await keychainUsable(runtime, directory))) return unavailable("keychainUnavailable");
  return reading;
}

/**
 * Whether this session can use the default keychain. An SSH session on macOS
 * cannot. Only the keychain's settings are asked for; no item is read.
 */
function keychainUsable(runtime, directory) {
  return new Promise(resolve => execFile("security", ["show-keychain-info"], {
    cwd: directory, env: strings(runtime.env), timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
  }, error => resolve(!error)));
}

function requestClaudeLimits(runtime, directory) {
  return runLimitsRequest({ executable: runtime.claude,
    args: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--no-session-persistence", "--strict-mcp-config", "--settings", '{"disableAllHooks":true}'],
    env: runtime.env, directory }, ({ send: sendMessage, finish }) => {
    let stage = "init";
    const send = (request_id, request) => sendMessage({ type: "control_request", request_id, request });
    send(stage, { subtype: "initialize" });
    return message => {
      if (message?.type !== "control_response" || message.response?.request_id !== stage) return;
      const response = message.response;
      if (response.subtype === "error") {
        finish(typeof response.error === "string" && response.error.startsWith("Unsupported control request subtype")
          ? unavailable("programTooOld") : failed("requestFailed"));
      } else if (response.subtype !== "success") finish(failed("invalidResponse"));
      else if (stage === "init") { stage = "usage"; send(stage, { subtype: "get_usage", skip_behaviors: true }); }
      else finish(readingFrom(response.response));
    };
  });
}

const REQUEST = "claude-request.json";
const READING = "claude-reading.json";

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

/**
 * The action's side: answers the pending request once, in herdr's session.
 * Only the Default Account or an `ok` Account the Account file lists is read,
 * so a request file cannot hand Claude Code another config directory.
 */
export async function answerClaudeLimitsRequest(runtime, directory, accounts) {
  const path = join(directory, REQUEST);
  const request = readJSON(path);
  rmSync(path, { force: true });
  if (typeof request?.token !== "string") return;
  const account = accounts.find(account => account.state === "ok"
    && (request.directory === null ? account.isDefault : !account.isDefault && account.directory === request.directory));
  const reading = account ? await readClaudeLimits(accountRuntime(runtime, account), directory, request.version) : failed("requestFailed");
  writeJSON(join(directory, READING), { token: request.token, reading });
}

/**
 * Failed requests retain the last good reading while the failure back-off runs.
 * Any other answer (signed out, no plan, too old) ends it: a later failure must
 * not resurface a reading that may belong to a previous sign-in.
 */
export function cacheClaudeLimits(previous, reading, now = Date.now()) {
  const nextAllowedAt = now + (reading.state === "error" ? 300_000 : 60_000);
  const lastGood = reading.state === "ok" ? reading : reading.state === "error" ? previous?.lastGood : undefined;
  const report = reading.state === "error" && lastGood
    ? { ...lastGood, state: "throttled", reason: reading.reason, retryAt: new Date(nextAllowedAt).toISOString() } : reading;
  return { report, nextAllowedAt, ...(lastGood ? { lastGood } : {}) };
}
