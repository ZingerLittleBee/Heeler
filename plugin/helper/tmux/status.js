// A tmux Pane's `@heeler-status` option (ADR 0044), shared with
// `plugin/test-vectors/tmux-heeler-status-v1.json`.

/** Programs known to report done, so their idle ends no turn (tmux-heeler-status-v1.json). */
export const DONE_REPORTERS = new Set(["claude-code", "codex", "pi", "omp", "grok-build"]);

/** Reads a tmux Pane's `@heeler-status` value into its fields and counts. */
export function readHeelerStatus(value) {
  const status = { state: null, app: null, kind: null, msg: null, turn: 0, blocked: 0 };
  for (const word of (value ?? "").split(":")) {
    const equals = word.indexOf("=");
    if (equals < 0) continue;
    const key = word.slice(0, equals);
    const text = word.slice(equals + 1);
    if (key === "turn" || key === "blocked") status[key] = /^\d+$/.test(text) ? Number(text) : 0;
    else if (key in status) status[key] = text || null;
  }
  return status;
}

/**
 * Computes the next `@heeler-status` value for `report` (`state`, optional
 * `app`, `kind` and `msg`), continuing the `turn` and `blocked` counts of
 * `previous`.
 */
export function continueHeelerStatus(previous, report) {
  const last = readHeelerStatus(previous);
  const counts = (turn, blocked) => `turn=${turn}:blocked=${blocked}`;
  if (report.state === "clear") return counts(last.turn, last.blocked);
  const app = report.app || null;
  const sameApp = last.state !== null && last.app === app;
  const endsTurn =
    sameApp &&
    (((last.state === "working" || last.state === "blocked") && (report.state === "done" || report.state === "error")) ||
      (last.state === "working" && report.state === "idle" && !DONE_REPORTERS.has(app)));
  const asks = report.state === "blocked" && !(sameApp && last.state === "blocked");
  const words = [`state=${report.state}`];
  if (app) words.push(`app=${app}`);
  if (report.kind) words.push(`kind=${report.kind}`);
  if (report.msg) words.push(`msg=${report.msg}`);
  return `${words.join(":")}:${counts(last.turn + (endsTurn ? 1 : 0), last.blocked + (asks ? 1 : 0))}`;
}
