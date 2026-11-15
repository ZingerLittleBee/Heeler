import { execFile, spawn } from "node:child_process";
import { rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { readJSON, writeJSON } from "./cache.js";
import { cacheClaudeLimits, failed, strings } from "./claude-limits.js";
import { agyExecutable, agySearchPath } from "./runtime-record.js";

const unavailable = reason => ({ state: "unavailable", reason });
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);

// Antigravity CLI 1.1.11 added read-only `-p "/usage" --output-format json`
// without starting an agent turn; 1.1.10 and earlier sent slash commands in `-p`
// as literal prompt text.
export const LAST_UNSAFE_AGY_VERSION = [1, 1, 10];
export const agyAtOrBefore = (version, limit = LAST_UNSAFE_AGY_VERSION) => {
  for (let index = 0; index < limit.length; index++) {
    if (version[index] !== limit[index]) return version[index] < limit[index];
  }
  return true;
};

const AUTH_FAILURE = /(?:not logged in|authentication (?:required|expired|failed)|please (?:log|sign) in|unauthenticated|login required|re-authenticate|sign in to continue)/i;

function groupPrefix(name) {
  if (typeof name !== "string") return "";
  const trimmed = name.trim();
  if (/^gemini models$/i.test(trimmed)) return "Gemini";
  if (/^claude and gpt models$/i.test(trimmed)) return "Claude & GPT";
  return trimmed.replace(/\s+models$/i, "");
}

function durationOfWindow(windowCode) {
  if (typeof windowCode !== "string") return null;
  const normalized = windowCode.trim().toLowerCase();
  if (normalized === "5h") return 300;
  if (normalized === "daily") return 1440;
  if (normalized === "weekly") return 10080;
  const hours = /^(\d+)h$/.exec(normalized);
  if (hours) return Number(hours[1]) * 60;
  const days = /^(\d+)d$/.exec(normalized);
  if (days) return Number(days[1]) * 1440;
  return null;
}

function windowSuffix(durationMinutes, rawName) {
  if (durationMinutes === 300) return "5-hour";
  if (durationMinutes === 1440) return "Daily";
  if (durationMinutes === 10080) return "Weekly";
  if (Number.isFinite(durationMinutes) && durationMinutes > 0) {
    if (durationMinutes % 1440 === 0) return `${durationMinutes / 1440}-day`;
    if (durationMinutes % 60 === 0) return `${durationMinutes / 60}-hour`;
  }
  if (typeof rawName === "string") {
    const cleaned = rawName.replace(/\s*Limit Remaining$/i, "").trim();
    if (cleaned) return cleaned;
  }
  return "Usage window";
}

function parseAgyReading(stdout) {
  let body;
  try { body = JSON.parse(stdout); } catch { return failed("invalidResponse"); }
  if (!object(body)) return failed("invalidResponse");
  if (body.status === "ERROR") {
    const detail = typeof body.error === "string" ? body.error : "";
    return AUTH_FAILURE.test(detail) ? unavailable("notSignedIn") : failed("requestFailed");
  }
  if (body.status !== "SUCCESS" || body.command?.name !== "usage" || !object(body.command.data)) {
    return failed("invalidResponse");
  }
  const groups = Array.isArray(body.command.data.groups) ? body.command.data.groups : [];
  const windows = [];
  const multipleGroups = groups.length > 1;
  try {
    for (const group of groups) {
      if (!object(group) || !Array.isArray(group.buckets)) continue;
      const prefix = groupPrefix(group.name);
      const groupWindows = [];
      for (const bucket of group.buckets) {
        if (!object(bucket) || bucket.remaining_fraction == null) continue;
        if (typeof bucket.id !== "string" || !bucket.id
            || !Number.isFinite(bucket.remaining_fraction)
            || bucket.remaining_fraction < -1 || bucket.remaining_fraction > 1.0001) {
          throw new Error("invalid bucket");
        }
        const durationMinutes = durationOfWindow(bucket.window);
        const suffix = windowSuffix(durationMinutes, bucket.name);
        const label = prefix && (multipleGroups || !/^usage$/i.test(prefix)) ? `${prefix} · ${suffix}` : suffix;
        const reset = bucket.reset_time;
        const milliseconds = reset == null || reset === "" ? null : typeof reset === "string" ? Date.parse(reset) : NaN;
        if (milliseconds !== null && !Number.isFinite(new Date(milliseconds).getTime())) {
          throw new Error("invalid reset_time");
        }
        const usedPercent = Math.min(100, Math.max(0, (1 - bucket.remaining_fraction) * 100));
        groupWindows.push({
          id: `agy:${bucket.id}`,
          durationMinutes,
          usedPercent: Number(usedPercent.toFixed(4)),
          resetsAt: milliseconds === null ? null : new Date(milliseconds).toISOString(),
          expired: false,
          label,
        });
      }
      // Show shorter windows (5-hour) ahead of longer ones (Weekly), matching Claude Code and Codex.
      groupWindows.sort((a, b) => (a.durationMinutes ?? Infinity) - (b.durationMinutes ?? Infinity));
      windows.push(...groupWindows);
    }
  } catch {
    return failed("invalidResponse");
  }
  if (!windows.length) return unavailable("noPlanLimits");
  return { state: "ok", source: "service", observedAt: new Date().toISOString(), windows };
}

function agyEnv(runtime) {
  const env = strings(runtime.env);
  const path = agySearchPath(runtime.env);
  if (path) env.PATH = path;
  return env;
}

/**
 * The version of `agy`. Versions at or after 1.1.11 are cached per file
 * identity; older or unparseable versions are re-checked on each allowed read.
 */
export async function agyVersion(runtime, directory, known) {
  const executable = agyExecutable(runtime);
  if (!executable) return null;
  let identity;
  try {
    const file = statSync(executable);
    identity = [file.dev, file.ino, file.size, file.mtimeMs].join(":");
  } catch { return null; }
  if (known?.identity === identity && Array.isArray(known.version) && !agyAtOrBefore(known.version)) {
    return known;
  }
  const version = await new Promise(resolve => execFile(executable, ["--version"], {
    cwd: directory, env: agyEnv(runtime),
    timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
  }, (error, stdout) => {
    const match = error ? null : /^\s*(?:agy\s+)?v?(\d+)\.(\d+)\.(\d+)/i.exec(stdout);
    resolve(match ? match.slice(1).map(Number) : null);
  }));
  return { identity, version };
}

function keychainUsable(runtime, directory) {
  return new Promise(resolve => execFile("security", ["show-keychain-info"], {
    cwd: directory, env: strings(runtime.env), timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
  }, error => resolve(!error)));
}

function runAgyUsageCommand(executable, runtime, directory) {
  return new Promise(resolve => {
    const child = spawn(executable, ["-p", "/usage", "--output-format", "json"], {
      cwd: directory, env: agyEnv(runtime), stdio: ["ignore", "pipe", "pipe"], detached: true,
    });
    let result = null;
    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let terminated = false;
    const terminateGroup = () => {
      if (terminated) return;
      terminated = true;
      if (child.pid) {
        try { process.kill(-child.pid, "SIGKILL"); }
        catch { child.kill("SIGKILL"); }
      }
    };
    const finish = value => {
      if (result) return;
      result = value;
      clearTimeout(timer);
      terminateGroup();
      child.stdout.destroy();
      child.stderr.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ outcome: failed("timeout"), stderr: "" }), 15_000);
    child.stdout.on("error", () => finish({ outcome: failed("requestFailed"), stderr }));
    child.stderr.on("error", () => finish({ outcome: failed("requestFailed"), stderr }));
    child.on("error", error => finish({
      outcome: error.code === "ENOENT" || error.code === "EACCES" ? unavailable("programMissing") : failed("requestFailed"),
      stderr,
    }));
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      if (result) return;
      stdoutBytes += Buffer.byteLength(chunk);
      if (stdoutBytes > 1024 * 1024) { finish({ outcome: failed("invalidResponse"), stderr }); return; }
      stdout += chunk;
    });
    child.stderr.on("data", chunk => {
      if (result || stderrBytes >= 64 * 1024) return;
      stderrBytes += Buffer.byteLength(chunk);
      stderr += chunk.slice(0, 64 * 1024);
    });
    child.on("exit", terminateGroup);
    child.on("close", code => {
      clearTimeout(timer);
      if (result) { resolve(result); return; }
      if (code === 126 || code === 127) { resolve({ outcome: unavailable("programMissing"), stderr }); return; }
      const combined = `${stderr}\n${stdout}`;
      if (AUTH_FAILURE.test(combined)) { resolve({ outcome: unavailable("notSignedIn"), stderr: combined }); return; }
      if (code !== 0) {
        if (/flag provided but not defined|unknown flag/i.test(combined)) {
          resolve({ outcome: unavailable("programTooOld"), stderr: combined });
          return;
        }
        resolve({ outcome: failed("requestFailed"), stderr: combined });
        return;
      }
      resolve({ outcome: parseAgyReading(stdout), stderr: combined });
    });
  });
}

/**
 * Ask Antigravity CLI (`agy -p "/usage" --output-format json`) to report its
 * own plan limits. Requires `version` >= 1.1.11 so `/usage` never runs as a prompt.
 */
export async function readAgyLimits(runtime, directory, version = null) {
  const executable = agyExecutable(runtime);
  if (!executable) return unavailable("programMissing");
  if (!Array.isArray(version) || agyAtOrBefore(version)) return unavailable("programTooOld");
  const { outcome, stderr } = await runAgyUsageCommand(executable, runtime, directory);
  if (process.platform === "darwin" && (
    (outcome.state === "unavailable" && (outcome.reason === "notSignedIn" || outcome.reason === "noPlanLimits"))
    || (outcome.state === "error" && /keychain/i.test(stderr))
  ) && !(await keychainUsable(runtime, directory))) {
    return unavailable("keychainUnavailable");
  }
  return outcome;
}

export const AGY_REQUEST = "agy-request.json";
export const AGY_READING = "agy-reading.json";

/** Answers one pending `usage-agy-limits` request in herdr's GUI session on macOS. */
export async function answerAgyLimitsRequest(runtime, directory) {
  const path = join(directory, AGY_REQUEST);
  const request = readJSON(path);
  rmSync(path, { force: true });
  if (typeof request?.token !== "string") return;
  const reading = await readAgyLimits(runtime, directory, request.version);
  writeJSON(join(directory, AGY_READING), { token: request.token, reading });
}

export function cacheAgyLimits(previous, reading, now = Date.now()) {
  return cacheClaudeLimits(previous, reading, now);
}

export function nextAgyRead(entry) {
  return Number.isFinite(entry?.nextAllowedAt) ? entry.nextAllowedAt : undefined;
}
