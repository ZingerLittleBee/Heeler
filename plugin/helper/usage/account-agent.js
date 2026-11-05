// Which process in a Terminal's record is a running Agent of a program with Usage
// Accounts (Claude Code, Codex), by the shared Agent rule (ADR 0032), for
// suggesting directories.

import { agentIn } from "../core/agent-rule.js";
import { ACCOUNT_PROGRAMS } from "../shared/usage/programs.js";

/** The record's Agent as `{program, pid}`, or null when it holds none with Accounts. */
export function accountAgentOf(record) {
  // A live Terminal with no pid is between a lost process and its restart, or has
  // yet to spawn, so it has no process to read.
  if (record?.state !== "live" || !Number.isSafeInteger(record.pid) || record.pid <= 0) return null;
  const program = agentIn(record)?.kind;
  if (!ACCOUNT_PROGRAMS.includes(program)) return null;
  const pid = record.foreground?.pid;
  return { program, pid: Number.isSafeInteger(pid) && pid > 0 ? pid : record.pid };
}
