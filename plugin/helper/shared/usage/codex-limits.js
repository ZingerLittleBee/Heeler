import { runLimitsRequest } from "./limits-process.js";

const unavailable = reason => ({ state: "unavailable", reason });
const failed = reason => ({ state: "error", reason });
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);

function windowsFrom(group, observedAt) {
  if (!object(group)) return null;
  const windows = [];
  let recognized = false;
  for (const id of ["primary", "secondary"]) {
    if (!Object.hasOwn(group, id)) continue;
    recognized = true;
    const window = group[id];
    if (window === null) continue;
    if (!object(window)) return null;
    const usedPercent = window.usedPercent ?? window.used_percent;
    const durationMinutes = window.windowDurationMins ?? window.window_minutes ?? null;
    if (!Number.isFinite(usedPercent) || usedPercent < 0
        || (durationMinutes !== null && (!Number.isFinite(durationMinutes) || durationMinutes <= 0))) return null;
    const reset = window.resetsAt ?? window.resets_at ?? null;
    let resetMilliseconds = reset === null ? null : Number.isFinite(reset) ? reset * 1000 : NaN;
    if (reset === null && Number.isFinite(window.resets_in_seconds)) resetMilliseconds = Date.parse(observedAt) + window.resets_in_seconds * 1000;
    if (resetMilliseconds !== null && !Number.isFinite(new Date(resetMilliseconds).getTime())) return null;
    windows.push({ id, durationMinutes, usedPercent,
      resetsAt: resetMilliseconds === null ? null : new Date(resetMilliseconds).toISOString(), expired: false });
  }
  return recognized ? windows : null;
}

/** Evaluate expiry for each query, even while a cached service reading is fresh. */
export function expireLimitWindows(reading, now = Date.now()) {
  if (!reading?.windows) return reading;
  return { ...reading, windows: reading.windows.map(window => {
    const expired = window.resetsAt !== null && Date.parse(window.resetsAt) <= now;
    return { ...window, expired, usedPercent: expired ? null : window.usedPercent };
  }) };
}

/** Retain only the default group's allowed fields from a Transcript event. */
export function codexRolloutLimits(line) {
  if (line?.type !== "event_msg" || line.payload?.type !== "token_count") return null;
  const group = line.payload.rate_limits;
  if (!object(group) || (group.limit_id != null && group.limit_id !== "codex")) return null;
  const timestamp = Date.parse(line.timestamp);
  if (!Number.isFinite(timestamp)) return null;
  const observedAt = new Date(timestamp).toISOString();
  const windows = windowsFrom(group, observedAt);
  // A snapshot without any window says nothing about the limits; an older one may.
  if (!windows?.length) return null;
  const plan = group.plan_type ?? group.planType;
  return { state: "ok", source: "lastSession", observedAt, ...(typeof plan === "string" ? { plan } : {}), windows };
}

export function codexLimitsWithFallback(service, fallback) {
  return service.state === "ok" || service.reason === "noPlanLimits" ? service : fallback || service;
}

/**
 * Codex answers a method it does not know with -32600: "Invalid request:
 * unknown variant …" since 0.54.0, a bare "Invalid request" before. -32601 is
 * the JSON-RPC code for the same case.
 */
function unknownMethod(error) {
  return error.code === -32601 || (error.code === -32600 && typeof error.message === "string"
    && (error.message === "Invalid request" || error.message.includes("unknown variant")));
}

/** Ask the user's program over its local control protocol; never read its sign-in. */
export async function readCodexLimits(runtime, directory) {
  if (typeof runtime.codex !== "string" || !runtime.codex.startsWith("/")) return unavailable("programMissing");
  return runLimitsRequest({ executable: runtime.codex, args: ["-s", "read-only", "-a", "never", "app-server"],
    env: runtime.env, directory }, ({ send, finish }) => {
    let plan;
    let stage = 1;
    const readLimits = () => { stage = 3; send({ id: 3, method: "account/rateLimits/read" }); };
    send({ id: 1, method: "initialize", params: { clientInfo: { name: "heeler", version: "0.7.0" } } });
    return message => {
      if (!object(message) || message.id !== stage) return;
      if (message.error) {
        // Codex 0.48.0 to 0.56 answer account/read with "not implemented yet"
        // but already serve rate limits, without a plan.
        if (stage === 2) readLimits();
        else finish(object(message.error) && unknownMethod(message.error) ? unavailable("programTooOld") : failed("requestFailed"));
        return;
      }
      if (!Object.hasOwn(message, "result")) { finish(failed("invalidResponse")); return; }
      if (stage === 1) {
        stage = 2;
        send({ method: "initialized" });
        send({ id: 2, method: "account/read", params: {} });
      } else if (stage === 2) {
        if (!object(message.result) || !Object.hasOwn(message.result, "account")) { finish(failed("invalidResponse")); return; }
        const account = message.result.account;
        // A provider that does not use OpenAI sign-in (a third-party or local
        // model provider) has no plan limits, signed in or not.
        if (account === null) { finish(unavailable(message.result.requiresOpenaiAuth === false ? "noPlanLimits" : "notSignedIn")); return; }
        if (!object(account) || typeof account.type !== "string") { finish(failed("invalidResponse")); return; }
        if (account.type !== "chatgpt") { finish(unavailable("noPlanLimits")); return; }
        const reportedPlan = account.planType ?? account.plan_type;
        if (typeof reportedPlan === "string") plan = reportedPlan;
        readLimits();
      } else {
        const observedAt = new Date().toISOString();
        const windows = windowsFrom(message.result?.rateLimits ?? message.result?.rate_limits, observedAt);
        finish(windows === null ? failed("invalidResponse") : {
          state: "ok", source: "service", observedAt, ...(plan ? { plan } : {}), windows,
        });
      }
    };
  });
}
