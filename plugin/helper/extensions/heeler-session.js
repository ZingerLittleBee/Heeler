// Heeler's extension for Pi and Oh My Pi (ADR 0033). The Host Helper copies this
// one file into each program's extension folder, or on native Windows the app
// writes it there, and those programs load every session on the Host through it,
// so outside a herdr-core Terminal or a tmux Pane it does nothing at all
// (ADR 0044). It imports only Node built-ins, since it runs from that folder.

import { execFile } from "node:child_process";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { connect } from "node:net";
import { homedir } from "node:os";
import { basename, isAbsolute, join } from "node:path";

/** Where Chat looks for the session (ADR 0034). The value is a JSON object. */
const SESSION_LABEL = "heeler.session";
const SOCKET_TIMEOUT_MS = 500;
const PS_TIMEOUT_MS = 1000;
/** PowerShell's own start takes a few seconds on a slow machine. */
const POWERSHELL_TIMEOUT_MS = 5000;
/** Pi's loader resolves these names to Pi itself, its former name included. Kept apart from `import` so it resolves them at run time. */
const PI_PACKAGES = ["@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent"];
/** The release that reports its own OSC 7501 (herdr compatibility). */
const FIRST_STATUS_RELEASE = { major: 1, minor: 1 };
/** Characters, so at most the 2048 bytes Pi itself sends. */
const STATUS_MESSAGE_LIMIT = 512;
/** Where a tmux Pane keeps its Program Status and the session its program holds (ADR 0044). */
const TMUX_STATUS_OPTION = "@heeler-status";
const TMUX_SESSION_OPTION = "@heeler-session";
const TMUX_TIMEOUT_MS = 2000;
/** Programs known to report done, so their idle ends no turn (tmux-heeler-status-v1.json). */
export const DONE_REPORTERS = new Set(["claude-code", "codex", "pi", "omp", "grok-build"]);

/** The start time in a Linux `/proc/<pid>/stat`, in clock ticks since boot. */
export function startTimeFromStat(stat) {
  // The command name may hold spaces and parentheses; the last ")" ends it.
  const start = stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19];
  return /^\d+$/.test(start ?? "") ? start : null;
}

/** A child's stdout. It never holds the process open. */
function outputOf(start) {
  return new Promise((done, fail) => {
    start((error, stdout) => (error ? fail(error) : done(stdout))).unref();
  });
}

/**
 * The system's own PowerShell, or null where Windows does not say where it is. A
 * bare name is looked for first in the working folder, which is the Agent's project.
 */
function windowsPowerShell() {
  const root = process.env.SystemRoot;
  return root ? `${root}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe` : null;
}

/** What the app's process reader reads for this process, or null. */
async function processStart(pid) {
  try {
    if (process.platform === "linux") return startTimeFromStat(await readFile(`/proc/${pid}/stat`, "utf8"));
    if (process.platform === "win32") {
      const powerShell = windowsPowerShell();
      if (!powerShell) return null;
      // Windows has no file to read it from. The creation FILETIME, which is what
      // the app's read prints too (ADR 0034).
      const output = await outputOf((finish) =>
        execFile(
          powerShell,
          [
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            `(Get-Process -Id ${Number(pid)}).StartTime.ToFileTimeUtc()`,
          ],
          { timeout: POWERSHELL_TIMEOUT_MS, windowsHide: true },
          finish,
        ),
      );
      return /^\d+$/.test(output.trim()) ? output.trim() : null;
    }
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

/**
 * True for the program holding the Terminal. A subagent or a `pi -p` a tool
 * started shares the Terminal's environment but must not rename its session,
 * and outside the terminal interface stdout is not Heeler's to write to.
 */
function holdsTheTerminal(context) {
  return context.hasUI !== false && (context.mode === undefined || context.mode === "tui");
}

// One after another, so a slow answer cannot let an older session land last.
let labels = Promise.resolve();

/** A process's creation time never changes, and on Windows each read starts a PowerShell. */
let ownStart = null;

function sendSessionLabel(socket, terminal, session, file, notSent) {
  labels = labels.then(async () => {
    ownStart ??= await processStart(process.pid);
    // Windows has no other evidence, and Chat drops a label with no start for good.
    if (!ownStart && process.platform === "win32") return notSent();
    const value = { session, ...(file ? { file } : {}), pid: process.pid, ...(ownStart ? { start: ownStart } : {}) };
    const request = {
      jsonrpc: "2.0",
      id: 1,
      method: "terminal.label",
      params: { terminal, labels: { [SESSION_LABEL]: JSON.stringify(value) } },
    };
    await sendLine(socket, `${JSON.stringify(request)}\n`);
  }).catch(() => {});
}

export default async function heelerSession(program) {
  const terminal = process.env.HC_TERMINAL_ID;
  if (!terminal) {
    const pane = tmuxPane(process.env);
    if (pane) await reportToTmux(program, pane);
    return;
  }
  const socket = process.env.HC_TERMINAL_SOCKET;

  let reported;
  const reportSession = (_event, context) => {
    try {
      if (!socket || !holdsTheTerminal(context)) return;
      const session = context.sessionManager.getSessionId();
      const file = context.sessionManager.getSessionFile();
      const current = `${session}\n${file}`;
      if (reported === current) return;
      reported = current;
      // Not returned: the program awaits its handlers, and a socket must never hold it up.
      sendSessionLabel(socket, terminal, session, file, () => {
        if (reported === current) reported = undefined;
      });
    } catch {
      // Nothing here is worth disturbing the program for.
    }
  };

  // Pi replaces the extension and fires session_start again; Oh My Pi keeps it
  // and fires one of the others (herdr compatibility).
  for (const event of ["session_start", "session_switch", "session_branch"]) program.on(event, reportSession);

  if (process.env.PI_PROGRAM_STATUS !== "0" && isBeforeProgramStatus(await piVersion())) {
    reportStatus(program, writeStatus);
  }
}

/**
 * Reports what Pi before 1.1.0 cannot say for itself, the way Pi says it from
 * 1.1.0, through `write(state, message)`. A tmux Pane also hears of a new
 * session, which Oh My Pi starts without a second `session_start`.
 */
function reportStatus(program, write, { sessionChanges = false } = {}) {
  const report = (context, state, message) => {
    if (holdsTheTerminal(context)) write(state, message);
  };
  program.on("session_start", (_event, context) => report(context, "idle"));
  if (sessionChanges) {
    for (const event of ["session_switch", "session_branch"]) {
      program.on(event, (_event, context) => report(context, "idle"));
    }
  }
  program.on("agent_start", (_event, context) => report(context, "working"));
  program.on("agent_end", (event, context) => {
    const last = event.messages?.findLast((message) => message.role === "assistant");
    if (last?.stopReason === "error") report(context, "error", last.errorMessage);
    else report(context, last?.stopReason === "aborted" ? "idle" : "done");
  });
  program.on("session_shutdown", (event, context) => {
    if (event.reason === "quit") report(context, "clear");
  });
}

/** A message as OSC 7501 carries it: its first line, in base64, or null. */
function statusMessage(message) {
  const text = (message ?? "").split(/\r?\n/, 1)[0].replace(/\p{Cc}/gu, " ").trim().slice(0, STATUS_MESSAGE_LIMIT);
  return text ? Buffer.from(text, "utf8").toString("base64") : null;
}

function writeStatus(state, message) {
  const fields = [`state=${state}`, "app=pi"];
  const msg = statusMessage(message);
  if (msg) fields.push(`msg=${msg}`);
  try {
    // One write of the whole sequence, between the renderer's own, as Pi does it.
    process.stdout.write(`\x1b]7501;${fields.join(":")}\x1b\\`);
  } catch {
    // A status nobody can read is no reason to disturb the program.
  }
}

/** Pi's version as Pi itself exports it, or null where no Pi resolves, as under Oh My Pi. */
async function piVersion() {
  for (const name of PI_PACKAGES) {
    try {
      const { VERSION } = await import(name);
      if (typeof VERSION === "string") return VERSION;
    } catch {
      // Try the next name.
    }
  }
  return null;
}

/** Unknown counts as reporting already: silence is the safe side of reporting twice. */
function isBeforeProgramStatus(version) {
  const parts = /^(\d+)\.(\d+)\.\d+/.exec(version ?? "");
  if (!parts) return false;
  const [major, minor] = [Number(parts[1]), Number(parts[2])];
  return major < FIRST_STATUS_RELEASE.major || (major === FIRST_STATUS_RELEASE.major && minor < FIRST_STATUS_RELEASE.minor);
}

// MARK: tmux Panes (ADR 0044)

/** A tmux Pane's `@heeler-status`, read as tmux-heeler-status-v1.json says. */
export function readHeelerStatus(value) {
  const status = { state: null, app: null, kind: null, msg: null, turn: 0, blocked: 0 };
  for (const word of (value ?? "").split(":")) {
    const equals = word.indexOf("=");
    if (equals < 0) continue;
    const key = word.slice(0, equals);
    const text = word.slice(equals + 1);
    if (key === "turn" || key === "blocked") status[key] = /^\d+$/.test(text) ? Number(text) : 0;
    else if (key in status) status[key] = text || null;
  }
  return status;
}

/**
 * What `@heeler-status` holds after `report` (`state`, `app`, optional `kind`
 * and `msg`), continuing the counts of the value the Pane had. A turn ends when
 * done or error follows working or blocked, or idle follows working for a
 * program not known to report done; each entry into blocked is one more
 * question. A report from another program than the last ends nothing of its.
 */
export function continueHeelerStatus(previous, report) {
  const last = readHeelerStatus(previous);
  const counts = (turn, blocked) => `turn=${turn}:blocked=${blocked}`;
  if (report.state === "clear") return counts(last.turn, last.blocked);
  const sameApp = last.state !== null && last.app === report.app;
  const endsTurn =
    sameApp &&
    (((last.state === "working" || last.state === "blocked") && (report.state === "done" || report.state === "error")) ||
      (last.state === "working" && report.state === "idle" && !DONE_REPORTERS.has(report.app)));
  const asks = report.state === "blocked" && !(sameApp && last.state === "blocked");
  const words = [`state=${report.state}`, `app=${report.app}`];
  if (report.kind) words.push(`kind=${report.kind}`);
  if (report.msg) words.push(`msg=${report.msg}`);
  return `${words.join(":")}:${counts(last.turn + (endsTurn ? 1 : 0), last.blocked + (asks ? 1 : 0))}`;
}

/**
 * The Pane this process's environment names, on a server whose tmux the
 * Helper stored, or null. `TMUX` is `<socket>,<server pid>,<session>`.
 */
function tmuxPane(env) {
  const pane = env.TMUX_PANE ?? "";
  const parts = (env.TMUX ?? "").split(",");
  if (!/^%\d+$/.test(pane) || parts.length < 3) return null;
  const socket = parts.slice(0, -2).join(",");
  const serverPid = parts.at(-2);
  if (!isAbsolute(socket) || !/^\d+$/.test(serverPid)) return null;
  const tmux = storedTmux(env, socket);
  return tmux ? { tmux, socket, serverPid, pane } : null;
}

/**
 * The tmux the app stored for the server on `socket`, as it gave it to the
 * Helper: `paths.json` under the Helper's `tmux/<socket name>/`, the
 * executable and socket of `TmuxPaths`. Paths stored for another server, or
 * none, leave the extension inert.
 */
function storedTmux(env, socket) {
  try {
    const home = env.HOME || homedir();
    const data =
      process.platform === "darwin"
        ? join(home, "Library", "Application Support")
        : isAbsolute(env.XDG_DATA_HOME ?? "")
          ? env.XDG_DATA_HOME
          : join(home, ".local", "share");
    const file = join(data, "heeler", "host-helper", "tmux", basename(socket), "paths.json");
    const { executable, socket: stored } = JSON.parse(readFileSync(file, "utf8"));
    if (typeof executable !== "string" || !isAbsolute(executable) || typeof stored !== "string") return null;
    return realpathSync(stored) === realpathSync(socket) ? executable : null;
  } catch {
    return null;
  }
}

/** One tmux command's stdout, through the server named in `TMUX`, which it never starts. */
function runTmux(target, args) {
  return outputOf((finish) =>
    execFile(target.tmux, ["-N", "-S", target.socket, ...args], { timeout: TMUX_TIMEOUT_MS }, finish),
  );
}

/** This process's process group, its terminal's foreground group, and that terminal, or null. */
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

/** Whether `paneTty` is this process's terminal and this process leads its foreground group. */
async function leadsThePane(paneTty) {
  const own = await ownTerminal();
  const pid = String(process.pid);
  if (!own || own.group !== pid || own.foreground !== pid) return false;
  return own.tty ? own.tty === paneTty : statSync(paneTty).rdev === own.device;
}

// One after another, so a later report never lands before an earlier one.
let tmuxWrites = Promise.resolve();

/** Settles once every write asked for so far has finished. */
export function tmuxWritesSettled() {
  return tmuxWrites;
}

/**
 * Sets the Pane's options from what `change(status)` makes of its current
 * `@heeler-status`, only while this process leads the foreground of the
 * Pane's own terminal on the server named in `TMUX`: a `pi -p` a tool
 * started, or a Pi in a terminal of its own inside the Pane, writes nothing,
 * and hears so through `notWritten`.
 */
function writeToPane(target, change, notWritten = () => {}) {
  tmuxWrites = tmuxWrites.then(async () => {
    try {
      const read = await runTmux(target, [
        "display-message", "-p", "-t", target.pane, `#{pid}\t#{pane_tty}\t#{${TMUX_STATUS_OPTION}}`,
      ]);
      const [serverPid, paneTty, status = ""] = read.replace(/\n$/, "").split("\t");
      if (serverPid !== target.serverPid || !(await leadsThePane(paneTty))) return notWritten();
      const options = await change(status);
      if (options.length === 0) return;
      const commands = options.flatMap(([name, value], index) => [
        ...(index > 0 ? [";"] : []), "set-option", "-p", "-t", target.pane, name, value,
      ]);
      await runTmux(target, commands);
    } catch {
      notWritten();
    }
  });
}

/** Inside a tmux Pane: the status, whatever Pi's release, and the session (ADR 0044). */
async function reportToTmux(program, target) {
  const app = (await piVersion()) ? "pi" : "omp";
  reportStatus(
    program,
    (state, message) =>
      writeToPane(target, (status) => {
        const next = continueHeelerStatus(status, { state, app, msg: statusMessage(message) });
        return next === status ? [] : [[TMUX_STATUS_OPTION, next]];
      }),
    { sessionChanges: true },
  );

  let reported;
  const reportSession = (_event, context) => {
    try {
      if (!holdsTheTerminal(context)) return;
      const session = context.sessionManager.getSessionId();
      const file = context.sessionManager.getSessionFile();
      const current = `${session}\n${file}`;
      if (reported === current) return;
      reported = current;
      writeToPane(
        target,
        async () => {
          ownStart ??= await processStart(process.pid);
          const value = { session, ...(file ? { file } : {}), pid: process.pid, ...(ownStart ? { start: ownStart } : {}) };
          return [[TMUX_SESSION_OPTION, JSON.stringify(value)]];
        },
        () => {
          if (reported === current) reported = undefined;
        },
      );
    } catch {
      // Nothing here is worth disturbing the program for.
    }
  };
  for (const event of ["session_start", "session_switch", "session_branch"]) program.on(event, reportSession);
}
