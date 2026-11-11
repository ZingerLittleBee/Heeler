// Attaches and closes Heeler's `pipe-pane` status readers on tmux Panes running
// Codex, Grok Build or OpenCode (ADR 0044). Leaves any Pane the user already
// pipes untouched, and leaves a Pane whose pipe closed without Heeler untouched
// until its foreground program changes.

import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

import { runStoredTmux } from "./client.js";

const PIPE_PROGRAMS = new Set(["codex", "grok", "opencode"]);
const WORKER_PATH = fileURLToPath(new URL("./pipe-pane-worker.js", import.meta.url));

function programKeyFor(pane) {
  if (pane.isDead || !PIPE_PROGRAMS.has(pane.agentKind)) return null;
  const pid = pane.foregroundPid ?? pane.panePid;
  return `${pane.agentKind}:${pid}`;
}

function markedProgramKey(mark) {
  const parts = (mark ?? "").split(":");
  if (parts.length < 3) return null;
  const [kind, pid] = parts;
  if (!PIPE_PROGRAMS.has(kind) || !/^\d+$/.test(pid)) return null;
  return `${kind}:${pid}`;
}

/**
 * Quotes one argument for the server's shell (`sh`, `bash`, `zsh`, `fish`,
 * `tcsh`) and escapes `%` and `#` against `pipe-pane`'s strftime and format
 * expansion (`man tmux`, `pipe-pane`).
 */
function quoteForPipePane(argument) {
  const shellQuoted = `'${argument.replaceAll("'", "'\\''")}'`;
  return shellQuoted.replaceAll("%", "%%").replaceAll("#", "##");
}

function workerCommand({ tmux, socket, serverPid, pane, mark }) {
  const encoded = Buffer.from(
    JSON.stringify({ tmux, socket, serverPid: String(serverPid), pane, mark }),
    "utf8",
  ).toString("base64url");
  return `exec ${quoteForPipePane(process.execPath)} ${quoteForPipePane(WORKER_PATH)} ${encoded}`;
}

async function readLivePanePipe(target, paneID) {
  const read = await runStoredTmux(target, [
    "display-message",
    "-p",
    "-t",
    paneID,
    "#{pid}\t#{pane_pipe}\t#{@heeler-pipe}",
  ]);
  if (!read.ok) return null;
  const [pid = "", pipe = "0", pipeMark = ""] = read.stdout.replace(/\n$/, "").split("\t");
  return { serverPid: pid, hasPipe: pipe !== "0", pipeMark };
}

export function tmuxPipeReaderListener({ log = () => {} } = {}) {
  // Per socket: `{ instance, pipedPrograms: Map<paneID, programKey> }`.
  const servers = new Map();

  const stateFor = (socket, instance) => {
    const existing = servers.get(socket);
    if (existing && existing.instance === instance) return existing;
    const fresh = { instance, pipedPrograms: new Map() };
    servers.set(socket, fresh);
    return fresh;
  };

  return {
    async serverStarted({ socket, instance }) {
      stateFor(socket, instance);
    },

    async serverEnded({ socket }) {
      servers.delete(socket);
    },

    async followerStopped({ socket }) {
      servers.delete(socket);
    },

    async panesUpdated({ socket, paths, instance, serverPid, panes }) {
      const target = { tmux: paths.executable, socket: paths.socket };
      const expectedPid = String(serverPid);
      const { pipedPrograms } = stateFor(socket, instance);
      const seenPanes = new Set();

      for (const pane of panes) {
        seenPanes.add(pane.paneID);
        const currentKey = programKeyFor(pane);

        // A Pane the user already pipes has no `@heeler-pipe` mark: leave it alone.
        if (pane.hasPipe && pane.pipeMark === "") {
          continue;
        }

        if (pane.pipeMark !== "") {
          const markedKey = markedProgramKey(pane.pipeMark);
          if (pane.hasPipe) {
            if (currentKey !== null && markedKey === currentKey) {
              pipedPrograms.set(pane.paneID, currentKey);
              continue;
            }
            const live = await readLivePanePipe(target, pane.paneID);
            if (!live || live.serverPid !== expectedPid || live.pipeMark !== pane.pipeMark) continue;
            if (currentKey !== null) {
              const nextMark = `${currentKey}:${randomBytes(6).toString("hex")}`;
              const command = workerCommand({
                tmux: paths.executable,
                socket: paths.socket,
                serverPid,
                pane: pane.paneID,
                mark: nextMark,
              });
              const replaced = await runStoredTmux(target, [
                "set-option", "-p", "-t", pane.paneID, "@heeler-pipe", nextMark,
                ";",
                "pipe-pane", "-O", "-t", pane.paneID, command,
              ]);
              if (replaced.ok) pipedPrograms.set(pane.paneID, currentKey);
            } else {
              await runStoredTmux(target, [
                "pipe-pane", "-t", pane.paneID,
                ";",
                "set-option", "-p", "-u", "-t", pane.paneID, "@heeler-pipe",
              ]);
              pipedPrograms.delete(pane.paneID);
            }
            continue;
          }

          // `hasPipe` is false while `@heeler-pipe` is still set: the pipe closed
          // externally right before `list-panes` or its worker died without clearing.
          if (currentKey !== null && markedKey === currentKey) {
            pipedPrograms.set(pane.paneID, currentKey);
          } else if (currentKey === null) {
            pipedPrograms.delete(pane.paneID);
          }
          const live = await readLivePanePipe(target, pane.paneID);
          if (live && live.serverPid === expectedPid && !live.hasPipe && live.pipeMark === pane.pipeMark) {
            await runStoredTmux(target, ["set-option", "-p", "-u", "-t", pane.paneID, "@heeler-pipe"]);
          }
          continue;
        }

        // `!pane.hasPipe && pane.pipeMark === ""`
        if (currentKey === null) {
          pipedPrograms.delete(pane.paneID);
          continue;
        }
        if (pipedPrograms.get(pane.paneID) === currentKey) {
          // A pipe closed without Heeler while this same foreground kept running.
          continue;
        }

        const live = await readLivePanePipe(target, pane.paneID);
        if (!live || live.serverPid !== expectedPid || live.hasPipe || live.pipeMark !== "") continue;

        const mark = `${currentKey}:${randomBytes(6).toString("hex")}`;
        const command = workerCommand({
          tmux: paths.executable,
          socket: paths.socket,
          serverPid,
          pane: pane.paneID,
          mark,
        });
        const attached = await runStoredTmux(target, [
          "set-option", "-p", "-t", pane.paneID, "@heeler-pipe", mark,
          ";",
          "pipe-pane", "-O", "-t", pane.paneID, command,
        ]);
        if (attached.ok) {
          pipedPrograms.set(pane.paneID, currentKey);
        } else {
          log(`tmux socket ${JSON.stringify(socket)}: pipe-pane on ${pane.paneID} failed (${attached.stderr.trim()})`);
        }
      }

      for (const paneID of pipedPrograms.keys()) {
        if (!seenPanes.has(paneID)) pipedPrograms.delete(paneID);
      }
    },
  };
}
