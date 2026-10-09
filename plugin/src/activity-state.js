// Live Activity content-state builder (docs/agents/live-activity-contract.md).
//
// Pure: given a herdr `agent list` inventory and a host label, produce the
// plaintext counts (full eligible set) and the capped, sorted agents array
// that goes inside the encrypted envelope. An optional `pinnedPaneIds` list
// (most-recently-pinned first) reorders eligible agents; it never changes
// eligibility or counts.

import os from "node:os";

import { parseActivityRowLayout, renderActivityRows } from "./activity-rows.js";

import { forDisplay, optionalText } from "./display-text.js";
import { cleanText, clipRow, conversationalRows, workingTitle } from "./status-rows.js";

export const ELIGIBLE_STATUSES = new Set(["working", "blocked", "done"]);
const STATUS_RANK = { blocked: 0, done: 1, working: 2 };
// Degrade order (docs/agents/live-activity-contract.md, "Size limit"): blocked
// agents keep their rows longest, done agents lose theirs first.
const LADDER_RANK = new Map([["blocked", 0], ["working", 1], ["done", 2]]);
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
 * Lenient reader for `live_activity.pinned_pane_ids`. Missing, null, a
 * non-array, or any non-string entry becomes an empty list.
 *
 * @param {unknown} value
 * @returns {string[]}
 */
export function parsePinnedPaneIds(value) {
  if (!Array.isArray(value)) return [];
  const ids = [];
  for (const entry of value) {
    if (typeof entry !== "string") return [];
    ids.push(entry);
  }
  return ids;
}

/**
 * @param {{agents: object[], hostName: string, pinnedPaneIds?: unknown, workspaceLabels?: Map<string, string>}} input
 * @returns {{counts: {working: number, blocked: number, done: number}, plaintextObject: object,
 *   ladder: {status: string, pinned: boolean, said: string|null}[]}}
 *   `ladder` runs parallel to `plaintextObject.agents` and feeds conversationalSteps.
 */
export function buildActivityState({
  agents,
  hostName,
  pinnedPaneIds,
  workspaceLabels = new Map(),
  rowLayout,
  rowHostName,
  tabs = new Map(),
  panes = new Map(),
  rowsMode = "layout",
  sinceByPane = {},
  asOfMs = Date.now(),
  timeZone,
}) {
  const counts = { working: 0, blocked: 0, done: 0 };
  const eligible = [];
  for (const agent of Array.isArray(agents) ? agents : []) {
    const parsed = parseEligible(agent);
    if (parsed === null) continue;
    counts[parsed.status] += 1;
    eligible.push(parsed);
  }
  const pinIndex = new Map();
  for (const [index, pane] of parsePinnedPaneIds(pinnedPaneIds).entries()) {
    if (!pinIndex.has(pane)) pinIndex.set(pane, index);
  }
  eligible.sort((left, right) => {
    const leftPinned = pinIndex.has(left.pane);
    const rightPinned = pinIndex.has(right.pane);
    if (leftPinned && rightPinned) {
      return pinIndex.get(left.pane) - pinIndex.get(right.pane);
    }
    if (leftPinned !== rightPinned) return leftPinned ? -1 : 1;
    const rank = STATUS_RANK[left.status] - STATUS_RANK[right.status];
    if (rank !== 0) return rank;
    if (left.pane < right.pane) return -1;
    if (left.pane > right.pane) return 1;
    return 0;
  });
  const host = forDisplay(hostName) ?? "";
  const layout = parseActivityRowLayout(rowLayout);
  const conversational = rowsMode === "conversational";
  // Conversational mode cleans every wire string, not only the rows.
  const text = conversational ? (value) => forDisplay(cleanText(value) || null) : (value) => forDisplay(value);
  const ladder = [];
  const selected = eligible.slice(0, AGENT_CAP).map((entry) => {
    const title = conversational
      ? forDisplay(workingTitle(entry.agent))
      : forDisplay(optionalText(entry.agent.terminal_title_stripped) ?? optionalText(entry.agent.terminal_title));
    const name = text(optionalText(entry.agent.display_agent) ?? optionalText(entry.agent.name));
    const wire = {};
    wire.kind = optionalText(entry.agent.agent) ?? "unknown";
    if (name !== null) wire.name = name;
    wire.pane = entry.pane;
    const workspaceId = optionalText(entry.agent.workspace_id);
    const workspace = text(workspaceId === null ? null : workspaceLabels.get(workspaceId));
    const rows = conversational
      ? conversationalRows({
        agent: entry.agent, status: entry.status, workspace, sinceMs: sinceByPane?.[entry.pane], asOfMs, timeZone,
      })
      : renderActivityRows(layout, entry.agent, { hostName: rowHostName ?? host, workspaceLabels, tabs, panes });
    if (rows !== null) wire.rows = rows;
    wire.status = entry.status;
    if (title !== null) wire.title = title;
    if (workspace !== null) wire.workspace = workspace;
    ladder.push({ status: entry.status, pinned: pinIndex.has(entry.pane), said: rows?.length === 3 ? "title" : null });
    return wire;
  });
  return {
    counts,
    plaintextObject: {
      agents: selected,
      host,
      v: 1,
    },
    ladder,
  };
}

/**
 * Conversational payloads from full to smallest, one change per step
 * (docs/agents/live-activity-contract.md, "Size limit"). Each step touches the
 * lowest-ranked agent that still has the thing being removed: rank is blocked,
 * then working, then done; ties keep pinned agents, then display order.
 *
 * 1. row 2 of done, then working, then blocked agents; 2. the `title` and
 * `name` wire fields; 3. whole agents, never a blocked one while another
 * remains; 4. identity-only rows; 5. no agents (counts stay).
 */
export function conversationalSteps(plaintextObject, ladder) {
  const entries = [...plaintextObject.agents];
  const said = ladder.map((entry) => entry.said);
  const order = ladder.map((entry, index) => ({ ...entry, index }))
    .sort((a, b) => LADDER_RANK.get(b.status) - LADDER_RANK.get(a.status) || a.pinned - b.pinned || b.index - a.index)
    .map(({ index }) => index);
  const steps = [plaintextObject];
  const snapshot = () => steps.push({ ...plaintextObject, agents: entries.filter(Boolean) });
  for (const status of ["done", "working", "blocked"]) {
    for (const index of order) {
      if (ladder[index].status !== status || said[index] !== "title") continue;
      said[index] = null;
      entries[index] = { ...entries[index], rows: [entries[index].rows[0], entries[index].rows.at(-1)] };
      snapshot();
    }
  }
  entries.forEach((agent, index) => {
    const { title, name, ...rest } = agent;
    entries[index] = rest;
  });
  snapshot();
  for (const index of order.slice(0, -1)) {
    entries[index] = null;
    snapshot();
  }
  entries.forEach((agent, index) => {
    if (agent) entries[index] = { ...agent, rows: agent.rows.slice(0, 1) };
  });
  snapshot();
  steps.push({ ...plaintextObject, agents: [] });
  return steps;
}

/**
 * Hook-observed start of each eligible agent's current `(status,
 * state_change_seq)`, keyed by herdr `terminal_id` (docs/agents/
 * live-activity-contract.md, "Since"). A start is kept while the pair is
 * unchanged, is `nowMs` for a pair first observed now, and is null (unknown)
 * when there is no comparable saved state: none saved, another herdr server
 * (`epoch` differs or is unknown), or any saved seq above the current one.
 *
 * @param {{v?: number, epoch?: string, terminals?: object}|null} previous last-state.json
 * @param {string|null} epoch identity of the herdr server's socket
 * @returns {{terminals: object, sinceByPane: Record<string, number|null>, allRecorded: boolean}}
 *   `allRecorded`: every eligible agent's pair was already saved (a content-only change).
 */
export function trackSince(previous, agents, nowMs, epoch) {
  const current = (Array.isArray(agents) ? agents : []).map(parseEligible).filter(Boolean).map((entry) => ({
    ...entry,
    terminal: optionalText(entry.agent.terminal_id),
    seq: Number.isInteger(entry.agent.state_change_seq) ? entry.agent.state_change_seq : null,
  }));
  let saved = previous?.v === 2 && epoch !== null && previous.epoch === epoch ? previous.terminals ?? {} : null;
  if (saved !== null && current.some(({ terminal, seq }) => Number.isInteger(saved[terminal]?.seq) && seq < saved[terminal].seq)) {
    saved = null;
  }
  const terminals = {};
  const sinceByPane = {};
  let allRecorded = saved !== null;
  for (const { pane, status, terminal, seq } of current) {
    const prior = terminal === null ? undefined : saved?.[terminal];
    const same = prior?.status === status && prior?.seq === seq;
    allRecorded &&= same;
    const since = same ? (prior.since_ms ?? null) : saved !== null && terminal !== null ? nowMs : null;
    sinceByPane[pane] = since;
    if (terminal !== null) terminals[terminal] = { status, seq, since_ms: since };
  }
  return { terminals, sinceByPane, allRecorded };
}

function parseEligible(agent) {
  if (typeof agent !== "object" || agent === null) return null;
  const pane = typeof agent.pane_id === "string" ? agent.pane_id : "";
  const status = typeof agent.agent_status === "string" ? agent.agent_status.toLowerCase() : "";
  if (pane.length === 0 || !ELIGIBLE_STATUSES.has(status)) return null;
  return { agent, pane, status };
}
