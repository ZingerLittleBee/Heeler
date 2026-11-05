// The Helper's turn-end rule and Done per device, read from the same vector the
// app's tests read, so the two cannot disagree about a turn's end (ADR 0033).

import { suite, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { DONE_REPORTER_KINDS, TurnState } from "../helper/core/turn-state.js";

const vectors = JSON.parse(readFileSync(new URL("../test-vectors/herdr-core-turn-end-v1.json", import.meta.url), "utf8"));

/**
 * Runs one step as the Helper's listener does, with the count a status event finds
 * on its record, which only its turn event moves. `seen` is what the app writes as
 * it opens an Agent: the turn that ended, else where the Agent stands.
 */
function apply(step, run) {
  const { state } = run;
  switch (step.event) {
    case "snapshot":
      run.count = step.turn;
      return state.noteSnapshot(step.turn, step.state ?? null, run.kind, step.reported);
    case "status":
      return state.noteStatus(step.state ?? null, run.count, run.kind);
    case "turn":
      run.count = step.turn;
      state.noteTurn(step.turn);
      return false;
    case "restarted":
      run.count = step.turn;
      state.noteRestart(step.turn);
      return false;
    case "agent":
      run.kind = step.kind ?? null;
      if (run.kind === null) state.noteNoAgent();
      return false;
    case "seen":
      run.mark = state.ended ?? state.last ?? run.mark;
      return false;
    default:
      throw new Error(`Unknown event ${step.event}`);
  }
}

suite("the Helper's turn-end rule", () => {
  test("the known done reporters are the file's", () => {
    assert.deepEqual([...DONE_REPORTER_KINDS].sort(), [...vectors.doneReporters].sort());
  });

  for (const vector of vectors.cases) {
    test(vector.name, () => {
      const run = { state: new TurnState(), kind: vector.kind, count: 0, mark: null };
      for (const [index, step] of vector.steps.entries()) {
        const ended = apply(step, run);
        assert.equal(ended, step.ends, `step ${index} (${step.event}): ends`);
        assert.equal(run.state.isDoneFor(run.mark), step.done, `step ${index} (${step.event}): done`);
      }
    });
  }

  test("what it remembers comes back the same", () => {
    const state = new TurnState();
    state.noteStatus("working", 4, "aider");
    state.noteStatus("done", 4, "aider");
    const restored = TurnState.restore(JSON.parse(JSON.stringify(state.toJSON())));
    assert.deepEqual(restored.last, { turn: 5, word: "done" });
    assert.deepEqual(restored.ended, { turn: 5, word: "done" });
    assert.equal(restored.hasReportedDone, true);
  });

  test("memory it cannot read starts over", () => {
    assert.equal(TurnState.restore({ last: "nonsense", ended: 3 }).ended, null);
    assert.equal(TurnState.restore(null).last, null);
  });
});
