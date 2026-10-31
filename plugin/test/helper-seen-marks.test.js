// A device's seen marks as the Helper reads them, from the vector the app's writer
// reproduces byte for byte (ADR 0033).

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { TurnState } from "../helper/core/turn-state.js";
import { parseSeenMarks, readSeenMark, removeSeenMarks, seenMarkFileName } from "../helper/notifications/seen-marks.js";
import { notificationKeyId } from "../helper/shared/notification-envelope.js";

const vectors = JSON.parse(readFileSync(new URL("../test-vectors/herdr-core-seen-mark-v1.json", import.meta.url), "utf8"));

let directory;

beforeEach(() => {
  directory = mkdtempSync(join(tmpdir(), "hh-seen-"));
});

afterEach(() => {
  rmSync(directory, { recursive: true, force: true });
});

suite("the Helper reads a device's seen marks", () => {
  for (const vector of vectors.files) {
    test(`reads ${vector.name}`, () => {
      const file = parseSeenMarks(vector.contents, vector.keyId);
      assert.equal(file.core, vector.core);
      assert.deepEqual(
        [...file.marks].map(([terminal, mark]) => ({ terminal, turn: mark.turn, ...(mark.word === null ? {} : { word: mark.word }) })),
        vector.marks,
      );
    });

    test(`names the file from the key id: ${vector.name}`, () => {
      assert.equal(notificationKeyId(Buffer.from(vector.key, "base64url")), vector.keyId);
      assert.equal(seenMarkFileName(vector.keyId), vector.fileName);
    });
  }

  for (const vector of vectors.unreadable) {
    test(`reads nothing from ${vector.name}`, () => {
      assert.equal(parseSeenMarks(vector.contents, vector.keyId), null);
    });
  }

  for (const vector of vectors.done) {
    test(`Done: ${vector.name}`, () => {
      const state = new TurnState();
      state.noteSnapshot(vector.ended.turn - 1, "working", "aider", true);
      state.noteStatus(vector.ended.word, vector.ended.turn - 1, "aider");
      assert.deepEqual(state.ended, vector.ended);
      assert.equal(state.isDoneFor(vector.mark), vector.done);
    });
  }

  test("a mark that does not read as one leaves its neighbors", () => {
    const file = parseSeenMarks(
      '{"core":"c1","device":"k","marks":[{"terminal":"t1","turn":"3"},{"turn":3},{"terminal":"t2","turn":4,"word":"done"}],"v":1}',
      "k",
    );
    assert.deepEqual([...file.marks], [["t2", { turn: 4, word: "done" }]]);
  });

  test("gives the mark of one Terminal of the core asked about", () => {
    const [vector] = vectors.files;
    writeFileSync(join(directory, vector.fileName), vector.contents);
    assert.deepEqual(readSeenMark(directory, vector.keyId, "c1", "t1"), { turn: 3, word: "done" });
    assert.equal(readSeenMark(directory, vector.keyId, "c1", "t9"), null);
  });

  test("a mark made for another core does not apply", () => {
    const [vector] = vectors.files;
    writeFileSync(join(directory, vector.fileName), vector.contents);
    assert.equal(readSeenMark(directory, vector.keyId, "another", "t1"), null);
  });

  test("a device with no file has no marks", () => {
    assert.equal(readSeenMark(directory, "Yw3NKWbEM2Y", "c1", "t1"), null);
  });

  test("a Terminal named like an object's own property has no mark", () => {
    const [vector] = vectors.files;
    writeFileSync(join(directory, vector.fileName), vector.contents);
    assert.equal(readSeenMark(directory, vector.keyId, "c1", "__proto__"), null);
  });

  test("removing a device's marks leaves another's", () => {
    const [first, second] = vectors.files;
    writeFileSync(join(directory, first.fileName), first.contents);
    writeFileSync(join(directory, second.fileName), second.contents);
    removeSeenMarks(directory, first.keyId);
    assert.equal(existsSync(join(directory, first.fileName)), false);
    assert.equal(existsSync(join(directory, second.fileName)), true);
    removeSeenMarks(directory, first.keyId);
  });
});
