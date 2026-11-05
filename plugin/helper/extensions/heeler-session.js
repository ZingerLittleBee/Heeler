// Heeler's extension for Pi and Oh My Pi (ADR 0033). The Host Helper copies this
// one file into each program's extension folder, or on native Windows the app
// writes it there, and those programs load every session on the Host through it,
// so outside a herdr-core Terminal it does nothing at all. It imports only Node
// built-ins, since it runs from that folder.

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { connect } from "node:net";

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
  if (!terminal) return;
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

  if (process.env.PI_PROGRAM_STATUS !== "0" && isBeforeProgramStatus(await piVersion())) reportStatus(program);
}

/** Reports what Pi before 1.1.0 cannot say for itself, the way Pi says it from 1.1.0. */
function reportStatus(program) {
  const report = (context, state, message) => {
    if (holdsTheTerminal(context)) writeStatus(state, message);
  };
  program.on("session_start", (_event, context) => report(context, "idle"));
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

function writeStatus(state, message) {
  const fields = [`state=${state}`, "app=pi"];
  const text = (message ?? "").split(/\r?\n/, 1)[0].replace(/\p{Cc}/gu, " ").trim().slice(0, STATUS_MESSAGE_LIMIT);
  if (text) fields.push(`msg=${Buffer.from(text, "utf8").toString("base64")}`);
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
