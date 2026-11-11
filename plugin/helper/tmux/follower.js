// Follows the tmux servers whose paths the app stored under `tmux/<socket>/`
// (ADRs 0042, 0043 and 0044). Every command passes `-N` and `-S`, so a stopped
// server stays stopped; a server that starts or restarts gets a fresh instance.

import { setTimeout as delay } from "node:timers/promises";

import { agentIn } from "../core/agent-rule.js";
import { runStoredTmux } from "./client.js";
import { createForegroundReader } from "./foreground.js";
import { storedTmuxServers } from "./socket-name.js";

export const TMUX_POLL_INTERVAL_MS = 5000;
const RECONCILE_MS = 3000;

const FIXED_FIELDS = [
  "#{pid}",
  "#{start_time}",
  "#{session_id}",
  "#{window_id}",
  "#{window_index}",
  "#{pane_id}",
  "#{pane_pid}",
  "#{pane_dead}",
  "#{pane_pipe}",
];

const TEXT_FIELDS = [
  "session_name",
  "window_name",
  "pane_current_command",
  "pane_current_path",
  "pane_tty",
  "@heeler-status",
  "@heeler-session",
  "@heeler-pipe",
  "@heeler-attach",
];

const LIST_PANES_FORMAT =
  `${[...FIXED_FIELDS, ...TEXT_FIELDS.map((name) => `#{n:${name}}`)].join("\t")}\n` +
  `${TEXT_FIELDS.map((name) => `#{${name}}`).join("")}.`;

/** Combines several tmux follower listeners in order. */
export function combineTmuxListeners(...listeners) {
  const tell = (name) => async (report) => {
    for (const listener of listeners) await listener[name]?.(report);
  };
  return {
    serverStarted: tell("serverStarted"),
    serverEnded: tell("serverEnded"),
    panesUpdated: tell("panesUpdated"),
    followerStopped: tell("followerStopped"),
  };
}

function parseListedPanes(buffer) {
  const panes = [];
  let instance = null;
  let serverPid = null;
  let startTime = null;
  let offset = 0;

  while (offset < buffer.length) {
    const newline = buffer.indexOf(0x0a, offset);
    if (newline < 0) break;
    const header = buffer.subarray(offset, newline).toString("utf8");
    offset = newline + 1;
    const columns = header.split("\t");
    if (columns.length !== FIXED_FIELDS.length + TEXT_FIELDS.length) continue;

    const [pidText, startText, sessionID, windowID, windowIndexText, paneID, panePidText, deadText, pipeText] = columns;
    if (
      !/^\d+$/.test(pidText) ||
      !/^\d+$/.test(startText) ||
      !/^\$\d+$/.test(sessionID) ||
      !/^@\d+$/.test(windowID) ||
      !/^\d+$/.test(windowIndexText) ||
      !/^%\d+$/.test(paneID) ||
      !/^\d+$/.test(panePidText) ||
      !/^\d+$/.test(deadText) ||
      !/^\d+$/.test(pipeText)
    ) {
      continue;
    }

    const lengths = columns.slice(FIXED_FIELDS.length).map((value) => (/^\d+$/.test(value) ? Number(value) : -1));
    if (lengths.some((length) => length < 0)) continue;
    const totalBytes = lengths.reduce((sum, length) => sum + length, 0);
    if (offset + totalBytes + 2 > buffer.length) break;
    if (buffer[offset + totalBytes] !== 0x2e || buffer[offset + totalBytes + 1] !== 0x0a) continue;

    const texts = [];
    let cursor = offset;
    for (const length of lengths) {
      texts.push(buffer.subarray(cursor, cursor + length).toString("utf8"));
      cursor += length;
    }
    offset += totalBytes + 2;

    const rowInstance = `tmux-${pidText}-${startText}`;
    if (instance === null) {
      instance = rowInstance;
      serverPid = Number(pidText);
      startTime = Number(startText);
    } else if (instance !== rowInstance) {
      continue;
    }

    panes.push({
      sessionID,
      sessionName: texts[0],
      windowID,
      windowIndex: Number(windowIndexText),
      windowName: texts[1],
      paneID,
      panePid: Number(panePidText),
      isDead: deadText !== "0",
      hasPipe: pipeText !== "0",
      command: texts[2],
      path: texts[3],
      tty: texts[4],
      status: texts[5],
      agentSession: texts[6],
      pipeMark: texts[7],
      attachMark: texts[8],
    });
  }

  return { instance, serverPid, startTime, panes };
}

function sessionNumber(sessionID) {
  const value = Number(sessionID.slice(1));
  return Number.isSafeInteger(value) ? value : Number.MAX_SAFE_INTEGER;
}

/**
 * The user's Panes, matching `TmuxOrganization.shownPanes`: omits Heeler's own
 * `@heeler-attach` sessions and keeps each linked window once under its lowest
 * session id.
 */
export function shownTmuxPanes(listed) {
  const users = listed.filter((pane) => pane.attachMark === "");
  const owners = new Map();
  for (const pane of users) {
    const number = sessionNumber(pane.sessionID);
    const current = owners.get(pane.windowID);
    if (current && current.number <= number) continue;
    owners.set(pane.windowID, { number, sessionID: pane.sessionID });
  }
  const seen = new Set();
  const windowIndexes = new Map();
  return users.filter((pane) => {
    if (owners.get(pane.windowID)?.sessionID !== pane.sessionID) return false;
    const firstIndex = windowIndexes.get(pane.windowID) ?? pane.windowIndex;
    if (firstIndex !== pane.windowIndex) return false;
    windowIndexes.set(pane.windowID, pane.windowIndex);
    if (seen.has(pane.paneID)) return false;
    seen.add(pane.paneID);
    return true;
  });
}

function knownAgentKind(pane) {
  if (pane.isDead) return null;
  const pid = pane.foregroundPid ?? pane.panePid;
  const agent = agentIn({
    state: "live",
    pid,
    foreground: {
      pid,
      name: pane.command,
      argv: pane.foregroundArguments ?? [],
    },
  });
  return agent?.known ? agent.kind : null;
}

/**
 * Follows one tmux server on `paths` (`{ executable, socket }`) until `stop()`.
 */
export function followTmuxServer(
  socket,
  paths,
  {
    listener = {},
    log = () => {},
    pollIntervalMs = TMUX_POLL_INTERVAL_MS,
  } = {},
) {
  const stopping = new AbortController();
  const { signal } = stopping;
  const target = { tmux: paths.executable, socket: paths.socket };
  const foregrounds = createForegroundReader();

  let currentInstance = null;
  let said = null;
  const say = (line) => {
    if (line === said) return;
    said = line;
    log(`tmux socket ${JSON.stringify(socket)}: ${line}`);
  };

  const noteEnded = async () => {
    if (currentInstance === null) return;
    const endedInstance = currentInstance;
    currentInstance = null;
    foregrounds.reset();
    await listener.serverEnded?.({ socket, instance: endedInstance, paths });
  };

  const sample = async () => {
    const listed = await runStoredTmux(target, ["list-panes", "-a", "-F", LIST_PANES_FORMAT], {
      signal,
      buffer: true,
    });
    if (signal.aborted) return;
    if (!listed.ok) {
      await noteEnded();
      say(`waiting for a tmux server at ${paths.socket}`);
      return;
    }

    let { instance, serverPid, startTime, panes } = parseListedPanes(listed.stdout);
    if (instance === null) {
      const serverCheck = await runStoredTmux(target, ["display-message", "-p", "#{pid}\t#{start_time}"], { signal });
      if (signal.aborted) return;
      if (!serverCheck.ok) {
        await noteEnded();
        say(`waiting for a tmux server at ${paths.socket}`);
        return;
      }
      const [pidText, startText] = serverCheck.stdout.trim().split("\t");
      if (!/^\d+$/.test(pidText ?? "") || !/^\d+$/.test(startText ?? "")) return;
      serverPid = Number(pidText);
      startTime = Number(startText);
      instance = `tmux-${pidText}-${startText}`;
      panes = [];
    }

    const shown = shownTmuxPanes(panes);
    if (currentInstance !== instance) {
      await noteEnded();
      currentInstance = instance;
      say(`connected to tmux server pid ${serverPid}`);
    }

    const leaders = await foregrounds.readForPanes(shown, { signal });
    if (signal.aborted) return;
    const enriched = shown.map((pane) => {
      const leader = leaders.get(pane.paneID);
      const withForeground = {
        ...pane,
        foregroundPid: leader?.foregroundPid ?? pane.panePid,
        foregroundArguments: leader?.foregroundArguments ?? null,
      };
      return {
        ...withForeground,
        agentKind: knownAgentKind(withForeground),
      };
    });

    return { instance, serverPid, startTime, panes: enriched };
  };

  let startedInstance = null;
  const run = async () => {
    while (!signal.aborted) {
      const snapshot = await sample();
      if (!signal.aborted && snapshot) {
        if (startedInstance !== snapshot.instance) {
          startedInstance = snapshot.instance;
          await listener.serverStarted?.({ socket, paths, ...snapshot });
        }
        await listener.panesUpdated?.({ socket, paths, ...snapshot });
      }
      if (currentInstance === null) startedInstance = null;
      await delay(pollIntervalMs, undefined, { signal }).catch(() => {});
    }
    await listener.followerStopped?.({ socket, instance: currentInstance, paths });
  };
  const done = run();

  return {
    stop() {
      stopping.abort();
      return done;
    },
  };
}

/**
 * Follows every stored server under `directory/tmux/<socket>/paths.json`,
 * picking up newly installed or updated paths and stopping removed ones.
 */
export function followStoredTmuxServers({
  directory,
  log = () => {},
  pollMs = RECONCILE_MS,
  ...followOptions
}) {
  const followers = new Map();
  const leaving = new Set();

  const stopEntry = (socket, entry) => {
    followers.delete(socket);
    const stopped = entry.follower.stop().finally(() => leaving.delete(stopped));
    leaving.add(stopped);
  };

  const reconcile = () => {
    const wanted = storedTmuxServers(directory);
    for (const [socket, entry] of followers) {
      const nextPaths = wanted.get(socket);
      if (
        nextPaths &&
        nextPaths.executable === entry.paths.executable &&
        nextPaths.socket === entry.paths.socket
      ) {
        continue;
      }
      stopEntry(socket, entry);
    }
    for (const [socket, paths] of wanted) {
      if (!followers.has(socket)) {
        followers.set(socket, {
          paths,
          follower: followTmuxServer(socket, paths, { log, ...followOptions }),
        });
      }
    }
  };

  reconcile();
  const poll = setInterval(reconcile, pollMs);

  return {
    async stop() {
      clearInterval(poll);
      await Promise.all([...followers.values()].map((entry) => entry.follower.stop()));
      await Promise.all(leaving);
      followers.clear();
    },
  };
}
