// Live Activity updates and the end, from what the core reports (ADR 0033,
// docs/agents/live-activity-contract.md). A listener for the core follower, doing what
// the plugin's activity hook does on Herdr TUI: the app starts an activity and writes
// its push token into the Helper's registrations, and once the app has suspended this
// keeps it current through the Push Relay.
//
// Unlike the hook, each device's token has its own content, since Done is per device:
// an Agent counts as Done for a device while it has ended a turn that device's seen
// marks do not cover. So what each token last heard is kept by token, on disk, and every
// connection looks again.

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

import { agentIn } from "../core/agent-rule.js";
import { normalizeSessionName } from "../core/session-name.js";
import { AGENT_EVENTS, foldEvent, foldRecord } from "../core/turn-fold.js";
import { TurnState } from "../core/turn-state.js";
import { strippedSidebarTitle } from "../shared/activity-rows.js";
import { buildActivityState, eligibleStatusMap, hasNewlyBlocked, sameStatusMap, shortHostName } from "../shared/activity-state.js";
import { deliverLiveActivity } from "../shared/delivery/activity-seal.js";
import { liveActivityPreferences, pruneLiveActivityTokens, readLiveActivityDevices, registeredSessions } from "../shared/delivery/registrations.js";
import { readNotificationConfig } from "../shared/notification-config.js";
import { notificationKeyId } from "../shared/notification-envelope.js";
import { readSeenMarks } from "./seen-marks.js";

const MEMORY_VERSION = 1;

/** Where the desktop app looks for a Terminal's folder: what runs there now, else where it launched. */
const liveDirectory = (record) => record.foreground?.cwd || record.cwd || "";

/**
 * The Agents of an inventory as a device sees them, in the shape of the plugin's
 * `herdr agent list`. Its fields come from the Terminal's record, so a desktop app's
 * space name, and the Tab and Pane fields, are not among them.
 */
function agentsFor(inventory, turns, marks) {
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
  return agents;
}

const folderNames = (agents) =>
  new Map(agents.filter((agent) => agent.workspace_id !== "").map((agent) => [agent.workspace_id, basename(agent.workspace_id)]));

/** A listener for `followCoreSession`, updating the activities registered under the Helper's `directory`. */
export function liveActivityListener({ directory, log = () => {}, hostName = shortHostName() }) {
  const sessions = new Map();
  const say = (session, line) => log(`core session ${JSON.stringify(session)}: ${line}`);
  const memoryPath = (session) => join(directory, "state", "activity", `${session}.json`);

  function sessionNamed(session) {
    let memory = sessions.get(session);
    if (memory !== undefined) return memory;
    memory = { core: null, inventory: null, turns: new Map(), tokens: {}, timer: null, updating: Promise.resolve() };
    try {
      const file = JSON.parse(readFileSync(memoryPath(session), "utf8"));
      if (file?.v === MEMORY_VERSION && typeof file.core === "string") {
        memory.core = file.core;
        memory.tokens = file.tokens ?? {};
        for (const [address, value] of Object.entries(file.turns ?? {})) {
          memory.turns.set(address, TurnState.restore(value));
        }
      }
    } catch {
      // Absent or unreadable: every token hears what shows now, once.
    }
    sessions.set(session, memory);
    return memory;
  }

  function remember(session, memory) {
    const path = memoryPath(session);
    const temporary = `${path}.tmp-${process.pid}`;
    try {
      mkdirSync(join(directory, "state", "activity"), { recursive: true, mode: 0o700 });
      const turns = Object.fromEntries(memory.turns);
      writeFileSync(temporary, JSON.stringify({ v: MEMORY_VERSION, core: memory.core, turns, tokens: memory.tokens }), { mode: 0o600 });
      renameSync(temporary, path);
    } catch (error) {
      say(session, `could not save what it sent: ${error.message}`);
    }
  }

  /** Sends one device what it should now see. Returns its memory, or null if the token is gone. */
  async function updateDevice(config, memory, device) {
    const agents = agentsFor(memory.inventory, memory.turns, readSeenMarks(directory, notificationKeyId(device.key), memory.core));
    const statuses = eligibleStatusMap(agents);
    const preferences = liveActivityPreferences([device]);
    const last = memory.tokens[device.token] ?? null;
    const previous = last?.statuses ?? null;
    if (previous !== null && sameStatusMap(statuses, previous) && last.preferences === preferences) return last;
    const empty = Object.keys(statuses).length === 0;
    if (empty && last?.ended === true) return last;

    const { counts, plaintextObject } = buildActivityState({
      agents,
      hostName,
      pinnedPaneIds: device.pinnedPaneIds,
      workspaceLabels: folderNames(agents),
      rowLayout: device.rowLayout,
      rowHostName: device.rowHostName,
    });
    const outcome = await deliverLiveActivity(config, device, plaintextObject, {
      event: empty ? "end" : "update",
      priority: hasNewlyBlocked(statuses, previous) ? 10 : 5,
      timestamp: Math.floor(Date.now() / 1000),
      counts,
    });
    return outcome === "ok" ? { statuses, preferences, ended: empty } : null;
  }

  async function update(session, memory) {
    if (memory.inventory === null) return;
    const devices = readLiveActivityDevices(directory, session);
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
        say(session, `could not update a Live Activity: ${error.message}`);
        // Left as it was, so the next look tries again.
        if (memory.tokens[device.token] !== undefined) tokens[device.token] = memory.tokens[device.token];
      }
    }
    if (gone.size > 0) pruneLiveActivityTokens(directory, gone);
    memory.tokens = tokens;
    remember(session, memory);
  }

  /** Only what still holds after the debounce goes out: each token has a budget of pushes an hour. */
  function updateLater(session, memory) {
    clearTimeout(memory.timer);
    memory.timer = setTimeout(() => {
      memory.timer = null;
      // One at a time: the relay can take a while, and a look taken during another's
      // send must see what that send settled.
      memory.updating = memory.updating
        .then(() => update(session, memory))
        .catch((error) => say(session, `could not update Live Activities: ${error.message}`));
    }, readNotificationConfig(directory).activityDebounceMs);
    memory.timer.unref?.();
  }

  function foldSnapshot(session, memory, inventory) {
    memory.inventory = inventory;
    for (const address of memory.turns.keys()) {
      if (!inventory.has(address)) memory.turns.delete(address);
    }
    for (const [address, record] of inventory) {
      let turns = memory.turns.get(address);
      if (turns === undefined) {
        turns = new TurnState();
        memory.turns.set(address, turns);
      }
      foldRecord(turns, record);
    }
    updateLater(session, memory);
  }

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
      const memory = sessionNamed(session);
      if (memory.core !== coreId) {
        memory.turns.clear();
        memory.core = coreId;
      }
      foldSnapshot(session, memory, inventory);
    }),
    inventoryReplaced: guarded(({ session, inventory }) => {
      foldSnapshot(session, sessionNamed(session), inventory);
    }),
    event: guarded(({ session, event, inventory }) => {
      const memory = sessionNamed(session);
      memory.inventory = inventory;
      if (event.type === "removed") {
        memory.turns.delete(event.terminal);
        updateLater(session, memory);
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
      updateLater(session, memory);
    }),
    ended: guarded(({ session }) => {
      const memory = sessionNamed(session);
      clearTimeout(memory.timer);
      memory.timer = null;
      memory.inventory = null;
      const isRegistered = registeredSessions(directory).some((name) => normalizeSessionName(name) === session);
      if (!isRegistered) {
        sessions.delete(session);
        rmSync(memoryPath(session), { force: true });
      }
    }),
  };
}
