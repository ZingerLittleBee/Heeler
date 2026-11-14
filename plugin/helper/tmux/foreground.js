// Reads the process leading each live tmux Pane's foreground process group and
// its arguments, as `TmuxInventoryLoop` does: from `/proc` on Linux and
// `/bin/ps` on macOS (ADR 0045).

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";

const PS_TIMEOUT_MS = 2000;
const ARGUMENT_BYTES = 4096;

function runPs(args, signal) {
  return new Promise((resolve) => {
    execFile(
      "/bin/ps",
      args,
      {
        timeout: PS_TIMEOUT_MS,
        killSignal: "SIGKILL",
        maxBuffer: 1 << 20,
        encoding: "utf8",
        env: { LC_ALL: "C" },
        ...(signal ? { signal } : {}),
      },
      (error, stdout) => resolve(error ? null : stdout),
    );
  });
}

function foregroundFromStat(stat) {
  const end = stat.lastIndexOf(") ");
  if (end < 0) return null;
  const field = stat.slice(end + 2).split(" ")[5];
  const pid = Number(field);
  return Number.isSafeInteger(pid) && pid > 0 ? pid : null;
}

async function readLinuxCmdline(pid) {
  try {
    const raw = await readFile(`/proc/${pid}/cmdline`);
    const sliced = raw.subarray(0, ARGUMENT_BYTES);
    if (sliced.length === 0) return null;
    const parts = sliced.toString("utf8").split("\0");
    if (parts.at(-1) === "") parts.pop();
    return parts.length > 0 ? parts : null;
  } catch {
    return null;
  }
}

function parsePidLines(output) {
  const rows = new Map();
  if (!output) return rows;
  for (const line of output.split("\n")) {
    const match = /^\s*(\d+)\s+(.*)$/.exec(line);
    if (!match) continue;
    const pid = Number(match[1]);
    if (Number.isSafeInteger(pid) && pid > 0) rows.set(pid, match[2]);
  }
  return rows;
}

function splitMacArguments(comm, argsLine) {
  const arg0 = (comm ?? "").trimEnd();
  const full = (argsLine ?? "").trimEnd();
  if (!arg0 && !full) return null;
  if (!arg0) return full.split(/\s+/).filter(Boolean);
  if (!full.startsWith(arg0)) return [arg0];
  const rest = full.slice(arg0.length).trim();
  if (rest === "") return [arg0];
  if (existsSync(rest)) return [arg0, rest];
  return [arg0, ...rest.split(/\s+/).filter(Boolean)];
}

/**
 * Keeps a cache of `(tpgid, command) -> argv` per server instance so steady
 * ticks only resolve `tpgid` and skip argument reads for unchanged leaders.
 */
export function createForegroundReader() {
  const cache = new Map();

  return {
    reset() {
      cache.clear();
    },

    async readForPanes(panes, { signal } = {}) {
      const live = panes.filter((pane) => !pane.isDead && Number.isSafeInteger(pane.panePid) && pane.panePid > 0);
      if (live.length === 0) {
        cache.clear();
        return new Map();
      }

      const leaderByPanePid = new Map();
      if (process.platform === "linux") {
        await Promise.all(
          [...new Set(live.map((pane) => pane.panePid))].map(async (panePid) => {
            try {
              const stat = await readFile(`/proc/${panePid}/stat`, "utf8");
              const tpgid = foregroundFromStat(stat);
              if (tpgid !== null) leaderByPanePid.set(panePid, tpgid);
            } catch {
              // Process exited since list-panes.
            }
          }),
        );
      } else {
        const pidList = [...new Set(live.map((pane) => pane.panePid))].join(",");
        const output = await runPs(["-o", "pid=,tpgid=", "-p", pidList], signal);
        for (const [pid, rest] of parsePidLines(output)) {
          const tpgid = Number(rest.trim());
          if (Number.isSafeInteger(tpgid) && tpgid > 0) leaderByPanePid.set(pid, tpgid);
        }
      }

      const neededLeaders = new Set();
      for (const pane of live) {
        const leader = leaderByPanePid.get(pane.panePid);
        if (leader === undefined) continue;
        const cached = cache.get(leader);
        if (!cached || cached.command !== pane.command) neededLeaders.add(leader);
      }

      if (neededLeaders.size > 0) {
        if (process.platform === "linux") {
          await Promise.all(
            [...neededLeaders].map(async (leader) => {
              const argv = await readLinuxCmdline(leader);
              const pane = live.find((item) => leaderByPanePid.get(item.panePid) === leader);
              cache.set(leader, { command: pane?.command ?? "", argv });
            }),
          );
        } else {
          const list = [...neededLeaders].join(",");
          const [commOut, argsOut] = await Promise.all([
            runPs(["-ww", "-o", "pid=,comm=", "-p", list], signal),
            runPs(["-ww", "-o", "pid=,args=", "-p", list], signal),
          ]);
          const comms = parsePidLines(commOut);
          const argsLines = parsePidLines(argsOut);
          for (const leader of neededLeaders) {
            const pane = live.find((item) => leaderByPanePid.get(item.panePid) === leader);
            const argv = splitMacArguments(comms.get(leader), argsLines.get(leader));
            cache.set(leader, { command: pane?.command ?? "", argv });
          }
        }
      }

      const activeLeaders = new Set(leaderByPanePid.values());
      for (const leader of cache.keys()) {
        if (!activeLeaders.has(leader)) cache.delete(leader);
      }

      const result = new Map();
      for (const pane of live) {
        const leader = leaderByPanePid.get(pane.panePid) ?? pane.panePid;
        const argv = cache.get(leader)?.argv ?? null;
        result.set(pane.paneID, { foregroundPid: leader, foregroundArguments: argv });
      }
      return result;
    },
  };
}
