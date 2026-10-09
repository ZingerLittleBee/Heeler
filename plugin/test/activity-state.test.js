import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { DISPLAY_LIMIT } from "../src/display-text.js";
import {
  buildActivityState,
  conversationalSteps,
  eligibleStatusMap,
  hasNewlyBlocked,
  parsePinnedPaneIds,
  sameStatusMap,
  trackSince,
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

  test("carries the workspace label by workspace id and omits unavailable labels", () => {
    const { plaintextObject } = buildActivityState({
      agents: [
        agent("w1:p1", "working", { agent: "codex", workspace_id: "w1" }),
        agent("w2:p1", "blocked", { agent: "claude", workspace_id: "missing" }),
      ],
      hostName: "mbp",
      workspaceLabels: new Map([["w1", "Heeler"]]),
    });
    const byPane = Object.fromEntries(plaintextObject.agents.map((entry) => [entry.pane, entry]));
    assert.equal(byPane["w1:p1"].workspace, "Heeler");
    assert.equal("workspace" in byPane["w2:p1"], false);
    assert.deepEqual(Object.keys(byPane["w1:p1"]), ["kind", "pane", "status", "workspace"]);
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

suite("conversational rows in buildActivityState", () => {
  const AS_OF = Date.UTC(2026, 9, 9, 14, 31);
  const inventory = [
    agent("w1:p1", "working", { agent: "claude", name: "agent-a", workspace_id: "w1", terminal_title_stripped: "Refactor parser" }),
    agent("w1:p2", "idle", { agent: "claude" }),
  ];
  const labels = new Map([["w1", "Heeler"]]);

  test("layout mode is the default and ignores sinceByPane", () => {
    const { plaintextObject } = buildActivityState({ agents: inventory, hostName: "example-host", sinceByPane: { "w1:p1": AS_OF } });
    assert.equal(plaintextObject.agents[0].rows, undefined);
  });

  test("conversational mode builds rows from herdr fields, in the given zone, and reports the ladder", () => {
    const { counts, plaintextObject, ladder } = buildActivityState({
      agents: inventory, hostName: "example-host", workspaceLabels: labels, rowsMode: "conversational",
      sinceByPane: { "w1:p1": AS_OF - 120_000 }, asOfMs: AS_OF, timeZone: "UTC",
      rowLayout: { rows: [[{ token: "directory" }]] },
    });
    assert.deepEqual(counts, { working: 1, blocked: 0, done: 0 });
    assert.deepEqual(plaintextObject.agents[0].rows.map((row) => row.map((span) => span.text).join("")), [
      "agent-a · Heeler", "Refactor parser", "Working since 14:29 · updated 14:31 UTC",
    ]);
    assert.deepEqual(ladder, [{ status: "working", pinned: false, said: "title" }]);
  });

  test("title, name and workspace wire fields are cleaned in conversational mode only (T-H5)", () => {
    const hostile = [agent("w1:p1", "working", {
      agent: "claude", name: "agent\u202E-a", workspace_id: "w1", terminal_title_stripped: "\u202ERefactor\u0000 parser",
    })];
    const rlo = new Map([["w1", "\u202EHeeler"]]);
    const conversational = buildActivityState({ agents: hostile, hostName: "h", workspaceLabels: rlo, rowsMode: "conversational", timeZone: "UTC" });
    assert.doesNotMatch(JSON.stringify(conversational.plaintextObject), /\\u202e|\\u0000/i);
    assert.deepEqual(
      [conversational.plaintextObject.agents[0].title, conversational.plaintextObject.agents[0].name, conversational.plaintextObject.agents[0].workspace],
      ["Refactor parser", "agent-a", "Heeler"],
    );
    const layout = buildActivityState({ agents: hostile, hostName: "h", workspaceLabels: rlo });
    assert.equal(layout.plaintextObject.agents[0].name, "agent\u202E-a");
  });
});

suite("conversationalSteps (degrade ladder)", () => {
  const rows3 = (name) => [[{ text: name }], [{ text: `title of ${name}` }], [{ text: "state" }]];
  const wire = (pane, status) => ({ kind: "claude", name: pane, pane, rows: rows3(pane), status, title: `title of ${pane}` });
  const plaintext = {
    agents: [wire("w1:p1", "blocked"), wire("w1:p2", "done"), wire("w1:p3", "working"), wire("w1:p4", "working")],
    host: "example-host",
    v: 1,
  };
  const ladder = [
    { status: "blocked", pinned: false, said: "title" },
    { status: "done", pinned: false, said: "title" },
    { status: "working", pinned: true, said: "title" },
    { status: "working", pinned: false, said: "title" },
  ];
  const shape = (step) => step.agents.map((entry) => `${entry.pane}:${entry.rows.length}${"title" in entry ? "t" : ""}`).join(" ");

  test("removes one agent's row 2 per step, done first, then working (unpinned first), then blocked", () => {
    const steps = conversationalSteps(plaintext, ladder);
    assert.deepEqual(steps.slice(0, 5).map(shape), [
      "w1:p1:3t w1:p2:3t w1:p3:3t w1:p4:3t",
      "w1:p1:3t w1:p2:2t w1:p3:3t w1:p4:3t",
      "w1:p1:3t w1:p2:2t w1:p3:3t w1:p4:2t",
      "w1:p1:3t w1:p2:2t w1:p3:2t w1:p4:2t",
      "w1:p1:2t w1:p2:2t w1:p3:2t w1:p4:2t",
    ]);
  });

  test("then drops title and name, then whole agents lowest first keeping the blocked one, then identity only, then none", () => {
    const steps = conversationalSteps(plaintext, ladder);
    assert.deepEqual(steps.slice(5).map(shape), [
      "w1:p1:2 w1:p2:2 w1:p3:2 w1:p4:2",
      "w1:p1:2 w1:p3:2 w1:p4:2",
      "w1:p1:2 w1:p3:2",
      "w1:p1:2",
      "w1:p1:1",
      "",
    ]);
    assert.equal(steps.every((step) => step.host === "example-host" && step.v === 1), true);
  });

  test("an agent with no row 2 costs no step", () => {
    const two = { ...plaintext, agents: [{ ...wire("w1:p1", "working"), rows: [[{ text: "a" }], [{ text: "s" }]] }] };
    assert.equal(conversationalSteps(two, [{ status: "working", pinned: false, said: null }]).length, 4);
  });
});

suite("trackSince (state v2)", () => {
  const NOW = 1_000_000;
  const EPOCH = "11:22";
  const term = (pane, status, terminal, seq) => agent(pane, status, { terminal_id: terminal, state_change_seq: seq });
  const saved = (terminals, epoch = EPOCH) => ({ v: 2, epoch, terminals });

  test("no comparable saved state leaves every start unknown, never now", () => {
    const agents = [term("w1:p1", "working", "t1", 4)];
    for (const previous of [null, { statuses: { "w1:p1": "working" } }, saved({}, "other")]) {
      assert.equal(trackSince(previous, agents, NOW, EPOCH).sinceByPane["w1:p1"], null);
    }
    assert.equal(trackSince(saved({}), agents, NOW, null).sinceByPane["w1:p1"], null);
    assert.equal(trackSince(saved({}), agents, NOW, EPOCH).sinceByPane["w1:p1"], NOW);
  });

  test("an unchanged (status, seq) keeps its time, a change takes now, and the terminal id is the key", () => {
    const previous = saved({ t1: { status: "working", seq: 4, since_ms: 5 }, t2: { status: "working", seq: 7, since_ms: 6 } });
    const result = trackSince(previous, [term("w9:p9", "working", "t1", 4), term("w1:p2", "blocked", "t2", 8)], NOW, EPOCH);
    assert.deepEqual(result.sinceByPane, { "w9:p9": 5, "w1:p2": NOW });
    assert.deepEqual(result.terminals, { t1: { status: "working", seq: 4, since_ms: 5 }, t2: { status: "blocked", seq: 8, since_ms: NOW } });
    assert.equal(result.allRecorded, false);
  });

  test("blocked, working, blocked between two runs is a new pair, so since is the last block (T-H3 a)", () => {
    const previous = saved({ t1: { status: "blocked", seq: 2, since_ms: 5 } });
    assert.equal(trackSince(previous, [term("w1:p1", "blocked", "t1", 4)], NOW, EPOCH).sinceByPane["w1:p1"], NOW);
  });

  test("a restart (new epoch) and a seq regression clear every start to unknown (T-H3 c, d)", () => {
    const previous = saved({ t1: { status: "working", seq: 4, since_ms: 5 }, t2: { status: "working", seq: 9, since_ms: 6 } });
    const agents = [term("w1:p1", "working", "t1", 4), term("w1:p2", "working", "t2", 1)];
    assert.deepEqual(trackSince(previous, agents, NOW, EPOCH).sinceByPane, { "w1:p1": null, "w1:p2": null });
    assert.deepEqual(trackSince(previous, agents.slice(0, 1), NOW, "33:44").sinceByPane, { "w1:p1": null });
  });

  test("a terminal id reused by a new server with a lower seq resets to unknown", () => {
    const previous = saved({ t1: { status: "working", seq: 12, since_ms: 5 } });
    assert.equal(trackSince(previous, [term("w1:p1", "working", "t1", 0)], NOW, EPOCH).sinceByPane["w1:p1"], null);
  });

  test("an unknown start stays unknown while its pair is unchanged", () => {
    const previous = saved({ t1: { status: "working", seq: 4, since_ms: null } });
    const result = trackSince(previous, [term("w1:p1", "working", "t1", 4)], NOW, EPOCH);
    assert.equal(result.sinceByPane["w1:p1"], null);
    assert.equal(result.allRecorded, true);
  });

  test("an agent without terminal_id is unknown and not stored; ineligible agents are not tracked", () => {
    const result = trackSince(saved({}), [agent("w1:p1", "working"), term("w1:p2", "idle", "t2", 1)], NOW, EPOCH);
    assert.deepEqual(result, { terminals: {}, sinceByPane: { "w1:p1": null }, allRecorded: false });
  });
});
