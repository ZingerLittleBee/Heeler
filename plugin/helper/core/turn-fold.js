// A Terminal's record and events folded into its turns. Whatever reads Done on the
// Helper folds the same way, so a notification and a Live Activity count one Agent's
// turn alike.

import { agentIn } from "./agent-rule.js";

/**
 * Events that can change what an Agent reads as. Size and the like cannot. A title can
 * only on native Windows, which runs no Helper (ADR 0033), so a program's frequent
 * retitling stays out.
 */
export const AGENT_EVENTS = new Set(["created", "restarted", "foreground", "status", "turn", "lost", "finished"]);

const statusWord = (record) => record.status?.state ?? null;
const turnCount = (record) => (Number.isSafeInteger(record.turn) ? record.turn : 0);

const noteRecord = (turns, record, kind) => turns.noteSnapshot(turnCount(record), statusWord(record), kind, record.reported === true);

/** What a snapshot, or a `created` event, says of a Terminal. */
export function foldRecord(turns, record) {
  const kind = agentIn(record)?.kind ?? null;
  noteRecord(turns, record, kind);
  if (kind === null) turns.noteNoAgent();
}

/** One event of `AGENT_EVENTS`, with `record` already holding what it changed. */
export function foldEvent(turns, event, record) {
  const kind = agentIn(record)?.kind ?? null;
  if (event.type === "status") turns.noteStatus(statusWord(record), turnCount(record), kind);
  else if (event.type === "turn") turns.noteTurn(turnCount(record));
  else if (event.type === "created" || event.type === "restarted") {
    if (event.type === "restarted") turns.noteRestart(turnCount(record));
    noteRecord(turns, record, kind);
  }
  if (kind === null) turns.noteNoAgent();
}

/**
 * What a debounced decision reads of a Terminal. The core sends a `status` for every
 * report, progress and child records included, so a report that leaves this alone
 * has nothing new to wait for and must not restart a debounce.
 */
export function decisionSignature(record, turns) {
  const agent = agentIn(record);
  return JSON.stringify([agent?.kind ?? null, agent?.status ?? null, turnCount(record), turns.ended?.turn ?? null, turns.ended?.word ?? null]);
}
