// Watches Claude Code Transcripts named by `@heeler-session` while a Claude
// Code Pane reads `working` or `blocked` (ADR 0044). Declining a permission
// prompt with Esc at the desktop runs no Claude Code hook, but appends a
// `system` / `turn_duration` entry to the Transcript; seeing one written after
// the status changed sets `idle` while continuing the Pane's counts.

import { open, stat } from "node:fs/promises";

import { transcriptEntries } from "../shared/usage/claude-scanner.js";
import { runStoredTmux } from "./client.js";
import { continueHeelerStatus, readHeelerStatus, wordForTmuxAgent } from "./status.js";

const PLAIN_STATUS = /^[A-Za-z0-9=:+/._ -]*$/;
const TAIL_CHUNK_BYTES = 4096;

function parseClaudeSession(raw, foregroundPid) {
  if (typeof raw !== "string" || raw === "") return null;
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  if (typeof parsed.file !== "string" || !parsed.file.startsWith("/") || !parsed.file.endsWith(".jsonl")) return null;
  if (parsed.pid != null && (!Number.isSafeInteger(parsed.pid) || parsed.pid !== foregroundPid)) return null;
  const sessionId = typeof parsed.session === "string" && parsed.session.length > 0 ? parsed.session : null;
  return { file: parsed.file, sessionId, pid: foregroundPid };
}

async function completeLineEndOffset(path) {
  let handle;
  try {
    handle = await open(path, "r");
    const { size } = await handle.stat();
    if (size <= 0) return 0;
    const buffer = Buffer.allocUnsafe(Math.min(TAIL_CHUNK_BYTES, size));
    let position = size;
    while (position > 0) {
      const length = Math.min(TAIL_CHUNK_BYTES, position);
      position -= length;
      const { bytesRead } = await handle.read(buffer, 0, length, position);
      const newline = buffer.subarray(0, bytesRead).lastIndexOf(0x0a);
      if (newline >= 0) return position + newline + 1;
    }
    return 0;
  } catch {
    return 0;
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function readTranscriptTail(path, fromOffset, sessionId) {
  let metadata;
  try {
    metadata = await stat(path);
  } catch {
    return { offset: 0, reset: fromOffset > 0, sawAssistant: false, turnEnded: false };
  }
  if (metadata.size < fromOffset) {
    return {
      offset: await completeLineEndOffset(path),
      reset: true,
      sawAssistant: false,
      turnEnded: false,
    };
  }
  if (metadata.size === fromOffset) {
    return { offset: fromOffset, reset: false, sawAssistant: false, turnEnded: false };
  }

  let offset = fromOffset;
  let sawAssistant = false;
  let turnEnded = false;
  try {
    for await (const entry of transcriptEntries(path, undefined, fromOffset)) {
      offset = entry.offset;
      const { line } = entry;
      if (!line || typeof line !== "object" || line.isSidechain === true) continue;
      if (sessionId && typeof line.sessionId === "string" && line.sessionId && line.sessionId !== sessionId) continue;
      if (line.type === "system" && line.subtype === "turn_duration") {
        turnEnded = true;
      } else if (line.type === "assistant") {
        sawAssistant = true;
        turnEnded = false;
      } else if (line.type === "user") {
        turnEnded = false;
      }
    }
  } catch {
    return { offset, reset: false, sawAssistant: false, turnEnded: false };
  }
  return { offset, reset: false, sawAssistant, turnEnded };
}

async function setIdleOnPane(target, pane) {
  const expected = pane.status;
  const next = continueHeelerStatus(expected, { state: "idle", app: "claude-code" });
  if (PLAIN_STATUS.test(expected) && /^%\d+$/.test(pane.paneID)) {
    const applied = await runStoredTmux(target, [
      "if-shell",
      "-F",
      "-t",
      pane.paneID,
      `#{==:#{@heeler-status},${expected}}`,
      `set-option -p -t '${pane.paneID}' @heeler-status '${next}' ; set-option -p -t '${pane.paneID}' @heeler-ask ''`,
      ";",
      "display-message",
      "-p",
      "-t",
      pane.paneID,
      "#{@heeler-status}",
    ]);
    if (!applied.ok) return false;
    pane.status = applied.stdout.replace(/\n$/, "");
    return pane.status === next;
  }

  const current = await runStoredTmux(target, ["display-message", "-p", "-t", pane.paneID, "#{@heeler-status}"]);
  if (!current.ok) return false;
  const live = current.stdout.replace(/\n$/, "");
  if (live !== expected) {
    pane.status = live;
    return false;
  }
  const applied = await runStoredTmux(target, [
    "set-option",
    "-p",
    "-t",
    pane.paneID,
    "@heeler-status",
    next,
    ";",
    "set-option",
    "-p",
    "-t",
    pane.paneID,
    "@heeler-ask",
    "",
  ]);
  if (!applied.ok) return false;
  pane.status = next;
  return true;
}

/** Listener for `followTmuxServer` that clears desktop-declined Claude Code turns. */
export function tmuxTranscriptListener() {
  const bySocket = new Map();

  const inspect = async ({ socket, instance, paths, panes }) => {
    let tracked = bySocket.get(socket);
    if (!tracked || tracked.instance !== instance) {
      tracked = { instance, panes: new Map() };
      bySocket.set(socket, tracked);
    }

    const target = { tmux: paths.executable, socket: paths.socket };
    const present = new Set();

    for (const pane of panes) {
      if (pane.isDead || pane.agentKind !== "claude") continue;
      const pid = pane.foregroundPid ?? pane.panePid;
      const session = parseClaudeSession(pane.agentSession, pid);
      if (!session) continue;

      present.add(pane.paneID);
      const parsed = readHeelerStatus(pane.status);
      const word = wordForTmuxAgent(parsed, "claude");
      const active = word === "working" || word === "blocked";
      const prev = tracked.panes.get(pane.paneID);

      if (!prev || prev.pid !== session.pid || prev.file !== session.file) {
        const offset = await completeLineEndOffset(session.file);
        tracked.panes.set(pane.paneID, {
          pid: session.pid,
          file: session.file,
          offset,
          turn: parsed.turn,
          watching: active,
        });
        continue;
      }

      if (!active) {
        const offset = await completeLineEndOffset(session.file);
        tracked.panes.set(pane.paneID, {
          pid: session.pid,
          file: session.file,
          offset,
          turn: parsed.turn,
          watching: false,
        });
        continue;
      }

      const tail = await readTranscriptTail(session.file, prev.offset, session.sessionId);
      const endedAfterStatusChanged =
        !tail.reset &&
        tail.turnEnded &&
        parsed.turn === prev.turn &&
        (prev.watching || (word === "blocked" && tail.sawAssistant));

      if (endedAfterStatusChanged) {
        const applied = await setIdleOnPane(target, pane);
        const updated = readHeelerStatus(pane.status);
        const updatedWord = wordForTmuxAgent(updated, "claude");
        tracked.panes.set(pane.paneID, {
          pid: session.pid,
          file: session.file,
          offset: applied ? tail.offset : prev.offset,
          turn: updated.turn,
          watching: updatedWord === "working" || updatedWord === "blocked",
        });
      } else {
        tracked.panes.set(pane.paneID, {
          pid: session.pid,
          file: session.file,
          offset: tail.offset,
          turn: parsed.turn,
          watching: true,
        });
      }
    }

    for (const paneID of tracked.panes.keys()) {
      if (!present.has(paneID)) tracked.panes.delete(paneID);
    }
  };

  return {
    serverStarted: inspect,
    panesUpdated: inspect,
    serverEnded({ socket, instance }) {
      if (bySocket.get(socket)?.instance === instance) bySocket.delete(socket);
    },
    followerStopped({ socket }) {
      bySocket.delete(socket);
    },
  };
}
