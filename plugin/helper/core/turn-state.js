// What the Helper knows of one Terminal's turns: the app's HerdrCoreTurnState read
// on the Host (ADR 0033). A turn's end comes from the status word. The turn count
// cannot tell it: the count also moves on entering Blocked or Error and on Codex's
// start-up blip, and a move from Blocked straight to Done leaves it alone.
//
// plugin/test-vectors/herdr-core-turn-end-v1.json holds this rule's cases for both
// sides, so a change here changes that file and the app's rule in one commit.
//
// A mark is `{turn, word}`: a point in a Terminal's reports. The word tells two
// points at one count apart.

/** Agent kinds known to report done, whose idle therefore ends no turn. */
export const DONE_REPORTER_KINDS = new Set(["claude", "codex", "pi", "omp", "grok"]);

const keepsAFinishedTurn = (word) => word === "idle" || word === "done";

const sameMark = (left, right) => left?.turn === right?.turn && left?.word === right?.word;

/** A move from Blocked straight to Done ends the turn that went to Blocked. */
function endsTurn(previous, word, reportsDone) {
  if (word === "done") return previous === "working" || previous === "blocked";
  return previous === "working" && word === "idle" && !reportsDone;
}

/**
 * Whether a device's seen mark says it has seen the turn that ended at `ended`. A
 * later count has. At the same count the same word has, and so has a word that
 * reads as finished: the app, first told of a turn by a snapshot, marks where the
 * Agent stands, and a key may have turned its done into idle since. Any other word
 * at that count came before the end: an Agent opened while Blocked has not seen the
 * Done that follows.
 */
export function markCoversTurn(mark, ended) {
  if (mark === null || mark === undefined) return false;
  if (mark.turn !== ended.turn) return mark.turn > ended.turn;
  return mark.word === ended.word || keepsAFinishedTurn(mark.word);
}

const readMark = (value) =>
  Number.isSafeInteger(value?.turn) && (typeof value.word === "string" || value.word === null)
    ? { turn: value.turn, word: value.word }
    : null;

export class TurnState {
  /** The last report the Helper knows of. */
  last = null;
  /** The latest finished turn, while the Agent has not reported anything since that takes it back, as working does. */
  ended = null;
  /** Whether this Terminal has reported done since its last restart. */
  hasReportedDone = false;

  /** Whether a device whose seen mark is `mark` counts this Agent as Done. */
  isDoneFor(mark) {
    return this.ended !== null && !markCoversTurn(mark, this.ended);
  }

  /**
   * One `status` event, whose `turn` is the count on the record. The core moves the
   * count before it sends the event, and says so only in the `turn` event after it,
   * so the count of a report that left working is worked out here. Returns whether
   * it ended a turn.
   */
  noteStatus(word, turn, kind) {
    const previous = this.last?.word ?? null;
    if (this.last !== null && previous === word) return false;
    const mark = { turn: previous === "working" && word !== "working" ? turn + 1 : turn, word };
    this.last = mark;
    const reportsDone = this.#reportsDone(kind);
    if (word === "done") this.hasReportedDone = true;
    if (!endsTurn(previous, word, reportsDone)) {
      if (!keepsAFinishedTurn(word)) this.ended = null;
      return false;
    }
    this.ended = { ...mark };
    return true;
  }

  /** One `turn` event: the count the core moved. */
  noteTurn(turn) {
    if (this.last === null || this.last.turn === turn) return;
    if (sameMark(this.ended, this.last)) this.ended = { ...this.ended, turn };
    this.last = { ...this.last, turn };
  }

  /** A kept restart: the turn count carries over and the reports do not. */
  noteRestart(turn) {
    this.last = { turn, word: null };
    this.ended = null;
    this.hasReportedDone = false;
  }

  /**
   * A snapshot stands in for whatever happened since the last report known here, and
   * event numbers cannot be resumed to ask. Only leaving working moves the count, so
   * the same count means no working came between. A moved or new one means some turn
   * stopped working, and what the word says now is all that is left to tell how.
   * Returns whether it ended a turn.
   */
  noteSnapshot(turn, word, kind, reported) {
    // Only a kept restart clears `reported`.
    if (!reported) this.hasReportedDone = false;
    const previous = this.last;
    const mark = { turn, word };
    this.last = mark;
    const reportsDone = this.#reportsDone(kind);
    if (word === "done") this.hasReportedDone = true;
    if (previous !== null && sameMark(previous, mark)) return false;
    if (!keepsAFinishedTurn(word)) {
      this.ended = null;
      return false;
    }
    let ends;
    if (previous !== null && previous.turn === turn) {
      ends = endsTurn(previous.word, word, reportsDone);
    } else {
      this.ended = null;
      ends = turn > 0 && (word === "done" || !reportsDone);
    }
    if (ends) this.ended = { ...mark };
    return ends;
  }

  /** The Agent rule finds no Agent here now: a later one starts with no Done, whatever report the core kept. */
  noteNoAgent() {
    this.ended = null;
  }

  #reportsDone(kind) {
    return this.hasReportedDone || DONE_REPORTER_KINDS.has(kind);
  }

  toJSON() {
    return { last: this.last, ended: this.ended, hasReportedDone: this.hasReportedDone };
  }

  /** What `toJSON` wrote. A part that does not read as what it should starts over. */
  static restore(value) {
    const state = new TurnState();
    state.last = readMark(value?.last);
    state.ended = readMark(value?.ended);
    state.hasReportedDone = value?.hasReportedDone === true;
    return state;
  }
}
