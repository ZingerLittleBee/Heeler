// Live Activity content-state builder (docs/agents/live-activity-contract.md).
//
// Pure: given a herdr `agent list` inventory and a host label, produce the
// plaintext counts (full eligible set) and the capped, sorted agents array
// that goes inside the encrypted envelope.

import os from "node:os";

import { forDisplay, optionalText } from "./display-text.js";

export const ELIGIBLE_STATUSES = new Set(["working", "blocked", "done"]);
const STATUS_RANK = { blocked: 0, done: 1, working: 2 };
const AGENT_CAP = 5;

/**
 * Short hostname: first DNS label of `os.hostname()`, trimmed to the display
 * limit. Exported so tests can assert the hook's host field without guessing.
 */
export function shortHostName(hostname = os.hostname()) {
  const label = String(hostname).split(".")[0] ?? "";
  return forDisplay(label) ?? "";
}

/**
 * `{pane_id: status}` map over the full eligible inventory (uncapped).
 *
 * @param {object[]} agents
 * @returns {Record<string, string>}
 */
export function eligibleStatusMap(agents) {
  const map = {};
  for (const agent of Array.isArray(agents) ? agents : []) {
    const parsed = parseEligible(agent);
    if (parsed === null) continue;
    map[parsed.pane] = parsed.status;
  }
  return map;
}

export function sameStatusMap(left, right) {
  const a = left ?? {};
  const b = right ?? {};
  const keysA = Object.keys(a).sort();
  const keysB = Object.keys(b).sort();
  if (keysA.length !== keysB.length) return false;
  return keysA.every((key, index) => key === keysB[index] && a[key] === b[key]);
}

/**
 * Priority 10 only when some pane is blocked now and was not blocked in the
 * previous map. An absent previous map counts as empty.
 */
export function hasNewlyBlocked(current, previous) {
  const prev = previous ?? {};
  for (const [pane, status] of Object.entries(current ?? {})) {
    if (status === "blocked" && prev[pane] !== "blocked") return true;
  }
  return false;
}

/**
 * @param {{agents: object[], hostName: string}} input
 * @returns {{counts: {working: number, blocked: number, done: number}, plaintextObject: object}}
 */
export function buildActivityState({ agents, hostName }) {
  const counts = { working: 0, blocked: 0, done: 0 };
  const eligible = [];
  for (const agent of Array.isArray(agents) ? agents : []) {
    const parsed = parseEligible(agent);
    if (parsed === null) continue;
    counts[parsed.status] += 1;
    eligible.push(parsed);
  }
  eligible.sort((left, right) => {
    const rank = STATUS_RANK[left.status] - STATUS_RANK[right.status];
    if (rank !== 0) return rank;
    if (left.pane < right.pane) return -1;
    if (left.pane > right.pane) return 1;
    return 0;
  });
  const host = forDisplay(hostName) ?? "";
  const selected = eligible.slice(0, AGENT_CAP).map((entry) => {
    const title = forDisplay(
      optionalText(entry.agent.terminal_title_stripped) ?? optionalText(entry.agent.terminal_title),
    );
    const name = forDisplay(
      optionalText(entry.agent.display_agent) ?? optionalText(entry.agent.name),
    );
    const wire = { kind: optionalText(entry.agent.agent) ?? "unknown" };
    if (name !== null) wire.name = name;
    wire.pane = entry.pane;
    wire.status = entry.status;
    if (title !== null) wire.title = title;
    return wire;
  });
  return {
    counts,
    plaintextObject: {
      agents: selected,
      host,
      v: 1,
    },
  };
}

function parseEligible(agent) {
  if (typeof agent !== "object" || agent === null) return null;
  const pane = typeof agent.pane_id === "string" ? agent.pane_id : "";
  const status = typeof agent.agent_status === "string" ? agent.agent_status.toLowerCase() : "";
  if (pane.length === 0 || !ELIGIBLE_STATUSES.has(status)) return null;
  return { agent, pane, status };
}
