// Live Activity updates and the end, from what a herdr-core session or tmux
// server reports (ADRs 0033 and 0046, docs/agents/live-activity-contract.md).
// The app starts an activity and writes its push token into the Helper's
// registrations, and once the app has suspended this keeps it current through
// the Push Relay.
//
// Unlike the hook, each device's token has its own content, since Done is per device:
// an Agent counts as Done for a device while it has ended a turn that device's seen
// marks do not cover. So what each token last heard is kept by token, on disk, and every
// connection looks again.

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

import { agentIn } from "../core/agent-rule.js";
import { normalizeSessionName } from "../core/session-name.js";
import { AGENT_EVENTS, decisionSignature, foldEvent, foldRecord } from "../core/turn-fold.js";
import { TurnState } from "../core/turn-state.js";
import { strippedSidebarTitle } from "../shared/activity-rows.js";
import { buildActivityState, eligibleStatusMap, hasNewlyBlocked, sameStatusMap, shortHostName } from "../shared/activity-state.js";
import { deliverLiveActivity } from "../shared/delivery/activity-seal.js";
import { liveActivityPreferences, pruneLiveActivityTokens, readLiveActivityDevices, registeredSessions } from "../shared/delivery/registrations.js";
import { readNotificationConfig } from "../shared/notification-config.js";
import { notificationKeyId } from "../shared/notification-envelope.js";
import { normalizeTmuxSocketName } from "../tmux/socket-name.js";
import {
  TmuxTurnState,
  foldTmuxPane,
  tmuxDecisionSignature,
  tmuxKindLabel,
  tmuxPaneInventory,
} from "../tmux/turn-state.js";
import { readSeenMarks } from "./seen-marks.js";

const MEMORY_VERSION = 1;

/** Where the desktop app looks for a Terminal's folder: what runs there now, else where it launched. */
const liveDirectory = (record) => record.foreground?.cwd || record.cwd || "";

const folderNames = (agents) =>
  new Map(agents.filter((agent) => agent.workspace_id !== "").map((agent) => [agent.workspace_id, basename(agent.workspace_id)]));

/**
 * The Agents of a herdr-core inventory as a device sees them, in the shape of
 * the plugin's `herdr agent list`.
 */
function coreSnapshotView(inventory, turns, marks) {
  const agents = [];
  for (const [address, record] of inventory) {
    const found = agentIn(record);
    if (found === null) continue;
    const done = found.status === "idle" && turns.get(address)?.isDoneFor(marks.get(address) ?? null) === true;
    const title = typeof record.title === "string" ? record.title : "";
    agents.push({
      pane_id: address,
      agent_status: done ? "done" : found.status,
      agent: found.kind,
      display_agent: record.name,
      terminal_title: title,
      terminal_title_stripped: strippedSidebarTitle(title),
      workspace_id: liveDirectory(record),
      cwd: record.cwd,
      tokens: record.labels,
    });
  }
  return {
    agents,
    workspaceLabels: folderNames(agents),
    tabs: new Map(),
    panes: new Map(),
    blockedCounts: null,
  };
}

/**
 * The Agents of a tmux server's shown Panes, with the tmux session's name as
 * each Agent's workspace and per-pane `blocked=<n>` counts for step detection.
 */
function tmuxSnapshotView(inventory, turns, marks) {
  const workspaceLabels = new Map();
  const windowsBySession = new Map();
  const windowNames = new Map();
  const panes = new Map();

  for (const pane of inventory.values()) {
    if (!workspaceLabels.has(pane.sessionID)) workspaceLabels.set(pane.sessionID, pane.sessionName);
    let sessionWindows = windowsBySession.get(pane.sessionID);
    if (!sessionWindows) {
      sessionWindows = [];
      windowsBySession.set(pane.sessionID, sessionWindows);
    }
    if (!windowNames.has(pane.windowID)) {
      windowNames.set(pane.windowID, { sessionID: pane.sessionID, label: pane.windowName });
      sessionWindows.push(pane.windowID);
    }
    panes.set(pane.paneID, {
      workspace_id: pane.sessionID,
      tab_id: pane.windowID,
      label: pane.command || null,
    });
  }

  const tabs = new Map();
  for (const [sessionID, windowIDs] of windowsBySession) {
    for (const [index, windowID] of windowIDs.entries()) {
      tabs.set(windowID, {
        workspace_id: sessionID,
        label: windowNames.get(windowID)?.label ?? "",
        position: index + 1,
        count: windowIDs.length,
      });
    }
  }

  const agents = [];
  const blockedCounts = {};
  for (const [paneID, pane] of inventory) {
    if (pane.isDead || !pane.agentKind) continue;
    const turnState = turns.get(paneID);
    const status = turnState?.agentStatus ?? "unknown";
    if (status === "blocked") blockedCounts[paneID] = turnState?.blockedCount ?? 0;
    const done = status === "idle" && turnState?.isDoneFor(marks.get(paneID) ?? null) === true;
    agents.push({
      pane_id: paneID,
      agent_status: done ? "done" : status,
      agent: pane.agentKind,
      terminal_title: null,
      terminal_title_stripped: tmuxKindLabel(pane.agentKind),
      workspace_id: pane.sessionID,
      tab_id: pane.windowID,
      cwd: pane.path,
      tokens: {},
    });
  }

  return { agents, workspaceLabels, tabs, panes, blockedCounts };
}

function hasSteppedBlocked(current, previous) {
  if (current === null || !previous || typeof previous !== "object") return false;
  for (const [pane, count] of Object.entries(current)) {
    if (typeof previous[pane] === "number" && count > previous[pane]) return true;
  }
  return false;
}

function createActivityUpdater({
  directory,
  say,
  hostName,
  memoryPath,
  registrationSession,
  isRegistered,
  TurnModel,
  foldItem,
  signatureOf,
  buildSnapshotView,
}) {
  const sessions = new Map();

  function sessionNamed(key) {
    let memory = sessions.get(key);
    if (memory !== undefined) return memory;
    memory = {
      core: null,
      inventory: null,
      turns: new Map(),
      signatures: new Map(),
      tokens: {},
      timer: null,
      updating: Promise.resolve(),
    };
    try {
      const file = JSON.parse(readFileSync(memoryPath(key), "utf8"));
      if (file?.v === MEMORY_VERSION && typeof file.core === "string") {
        memory.core = file.core;
        memory.tokens = file.tokens ?? {};
        for (const [address, value] of Object.entries(file.turns ?? {})) {
          memory.turns.set(address, TurnModel.restore(value));
        }
      }
    } catch {
      // Absent or unreadable: every token hears what shows now, once.
    }
    sessions.set(key, memory);
    return memory;
  }

  function remember(key, memory) {
    const path = memoryPath(key);
    const temporary = `${path}.tmp-${process.pid}`;
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const turns = Object.fromEntries(memory.turns);
      writeFileSync(temporary, JSON.stringify({ v: MEMORY_VERSION, core: memory.core, turns, tokens: memory.tokens }), {
        mode: 0o600,
      });
      renameSync(temporary, path);
    } catch (error) {
      say(key, `could not save what it sent: ${error.message}`);
    }
  }

  function evaluateDevice(memory, device) {
    const view = buildSnapshotView(
      memory.inventory,
      memory.turns,
      readSeenMarks(directory, notificationKeyId(device.key), memory.core),
    );
    const statuses = eligibleStatusMap(view.agents);
    const preferences = liveActivityPreferences([device]);
    const last = memory.tokens[device.token] ?? null;
    const previous = last?.statuses ?? null;
    const steppedBlocked = hasSteppedBlocked(view.blockedCounts, last?.blockedCounts);
    const empty = Object.keys(statuses).length === 0;
    const unchanged =
      (previous !== null && sameStatusMap(statuses, previous) && last.preferences === preferences && !steppedBlocked) ||
      (empty && last?.ended === true);
    return { view, statuses, preferences, last, previous, steppedBlocked, empty, unchanged };
  }

  /** Sends one device what it should now see. Returns its memory, or null if the token is gone. */
  async function updateDevice(config, memory, device) {
    const { view, statuses, preferences, last, previous, steppedBlocked, empty, unchanged } = evaluateDevice(memory, device);
    if (unchanged) return last;

    const { counts, plaintextObject } = buildActivityState({
      agents: view.agents,
      hostName,
      pinnedPaneIds: device.pinnedPaneIds,
      workspaceLabels: view.workspaceLabels,
      rowLayout: device.rowLayout,
      rowHostName: device.rowHostName,
      tabs: view.tabs,
      panes: view.panes,
    });
    const outcome = await deliverLiveActivity(config, device, plaintextObject, {
      event: empty ? "end" : "update",
      priority: hasNewlyBlocked(statuses, previous) || steppedBlocked ? 10 : 5,
      timestamp: Math.floor(Date.now() / 1000),
      counts,
    });
    if (outcome !== "ok") return null;
    return view.blockedCounts === null
      ? { statuses, preferences, ended: empty }
      : { statuses, blockedCounts: view.blockedCounts, preferences, ended: empty };
  }

  async function update(key, memory) {
    if (memory.inventory === null) return;
    const devices = readLiveActivityDevices(directory, registrationSession(key));
    if (devices.length === 0 && Object.keys(memory.tokens).length === 0) return;
    const config = readNotificationConfig(directory);
    const tokens = {};
    const gone = new Set();
    for (const device of devices) {
      try {
        const sent = await updateDevice(config, memory, device);
        if (sent === null) gone.add(device.token);
        else tokens[device.token] = sent;
      } catch (error) {
        say(key, `could not update a Live Activity: ${error.message}`);
        // Left as it was, so the next look tries again.
        if (memory.tokens[device.token] !== undefined) tokens[device.token] = memory.tokens[device.token];
      }
    }
    if (gone.size > 0) pruneLiveActivityTokens(directory, gone);
    memory.tokens = tokens;
    remember(key, memory);
  }

  /** Only what still holds after the debounce goes out: each token has a budget of pushes an hour. */
  function updateLater(key, memory) {
    clearTimeout(memory.timer);
    memory.timer = setTimeout(() => {
      memory.timer = null;
      // One at a time: the relay can take a while, and a look taken during another's
      // send must see what that send settled.
      memory.updating = memory.updating
        .then(() => update(key, memory))
        .catch((error) => say(key, `could not update Live Activities: ${error.message}`));
    }, readNotificationConfig(directory).activityDebounceMs);
    memory.timer.unref?.();
  }

  function needsDeviceSync(key, memory) {
    if (memory.inventory === null) return false;
    const devices = readLiveActivityDevices(directory, registrationSession(key));
    const rememberedTokens = Object.keys(memory.tokens);
    if (devices.length === 0 && rememberedTokens.length === 0) return false;
    if (devices.length !== rememberedTokens.length) return true;
    for (const device of devices) {
      if (!evaluateDevice(memory, device).unchanged) return true;
    }
    return false;
  }

  function foldSnapshot(key, memory, inventory, { alwaysSchedule = true } = {}) {
    memory.inventory = inventory;
    let changed = alwaysSchedule;
    for (const address of memory.turns.keys()) {
      if (!inventory.has(address)) {
        memory.turns.delete(address);
        memory.signatures.delete(address);
        changed = true;
      }
    }
    for (const [address, record] of inventory) {
      let turns = memory.turns.get(address);
      if (turns === undefined) {
        turns = new TurnModel();
        memory.turns.set(address, turns);
        changed = true;
      }
      foldItem(turns, record);
      const nextSignature = signatureOf(record, turns);
      if (nextSignature !== memory.signatures.get(address)) {
        memory.signatures.set(address, nextSignature);
        changed = true;
      }
    }
    if (changed) {
      updateLater(key, memory);
    } else if (memory.timer === null && needsDeviceSync(key, memory)) {
      updateLater(key, memory);
    }
  }

  function noteConnected(key, instanceId, inventory) {
    const memory = sessionNamed(key);
    if (memory.core !== instanceId) {
      memory.turns.clear();
      memory.signatures.clear();
      for (const tokenMemory of Object.values(memory.tokens)) {
        if (tokenMemory?.blockedCounts && typeof tokenMemory.blockedCounts === "object") {
          tokenMemory.blockedCounts = Object.fromEntries(Object.keys(tokenMemory.blockedCounts).map((pane) => [pane, 0]));
        }
      }
      memory.core = instanceId;
    }
    foldSnapshot(key, memory, inventory, { alwaysSchedule: true });
  }

  function noteEnded(key) {
    const memory = sessionNamed(key);
    clearTimeout(memory.timer);
    memory.timer = null;
    memory.inventory = null;
    if (!isRegistered(key)) {
      sessions.delete(key);
      rmSync(memoryPath(key), { force: true });
    }
  }

  return {
    sessionNamed,
    updateLater,
    foldSnapshot,
    noteConnected,
    noteEnded,
  };
}

/** A listener for `followCoreSession`, updating the activities registered under the Helper's `directory`. */
export function liveActivityListener({ directory, log = () => {}, hostName = shortHostName() }) {
  const say = (session, line) => log(`core session ${JSON.stringify(session)}: ${line}`);
  const updater = createActivityUpdater({
    directory,
    say,
    hostName,
    memoryPath: (session) => join(directory, "state", "activity", `${session}.json`),
    registrationSession: (session) => session,
    isRegistered: (session) => registeredSessions(directory).some((name) => normalizeSessionName(name) === session),
    TurnModel: TurnState,
    foldItem: foldRecord,
    signatureOf: decisionSignature,
    buildSnapshotView: coreSnapshotView,
  });

  // Each callback is guarded: a listener that throws would end the core's connection.
  const guarded = (body) => (report) => {
    try {
      body(report);
    } catch (error) {
      say(report.session, `could not follow for Live Activities: ${error.message}`);
    }
  };

  return {
    connected: guarded(({ session, coreId, inventory }) => {
      updater.noteConnected(session, coreId, inventory);
    }),
    inventoryReplaced: guarded(({ session, inventory }) => {
      updater.foldSnapshot(session, updater.sessionNamed(session), inventory, { alwaysSchedule: true });
    }),
    event: guarded(({ session, event, inventory }) => {
      const memory = updater.sessionNamed(session);
      memory.inventory = inventory;
      if (event.type === "removed") {
        memory.turns.delete(event.terminal);
        memory.signatures.delete(event.terminal);
        updater.updateLater(session, memory);
        return;
      }
      if (!AGENT_EVENTS.has(event.type)) return;
      const record = inventory.get(event.terminal);
      if (record === undefined) return;
      let turns = memory.turns.get(event.terminal);
      if (turns === undefined) {
        turns = new TurnState();
        memory.turns.set(event.terminal, turns);
      }
      foldEvent(turns, event, record);
      const signature = decisionSignature(record, turns);
      const isWaitingForThis = memory.timer !== null && signature === memory.signatures.get(event.terminal);
      memory.signatures.set(event.terminal, signature);
      if (!isWaitingForThis) updater.updateLater(session, memory);
    }),
    ended: guarded(({ session }) => {
      updater.noteEnded(session);
    }),
  };
}

/** A listener for `followTmuxServer`, keeping records under `tmux/<socket>/activity.json`. */
export function tmuxLiveActivityListener({ directory, log = () => {}, hostName = shortHostName() }) {
  const say = (socket, line) => log(`tmux socket ${JSON.stringify(socket)}: ${line}`);
  const updater = createActivityUpdater({
    directory,
    say,
    hostName,
    memoryPath: (socket) => join(directory, "tmux", socket, "activity.json"),
    registrationSession: (socket) => `tmux/${socket}`,
    isRegistered: (socket) =>
      registeredSessions(directory).some(
        (name) => name.startsWith("tmux/") && normalizeTmuxSocketName(name.slice("tmux/".length)) === socket,
      ),
    TurnModel: TmuxTurnState,
    foldItem: foldTmuxPane,
    signatureOf: tmuxDecisionSignature,
    buildSnapshotView: tmuxSnapshotView,
  });

  const guarded = (body) => (report) => {
    const socket = normalizeTmuxSocketName(report.socket);
    if (socket === null) return;
    try {
      body({ ...report, socket });
    } catch (error) {
      say(socket, `could not follow for Live Activities: ${error.message}`);
    }
  };

  return {
    serverStarted: guarded(({ socket, instance, panes }) => {
      updater.noteConnected(socket, instance, tmuxPaneInventory(panes));
    }),
    panesUpdated: guarded(({ socket, instance, panes }) => {
      const memory = updater.sessionNamed(socket);
      if (memory.core !== instance) {
        updater.noteConnected(socket, instance, tmuxPaneInventory(panes));
        return;
      }
      updater.foldSnapshot(socket, memory, tmuxPaneInventory(panes), { alwaysSchedule: false });
    }),
    serverEnded: guarded(({ socket }) => {
      updater.noteEnded(socket);
    }),
    followerStopped: guarded(({ socket }) => {
      updater.noteEnded(socket);
    }),
  };
}
