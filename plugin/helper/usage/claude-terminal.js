// Which process in a Terminal's record is a running Claude Code Agent, by the shared
// Agent rule (ADR 0032), for suggesting directories.

import { agentIn } from "../core/agent-rule.js";

/** The record's Claude Code process, or null when it holds no Claude Code Agent. */
export function claudeAgentPid(record) {
  // A live Terminal with no pid is between a lost process and its restart, or has
  // yet to spawn, so it has no process to read.
  if (record?.state !== "live" || !Number.isSafeInteger(record.pid) || record.pid <= 0) return null;
  if (agentIn(record)?.kind !== "claude") return null;
  const pid = record.foreground?.pid;
  return Number.isSafeInteger(pid) && pid > 0 ? pid : record.pid;
}
