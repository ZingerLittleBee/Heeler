import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, statSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { readJSON, writeJSON } from "./cache.js";

// One process lookup per pane every 10 minutes; an Agent restarted in the
// meantime is seen at the next check.
const PANE_INTERVAL = 10 * 60_000;
// Checks past their interval leave the file; the limit bounds only a burst of panes.
const PANE_LIMIT = 256;
const DIRECTORY_RETENTION = 30 * 86_400_000;
const TIME_LIMIT = 3_000;
// In `ps -E` output a value runs until the next ` NAME=` or the end. A name is
// anything up to `=`: bash exports a function as `BASH_FUNC_name%%=`.
const PS_VALUE = / CLAUDE_CONFIG_DIR=(.*?)(?= [^\s=]+=|$)/g;
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };
const times = (value, keep) => Object.fromEntries(Object.entries(object(value) ? value : {})
  .filter(([key, at]) => Number.isFinite(at) && keep(key, at)));

const claudeAgentsPath = stateDir => join(stateDir, "usage", "claude-agents.json");

/** The file's checks still throttling a pane, and directories seen in the last 30 days. */
function readAgents(path, now) {
  const file = readJSON(path);
  return {
    panes: times(file?.panes, (_, at) => now - at < PANE_INTERVAL),
    directories: times(file?.directories, (directory, at) => isAbsolute(directory) && now - at < DIRECTORY_RETENTION),
  };
}

/** The config directories running Agents were started with, most recently seen first. */
export function agentDirectories(stateDir, now = Date.now()) {
  return Object.entries(readAgents(claudeAgentsPath(stateDir), now).directories)
    .sort(([, a], [, b]) => b - a).map(([directory]) => directory);
}

const output = (file, args, deadline) => new Promise(resolve => execFile(file, args, {
  timeout: Math.max(1, deadline - Date.now()), killSignal: "SIGKILL", maxBuffer: 1 << 20, encoding: "utf8",
}, (error, stdout) => resolve(error ? null : stdout.replace(/\n$/, ""))));

/**
 * `CLAUDE_CONFIG_DIR` from a process's initial environment; nothing else of it
 * is kept. Null when it is unset or unreadable: macOS shows no environment for
 * Apple platform binaries, Linux none for a process that is not dumpable.
 */
async function configDirectoryOf(pid, deadline) {
  let value;
  if (process.platform === "linux") {
    let environment;
    try { environment = readFileSync(`/proc/${pid}/environ`, "utf8"); } catch { return null; }
    value = environment.split("\0").find(entry => entry.startsWith("CLAUDE_CONFIG_DIR="))?.slice("CLAUDE_CONFIG_DIR=".length);
  } else {
    // `ps -E` appends the environment to the arguments, each `NAME=value`
    // after a space; the plain command tells where the arguments end.
    const [command, withEnvironment] = await Promise.all([["-ww"], ["-E", "-ww"]]
      .map(flags => output("/bin/ps", [...flags, "-o", "command=", "-p", String(pid)], deadline)));
    if (command === null || withEnvironment === null || !withEnvironment.startsWith(command)) return null;
    // Another value that names the variable leaves no telling which is real.
    const values = [...withEnvironment.slice(command.length).matchAll(PS_VALUE)];
    if (values.length !== 1) return null;
    value = values[0][1];
  }
  // A relative value depends on where the Agent started, which is not known.
  // Only an existing directory is kept: a value read on into the next
  // variable, with whatever that holds, is not one.
  return typeof value === "string" && isAbsolute(value) && isDirectory(value) ? value : null;
}

/** The pane's Claude Code process: the foreground group leader when it is one. */
async function claudeProcess(herdr, paneId, deadline) {
  const answer = await output(herdr, ["pane", "process-info", "--pane", paneId], deadline);
  const info = answer === null ? null : JSON.parse(answer)?.result?.process_info;
  const processes = (Array.isArray(info?.foreground_processes) ? info.foreground_processes : [])
    .filter(entry => Number.isSafeInteger(entry?.pid) && entry.pid > 0 && typeof entry.argv0 === "string" && basename(entry.argv0) === "claude");
  return processes.find(entry => entry.pid === info.foreground_process_group_id) ?? processes[0] ?? null;
}

/**
 * Note the config directory a pane's Claude Code Agent runs with, for the
 * usage query to suggest as an Account. A pane is asked at most once every 10
 * minutes and for at most 3 seconds; a read that fails records only the check.
 * Pane ids repeat across herdr sessions, so a pane is keyed by its session too.
 */
export async function noteClaudeAgent({ stateDir, herdr, session, paneId, now = Date.now() }) {
  const path = claudeAgentsPath(stateDir);
  const pane = JSON.stringify([session, paneId]);
  const agents = readAgents(path, now);
  if (Object.hasOwn(agents.panes, pane)) return;
  const deadline = now + TIME_LIMIT;
  let directory = null;
  try {
    const claude = await claudeProcess(herdr, paneId, deadline);
    if (claude) directory = await configDirectoryOf(claude.pid, deadline);
  } catch { /* An unexpected answer suggests nothing. */ }
  const panes = Object.entries({ ...agents.panes, [pane]: now }).sort(([, a], [, b]) => b - a).slice(0, PANE_LIMIT);
  mkdirSync(join(stateDir, "usage"), { recursive: true, mode: 0o700 });
  writeJSON(path, { panes: Object.fromEntries(panes),
    directories: directory === null ? agents.directories : { ...agents.directories, [directory]: Date.now() } });
}
