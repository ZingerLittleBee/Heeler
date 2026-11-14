// Attaches and closes Heeler's `pipe-pane` status readers on tmux Panes running
// Codex, Grok Build or OpenCode (ADR 0046). Leaves any Pane the user already
// pipes untouched; the running worker records its `kind:pid` in `@heeler-piped`
// on the Pane so a pipe closed without Heeler stays untouched across Helper
// restarts until the Pane's foreground program changes, while a failed attach
// leaves neither option behind and retries on the next sample.

import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

import { runStoredTmux } from "./client.js";

const PIPE_PROGRAMS = new Set([
  "codex",
  "grok",
  // The service closure allows only `/bin/ps` and the stored tmux with `-N`, so
  // the Helper cannot probe `opencode --version`. An older OpenCode (< 2.1)
  // emits no OSC 7501 reports, writing no status, and the app explains the 2.1
  // floor.
  "opencode",
]);
const PIPE_OPTION = "@heeler-pipe";
const PIPED_OPTION = "@heeler-piped";
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

function workerCommand({ tmux, socket, serverPid, pane, mark, programKey, workerPath }) {
  const encoded = Buffer.from(
    JSON.stringify({ tmux, socket, serverPid: String(serverPid), pane, mark, programKey }),
    "utf8",
  ).toString("base64url");
  return `exec ${quoteForPipePane(process.execPath)} ${quoteForPipePane(workerPath)} ${encoded}`;
}

async function readLivePanePipe(runTmux, target, paneID) {
  const read = await runTmux(target, [
    "display-message",
    "-p",
    "-t",
    paneID,
    `#{pid}\t#{pane_pipe}\t#{${PIPE_OPTION}}\t#{${PIPED_OPTION}}`,
  ]);
  if (!read.ok) return null;
  const [pid = "", pipe = "0", pipeMark = "", pipedProgram = ""] = read.stdout.replace(/\n$/, "").split("\t");
  return { serverPid: pid, hasPipe: pipe !== "0", pipeMark, pipedProgram };
}

async function attachPipe(
  runTmux,
  target,
  { paths, serverPid, paneID, currentKey, socket, log, resolveWorkerPath },
) {
  const mark = `${currentKey}:${randomBytes(6).toString("hex")}`;
  const workerPath = resolveWorkerPath(WORKER_PATH);
  const command = workerCommand({
    tmux: paths.executable,
    socket: paths.socket,
    serverPid,
    pane: paneID,
    mark,
    programKey: currentKey,
    workerPath,
  });
  const attached = await runTmux(target, [
    "set-option", "-p", "-t", paneID, PIPE_OPTION, mark,
    ";",
    "set-option", "-p", "-u", "-t", paneID, PIPED_OPTION,
    ";",
    "pipe-pane", "-O", "-t", paneID, command,
  ]);
  if (!attached.ok) {
    const live = await readLivePanePipe(runTmux, target, paneID);
    if (live && live.serverPid === String(serverPid) && live.pipeMark === mark) {
      await runTmux(target, [
        "set-option", "-p", "-u", "-t", paneID, PIPE_OPTION,
        ";",
        "set-option", "-p", "-u", "-t", paneID, PIPED_OPTION,
      ]);
    }
    log(`tmux socket ${JSON.stringify(socket)}: pipe-pane on ${paneID} failed (${attached.stderr.trim()})`);
  }
}

export function tmuxPipeReaderListener({
  log = () => {},
  runTmux = runStoredTmux,
  resolveWorkerPath = (defaultPath) => defaultPath,
} = {}) {
  return {
    async panesUpdated({ socket, paths, serverPid, panes }) {
      const target = { tmux: paths.executable, socket: paths.socket };
      const expectedPid = String(serverPid);

      for (const pane of panes) {
        const currentKey = programKeyFor(pane);
        const pipedProgram = pane.pipedProgram ?? "";

        // A Pane the user already pipes has no `@heeler-pipe` mark: leave it alone.
        if (pane.hasPipe && pane.pipeMark === "") {
          continue;
        }

        if (pane.pipeMark !== "") {
          const markedKey = markedProgramKey(pane.pipeMark);
          if (pane.hasPipe) {
            if (currentKey !== null && markedKey === currentKey) {
              continue;
            }
            const live = await readLivePanePipe(runTmux, target, pane.paneID);
            if (!live || live.serverPid !== expectedPid || live.pipeMark !== pane.pipeMark) continue;
            if (currentKey !== null) {
              await attachPipe(runTmux, target, {
                paths,
                serverPid,
                paneID: pane.paneID,
                currentKey,
                socket,
                log,
                resolveWorkerPath,
              });
            } else {
              await runTmux(target, [
                "set-option", "-p", "-u", "-t", pane.paneID, PIPE_OPTION,
                ";",
                "set-option", "-p", "-u", "-t", pane.paneID, PIPED_OPTION,
                ";",
                "pipe-pane", "-t", pane.paneID,
              ]);
            }
            continue;
          }

          // `hasPipe` is false while `@heeler-pipe` is still set: either a running
          // worker closed before clearing `@heeler-pipe`, or a worker command failed
          // before starting (`@heeler-piped` was never set).
          const live = await readLivePanePipe(runTmux, target, pane.paneID);
          if (!live || live.serverPid !== expectedPid || live.hasPipe || live.pipeMark !== pane.pipeMark) continue;
          if (currentKey !== null && markedKey === currentKey && live.pipedProgram === currentKey) {
            await runTmux(target, ["set-option", "-p", "-u", "-t", pane.paneID, PIPE_OPTION]);
          } else if (currentKey === null) {
            await runTmux(target, [
              "set-option", "-p", "-u", "-t", pane.paneID, PIPE_OPTION,
              ";",
              "set-option", "-p", "-u", "-t", pane.paneID, PIPED_OPTION,
            ]);
          } else {
            await attachPipe(runTmux, target, {
              paths,
              serverPid,
              paneID: pane.paneID,
              currentKey,
              socket,
              log,
              resolveWorkerPath,
            });
          }
          continue;
        }

        // `!pane.hasPipe && pane.pipeMark === ""`
        if (currentKey === null) {
          if (pipedProgram !== "") {
            const live = await readLivePanePipe(runTmux, target, pane.paneID);
            if (
              live &&
              live.serverPid === expectedPid &&
              !live.hasPipe &&
              live.pipeMark === "" &&
              live.pipedProgram === pipedProgram
            ) {
              await runTmux(target, ["set-option", "-p", "-u", "-t", pane.paneID, PIPED_OPTION]);
            }
          }
          continue;
        }
        if (pipedProgram === currentKey) {
          // A pipe closed without Heeler while this same foreground kept running.
          continue;
        }

        const live = await readLivePanePipe(runTmux, target, pane.paneID);
        if (
          !live ||
          live.serverPid !== expectedPid ||
          live.hasPipe ||
          live.pipeMark !== "" ||
          live.pipedProgram === currentKey
        ) {
          continue;
        }

        await attachPipe(runTmux, target, {
          paths,
          serverPid,
          paneID: pane.paneID,
          currentKey,
          socket,
          log,
          resolveWorkerPath,
        });
      }
    },
  };
}
