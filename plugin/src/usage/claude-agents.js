import { execFile } from "node:child_process";
import { basename } from "node:path";
import { noteAgentDirectory } from "./agent-directories.js";

const output = (file, args, deadline) => new Promise(resolve => execFile(file, args, {
  timeout: Math.max(1, deadline - Date.now()), killSignal: "SIGKILL", maxBuffer: 1 << 20, encoding: "utf8",
}, (error, stdout) => resolve(error ? null : stdout.replace(/\n$/, ""))));

/** The pane's Claude Code process: the foreground group leader when it is one. */
async function claudeProcess(herdr, paneId, deadline) {
  const answer = await output(herdr, ["pane", "process-info", "--pane", paneId], deadline);
  const info = answer === null ? null : JSON.parse(answer)?.result?.process_info;
  const processes = (Array.isArray(info?.foreground_processes) ? info.foreground_processes : [])
    .filter(entry => Number.isSafeInteger(entry?.pid) && entry.pid > 0 && typeof entry.argv0 === "string" && basename(entry.argv0) === "claude");
  return processes.find(entry => entry.pid === info.foreground_process_group_id) ?? processes[0] ?? null;
}

/** Notes the config directory of the Claude Code Agent in a herdr pane. */
export async function noteClaudeAgent({ stateDir, herdr, session, paneId, now = Date.now() }) {
  await noteAgentDirectory({ stateDir, session, paneId, now,
    pidOf: async deadline => (await claudeProcess(herdr, paneId, deadline))?.pid ?? null });
}
