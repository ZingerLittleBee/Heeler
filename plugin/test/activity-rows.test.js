import { test } from "node:test";
import assert from "node:assert/strict";
import { buildActivityState } from "../src/activity-state.js";
import { parseActivityRowLayout } from "../src/activity-rows.js";

const agent = {
  pane_id: "opaque:pane", workspace_id: "workspace", tab_id: "tab", agent: "claude",
  agent_status: "working", cwd: " /work/Heeler ", display_agent: "reviewer",
  terminal_title: "⠂ raw", terminal_title_stripped: "stripped", title: null,
  tokens: { task: "**plain text**", blank: "  " },
};
function render(rows, overrides = {}) {
  return buildActivityState({
    agents: [agent], hostName: "studio", rowHostName: "My Mac",
    workspaceLabels: new Map([["workspace", "Heeler"]]),
    tabs: new Map([["tab", { workspace_id: "workspace", label: "1", position: 1, count: 1 }]]),
    panes: new Map([["opaque:pane", { workspace_id: "workspace", tab_id: "tab", label: "shell" }]]),
    rowLayout: { rows: rows.map((row) => row.map((token) => typeof token === "string" ? { token } : token)) },
    ...overrides,
  }).plaintextObject.agents[0];
}

test("renders the three configured rows with styles, unstyled separators and no empty fields", () => {
  assert.deepEqual(render([
    ["state_icon", "workspace", "tab", { token: "agent", fg: "#AbC", bold: true, dim: false }],
    ["pane", "terminal_title", "terminal_title_stripped", "$task", "$blank", "$missing"],
    ["directory", "host", "status", "state_text"],
  ]).rows, [
    [{ text: "Heeler" }, { text: " · " }, { text: "reviewer", fg: "#AbC", bold: true, dim: false }],
    [{ text: "shell" }, { text: " · " }, { text: "⠂ raw" }, { text: " · " }, { text: "stripped" }, { text: " · " }, { text: "**plain text**" }],
    [{ text: "/work/Heeler" }, { text: " · " }, { text: "My Mac" }, { text: " · " }, { text: "Working" }],
  ]);
});

test("tab visibility matches Console and unrelated pane context is ignored", () => {
  assert.deepEqual(render([["tab"]]).rows, []);
  const tabs = new Map([["tab", { workspace_id: "workspace", label: "1", position: 1, count: 2 }]]);
  assert.deepEqual(render([["tab"]], { tabs }).rows, [[{ text: "1" }]]);
  tabs.get("tab").count = 1;
  tabs.get("tab").label = "review";
  assert.deepEqual(render([["tab"]], { tabs }).rows, [[{ text: "review" }]]);
  tabs.get("tab").workspace_id = "other";
  assert.deepEqual(render([["tab", "pane"]], { tabs, panes: new Map() }).rows, []);
});

test("pane empty title and stripped empty title do not fall back, unnamed agent uses raw kind", () => {
  assert.deepEqual(render([["pane", "terminal_title_stripped", "agent"]], {
    agents: [{ ...agent, title: "", terminal_title_stripped: "", display_agent: "", name: "" }],
  }).rows, [[{ text: "claude" }]]);
});

test("row values cap at 80 graphemes without splitting joined emoji", () => {
  const emoji = "👨‍👩‍👧‍👦";
  assert.equal(render([["directory"]], { agents: [{ ...agent, cwd: emoji.repeat(81) }] }).rows[0][0].text,
    emoji.repeat(80));
});

test("missing or malformed layout preserves legacy fallback; explicit empty layout stays empty", () => {
  for (const rowLayout of [undefined, null, {}, { rows: [null] }, { rows: [Array(17).fill({ token: "agent" })] },
    { rows: Array(4).fill([]) }, { rows: [[{ token: "unknown" }]] }, { rows: [[{ token: "agent", bold: 1 }]] },
    { rows: [[{ token: "agent", fg: "red" }]] }]) {
    assert.equal(parseActivityRowLayout(rowLayout), null);
    assert.equal("rows" in render([], { rowLayout }), false);
  }
  assert.deepEqual(render([]).rows, []);
});


test("field truncation preserves the first 80 graphemes without ellipsis or trailing-space trimming", () => {
  const text = "x".repeat(79) + " y";
  assert.equal(render([["$task"]], { agents: [{ ...agent, tokens: { task: text } }] }).rows[0][0].text,
    "x".repeat(79) + " ");
});

test("missing stripped title removes one activity glyph only at a whitespace boundary", () => {
  for (const [raw, expected] of [
    ["  ⠂ building  ", "building"],
    ["✳\tbuilding", "building"],
    ["◐\nbuilding", "building"],
    ["⠂building", "⠂building"],
    ["✳building", "✳building"],
    ["⠂ ⠂ building", "⠂ building"],
    ["plain title  ", "plain title"],
    ["⠂", null],
    [" · ", null],
  ]) {
    const rows = render([["terminal_title_stripped"]], {
      agents: [{ ...agent, terminal_title: raw, terminal_title_stripped: null }],
    }).rows;
    assert.deepEqual(rows, expected === null ? [] : [[{ text: expected }]], raw);
  }
  assert.deepEqual(render([["terminal_title_stripped"]], {
    agents: [{ ...agent, terminal_title: "⠂ building", terminal_title_stripped: "" }],
  }).rows, []);
});
