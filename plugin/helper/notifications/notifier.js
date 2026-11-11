// Agent Notifications for Blocked, Error and Done, from what a herdr-core
// session or tmux server reports (ADRs 0033 and 0044). Folds turns as the app
// does, and after a debounce sends what the current state calls for to the
// devices registered for that session or server, sealed with each device's
// Notification Key, exactly as the plugin's notify hook does on Herdr TUI.
//
// Sending decides from state, not from the event at hand, so a connection that ended
// inside the debounce, or a Helper that restarted there, loses nothing: what each
// Terminal was last notified of is kept on disk, and every connection looks again.
// A send that failed also looks again by itself, a limited number of times, since a
// quiet Terminal has no event to bring the next decision.
// A core or tmux server seen for the first time sets that memory without sending, so
// installing the Helper, or a new server instance, does not announce old state.

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

import { agentIn } from "../core/agent-rule.js";
import { normalizeSessionName } from "../core/session-name.js";
import { AGENT_EVENTS, decisionSignature, foldEvent, foldRecord } from "../core/turn-fold.js";
import { TurnState } from "../core/turn-state.js";
import { strippedSidebarTitle } from "../shared/activity-rows.js";
import { collapseKeyFor, sendAlertPush } from "../shared/delivery/push.js";
import { pruneAlertTokens, readAlertDevices, registeredSessions } from "../shared/delivery/registrations.js";
import { forDisplay } from "../shared/display-text.js";
import { readNotificationConfig } from "../shared/notification-config.js";
import { encryptNotificationEnvelope, notificationKeyId } from "../shared/notification-envelope.js";
import { normalizeTmuxSocketName } from "../tmux/socket-name.js";
import {
  TmuxTurnState,
  foldTmuxPane,
  tmuxDecisionSignature,
  tmuxKindLabel,
  tmuxPaneInventory,
} from "../tmux/turn-state.js";
import { readSeenMark, removeSeenMarks } from "./seen-marks.js";

const MEMORY_VERSION = 1;
// Error is sent under the Blocked trigger, in its own word.
const ATTENTION_STATUSES = new Set(["blocked", "error"]);
// A failed send's next tries, each wait double the last up to the ceiling. Kept in
// memory only: after them, or a restart, the next decision is what tries again.
const RETRY_FIRST_DELAY_MS = 30_000;
const RETRY_DELAY_CEILING_MS = 5 * 60_000;
const RETRY_ATTEMPT_LIMIT = 5;

const realRetryTimers = {
  set(run, delayMs) {
    const timer = setTimeout(run, delayMs);
    timer.unref?.();
    return timer;
  },
  clear: clearTimeout,
};

const sameMark = (left, right) => left?.turn === right?.turn && left?.word === right?.word;
const tokensFrom = (value) => (Array.isArray(value) ? value.filter((token) => typeof token === "string") : []);

class Terminal {
  constructor(TurnModel = TurnState) {
    this.turns = new TurnModel();
  }

  /** The attention status last notified, until the Agent is confirmed to have left it. */
  notified = null;
  /** The finished turn last decided on. */
  notifiedTurn = null;
  /** Tokens `notified` has yet to reach, because their send failed. */
  unsentStatus = [];
  /** Tokens `notifiedTurn` has yet to reach, because their send failed. */
  unsentTurn = [];
  timer = null;
  /** What the pending timer's wait is about. */
  signature = null;
  deciding = Promise.resolve();
  /** The wait before trying a failed send again, apart from the debounce. */
  retryTimer = null;
  /** Waits armed since a send last reached everyone or the state changed. */
  retryAttempts = 0;

  toJSON() {
    return {
      turns: this.turns,
      notified: this.notified,
      notifiedTurn: this.notifiedTurn,
      unsentStatus: this.unsentStatus,
      unsentTurn: this.unsentTurn,
    };
  }

  static restore(value, TurnModel = TurnState) {
    const terminal = new Terminal(TurnModel);
    terminal.turns = TurnModel.restore(value?.turns);
    terminal.notified = typeof value?.notified === "string" ? value.notified : null;
    terminal.notifiedTurn = TurnState.restore({ ended: value?.notifiedTurn }).ended;
    terminal.unsentStatus = tokensFrom(value?.unsentStatus);
    terminal.unsentTurn = tokensFrom(value?.unsentTurn);
    return terminal;
  }
}

function createNotifier({
  directory,
  say,
  memoryPath,
  registrationSession,
  isRegistered,
  TurnModel,
  foldItem,
  signatureOf,
  inspectItem,
  retryTimers,
}) {
  const sessions = new Map();

  function sessionNamed(key) {
    let memory = sessions.get(key);
    if (memory !== undefined) return memory;
    memory = { core: null, inventory: null, terminals: new Map() };
    try {
      const file = JSON.parse(readFileSync(memoryPath(key), "utf8"));
      if (file?.v === MEMORY_VERSION && typeof file.core === "string") {
        memory.core = file.core;
        for (const [address, value] of Object.entries(file.terminals ?? {})) {
          memory.terminals.set(address, Terminal.restore(value, TurnModel));
        }
      }
    } catch {
      // Absent or unreadable: this instance reads as seen for the first time.
    }
    sessions.set(key, memory);
    return memory;
  }

  function remember(key, memory) {
    const path = memoryPath(key);
    const temporary = `${path}.tmp-${process.pid}`;
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const terminals = Object.fromEntries(memory.terminals);
      writeFileSync(temporary, JSON.stringify({ v: MEMORY_VERSION, core: memory.core, terminals }), { mode: 0o600 });
      renameSync(temporary, path);
    } catch (error) {
      say(key, `could not save what it notified: ${error.message}`);
    }
  }

  function clearRetry(terminal) {
    retryTimers.clear(terminal.retryTimer);
    terminal.retryTimer = null;
  }

  function forgetTimers(memory) {
    for (const terminal of memory.terminals.values()) {
      clearTimeout(terminal.timer);
      terminal.timer = null;
      clearRetry(terminal);
    }
  }

  /** Sends one notification to each device, and returns the tokens whose send failed. */
  async function deliver(key, address, inspected, status, flag, wants = () => true) {
    const config = readNotificationConfig(directory);
    const devices = readAlertDevices(directory, flag, registrationSession(key)).filter(wants);
    if (devices.length === 0) return [];
    const payload = {
      paneId: address,
      agentKind: inspected.kind,
      status,
      timestamp: Math.floor(Date.now() / 1000),
      project: forDisplay(inspected.project),
      title: forDisplay(inspected.title),
    };
    const gone = [];
    const failed = [];
    for (const device of devices) {
      try {
        const envelope = encryptNotificationEnvelope(payload, device.key);
        const outcome = await sendAlertPush(config.relayUrl, device, envelope, collapseKeyFor(device.key, address), config.retryDelayMs);
        if (outcome !== "ok") gone.push(device);
      } catch (error) {
        failed.push(device.token);
        say(key, `could not notify about ${JSON.stringify(address)}: ${error.message}`);
      }
    }
    // Housekeeping, which says nothing of who heard this: the next 410 tries it again.
    try {
      if (gone.length > 0) {
        pruneAlertTokens(directory, new Set(gone.map((device) => device.token)));
        for (const device of gone) removeSeenMarks(directory, notificationKeyId(device.key));
      }
    } catch (error) {
      say(key, `could not remove a device the relay says is gone: ${error.message}`);
    }
    return failed;
  }

  async function decide(key, memory, address) {
    const terminal = memory.terminals.get(address);
    const record = memory.inventory?.get(address);
    if (terminal === undefined || record === undefined) return;
    const { notified, notifiedTurn } = terminal;
    await send(key, memory, address, terminal, record);
    const isNewState = terminal.notified !== notified || !sameMark(terminal.notifiedTurn, notifiedTurn);
    const hasUnsent = terminal.unsentStatus.length > 0 || terminal.unsentTurn.length > 0;
    if (isNewState || !hasUnsent) {
      clearRetry(terminal);
      terminal.retryAttempts = 0;
    }
    // During the send the connection can have ended or the Terminal gone.
    if (!hasUnsent || memory.inventory === null || memory.terminals.get(address) !== terminal) return;
    if (terminal.retryTimer === null) retryLater(key, memory, address, terminal);
  }

  async function send(key, memory, address, terminal, record) {
    const inspected = inspectItem(record, terminal.turns);
    // A send that failed waits for the next decision while what it said still holds.
    // What was notified is noted only once `deliver` returns: a report during the send
    // saves this memory, and a Helper killed there must send again after its restart.
    const isUnsent = (unsent) => (device) => unsent.includes(device.token);
    if (inspected?.status !== "idle") terminal.unsentTurn = [];
    if (inspected !== null && inspected.attention !== null) {
      if (terminal.notified !== inspected.attention) {
        terminal.unsentStatus = await deliver(key, address, inspected, inspected.wireAttention, "blocked");
        terminal.notified = inspected.attention;
      } else if (terminal.unsentStatus.length > 0) {
        terminal.unsentStatus = await deliver(
          key,
          address,
          inspected,
          inspected.wireAttention,
          "blocked",
          isUnsent(terminal.unsentStatus),
        );
      } else {
        return;
      }
    } else {
      terminal.notified = null;
      terminal.unsentStatus = [];
      const ended = terminal.turns.ended;
      if (inspected?.status === "idle" && ended !== null) {
        const stillDone = (device) =>
          terminal.turns.isDoneFor(readSeenMark(directory, notificationKeyId(device.key), memory.core, address));
        if (!sameMark(terminal.notifiedTurn, ended)) {
          terminal.unsentTurn = await deliver(key, address, inspected, "done", "done", stillDone);
          terminal.notifiedTurn = ended;
        } else if (terminal.unsentTurn.length > 0) {
          const unsent = isUnsent(terminal.unsentTurn);
          terminal.unsentTurn = await deliver(
            key,
            address,
            inspected,
            "done",
            "done",
            (device) => unsent(device) && stillDone(device),
          );
        }
      }
    }
    remember(key, memory);
  }

  // One at a time per Terminal: the relay can take a while, and a decision made
  // during another's send must see what that send settled.
  function decideNext(key, memory, address, terminal) {
    terminal.deciding = terminal.deciding
      .then(() => decide(key, memory, address))
      .catch((error) => say(key, `could not decide about ${JSON.stringify(address)}: ${error.message}`));
    return terminal.deciding;
  }

  /** Only a status that still holds after the debounce notifies, so a flap never reaches the user. */
  function decideLater(key, memory, address) {
    const terminal = memory.terminals.get(address);
    if (terminal === undefined) return;
    clearTimeout(terminal.timer);
    terminal.timer = setTimeout(() => {
      terminal.timer = null;
      decideNext(key, memory, address, terminal);
    }, readNotificationConfig(directory).debounceMs);
    terminal.timer.unref?.();
  }

  /** Decides again by itself, apart from the debounce and whatever it is waiting for. */
  function retryLater(key, memory, address, terminal) {
    if (terminal.retryAttempts >= RETRY_ATTEMPT_LIMIT) return;
    const delayMs = Math.min(RETRY_FIRST_DELAY_MS * 2 ** terminal.retryAttempts, RETRY_DELAY_CEILING_MS);
    terminal.retryAttempts += 1;
    terminal.retryTimer = retryTimers.set(() => {
      terminal.retryTimer = null;
      // A debounce under way is about a change, and its decision tries this too.
      return terminal.timer === null ? decideNext(key, memory, address, terminal) : undefined;
    }, delayMs);
  }

  /** A snapshot's Terminals. With `settled`, what they show already counts as notified. */
  function foldSnapshot(key, memory, inventory, { settled, armUnchanged = true }) {
    memory.inventory = inventory;
    let dirty = settled || armUnchanged;
    for (const [address, terminal] of memory.terminals) {
      if (inventory.has(address)) continue;
      clearTimeout(terminal.timer);
      clearRetry(terminal);
      memory.terminals.delete(address);
      dirty = true;
    }
    for (const [address, record] of inventory) {
      let terminal = memory.terminals.get(address);
      if (terminal === undefined) {
        terminal = new Terminal(TurnModel);
        memory.terminals.set(address, terminal);
        dirty = true;
      }
      foldItem(terminal.turns, record);
      if (settled) {
        terminal.notified = inspectItem(record, terminal.turns)?.attention ?? null;
        terminal.notifiedTurn = terminal.turns.ended;
      }
      const nextSignature = signatureOf(record, terminal.turns);
      const changed = nextSignature !== terminal.signature;
      terminal.signature = nextSignature;
      if (changed) dirty = true;
      if (armUnchanged || changed) decideLater(key, memory, address);
    }
    if (dirty) remember(key, memory);
  }

  function noteConnected(key, instanceId, inventory) {
    const memory = sessionNamed(key);
    const isKnownInstance = memory.core === instanceId;
    if (!isKnownInstance) {
      forgetTimers(memory);
      memory.terminals.clear();
      memory.core = instanceId;
    }
    foldSnapshot(key, memory, inventory, { settled: !isKnownInstance, armUnchanged: true });
  }

  function noteEnded(key) {
    const memory = sessionNamed(key);
    forgetTimers(memory);
    memory.inventory = null;
    if (!isRegistered(key)) {
      sessions.delete(key);
      rmSync(memoryPath(key), { force: true });
    }
  }

  return {
    sessionNamed,
    remember,
    clearRetry,
    decideLater,
    foldSnapshot,
    noteConnected,
    noteEnded,
  };
}

/** A listener for `followCoreSession`, sending for the registrations under the Helper's `directory`. */
export function notificationListener({ directory, log = () => {}, retryTimers = realRetryTimers }) {
  const say = (session, line) => log(`core session ${JSON.stringify(session)}: ${line}`);
  const notifier = createNotifier({
    directory,
    say,
    memoryPath: (session) => join(directory, "state", "notify", `${session}.json`),
    registrationSession: (session) => session,
    isRegistered: (session) => registeredSessions(directory).some((name) => normalizeSessionName(name) === session),
    TurnModel: TurnState,
    foldItem: foldRecord,
    signatureOf: decisionSignature,
    inspectItem(record) {
      const agent = agentIn(record);
      if (agent === null) return null;
      const attention = ATTENTION_STATUSES.has(agent.status) ? agent.status : null;
      return {
        kind: agent.kind,
        status: agent.status,
        attention,
        wireAttention: attention,
        project: typeof record.cwd === "string" && record.cwd !== "" ? basename(record.cwd) : null,
        title: strippedSidebarTitle(record.title),
      };
    },
    retryTimers,
  });

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
      notifier.noteConnected(session, coreId, inventory);
    }),
    inventoryReplaced: guarded(({ session, inventory }) => {
      notifier.foldSnapshot(session, notifier.sessionNamed(session), inventory, { settled: false, armUnchanged: true });
    }),
    event: guarded(({ session, event, inventory }) => {
      const memory = notifier.sessionNamed(session);
      memory.inventory = inventory;
      if (event.type === "removed") {
        const terminal = memory.terminals.get(event.terminal);
        clearTimeout(terminal?.timer);
        if (terminal !== undefined) notifier.clearRetry(terminal);
        memory.terminals.delete(event.terminal);
        notifier.remember(session, memory);
        return;
      }
      if (!AGENT_EVENTS.has(event.type)) return;
      const record = inventory.get(event.terminal);
      if (record === undefined) return;
      let terminal = memory.terminals.get(event.terminal);
      if (terminal === undefined) {
        terminal = new Terminal(TurnState);
        memory.terminals.set(event.terminal, terminal);
      }
      foldEvent(terminal.turns, event, record);
      notifier.remember(session, memory);
      const signature = decisionSignature(record, terminal.turns);
      const isWaitingForThis = terminal.timer !== null && signature === terminal.signature;
      terminal.signature = signature;
      if (!isWaitingForThis) notifier.decideLater(session, memory, event.terminal);
    }),
    ended: guarded(({ session }) => {
      notifier.noteEnded(session);
    }),
  };
}

/** A listener for `followTmuxServer`, keeping records under `tmux/<socket>/notify.json`. */
export function tmuxNotificationListener({ directory, log = () => {}, retryTimers = realRetryTimers }) {
  const say = (socket, line) => log(`tmux socket ${JSON.stringify(socket)}: ${line}`);
  const notifier = createNotifier({
    directory,
    say,
    memoryPath: (socket) => join(directory, "tmux", socket, "notify.json"),
    registrationSession: (socket) => `tmux/${socket}`,
    isRegistered: (socket) =>
      registeredSessions(directory).some(
        (name) => name.startsWith("tmux/") && normalizeTmuxSocketName(name.slice("tmux/".length)) === socket,
      ),
    TurnModel: TmuxTurnState,
    foldItem: foldTmuxPane,
    signatureOf: tmuxDecisionSignature,
    inspectItem(pane, turns) {
      if (!pane.agentKind || pane.isDead) return null;
      const status = turns.agentStatus;
      const attention =
        status === "blocked" ? `blocked:${turns.blockedCount}` : status === "error" ? "error" : null;
      return {
        kind: pane.agentKind,
        status,
        attention,
        wireAttention: status,
        project:
          typeof pane.sessionName === "string" && pane.sessionName !== ""
            ? pane.sessionName
            : typeof pane.path === "string" && pane.path !== ""
              ? basename(pane.path)
              : null,
        title: tmuxKindLabel(pane.agentKind),
      };
    },
    retryTimers,
  });

  const guarded = (body) => (report) => {
    const socket = normalizeTmuxSocketName(report.socket);
    if (socket === null) return;
    try {
      body({ ...report, socket });
    } catch (error) {
      say(socket, `could not follow for notifications: ${error.message}`);
    }
  };

  return {
    serverStarted: guarded(({ socket, instance, panes }) => {
      notifier.noteConnected(socket, instance, tmuxPaneInventory(panes));
    }),
    panesUpdated: guarded(({ socket, instance, panes }) => {
      const memory = notifier.sessionNamed(socket);
      if (memory.core !== instance) {
        notifier.noteConnected(socket, instance, tmuxPaneInventory(panes));
        return;
      }
      notifier.foldSnapshot(socket, memory, tmuxPaneInventory(panes), { settled: false, armUnchanged: false });
    }),
    serverEnded: guarded(({ socket }) => {
      notifier.noteEnded(socket);
    }),
    followerStopped: guarded(({ socket }) => {
      notifier.noteEnded(socket);
    }),
  };
}
