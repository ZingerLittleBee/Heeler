// `<program>-agents.json`: the config directories running Agents of a program
// with Accounts were started with, which the usage query suggests as Accounts.
// Where an Agent's pid comes from is the caller's: herdr's pane info, or the
// Host Helper's inventory.

import { mkdirSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { readJSON, writeJSON } from "./cache.js";
import { readProcessEnvironment } from "./process-environment.js";
import { USAGE_PROGRAMS } from "./programs.js";

// One process lookup per pane every 10 minutes; an Agent restarted in the
// meantime is seen at the next check.
const PANE_INTERVAL = 10 * 60_000;
// Checks past their interval leave the file; the limit bounds only a burst of panes.
const PANE_LIMIT = 256;
const DIRECTORY_RETENTION = 30 * 86_400_000;
const TIME_LIMIT = 3_000;
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };
const times = (value, keep) => Object.fromEntries(Object.entries(object(value) ? value : {})
  .filter(([key, at]) => Number.isFinite(at) && keep(key, at)));

// Claude Code's file kept its name from before other programs had Accounts.
const agentsPath = (stateDir, program) => join(stateDir, "usage", `${program}-agents.json`);

/** The file's checks still throttling a pane, and directories seen in the last 30 days. */
function readAgents(path, now) {
  const file = readJSON(path);
  return {
    panes: times(file?.panes, (_, at) => now - at < PANE_INTERVAL),
    directories: times(file?.directories, (directory, at) => isAbsolute(directory) && now - at < DIRECTORY_RETENTION),
  };
}

/** The config directories the program's running Agents were started with, most recently seen first. */
export function agentDirectories(stateDir, now = Date.now(), program = "claude") {
  return Object.entries(readAgents(agentsPath(stateDir, program), now).directories)
    .sort(([, a], [, b]) => b - a).map(([directory]) => directory);
}

/**
 * The program's config variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) from a
 * process's initial environment; nothing else of it is kept. Null when it is
 * unset or unreadable.
 */
async function configDirectoryOf(pid, variable, deadline) {
  const value = (await readProcessEnvironment(pid, [variable], deadline))?.[variable];
  // A relative value depends on where the Agent started, which is not known.
  // Only an existing directory is kept: a value read on into the next
  // variable, with whatever that holds, is not one.
  return typeof value === "string" && isAbsolute(value) && isDirectory(value) ? value : null;
}

/**
 * Note the config directory a pane's Agent of `program` runs with, for the
 * usage query to suggest as an Account. A pane is asked at most once every 10
 * minutes and for at most 3 seconds; a read that fails records only the check.
 * Pane ids repeat across sessions, so a pane is keyed by its session too.
 * `pidOf(deadline)` gives the Agent's process, or null.
 */
export async function noteAgentDirectory({ stateDir, session, paneId, program, pidOf, now = Date.now() }) {
  const { variable } = USAGE_PROGRAMS[program];
  const path = agentsPath(stateDir, program);
  const pane = JSON.stringify([session, paneId]);
  const agents = readAgents(path, now);
  if (Object.hasOwn(agents.panes, pane)) return;
  const deadline = now + TIME_LIMIT;
  let directory = null;
  try {
    const pid = await pidOf(deadline);
    if (pid !== null) directory = await configDirectoryOf(pid, variable, deadline);
  } catch { /* An unexpected answer suggests nothing. */ }
  const panes = Object.entries({ ...agents.panes, [pane]: now }).sort(([, a], [, b]) => b - a).slice(0, PANE_LIMIT);
  mkdirSync(join(stateDir, "usage"), { recursive: true, mode: 0o700 });
  writeJSON(path, { panes: Object.fromEntries(panes),
    directories: directory === null ? agents.directories : { ...agents.directories, [directory]: Date.now() } });
}
