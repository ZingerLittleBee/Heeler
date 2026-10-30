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

import {
  ELIGIBLE_STATUSES,
  buildActivityState,
  eligibleStatusMap,
  hasNewlyBlocked,
  sameStatusMap,
  shortHostName,
} from "./activity-state.js";
import { readNotificationConfig } from "./notification-config.js";
import { readUsageRuntime, recordUsageRuntime } from "./usage-runtime.js";
import { noteClaudeAgent } from "./usage/claude-agents.js";
import { refreshSidebarSnapshotForEvent } from "./sidebar-config.js";
import { optionalText } from "./display-text.js";
import { hookSession, sessionStateDir } from "./session.js";
import { deliverLiveActivity } from "./delivery/activity-seal.js";
import {
  liveActivityPreferences,
  pruneLiveActivityTokens,
  readLiveActivityDevices,
} from "./delivery/registrations.js";

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

// `stateDir` is already the session's state directory, so each herdr session
// keeps its own claim and last-state: one session's debounce never supersedes
// another's, and one session ending its activity never silences another.
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

/**
 * Resolve all workspace labels once per update. Labels are presentation-only,
 * so a Host that cannot answer still sends kind-only identities.
 */
async function listWorkspaceLabels(binPath) {
  try {
    const result = await runHerdr(binPath, ["workspace", "list"]);
    if (result.code !== 0) return new Map();
    const workspaces = JSON.parse(result.stdout)?.result?.workspaces;
    if (!Array.isArray(workspaces)) return new Map();
    const labels = new Map();
    for (const workspace of workspaces) {
      const id = optionalText(workspace?.workspace_id);
      const label = optionalText(workspace?.label);
      if (id !== null && label !== null) labels.set(id, label);
    }
    return labels;
  } catch {
    return new Map();
  }
}

/** Read presentation context once per workspace, only for configured fields. */
async function listRowContext(binPath, agents, devices) {
  const tokens = new Set(devices.flatMap((device) =>
    device.rowLayout?.rows.flatMap((row) => row.map((field) => field.token)) ?? []));
  const tabs = new Map();
  const panes = new Map();
  const workspaces = new Set(agents.filter((agent) => typeof agent?.agent_status === "string" && ELIGIBLE_STATUSES.has(agent.agent_status.toLowerCase()))
    .map((agent) => optionalText(agent.workspace_id)).filter(Boolean));
  for (const workspace of workspaces) {
    for (const kind of ["tab", "pane"]) {
      if (!tokens.has(kind)) continue;
      try {
        const result = await runHerdr(binPath, [kind, "list", "--workspace", workspace]);
        if (result.code !== 0) continue;
        const entries = JSON.parse(result.stdout)?.result?.[`${kind}s`];
        if (!Array.isArray(entries)) continue;
        const matching = entries.filter((entry) => entry?.workspace_id === workspace);
        const unique = [...new Map(matching.map((entry) => [entry[`${kind}_id`], entry])).values()];
        unique.forEach((entry, index) => {
          if (kind === "tab") tabs.set(entry.tab_id, { ...entry, position: index + 1, count: unique.length });
          else panes.set(entry.pane_id, entry);
        });
      } catch {
        // Missing context suppresses only that field, never the activity.
      }
    }
  }
  return { tabs, panes };
}

function requireEnv(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${name} is not set; this script must run as a herdr event hook`);
  }
  return value;
}

/**
 * A Claude Code Agent's config directory is a Usage Account suggestion. It is
 * learned only once Usage has a runtime, and never fails the hook.
 */
async function learnClaudeAgent(configDir, binPath, session, paneId) {
  try {
    const runtime = readUsageRuntime(configDir);
    if (runtime) await noteClaudeAgent({ stateDir: runtime.stateDir, herdr: binPath, session, paneId });
  } catch {
    // Suggestions are best effort; the next status change tries again.
  }
}

async function main() {
  const configDir = requireEnv("HERDR_PLUGIN_CONFIG_DIR");
  refreshSidebarSnapshotForEvent(configDir);
  try {
    recordUsageRuntime(configDir);
  } catch (error) {
    // Usage setup must not suppress a Live Activity update.
    console.error(`usage-runtime: recording failed (${error.code ?? "invalid runtime"})`);
  }
  const eventJson = requireEnv("HERDR_PLUGIN_EVENT_JSON");
  const session = hookSession();
  const stateDir = sessionStateDir(requireEnv("HERDR_PLUGIN_STATE_DIR"), session);
  const binPath = requireEnv("HERDR_BIN_PATH");

  const event = parseStatusEvent(eventJson);
  // Runs beside the Live Activity update, which never waits for it.
  const learning = event.agentKind === "claude" ? learnClaudeAgent(configDir, binPath, session, event.paneId) : null;
  try {
    await updateLiveActivity(configDir, session, stateDir, binPath, event);
  } finally {
    await learning;
  }
}

async function updateLiveActivity(configDir, session, stateDir, binPath, event) {
  const config = readNotificationConfig(configDir);

  // Cheap exits before burning a debounce process on a no-op.
  if (readLiveActivityDevices(configDir, session).length === 0) return;
  const lastState = readLastState(stateDir);
  if (lastState?.ended === true && !ELIGIBLE_STATUSES.has(event.status)) return;

  const claim = { pid: process.pid, claimed_at_ms: Date.now() };
  writeClaim(stateDir, claim);
  await sleep(config.activityDebounceMs);
  if (claimSuperseded(claim, readClaim(stateDir))) return;

  const devices = readLiveActivityDevices(configDir, session);
  if (devices.length === 0) return;

  const agents = await listAgents(binPath);
  const statuses = eligibleStatusMap(agents);
  const previous = lastState?.statuses ?? null;
  const preferences = liveActivityPreferences(devices);
  if (previous !== null && sameStatusMap(statuses, previous)
      && lastState?.preferences === preferences) return;

  const empty = Object.keys(statuses).length === 0;
  if (empty && lastState?.ended === true) return;

  const workspaceLabels = empty ? new Map() : await listWorkspaceLabels(binPath);
  const rowContext = empty ? {} : await listRowContext(binPath, agents, devices);
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
      workspaceLabels,
      rowLayout: device.rowLayout,
      rowHostName: device.rowHostName,
      ...rowContext,
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
      const outcome = await deliverLiveActivity(config, device, content.plaintextObject, request);
      if (outcome === "ok") delivered = true;
      else pruned.add(device.token);
    } catch (error) {
      failures.push(error.message);
    }
  }
  if (pruned.size > 0) pruneLiveActivityTokens(configDir, pruned);
  if (delivered) {
    writeLastState(stateDir, {
      sent_at_ms: Date.now(),
      statuses,
      preferences,
      ended: pushEvent === "end",
    });
  }
  if (failures.length > 0) throw new Error(failures.join("; "));
}

main().catch((error) => {
  console.error(`activity-hook: ${error.message}`);
  process.exit(1);
});
