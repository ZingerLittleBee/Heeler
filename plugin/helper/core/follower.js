// Follows the core of each session the Notification Registrations name. While
// no core runs it waits and tries again, so a core the user stopped stays
// stopped until the user starts it (ADR 0033).

import { setTimeout as delay } from "node:timers/promises";

import { registeredSessions } from "../shared/delivery/registrations.js";
import { connectCore } from "./client.js";
import { normalizeSessionName } from "./session-name.js";
import { locateCoreSocket } from "./socket.js";

// Connecting to a socket file that is absent or has nothing behind it costs next to nothing.
const RETRY_DELAY_MS = 3000;
const POLL_MS = 3000;
// What a session with no running core reads as: no socket yet, or one a killed core left.
const NO_CORE_CODES = new Set(["ENOENT", "ENOTDIR", "ECONNREFUSED", "ENOTSOCK"]);

/**
 * Follows one normalized session until `stop()`. `listener` hears, each with
 * `session`: `connected({coreId, pid, socketPath, inventory})`, `ended({pid, reason})`,
 * `inventoryReplaced({inventory})` and `event({event, inventory})`.
 */
export function followCoreSession(
  session,
  {
    env,
    runUserDirectory,
    listener = {},
    log = () => {},
    retryDelayMs = RETRY_DELAY_MS,
    handshakeTimeoutMs,
    idleTimeoutMs,
  } = {},
) {
  const stopping = new AbortController();
  const { signal } = stopping;

  let said = null;
  const say = (line) => {
    if (line === said) return;
    said = line;
    log(`core session ${JSON.stringify(session)}: ${line}`);
  };

  const attempt = async () => {
    const { path } = locateCoreSocket(session, { env, runUserDirectory });
    let connection;
    try {
      connection = await connectCore(path, {
        signal,
        handshakeTimeoutMs,
        idleTimeoutMs,
        listener: {
          connected: (report) => listener.connected?.({ session, socketPath: path, ...report }),
          inventoryReplaced: (report) => listener.inventoryReplaced?.({ session, ...report }),
          event: (report) => listener.event?.({ session, ...report }),
        },
      });
    } catch (error) {
      if (signal.aborted) return;
      say(NO_CORE_CODES.has(error.code) ? `waiting for a core at ${path}` : `cannot use the core at ${path}: ${error.message}`);
      return;
    }
    say(`connected to core pid ${connection.pid}`);
    const reason = await connection.closed;
    say(`connection to core pid ${connection.pid} ended: ${reason.message}`);
    listener.ended?.({ session, pid: connection.pid, reason });
  };

  const run = async () => {
    while (!signal.aborted) {
      await attempt();
      await delay(retryDelayMs, undefined, { signal }).catch(() => {});
    }
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
 * Keeps one follower per session named in `directory`'s Notification
 * Registrations or by `alsoFollow()`, reading them again so a device registering
 * or leaving takes effect without a restart. Runs until `stop()`.
 */
export function followRegisteredSessions({ directory, log = () => {}, pollMs = POLL_MS, alsoFollow = () => [], ...followOptions }) {
  const followers = new Map();
  const leaving = new Set();
  const refused = new Set();

  const wantedSessions = () => {
    const wanted = new Set();
    for (const raw of [...registeredSessions(directory), ...alsoFollow()]) {
      const session = normalizeSessionName(raw);
      if (session !== null) {
        wanted.add(session);
      } else if (!refused.has(raw)) {
        refused.add(raw);
        log(`core session ${JSON.stringify(raw)}: the core refuses this name, so nothing follows it`);
      }
    }
    return wanted;
  };

  const reconcile = () => {
    const wanted = wantedSessions();
    for (const [session, follower] of followers) {
      if (wanted.has(session)) continue;
      followers.delete(session);
      const stopped = follower.stop().finally(() => leaving.delete(stopped));
      leaving.add(stopped);
    }
    for (const session of wanted) {
      if (!followers.has(session)) followers.set(session, followCoreSession(session, { log, ...followOptions }));
    }
  };

  reconcile();
  const poll = setInterval(reconcile, pollMs);

  return {
    async stop() {
      clearInterval(poll);
      await Promise.all([...followers.values()].map((follower) => follower.stop()));
      await Promise.all(leaving);
      followers.clear();
    },
  };
}
