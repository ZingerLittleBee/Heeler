import { setTimeout as delay } from "node:timers/promises";

import { connectRex } from "./client.js";
import { resolveRexSocket, wantsRexFollower } from "./socket.js";

const RETRY_DELAY_MS = 3000;
const POLL_MS = 3000;
const NO_SERVER_CODES = new Set(["ENOENT", "ENOTDIR", "ECONNREFUSED", "ENOTSOCK"]);

export function combineRexListeners(...listeners) {
  const tell = (name) => (report) => {
    for (const listener of listeners) listener[name]?.(report);
  };
  return {
    connected: tell("connected"),
    updated: tell("updated"),
    ended: tell("ended"),
  };
}

export function followRexSocket(
  socketPath,
  {
    listener = {},
    log = () => {},
    retryDelayMs = RETRY_DELAY_MS,
    handshakeTimeoutMs,
    requestTimeoutMs,
  } = {},
) {
  const stopping = new AbortController();
  const { signal } = stopping;

  let said = null;
  const say = (line) => {
    if (line === said) return;
    said = line;
    log(`rex: ${line}`);
  };

  const attempt = async () => {
    let connection;
    try {
      connection = await connectRex(socketPath, {
        signal,
        handshakeTimeoutMs,
        requestTimeoutMs,
        listener: {
          connected: (report) => listener.connected?.({ socketPath, ...report }),
          updated: (report) => listener.updated?.({ socketPath, ...report }),
        },
      });
    } catch (error) {
      if (signal.aborted) return;
      say(NO_SERVER_CODES.has(error.code) ? `waiting for Rex at ${socketPath}` : `cannot use Rex at ${socketPath}: ${error.message}`);
      return;
    }
    say(`connected to Rex instance ${connection.instanceId}`);
    const reason = await connection.closed;
    say(`connection to Rex instance ${connection.instanceId} ended: ${reason.message}`);
    listener.ended?.({ socketPath, instanceId: connection.instanceId, reason });
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

export function followRexServer({
  directory,
  log = () => {},
  pollMs = POLL_MS,
  ...followOptions
}) {
  let active = null;
  const leaving = new Set();

  const stopActive = () => {
    if (active === null) return;
    const current = active;
    active = null;
    const stopped = current.follower.stop().finally(() => leaving.delete(stopped));
    leaving.add(stopped);
  };

  const reconcile = () => {
    if (!wantsRexFollower(directory)) {
      stopActive();
      return;
    }
    const socketPath = resolveRexSocket(directory);
    if (socketPath === null) {
      stopActive();
      return;
    }
    if (active !== null && active.socketPath === socketPath) return;
    stopActive();
    active = {
      socketPath,
      follower: followRexSocket(socketPath, { log, ...followOptions }),
    };
  };

  reconcile();
  const poll = setInterval(reconcile, pollMs);

  return {
    async stop() {
      clearInterval(poll);
      stopActive();
      await Promise.all(leaving);
    },
  };
}
