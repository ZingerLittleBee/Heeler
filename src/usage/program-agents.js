import { execFile } from "node:child_process";
import { basename } from "node:path";
import { noteAgentDirectory } from "./agent-directories.js";
import { USAGE_PROGRAMS } from "./programs.js";

const output = (file, args, deadline) => new Promise(resolve => execFile(file, args, {
  timeout: Math.max(1, deadline - Date.now()), killSignal: "SIGKILL", maxBuffer: 1 << 20, encoding: "utf8",
}, (error, stdout) => resolve(error ? null : stdout.replace(/\n$/, ""))));

/** The pane's program process: the foreground group leader when it is one. */
async function programProcess(herdr, paneId, executable, deadline) {
  const answer = await output(herdr, ["pane", "process-info", "--pane", paneId], deadline);
  const info = answer === null ? null : JSON.parse(answer)?.result?.process_info;
  const processes = (Array.isArray(info?.foreground_processes) ? info.foreground_processes : [])
    .filter(entry => Number.isSafeInteger(entry?.pid) && entry.pid > 0 && typeof entry.argv0 === "string" && basename(entry.argv0) === executable);
  return processes.find(entry => entry.pid === info.foreground_process_group_id) ?? processes[0] ?? null;
}

/** Notes the config directory of the Agent of `program` (Claude Code, Codex) in a herdr pane. */
export async function noteProgramAgent({ stateDir, herdr, session, paneId, program, now = Date.now() }) {
  const { executable } = USAGE_PROGRAMS[program];
  await noteAgentDirectory({ stateDir, session, paneId, program, now,
    pidOf: async deadline => (await programProcess(herdr, paneId, executable, deadline))?.pid ?? null });
}
