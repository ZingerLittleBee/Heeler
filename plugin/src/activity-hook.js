#!/usr/bin/env node
// Live Activity update hook (docs/agents/live-activity-contract.md).
//
// herdr invokes this script through a second [[events]] hook on
// pane.agent_status_changed, independent of the alert notify hook. The flow:
//
//   event JSON ──> cheap exits (no live_activity / already ended)
//     ──> latest-wins debounce via activity/claim.json
//     ──> herdr agent list ──> suppress unchanged {pane: status}
//     ──> seal one envelope per device ──> POST kind=liveactivity
//
// Devices without a plausible `live_activity` registration send nothing;
// `notify` flags do not gate this path. APNs 410 clears only that field.

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { encryptActivityEnvelope } from "./activity-envelope.js";
import {
  ELIGIBLE_STATUSES,
  buildActivityState,
  eligibleStatusMap,
  hasNewlyBlocked,
  sameStatusMap,
  shortHostName,
} from "./activity-state.js";
import { readNotificationConfig } from "./notification-config.js";
import { optionalText } from "./display-text.js";

const SEND_ATTEMPTS = 3;
const REQUEST_TIMEOUT_MS = 10_000;
const KEY_BYTES = 32;
const APNS_ENVIRONMENTS = new Set(["production", "sandbox"]);
const ACTIVITY_TOKEN_PATTERN = /^[0-9a-f]{16,200}$/;
const CT_BUDGET = 2800;
const APNS_PAYLOAD_BUDGET = 4096;
const RELAY_REQUEST_BUDGET = 8192;
const STALE_AFTER_SECONDS = 900;

/** Parse HERDR_PLUGIN_EVENT_JSON leniently: require pane id and status only. */
function parseStatusEvent(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("HERDR_PLUGIN_EVENT_JSON is not JSON");
  }
  const data = parsed?.data;
  const paneId = data?.pane_id;
  const status = data?.agent_status;
  if (typeof paneId !== "string" || paneId.length === 0) {
    throw new Error("event data.pane_id missing");
  }
  if (typeof status !== "string" || status.length === 0) {
    throw new Error("event data.agent_status missing");
  }
  return {
    paneId,
    status: status.toLowerCase(),
    agentKind: optionalText(data.agent),
  };
}

/**
 * Devices whose registration entry carries a usable Live Activity token.
 * `notify` flags do not apply; a missing `live_activity` object means skip.
 */
function readActivityDevices(configDir) {
  let file;
  try {
    file = JSON.parse(readFileSync(join(configDir, "notifications.json"), "utf8"));
  } catch {
    return [];
  }
  if (file?.v !== 1 || !Array.isArray(file.devices)) return [];
  const devices = [];
  for (const entry of file.devices) {
    const live = entry?.live_activity;
    if (typeof live !== "object" || live === null || Array.isArray(live)) continue;
    if (typeof live.token !== "string" || !ACTIVITY_TOKEN_PATTERN.test(live.token)) continue;
    const env = APNS_ENVIRONMENTS.has(live.env) ? live.env : entry.env;
    if (!APNS_ENVIRONMENTS.has(env)) continue;
    const key = typeof entry.key === "string" ? Buffer.from(entry.key, "base64url") : null;
    if (key?.length !== KEY_BYTES) continue;
    devices.push({
      token: live.token,
      env,
      key,
      pinnedPaneIds: live.pinned_pane_ids,
    });
  }
  return devices;
}

/**
 * Drop `live_activity` from matching device entries, preserving the alert
 * token, key, notify flags, and any field this plugin does not understand.
 */
function pruneLiveActivity(configDir, tokens) {
  const path = join(configDir, "notifications.json");
  let file;
  try {
    file = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return;
  }
  if (file?.v !== 1 || !Array.isArray(file.devices)) return;
  for (const entry of file.devices) {
    if (tokens.has(entry?.live_activity?.token)) {
      delete entry.live_activity;
    }
  }
  writeAtomic(path, JSON.stringify(file));
}

function activityDir(stateDir) {
  return join(stateDir, "activity");
}

function lastStatePath(stateDir) {
  return join(activityDir(stateDir), "last-state.json");
}

function claimPath(stateDir) {
  return join(activityDir(stateDir), "claim.json");
}

function readLastState(stateDir) {
  try {
    const state = JSON.parse(readFileSync(lastStatePath(stateDir), "utf8"));
    return typeof state === "object" && state !== null ? state : null;
  } catch {
    return null;
  }
}

function writeLastState(stateDir, state) {
  mkdirSync(activityDir(stateDir), { recursive: true });
  writeAtomic(lastStatePath(stateDir), JSON.stringify(state));
}

function writeClaim(stateDir, claim) {
  mkdirSync(activityDir(stateDir), { recursive: true });
  writeAtomic(claimPath(stateDir), JSON.stringify(claim));
}

function readClaim(stateDir) {
  try {
    return JSON.parse(readFileSync(claimPath(stateDir), "utf8"));
  } catch {
    return null;
  }
}

function claimSuperseded(ours, latest) {
  if (latest === null || typeof latest !== "object") return false;
  if (typeof latest.claimed_at_ms !== "number") return false;
  if (latest.claimed_at_ms > ours.claimed_at_ms) return true;
  if (latest.claimed_at_ms === ours.claimed_at_ms && latest.pid !== ours.pid) return true;
  return false;
}

function writeAtomic(path, contents) {
  const temp = `${path}.tmp-${process.pid}`;
  writeFileSync(temp, contents);
  renameSync(temp, path);
}

function runHerdr(binPath, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(binPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

async function listAgents(binPath) {
  const result = await runHerdr(binPath, ["agent", "list"]);
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    parsed = null;
  }
  if (result.code !== 0) {
    throw new Error(
      `agent list failed (exit ${result.code}): ${result.stderr.trim() || result.stdout.trim()}`,
    );
  }
  const agents = parsed?.result?.agents;
  if (!Array.isArray(agents)) {
    throw new Error("agent list returned no agents array");
  }
  return agents;
}

function dropTitles(plaintextObject) {
  return {
    agents: plaintextObject.agents.map((agent) => {
      const entry = { kind: agent.kind, pane: agent.pane, status: agent.status };
      return entry;
    }),
    host: plaintextObject.host,
    v: plaintextObject.v,
  };
}

function emptyAgents(plaintextObject) {
  return { agents: [], host: plaintextObject.host, v: plaintextObject.v };
}

function plaintextAtStep(plaintextObject, step) {
  if (step <= 0) return plaintextObject;
  if (step === 1) return dropTitles(plaintextObject);
  return emptyAgents(plaintextObject);
}

function projectedApnsBytes(envelope, { event, timestamp, counts }) {
  const apns = {
    aps: {
      timestamp,
      event,
      "content-state": { counts, envelope: JSON.parse(envelope) },
    },
  };
  if (event === "update") apns.aps["stale-date"] = timestamp + STALE_AFTER_SECONDS;
  else apns.aps["dismissal-date"] = timestamp;
  return Buffer.byteLength(JSON.stringify(apns));
}

function relayBody({ device, event, priority, timestamp, counts, envelope }) {
  const body = {
    kind: "liveactivity",
    token: device.token,
    env: device.env,
    event,
    priority,
    timestamp,
    counts,
    envelope,
  };
  if (event === "update") body.stale_date = timestamp + STALE_AFTER_SECONDS;
  else body.dismissal_date = timestamp;
  return body;
}

function envelopeFits(envelope, request) {
  let parsed;
  try {
    parsed = JSON.parse(envelope);
  } catch {
    return false;
  }
  if (typeof parsed.ct === "string" && parsed.ct.length > CT_BUDGET) return false;
  if (projectedApnsBytes(envelope, request) > APNS_PAYLOAD_BUDGET) return false;
  const body = JSON.stringify(relayBody({ ...request, envelope }));
  if (Buffer.byteLength(body) > RELAY_REQUEST_BUDGET) return false;
  return true;
}

function sealFitting(plaintextObject, device, request) {
  let step = 0;
  let envelope = encryptActivityEnvelope(plaintextAtStep(plaintextObject, step), device.key);
  const sized = { ...request, device };
  while (step < 2 && !envelopeFits(envelope, sized)) {
    step += 1;
    envelope = encryptActivityEnvelope(plaintextAtStep(plaintextObject, step), device.key);
  }
  return { envelope, step };
}

/**
 * POST one Live Activity push. Transient failures (network, 429, 5xx) retry
 * up to SEND_ATTEMPTS. Returns "ok", "pruned" (APNs 410), or "too_large"
 * (relay-origin 413). Other conclusive failures throw.
 */
async function postPush(relayUrl, body, retryDelayMs) {
  const payload = JSON.stringify(body);
  let lastFailure = "";
  for (let attempt = 1; attempt <= SEND_ATTEMPTS; attempt += 1) {
    if (attempt > 1) await sleep(retryDelayMs);
    let response;
    try {
      response = await fetch(`${relayUrl}/push`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: payload,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (error) {
      lastFailure = `relay unreachable: ${error.message}`;
      continue;
    }
    if (response.ok) return "ok";
    const detail = (await response.text().catch(() => "")).slice(0, 200);
    if (response.status === 410) return "pruned";
    if (response.status === 413 && isRelayOrigin413(detail)) return "too_large";
    lastFailure = `relay answered ${response.status}: ${detail}`;
    if (response.status !== 429 && response.status < 500) break;
  }
  throw new Error(`push for token ${body.token.slice(0, 8)}… failed: ${lastFailure}`);
}

function isRelayOrigin413(detail) {
  try {
    const parsed = JSON.parse(detail);
    return typeof parsed?.error === "string";
  } catch {
    return false;
  }
}

function requireEnv(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${name} is not set; this script must run as a herdr event hook`);
  }
  return value;
}

async function deliver(config, device, plaintextObject, request) {
  let { envelope, step } = sealFitting(plaintextObject, device, request);
  while (true) {
    const outcome = await postPush(
      config.relayUrl,
      relayBody({ ...request, device, envelope }),
      config.retryDelayMs,
    );
    if (outcome === "ok" || outcome === "pruned") return outcome;
    if (outcome === "too_large" && step < 2) {
      step += 1;
      envelope = encryptActivityEnvelope(plaintextAtStep(plaintextObject, step), device.key);
      continue;
    }
    throw new Error(`push for token ${device.token.slice(0, 8)}… failed: payload too large`);
  }
}

async function main() {
  const eventJson = requireEnv("HERDR_PLUGIN_EVENT_JSON");
  const stateDir = requireEnv("HERDR_PLUGIN_STATE_DIR");
  const configDir = requireEnv("HERDR_PLUGIN_CONFIG_DIR");
  const binPath = requireEnv("HERDR_BIN_PATH");

  const event = parseStatusEvent(eventJson);
  const config = readNotificationConfig(configDir);

  // Cheap exits before burning a debounce process on a no-op.
  if (readActivityDevices(configDir).length === 0) return;
  const lastState = readLastState(stateDir);
  if (lastState?.ended === true && !ELIGIBLE_STATUSES.has(event.status)) return;

  const claim = { pid: process.pid, claimed_at_ms: Date.now() };
  writeClaim(stateDir, claim);
  await sleep(config.activityDebounceMs);
  if (claimSuperseded(claim, readClaim(stateDir))) return;

  const devices = readActivityDevices(configDir);
  if (devices.length === 0) return;

  const agents = await listAgents(binPath);
  const statuses = eligibleStatusMap(agents);
  const previous = lastState?.statuses ?? null;
  if (previous !== null && sameStatusMap(statuses, previous)) return;

  const empty = Object.keys(statuses).length === 0;
  if (empty && lastState?.ended === true) return;

  const pushEvent = empty ? "end" : "update";
  const priority = hasNewlyBlocked(statuses, previous) ? 10 : 5;
  const timestamp = Math.floor(Date.now() / 1000);
  const hostName = shortHostName();

  const pruned = new Set();
  const failures = [];
  let delivered = false;
  for (const device of devices) {
    const { counts, plaintextObject } = buildActivityState({
      agents,
      hostName,
      pinnedPaneIds: device.pinnedPaneIds,
    });
    const content =
      pushEvent === "end"
        ? {
            counts: { working: 0, blocked: 0, done: 0 },
            plaintextObject: { agents: [], host: plaintextObject.host, v: 1 },
          }
        : { counts, plaintextObject };
    const request = {
      event: pushEvent,
      priority,
      timestamp,
      counts: content.counts,
    };
    try {
      const outcome = await deliver(config, device, content.plaintextObject, request);
      if (outcome === "ok") delivered = true;
      else pruned.add(device.token);
    } catch (error) {
      failures.push(error.message);
    }
  }
  if (pruned.size > 0) pruneLiveActivity(configDir, pruned);
  if (delivered) {
    writeLastState(stateDir, {
      sent_at_ms: Date.now(),
      statuses,
      ended: pushEvent === "end",
    });
  }
  if (failures.length > 0) throw new Error(failures.join("; "));
}

main().catch((error) => {
  console.error(`activity-hook: ${error.message}`);
  process.exit(1);
});
