// Watches Claude Code Transcripts named by `@heeler-session` while a Claude
// Code Pane reads `working` or `blocked` (ADR 0044). Declining a permission
// prompt with Esc at the desktop runs no Claude Code hook, but appends a
// `system` / `turn_duration` entry to the Transcript; seeing one written after
// the status changed sets `idle` while continuing the Pane's counts.
//
// In a normal turn, Claude Code writes `turn_duration` before its `Stop` hook
// finishes writing `done`. Setting `idle` on the first poll that sees
// `turn_duration` would turn `working` into `idle` (no `turn` step for a
// done-reporting program) and leave the hook's `idle` -> `done` without a
// `turn` step either, eating `Done`. We therefore hold a candidate turn-end in
// memory until a later poll sees both the identical `@heeler-status` (same
// state and counts, with no new user/assistant Transcript entries) and at least
// `settleMs` on a monotonic clock (`performance.now()`). Monotonic elapsed time
// avoids filesystem `mtime` granularity/clock skew and trailing non-turn writes
// while giving `hook.sh` time to run even under fast polling; `setIdleOnPane`
// keeps a tmux compare-and-set so a hook landing at the same instant still wins.

import { open, stat } from "node:fs/promises";
import { performance } from "node:perf_hooks";

import { transcriptEntries } from "../shared/usage/claude-scanner.js";
import { runStoredTmux } from "./client.js";
import { continueHeelerStatus, readHeelerStatus, wordForTmuxAgent } from "./status.js";

const PLAIN_STATUS = /^[A-Za-z0-9=:+/._ -]*$/;
const TAIL_CHUNK_BYTES = 4096;
const DEFAULT_SETTLE_MS = 1000;

function fileKeyOf(metadata) {
  return `${metadata.dev}:${metadata.ino}`;
}

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
    const metadata = await handle.stat();
    const fileKey = fileKeyOf(metadata);
    const { size } = metadata;
    if (size <= 0) return { offset: 0, fileKey };
    const buffer = Buffer.allocUnsafe(Math.min(TAIL_CHUNK_BYTES, size));
    let position = size;
    while (position > 0) {
      const length = Math.min(TAIL_CHUNK_BYTES, position);
      position -= length;
      const { bytesRead } = await handle.read(buffer, 0, length, position);
      const newline = buffer.subarray(0, bytesRead).lastIndexOf(0x0a);
      if (newline >= 0) return { offset: position + newline + 1, fileKey };
    }
    return { offset: 0, fileKey };
  } catch {
    return { offset: 0, fileKey: null };
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function readTranscriptTail(path, fromOffset, prevFileKey, hadFile, sessionId) {
  let metadata;
  try {
    metadata = await stat(path);
  } catch {
    return {
      offset: 0,
      fileKey: null,
      reset: fromOffset > 0 || prevFileKey !== null,
      sawAssistant: false,
      sawTurnActivity: false,
      turnEnded: false,
    };
  }
  const fileKey = fileKeyOf(metadata);
  const rotated = prevFileKey !== null ? fileKey !== prevFileKey : hadFile;
  if (rotated || metadata.size < fromOffset) {
    const end = await completeLineEndOffset(path);
    return {
      offset: end.offset,
      fileKey: end.fileKey,
      reset: true,
      sawAssistant: false,
      sawTurnActivity: false,
      turnEnded: false,
    };
  }
  if (metadata.size === fromOffset) {
    return { offset: fromOffset, fileKey, reset: false, sawAssistant: false, sawTurnActivity: false, turnEnded: false };
  }

  let offset = fromOffset;
  let sawAssistant = false;
  let sawTurnActivity = false;
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
        sawTurnActivity = true;
        turnEnded = false;
      } else if (line.type === "user") {
        sawTurnActivity = true;
        turnEnded = false;
      }
    }
  } catch {
    return { offset, fileKey, reset: false, sawAssistant: false, sawTurnActivity: false, turnEnded: false };
  }
  return { offset, fileKey, reset: false, sawAssistant, sawTurnActivity, turnEnded };
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
    if (!applied.ok) return "failed";
    pane.status = applied.stdout.replace(/\n$/, "");
    return pane.status === next ? "applied" : "superseded";
  }

  const current = await runStoredTmux(target, ["display-message", "-p", "-t", pane.paneID, "#{@heeler-status}"]);
  if (!current.ok) return "failed";
  const live = current.stdout.replace(/\n$/, "");
  if (live !== expected) {
    pane.status = live;
    return "superseded";
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
  if (!applied.ok) return "failed";
  pane.status = next;
  return "applied";
}

/** Listener for `followTmuxServer` that clears desktop-declined Claude Code turns. */
export function tmuxTranscriptListener({ settleMs = DEFAULT_SETTLE_MS, now = () => performance.now() } = {}) {
  const settleDelay = Number.isFinite(settleMs) && settleMs >= 0 ? settleMs : DEFAULT_SETTLE_MS;
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

      if (
        !prev ||
        prev.pid !== session.pid ||
        prev.file !== session.file ||
        prev.sessionId !== session.sessionId
      ) {
        const end = await completeLineEndOffset(session.file);
        tracked.panes.set(pane.paneID, {
          pid: session.pid,
          sessionId: session.sessionId,
          file: session.file,
          fileKey: end.fileKey,
          hadFile: end.fileKey !== null,
          offset: end.offset,
          turn: parsed.turn,
          watching: active,
          pending: null,
        });
        continue;
      }

      if (!active) {
        const end = await completeLineEndOffset(session.file);
        tracked.panes.set(pane.paneID, {
          pid: session.pid,
          sessionId: session.sessionId,
          file: session.file,
          fileKey: end.fileKey,
          hadFile: prev.hadFile || end.fileKey !== null,
          offset: end.offset,
          turn: parsed.turn,
          watching: false,
          pending: null,
        });
        continue;
      }

      const tail = await readTranscriptTail(session.file, prev.offset, prev.fileKey, prev.hadFile, session.sessionId);
      const hadFile = prev.hadFile || tail.fileKey !== null;
      const freshTurnEnd =
        !tail.reset &&
        tail.turnEnded &&
        parsed.turn === prev.turn &&
        (prev.watching || (word === "blocked" && tail.sawAssistant));

      let pending = null;
      if (tail.reset) {
        pending = null;
      } else if (freshTurnEnd) {
        pending = { status: pane.status, seenAt: now() };
      } else if (prev.pending !== null && pane.status === prev.pending.status && !tail.sawTurnActivity) {
        if (now() - prev.pending.seenAt >= settleDelay) {
          const outcome = await setIdleOnPane(target, pane);
          const updated = readHeelerStatus(pane.status);
          const updatedWord = wordForTmuxAgent(updated, "claude");
          tracked.panes.set(pane.paneID, {
            pid: session.pid,
            sessionId: session.sessionId,
            file: session.file,
            fileKey: tail.fileKey,
            hadFile,
            offset: tail.offset,
            turn: updated.turn,
            watching: updatedWord === "working" || updatedWord === "blocked",
            pending: outcome === "failed" ? prev.pending : null,
          });
          continue;
        }
        pending = prev.pending;
      }

      tracked.panes.set(pane.paneID, {
        pid: session.pid,
        sessionId: session.sessionId,
        file: session.file,
        fileKey: tail.fileKey,
        hadFile,
        offset: tail.offset,
        turn: parsed.turn,
        watching: true,
        pending,
      });
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
    trackedPaneCount(socket) {
      return socket === undefined
        ? Array.from(bySocket.values()).reduce((sum, entry) => sum + entry.panes.size, 0)
        : (bySocket.get(socket)?.panes.size ?? 0);
    },
  };
}
