import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { DISPLAY_LIMIT } from "../src/display-text.js";
import {
  buildActivityState,
  eligibleStatusMap,
  hasNewlyBlocked,
  parsePinnedPaneIds,
  sameStatusMap,
} from "../src/activity-state.js";

function agent(pane, status, extra = {}) {
  return { pane_id: pane, agent_status: status, ...extra };
}

suite("buildActivityState", () => {
  test("sorts blocked > done > working and tie-breaks by pane ascending", () => {
    const { counts, plaintextObject } = buildActivityState({
      agents: [
        agent("w1:p1", "working", { agent: "claude", terminal_title_stripped: "refactor" }),
        agent("w1:p9", "blocked", { agent: "codex" }),
        agent("w1:p2", "blocked", { agent: "claude", terminal_title_stripped: "review" }),
        agent("w2:p1", "done", { agent: "droid", terminal_title_stripped: "copy" }),
        agent("w3:p4", "working", { agent: "grok", terminal_title_stripped: "research" }),
        agent("w9:p1", "idle", { agent: "claude" }),
        agent("w9:p2", "unknown", { agent: "claude" }),
      ],
      hostName: "studio",
    });

    assert.deepEqual(counts, { working: 2, blocked: 2, done: 1 });
    assert.deepEqual(
      plaintextObject.agents.map((entry) => `${entry.status}:${entry.pane}`),
      ["blocked:w1:p2", "blocked:w1:p9", "done:w2:p1", "working:w1:p1", "working:w3:p4"],
    );
    assert.equal(plaintextObject.host, "studio");
    assert.equal(plaintextObject.v, 1);
  });

  test("caps the agents array at 5 while counts cover the full inventory", () => {
    const agents = [
      agent("w1:p1", "blocked", { agent: "a" }),
      agent("w1:p2", "blocked", { agent: "b" }),
      agent("w1:p3", "done", { agent: "c" }),
      agent("w1:p4", "done", { agent: "d" }),
      agent("w1:p5", "working", { agent: "e" }),
      agent("w1:p6", "working", { agent: "f" }),
    ];
    const { counts, plaintextObject } = buildActivityState({ agents, hostName: "mbp" });
    assert.deepEqual(counts, { working: 2, blocked: 2, done: 2 });
    assert.equal(plaintextObject.agents.length, 5);
    assert.deepEqual(
      plaintextObject.agents.map((entry) => entry.pane),
      ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5"],
    );
  });

  test("trims titles at the 80-grapheme CJK boundary and omits empty titles", () => {
    const eighty = "屏".repeat(DISPLAY_LIMIT);
    const over = "屏".repeat(DISPLAY_LIMIT + 1);
    const { plaintextObject } = buildActivityState({
      agents: [
        agent("w1:p1", "working", {
          agent: "claude",
          terminal_title: `⠂ ${eighty}`,
          terminal_title_stripped: eighty,
        }),
        agent("w1:p2", "done", {
          agent: "codex",
          terminal_title: over,
          terminal_title_stripped: over,
        }),
        agent("w1:p3", "blocked", { agent: "grok" }),
      ],
      hostName: "mbp",
    });
    const byPane = Object.fromEntries(plaintextObject.agents.map((entry) => [entry.pane, entry]));
    assert.equal(byPane["w1:p1"].title, eighty);
    assert.equal([...byPane["w1:p1"].title].length, DISPLAY_LIMIT);
    assert.equal([...byPane["w1:p2"].title].length, DISPLAY_LIMIT);
    assert.ok(byPane["w1:p2"].title.endsWith("…"));
    assert.equal("title" in byPane["w1:p3"], false);
  });

  test("carries the herdr agent name, preferring display_agent, omitting it when unnamed", () => {
    const { plaintextObject } = buildActivityState({
      agents: [
        agent("w1:p1", "working", { agent: "grok", name: "la-demo" }),
        agent("w1:p2", "blocked", { agent: "codex", name: "reviewer", display_agent: "rev" }),
        agent("w1:p3", "done", { agent: "claude", name: "" }),
      ],
      hostName: "mbp",
    });
    const byPane = Object.fromEntries(plaintextObject.agents.map((entry) => [entry.pane, entry]));
    assert.equal(byPane["w1:p1"].name, "la-demo");
    assert.equal(byPane["w1:p2"].name, "rev");
    assert.equal("name" in byPane["w1:p3"], false);
    assert.deepEqual(Object.keys(byPane["w1:p1"]), ["kind", "name", "pane", "status"]);
  });

  test("prefers the stripped title, falls kind back to unknown, and trims host", () => {
    const longHost = "h".repeat(DISPLAY_LIMIT + 5);
    const { plaintextObject } = buildActivityState({
      agents: [
        agent("wV:p1", "working", {
          terminal_title: "raw with glyphs",
          terminal_title_stripped: "stripped title",
        }),
      ],
      hostName: longHost,
    });
    assert.equal(plaintextObject.agents[0].kind, "unknown");
    assert.equal(plaintextObject.agents[0].title, "stripped title");
    assert.equal([...plaintextObject.host].length, DISPLAY_LIMIT);
    assert.ok(plaintextObject.host.endsWith("…"));
  });

  test("empty eligible inventory yields zero counts and no agents", () => {
    const { counts, plaintextObject } = buildActivityState({
      agents: [agent("w1:p1", "idle"), agent("w1:p2", "unknown")],
      hostName: "mbp",
    });
    assert.deepEqual(counts, { working: 0, blocked: 0, done: 0 });
    assert.deepEqual(plaintextObject, { agents: [], host: "mbp", v: 1 });
  });
});

const MIXED_ELIGIBLE = [
  agent("w1:p1", "working", { agent: "claude" }),
  agent("w1:p9", "blocked", { agent: "codex" }),
  agent("w1:p2", "blocked", { agent: "claude" }),
  agent("w2:p1", "done", { agent: "droid" }),
  agent("w3:p4", "working", { agent: "grok" }),
  agent("w9:p1", "idle", { agent: "claude" }),
  agent("w9:p2", "unknown", { agent: "claude" }),
];
const STATUS_THEN_PANE_ORDER = [
  "blocked:w1:p2",
  "blocked:w1:p9",
  "done:w2:p1",
  "working:w1:p1",
  "working:w3:p4",
];

function rankedPanes(plaintextObject) {
  return plaintextObject.agents.map((entry) => `${entry.status}:${entry.pane}`);
}

suite("buildActivityState pin ordering", () => {
  test("pins float first in recency order, then the existing status rank", () => {
    const { counts, plaintextObject } = buildActivityState({
      agents: MIXED_ELIGIBLE,
      hostName: "studio",
      pinnedPaneIds: ["w3:p4", "w1:p2"],
    });
    assert.deepEqual(counts, { working: 2, blocked: 2, done: 1 });
    assert.deepEqual(rankedPanes(plaintextObject), [
      "working:w3:p4",
      "blocked:w1:p2",
      "blocked:w1:p9",
      "done:w2:p1",
      "working:w1:p1",
    ]);
  });

  test("an ineligible pinned agent is ignored", () => {
    const { counts, plaintextObject } = buildActivityState({
      agents: MIXED_ELIGIBLE,
      hostName: "studio",
      pinnedPaneIds: ["w9:p1", "w3:p4"],
    });
    assert.deepEqual(counts, { working: 2, blocked: 2, done: 1 });
    assert.deepEqual(rankedPanes(plaintextObject), [
      "working:w3:p4",
      "blocked:w1:p2",
      "blocked:w1:p9",
      "done:w2:p1",
      "working:w1:p1",
    ]);
  });

  test("unknown pane ids in the pin set are ignored", () => {
    const { counts, plaintextObject } = buildActivityState({
      agents: MIXED_ELIGIBLE,
      hostName: "studio",
      pinnedPaneIds: ["nope", "w1:p1", "also-missing"],
    });
    assert.deepEqual(counts, { working: 2, blocked: 2, done: 1 });
    assert.deepEqual(rankedPanes(plaintextObject), [
      "working:w1:p1",
      "blocked:w1:p2",
      "blocked:w1:p9",
      "done:w2:p1",
      "working:w3:p4",
    ]);
  });

  test("a missing or malformed pin set keeps today's ordering", () => {
    const expected = buildActivityState({
      agents: MIXED_ELIGIBLE,
      hostName: "studio",
    });
    assert.deepEqual(rankedPanes(expected.plaintextObject), STATUS_THEN_PANE_ORDER);

    for (const pinnedPaneIds of [undefined, null, [], "w1:p1", 1, { 0: "w3:p4" }, [1, "w3:p4"], ["w3:p4", null]]) {
      const { counts, plaintextObject } = buildActivityState({
        agents: MIXED_ELIGIBLE,
        hostName: "studio",
        pinnedPaneIds,
      });
      assert.deepEqual(counts, expected.counts, pinnedPaneIds);
      assert.deepEqual(rankedPanes(plaintextObject), STATUS_THEN_PANE_ORDER, pinnedPaneIds);
    }
  });

  test("the agent cap still applies when more than five agents are pinned", () => {
    const agents = [
      agent("w1:p1", "blocked", { agent: "a" }),
      agent("w1:p2", "blocked", { agent: "b" }),
      agent("w1:p3", "done", { agent: "c" }),
      agent("w1:p4", "done", { agent: "d" }),
      agent("w1:p5", "working", { agent: "e" }),
      agent("w1:p6", "working", { agent: "f" }),
    ];
    const { counts, plaintextObject } = buildActivityState({
      agents,
      hostName: "mbp",
      pinnedPaneIds: ["w1:p6", "w1:p5", "w1:p4", "w1:p3", "w1:p2", "w1:p1"],
    });
    assert.deepEqual(counts, { working: 2, blocked: 2, done: 2 });
    assert.equal(plaintextObject.agents.length, 5);
    assert.deepEqual(
      plaintextObject.agents.map((entry) => entry.pane),
      ["w1:p6", "w1:p5", "w1:p4", "w1:p3", "w1:p2"],
    );
  });
});

suite("parsePinnedPaneIds", () => {
  test("returns a string array as-is", () => {
    assert.deepEqual(parsePinnedPaneIds(["w3:p4", "w1:p2"]), ["w3:p4", "w1:p2"]);
    assert.deepEqual(parsePinnedPaneIds([]), []);
  });

  test("treats missing, null, non-array, or mixed entries as empty", () => {
    for (const value of [undefined, null, "w1:p1", 1, { 0: "w3:p4" }, [1, "w3:p4"], ["w3:p4", null]]) {
      assert.deepEqual(parsePinnedPaneIds(value), [], value);
    }
  });
});

suite("eligible status helpers", () => {
  test("eligibleStatusMap ignores idle panes and lowercases statuses", () => {
    assert.deepEqual(
      eligibleStatusMap([
        agent("w1:p1", "Working"),
        agent("w1:p2", "idle"),
        agent("w1:p3", "BLOCKED"),
      ]),
      { "w1:p1": "working", "w1:p3": "blocked" },
    );
  });

  test("sameStatusMap compares pane-to-status maps", () => {
    assert.equal(sameStatusMap({ a: "working" }, { a: "working" }), true);
    assert.equal(sameStatusMap({ a: "working" }, { a: "done" }), false);
    assert.equal(sameStatusMap({ a: "working" }, { a: "working", b: "done" }), false);
  });

  test("hasNewlyBlocked treats a missing previous map as empty", () => {
    assert.equal(hasNewlyBlocked({ a: "blocked" }, null), true);
    assert.equal(hasNewlyBlocked({ a: "blocked" }, { a: "blocked" }), false);
    assert.equal(hasNewlyBlocked({ a: "blocked", b: "working" }, { a: "working" }), true);
    assert.equal(hasNewlyBlocked({ a: "working" }, { a: "blocked" }), false);
  });
});
