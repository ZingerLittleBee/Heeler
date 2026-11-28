import { execFile } from "node:child_process";
import { readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Where Chat looks for the session (ADR 0034). The value is a JSON object. */
const SESSION_LABEL = "heeler.session";
const TMUX_SESSION_OPTION = "@heeler-session";
const REX_SESSION_FOLDER = "heeler-session";
const REX_SWEEP_LIMIT = 256;
const SOCKET_TIMEOUT_MS = 500;
const PS_TIMEOUT_MS = 1000;
const TMUX_TIMEOUT_MS = 2000;
/** OpenCode says nothing when its route changes (herdr compatibility). */
const ROUTE_POLL_MS = 250;

/** The start time in a Linux `/proc/<pid>/stat`, in clock ticks since boot. */
function startTimeFromStat(stat) {
  // The command name may hold spaces and parentheses; the last ")" ends it.
  const start = stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19];
  return /^\d+$/.test(start ?? "") ? start : null;
}

function outputOf(start) {
  return new Promise((done, fail) => {
    start((error, stdout) => (error ? fail(error) : done(stdout))).unref();
  });
}

/** What the app's process reader reads for this process, or null. */
async function processStart(pid) {
  try {
    if (process.platform === "linux") return startTimeFromStat(await readFile(`/proc/${pid}/stat`, "utf8"));
    if (process.platform === "win32") return null;
    const output = await outputOf((finish) =>
      execFile(
        "/bin/ps",
        ["-o", "lstart=", "-p", String(pid)],
        { timeout: PS_TIMEOUT_MS, env: { LC_ALL: "C", TZ: "UTC" } },
        finish,
      ),
    );
    return output.trim() || null;
  } catch {
    return null;
  }
}

let ownStart = null;

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
    ownStart ??= await processStart(process.pid);
    const value = { session, pid: process.pid, ...(ownStart ? { start: ownStart } : {}) };
    const request = {
      jsonrpc: "2.0",
      id: 1,
      method: "terminal.label",
      params: { terminal, labels: { [SESSION_LABEL]: JSON.stringify(value) } },
    };
    await sendLine(socket, `${JSON.stringify(request)}\n`);
  }).catch(() => {});
}

function tmuxPane(env) {
  const pane = env.TMUX_PANE ?? "";
  const parts = (env.TMUX ?? "").split(",");
  if (!/^%\d+$/.test(pane) || parts.length < 3) return null;
  const socket = parts.slice(0, -2).join(",");
  const serverPid = parts.at(-2);
  if (!isAbsolute(socket) || !/^\d+$/.test(serverPid)) return null;
  const tmux = resolveTmux(env, socket);
  return tmux ? { tmux, socket, serverPid, pane } : null;
}

function resolveTmux(env, socket) {
  const home = env.HOME || homedir();
  const data =
    process.platform === "darwin"
      ? join(home, "Library", "Application Support")
      : isAbsolute(env.XDG_DATA_HOME ?? "")
        ? env.XDG_DATA_HOME
        : join(home, ".local", "share");
  const file = join(data, "heeler", "host-helper", "tmux", basename(socket), "paths.json");
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch (error) {
    return error?.code === "ENOENT" ? "tmux" : null;
  }
  try {
    const { executable, socket: stored } = JSON.parse(raw);
    if (typeof executable !== "string" || !isAbsolute(executable) || typeof stored !== "string") return null;
    return realpathSync(stored) === realpathSync(socket) ? executable : null;
  } catch {
    return null;
  }
}

function runTmux(target, args) {
  return outputOf((finish) =>
    execFile(target.tmux, ["-N", "-S", target.socket, ...args], { timeout: TMUX_TIMEOUT_MS }, finish),
  );
}

async function ownTerminal() {
  if (process.platform === "linux") {
    const stat = readFileSync("/proc/self/stat", "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return { group: fields[2], foreground: fields[5], device: Number(fields[4]) };
  }
  const output = await outputOf((finish) =>
    execFile(
      "/bin/ps",
      ["-o", "pgid=,tpgid=,tty=", "-p", String(process.pid)],
      { timeout: PS_TIMEOUT_MS, env: { LC_ALL: "C" } },
      finish,
    ),
  );
  const [group, foreground, tty] = output.trim().split(/\s+/);
  return tty && tty !== "??" ? { group, foreground, tty: `/dev/${tty}` } : null;
}

async function leadsThePane(paneTty) {
  const own = await ownTerminal();
  const pid = String(process.pid);
  if (!own || own.group !== pid || own.foreground !== pid) return false;
  return own.tty ? own.tty === paneTty : statSync(paneTty).rdev === own.device;
}

let tmuxWrites = Promise.resolve();

export function tmuxWritesSettled() {
  return tmuxWrites;
}

function sendTmuxSession(target, session, notWritten) {
  tmuxWrites = tmuxWrites.then(async () => {
    try {
      const read = await runTmux(target, ["display-message", "-p", "-t", target.pane, "#{pid}\t#{pane_tty}"]);
      const [serverPid, paneTty = ""] = read.replace(/\n$/, "").split("\t");
      if (serverPid !== target.serverPid || !paneTty || !(await leadsThePane(paneTty))) return notWritten();
      ownStart ??= await processStart(process.pid);
      if (!ownStart) return notWritten();
      const value = { session, pid: process.pid, start: ownStart };
      await runTmux(target, ["set-option", "-p", "-t", target.pane, TMUX_SESSION_OPTION, JSON.stringify(value)]);
    } catch {
      notWritten();
    }
  });
}

export function rexSessionFile(env, extension = import.meta.url) {
  if (!env.REX_BLOCK || env.TMUX) return null;
  try {
    const folder = dirname(fileURLToPath(extension));
    return basename(folder) === "heeler-opencode"
      ? join(dirname(folder), REX_SESSION_FOLDER, `${process.pid}.json`)
      : null;
  } catch {
    return null;
  }
}

let rexWrites = Promise.resolve();

export function rexWritesSettled() {
  return rexWrites;
}

function hasGone(pid) {
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    return error.code === "ESRCH";
  }
}

async function sweepRexSessions(folder) {
  for (const name of (await readdir(folder)).slice(0, REX_SWEEP_LIMIT)) {
    const pid = Number(/^(\d+)\.json(?:\.tmp)?$/.exec(name)?.[1]);
    if (pid && pid !== process.pid && hasGone(pid)) await rm(join(folder, name), { force: true });
  }
}

const REX_EXIT_REMOVAL = Symbol.for("heeler.opencode.rex.exit-removal");

function removeRexFiles(path) {
  for (const left of [path, `${path}.tmp`]) {
    try {
      rmSync(left, { force: true });
    } catch {
    }
  }
}

function removeAtExit(path) {
  if (process[REX_EXIT_REMOVAL]) return;
  process[REX_EXIT_REMOVAL] = true;
  process.once("exit", () => removeRexFiles(path));
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
  let report;
  let onStop;
  if (terminal) {
    const socket = process.env.HC_TERMINAL_SOCKET;
    if (!socket) return undefined;
    report = (session) => sendSessionLabel(socket, terminal, session);
  } else {
    const pane = tmuxPane(process.env);
    if (pane) {
      report = (session, notWritten) => sendTmuxSession(pane, session, notWritten);
    } else {
      const path = rexSessionFile(process.env);
      if (!path) return undefined;
      const folder = dirname(path);
      let swept = false;
      let stopped = false;
      removeAtExit(path);
      report = (session, notWritten) => {
        rexWrites = rexWrites
          .then(async () => {
            if (stopped) return;
            ownStart ??= await processStart(process.pid);
            if (!ownStart || stopped) return notWritten();
            await mkdir(folder, { recursive: true, mode: 0o700 });
            if (!swept) {
              swept = true;
              await sweepRexSessions(folder).catch(() => {});
            }
            const value = { session, pid: process.pid, start: ownStart };
            await writeFile(`${path}.tmp`, JSON.stringify(value), { mode: 0o600 });
            if (stopped) return rm(`${path}.tmp`, { force: true });
            await rename(`${path}.tmp`, path);
          })
          .catch(notWritten);
      };
      onStop = () => {
        stopped = true;
        removeRexFiles(path);
      };
    }
  }

  let reported;
  const look = () => {
    try {
      const session = currentSession();
      if (session === undefined || session === reported) return;
      reported = session;
      report(session, () => {
        if (reported === session) reported = undefined;
      });
    } catch {
      // Nothing here is worth disturbing the program for.
    }
  };
  const poll = setInterval(look, ROUTE_POLL_MS);
  poll.unref?.();
  look();
  return () => {
    clearInterval(poll);
    onStop?.();
  };
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
