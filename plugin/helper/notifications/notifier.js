// Agent Notifications for Blocked, Error and Done, from what the core reports
// (ADR 0033). A listener for the core follower: it folds events into each Terminal's
// turns as the app does, and after a debounce sends what its current state calls for
// to the devices registered for that core session, sealed with each device's
// Notification Key, exactly as the plugin's notify hook does on Herdr TUI.
//
// Sending decides from state, not from the event at hand, so a connection that ended
// inside the debounce, or a Helper that restarted there, loses nothing: what each
// Terminal was last notified of is kept on disk, and every connection looks again.
// A core seen for the first time sets that memory without sending, so installing
// the Helper, or a new core id, does not announce everything that already happened.

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

import { agentIn } from "../core/agent-rule.js";
import { normalizeSessionName } from "../core/session-name.js";
import { AGENT_EVENTS, foldEvent, foldRecord } from "../core/turn-fold.js";
import { TurnState } from "../core/turn-state.js";
import { strippedSidebarTitle } from "../shared/activity-rows.js";
import { collapseKeyFor, sendAlertPush } from "../shared/delivery/push.js";
import { pruneAlertTokens, readAlertDevices, registeredSessions } from "../shared/delivery/registrations.js";
import { forDisplay } from "../shared/display-text.js";
import { readNotificationConfig } from "../shared/notification-config.js";
import { encryptNotificationEnvelope, notificationKeyId } from "../shared/notification-envelope.js";
import { readSeenMark, removeSeenMarks } from "./seen-marks.js";

const MEMORY_VERSION = 1;
// Error is sent under the Blocked trigger, in its own word.
const ATTENTION_STATUSES = new Set(["blocked", "error"]);

const sameMark = (left, right) => left?.turn === right?.turn && left?.word === right?.word;

class Terminal {
  turns = new TurnState();
  /** The attention status last notified, until the Agent is confirmed to have left it. */
  notified = null;
  /** The finished turn last decided on. */
  notifiedTurn = null;
  timer = null;
  deciding = Promise.resolve();

  toJSON() {
    return { turns: this.turns, notified: this.notified, notifiedTurn: this.notifiedTurn };
  }

  static restore(value) {
    const terminal = new Terminal();
    terminal.turns = TurnState.restore(value?.turns);
    terminal.notified = typeof value?.notified === "string" ? value.notified : null;
    terminal.notifiedTurn = TurnState.restore({ ended: value?.notifiedTurn }).ended;
    return terminal;
  }
}

/** A listener for `followCoreSession`, sending for the registrations under the Helper's `directory`. */
export function notificationListener({ directory, log = () => {} }) {
  const sessions = new Map();
  const say = (session, line) => log(`core session ${JSON.stringify(session)}: ${line}`);
  const memoryPath = (session) => join(directory, "state", "notify", `${session}.json`);

  function sessionNamed(session) {
    let memory = sessions.get(session);
    if (memory !== undefined) return memory;
    memory = { core: null, inventory: null, terminals: new Map() };
    try {
      const file = JSON.parse(readFileSync(memoryPath(session), "utf8"));
      if (file?.v === MEMORY_VERSION && typeof file.core === "string") {
        memory.core = file.core;
        for (const [address, value] of Object.entries(file.terminals ?? {})) {
          memory.terminals.set(address, Terminal.restore(value));
        }
      }
    } catch {
      // Absent or unreadable: this core reads as seen for the first time.
    }
    sessions.set(session, memory);
    return memory;
  }

  function remember(session, memory) {
    const path = memoryPath(session);
    const temporary = `${path}.tmp-${process.pid}`;
    try {
      mkdirSync(join(directory, "state", "notify"), { recursive: true, mode: 0o700 });
      const terminals = Object.fromEntries(memory.terminals);
      writeFileSync(temporary, JSON.stringify({ v: MEMORY_VERSION, core: memory.core, terminals }), { mode: 0o600 });
      renameSync(temporary, path);
    } catch (error) {
      say(session, `could not save what it notified: ${error.message}`);
    }
  }

  function forgetTimers(memory) {
    for (const terminal of memory.terminals.values()) {
      clearTimeout(terminal.timer);
      terminal.timer = null;
    }
  }

  /** Sends one notification to each device. True once there is nothing left to try. */
  async function deliver(session, address, record, agent, status, flag, wants = () => true) {
    const config = readNotificationConfig(directory);
    const devices = readAlertDevices(directory, flag, session).filter(wants);
    if (devices.length === 0) return true;
    const payload = {
      paneId: address,
      agentKind: agent.kind,
      status,
      timestamp: Math.floor(Date.now() / 1000),
      project: forDisplay(typeof record.cwd === "string" && record.cwd !== "" ? basename(record.cwd) : null),
      title: forDisplay(strippedSidebarTitle(record.title)),
    };
    const gone = [];
    let failed = false;
    let delivered = false;
    for (const device of devices) {
      try {
        const envelope = encryptNotificationEnvelope(payload, device.key);
        const outcome = await sendAlertPush(config.relayUrl, device, envelope, collapseKeyFor(device.key, address), config.retryDelayMs);
        if (outcome === "ok") delivered = true;
        else gone.push(device);
      } catch (error) {
        failed = true;
        say(session, `could not notify about ${JSON.stringify(address)}: ${error.message}`);
      }
    }
    if (gone.length > 0) {
      pruneAlertTokens(directory, new Set(gone.map((device) => device.token)));
      for (const device of gone) removeSeenMarks(directory, notificationKeyId(device.key));
    }
    return delivered || !failed;
  }

  async function decide(session, memory, address) {
    const terminal = memory.terminals.get(address);
    const record = memory.inventory?.get(address);
    if (terminal === undefined || record === undefined) return;
    const agent = agentIn(record);
    if (agent === null) {
      terminal.notified = null;
    } else if (ATTENTION_STATUSES.has(agent.status)) {
      if (terminal.notified === agent.status) return;
      const status = agent.status;
      if (await deliver(session, address, record, agent, status, "blocked")) terminal.notified = status;
    } else {
      terminal.notified = null;
      const ended = terminal.turns.ended;
      if (agent.status === "idle" && ended !== null && !sameMark(terminal.notifiedTurn, ended)) {
        const stillDone = (device) =>
          terminal.turns.isDoneFor(readSeenMark(directory, notificationKeyId(device.key), memory.core, address));
        if (await deliver(session, address, record, agent, "done", "done", stillDone)) terminal.notifiedTurn = ended;
      }
    }
    remember(session, memory);
  }

  /** Only a status that still holds after the debounce notifies, so a flap never reaches the user. */
  function decideLater(session, memory, address) {
    const terminal = memory.terminals.get(address);
    if (terminal === undefined) return;
    clearTimeout(terminal.timer);
    terminal.timer = setTimeout(() => {
      terminal.timer = null;
      // One at a time per Terminal: the relay can take a while, and a decision made
      // during another's send must see what that send settled.
      terminal.deciding = terminal.deciding
        .then(() => decide(session, memory, address))
        .catch((error) => say(session, `could not decide about ${JSON.stringify(address)}: ${error.message}`));
    }, readNotificationConfig(directory).debounceMs);
    terminal.timer.unref?.();
  }

  /** A snapshot's Terminals. With `settled`, what they show already counts as notified. */
  function foldSnapshot(session, memory, inventory, { settled }) {
    memory.inventory = inventory;
    for (const [address, terminal] of memory.terminals) {
      if (inventory.has(address)) continue;
      clearTimeout(terminal.timer);
      memory.terminals.delete(address);
    }
    for (const [address, record] of inventory) {
      let terminal = memory.terminals.get(address);
      if (terminal === undefined) {
        terminal = new Terminal();
        memory.terminals.set(address, terminal);
      }
      foldRecord(terminal.turns, record);
      if (settled) {
        const status = agentIn(record)?.status;
        terminal.notified = ATTENTION_STATUSES.has(status) ? status : null;
        terminal.notifiedTurn = terminal.turns.ended;
      }
      decideLater(session, memory, address);
    }
    remember(session, memory);
  }

  // Each callback is guarded: a listener that throws would end the core's connection.
  const guarded = (body) => (report) => {
    try {
      body(report);
    } catch (error) {
      say(report.session, `could not follow for notifications: ${error.message}`);
    }
  };

  return {
    connected: guarded(({ session, coreId, inventory }) => {
      const memory = sessionNamed(session);
      const isKnownCore = memory.core === coreId;
      if (!isKnownCore) {
        forgetTimers(memory);
        memory.terminals.clear();
        memory.core = coreId;
      }
      foldSnapshot(session, memory, inventory, { settled: !isKnownCore });
    }),
    inventoryReplaced: guarded(({ session, inventory }) => {
      foldSnapshot(session, sessionNamed(session), inventory, { settled: false });
    }),
    event: guarded(({ session, event, inventory }) => {
      const memory = sessionNamed(session);
      memory.inventory = inventory;
      if (event.type === "removed") {
        const terminal = memory.terminals.get(event.terminal);
        clearTimeout(terminal?.timer);
        memory.terminals.delete(event.terminal);
        remember(session, memory);
        return;
      }
      if (!AGENT_EVENTS.has(event.type)) return;
      const record = inventory.get(event.terminal);
      if (record === undefined) return;
      let terminal = memory.terminals.get(event.terminal);
      if (terminal === undefined) {
        terminal = new Terminal();
        memory.terminals.set(event.terminal, terminal);
      }
      foldEvent(terminal.turns, event, record);
      remember(session, memory);
      decideLater(session, memory, event.terminal);
    }),
    ended: guarded(({ session }) => {
      const memory = sessionNamed(session);
      forgetTimers(memory);
      memory.inventory = null;
      // With no device left here, what happens next is nobody's to hear of when one
      // registers again, so that device starts from what the core shows then.
      const isRegistered = registeredSessions(directory).some((name) => normalizeSessionName(name) === session);
      if (!isRegistered) {
        sessions.delete(session);
        rmSync(memoryPath(session), { force: true });
      }
    }),
  };
}
