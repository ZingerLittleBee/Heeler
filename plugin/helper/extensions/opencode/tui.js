// Heeler's OpenCode plugin (ADR 0033). The OpenCode edit copies this folder under
// OpenCode's config directory and lists it in OpenCode's plugin list, so it loads
// in every OpenCode on the Host and outside a herdr-core Terminal does nothing at
// all. Inside one it names the conversation on screen for Chat (ADR 0034). It
// imports only built-ins, since it runs from that folder.

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { connect } from "node:net";

/** Where Chat looks for the session (ADR 0034). The value is a JSON object. */
const SESSION_LABEL = "heeler.session";
const SOCKET_TIMEOUT_MS = 500;
const PS_TIMEOUT_MS = 1000;
/** OpenCode says nothing when its route changes (herdr compatibility). */
const ROUTE_POLL_MS = 250;

/** The start time in a Linux `/proc/<pid>/stat`, in clock ticks since boot. */
function startTimeFromStat(stat) {
  // The command name may hold spaces and parentheses; the last ")" ends it.
  const start = stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19];
  return /^\d+$/.test(start ?? "") ? start : null;
}

/** What the app's process reader reads for this process, or null. */
async function processStart(pid) {
  try {
    if (process.platform === "linux") return startTimeFromStat(await readFile(`/proc/${pid}/stat`, "utf8"));
    if (process.platform === "win32") return null;
    const output = await new Promise((done, fail) => {
      const child = execFile(
        "/bin/ps",
        ["-o", "lstart=", "-p", String(pid)],
        { timeout: PS_TIMEOUT_MS, env: { LC_ALL: "C" } },
        (error, stdout) => (error ? fail(error) : done(stdout)),
      );
      child.unref();
    });
    return output.trim() || null;
  } catch {
    return null;
  }
}

/** Sends one line and gives up at the timeout. Never rejects, and never holds the process open. */
function sendLine(path, line) {
  return new Promise((done) => {
    const socket = connect(path);
    const finish = () => {
      clearTimeout(timer);
      socket.destroy();
      done();
    };
    const timer = setTimeout(finish, SOCKET_TIMEOUT_MS);
    timer.unref();
    socket.unref();
    socket.on("connect", () => socket.write(line));
    socket.on("data", (chunk) => {
      if (chunk.includes(0x0a)) finish();
    });
    socket.on("error", finish);
    socket.on("close", finish);
  });
}

// One after another, so a slow answer cannot let an older session land last.
let labels = Promise.resolve();

function sendSessionLabel(socket, terminal, session) {
  labels = labels.then(async () => {
    const start = await processStart(process.pid);
    const value = { session, pid: process.pid, ...(start ? { start } : {}) };
    const request = {
      jsonrpc: "2.0",
      id: 1,
      method: "terminal.label",
      params: { terminal, labels: { [SESSION_LABEL]: JSON.stringify(value) } },
    };
    await sendLine(socket, `${JSON.stringify(request)}\n`);
  }).catch(() => {});
}

/**
 * The conversation a session belongs to, or undefined until OpenCode knows it: a
 * subagent's view stays its root's, as OpenCode's own records do (herdr compatibility).
 */
function rootOf(session, lookup) {
  const seen = new Set();
  let id = session;
  while (typeof id === "string" && !seen.has(id)) {
    seen.add(id);
    const known = lookup(id);
    if (!known) return undefined;
    if (!known.parentID) return id;
    id = known.parentID;
  }
  return undefined;
}

/**
 * Reports each new session on the screen. A screen with none, as after `/new`,
 * says nothing: the conversation stays until a prompt makes the next one.
 */
function followScreen(currentSession) {
  const terminal = process.env.HC_TERMINAL_ID;
  const socket = process.env.HC_TERMINAL_SOCKET;
  if (!terminal || !socket) return undefined;

  let reported;
  const look = () => {
    try {
      const session = currentSession();
      if (session === undefined || session === reported) return;
      reported = session;
      // Not awaited: a socket must never hold OpenCode's screen up.
      sendSessionLabel(socket, terminal, session);
    } catch {
      // Nothing here is worth disturbing the program for.
    }
  };
  const poll = setInterval(look, ROUTE_POLL_MS);
  poll.unref?.();
  look();
  return () => clearInterval(poll);
}

/** OpenCode 2.x's entry. */
function setup(api) {
  return followScreen(() => {
    const route = api.ui.router.current();
    return route?.type === "session" ? rootOf(route.sessionID, (id) => api.data.session.get(id)) : undefined;
  });
}

/** OpenCode 1.x's entry. */
function tui(api) {
  const stop = followScreen(() => {
    const route = api.route.current;
    return route?.name === "session" ? rootOf(route.params?.sessionID, (id) => api.state.session.get(id)) : undefined;
  });
  if (stop) api.lifecycle.onDispose(stop);
}

// A plain object: each release's loader reads its own entry, and neither package
// resolves from this folder.
export default { id: "heeler.opencode.session", setup, tui };
