// The Helper's Agent rule, read from the same vector the app's tests read, so the
// two cannot disagree about which Terminal is an Agent (ADR 0032).

import { suite, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { agentIn, REPORTED_APPS } from "../helper/core/agent-rule.js";
import { applyEvent } from "../helper/core/inventory.js";

const vectors = JSON.parse(readFileSync(new URL("../test-vectors/herdr-core-agent-rule-v1.json", import.meta.url), "utf8"));

/** The record as the Helper's inventory holds it after the case's `foreground` events. */
function recordOf(vector) {
  const inventory = new Map([[vector.record.address, vector.record]]);
  for (const data of vector.foregroundEvents ?? []) {
    applyEvent(inventory, { type: "foreground", terminal: vector.record.address, data });
  }
  return inventory.get(vector.record.address);
}

suite("the Helper's Agent rule", () => {
  test("the vector has its cases", () => {
    assert.ok(vectors.cases.length >= 100);
  });

  test("the app table is the file's", () => {
    assert.deepEqual(REPORTED_APPS, vectors.apps);
  });

  for (const vector of vectors.cases) {
    test(vector.name, () => {
      assert.deepEqual(agentIn(recordOf(vector)), vector.expected);
    });
  }
});
