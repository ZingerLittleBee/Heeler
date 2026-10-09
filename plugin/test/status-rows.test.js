import { test, suite } from "node:test";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

import { canonicalActivityPlaintext } from "../src/activity-envelope.js";
import {
  ROW_LIMIT,
  cleanText,
  clipRow,
  conversationalRows,
  displayTimeZone,
  freshness,
  workingTitle,
} from "../src/status-rows.js";

const SEGMENTER = new Intl.Segmenter("en", { granularity: "grapheme" });
const count = (text) => [...SEGMENTER.segment(text)].length;
const rowText = (row) => row.map((span) => span.text).join("");

// 2026-10-09T14:31:00Z and two minutes earlier.
const AS_OF = Date.UTC(2026, 9, 9, 14, 31);
const SINCE = Date.UTC(2026, 9, 9, 14, 29);
const FAMILY = "👨‍👩‍👧‍👦";
const FLAG = "🇯🇵";
const E_ACUTE = "é";

function build(agent, status, extra = {}) {
  return conversationalRows({
    agent, status, workspace: "Heeler", sinceMs: SINCE, asOfMs: AS_OF, timeZone: "UTC", ...extra,
  });
}

suite("cleanText", () => {
  test("drops controls, bidi overrides and separators, keeps joiners, collapses whitespace", () => {
    assert.equal(cleanText(" a\tb\n\nc‮d⁦e\u0000f\u001b[31m g h  i "), "a b cdef[31m gh i");
    assert.equal(cleanText(FAMILY), FAMILY);
  });

  test("lone surrogates and Hangul filler characters are removed (T-H12)", () => {
    assert.equal(cleanText("a\uD800b\uDC00c"), "abc");
    assert.equal(cleanText("xᅟᅠㅤﾠy"), "xy");
    assert.equal(cleanText("ㅤ"), "");
  });

  test("characters herdr does not strip are removed here: zero width, word joiner, BOM, soft hyphen, U+2028/9", () => {
    assert.equal(cleanText("a​b⁠c﻿d­e f g"), "abcdefg");
  });

  test("non-strings are empty", () => {
    for (const value of [undefined, null, 3, {}, []]) assert.equal(cleanText(value), "");
  });
});

suite("clipRow graphemes", () => {
  test("exactly 80 graphemes pass through unchanged, 81 are cut to 80 ending in an ellipsis", () => {
    const exact = clipRow([{ text: "a".repeat(80) }]);
    assert.equal(rowText(exact), "a".repeat(80));
    const over = clipRow([{ text: "a".repeat(81) }]);
    assert.equal(rowText(over), `${"a".repeat(79)}…`);
    assert.equal(count(rowText(over)), 80);
  });

  test("a multi-codepoint grapheme is never split", () => {
    for (const unit of [FAMILY, FLAG, E_ACUTE]) {
      const text = rowText(clipRow([{ text: unit.repeat(90) }]));
      assert.equal(text, `${unit.repeat(79)}…`);
    }
  });

  test("the limit is shared across spans and a cut separator is not left dangling", () => {
    const parts = [{ text: "a".repeat(78) }, { text: " · ", sep: true }, { text: "b".repeat(10) }];
    const row = clipRow(parts);
    assert.equal(rowText(row), `${"a".repeat(78)}…`);
    assert.equal(row.some((span) => "sep" in span || "index" in span), false);
  });

  test("clean-then-clip never ends in a doubled ellipsis or a dangling joiner (T-H12)", () => {
    assert.equal(rowText(clipRow([{ text: `${"a".repeat(78)}……tail` }])), `${"a".repeat(78)}…`);
    assert.equal(rowText(clipRow([{ text: `${"a".repeat(78)}‍${"b".repeat(5)}` }])).includes("‍…"), false);
    assert.equal(rowText(clipRow([{ text: "x".repeat(40) }], 40)), "x".repeat(40));
    assert.equal(rowText(clipRow(clipRow([{ text: "y".repeat(60) }], 40), 20)), `${"y".repeat(19)}…`);
  });

  test("styles survive on kept spans and an empty row stays empty", () => {
    assert.deepEqual(clipRow([{ text: "Working", bold: true }]), [{ text: "Working", bold: true }]);
    assert.deepEqual(clipRow([]), []);
  });
});

suite("workingTitle", () => {
  test("uses the stripped title", () => {
    assert.equal(workingTitle({ terminal_title_stripped: "Fix the login flow", terminal_title: "◐ Fix the login flow" }), "Fix the login flow");
  });

  test("an absent or blank stripped title falls back to the raw one minus a leading activity glyph", () => {
    assert.equal(workingTitle({ terminal_title: "⠋ Write tests" }), "Write tests");
    assert.equal(workingTitle({ terminal_title_stripped: " ", terminal_title: "✳ Write tests" }), "Write tests");
    assert.equal(workingTitle({ terminal_title: "◐" }), null);
    assert.equal(workingTitle({}), null);
  });
});

suite("row 3 time grammar (T-H2)", () => {
  // 2026-10-09 19:31 UTC with `since` 33 hours earlier.
  const asOf = Date.UTC(2026, 9, 9, 19, 31);
  const since = asOf - 33 * 3_600_000;
  const expected = {
    "America/Chicago": ["Oct 8 05:31", "updated 14:31 CDT"],
    "Asia/Kolkata": ["Oct 8 16:01", "updated 01:01 GMT+5:30"],
    UTC: ["Oct 8 10:31", "updated 19:31 UTC"],
    "Europe/London": ["Oct 8 11:31", "updated 20:31 GMT+1"],
    "America/Sao_Paulo": ["Oct 8 07:31", "updated 16:31 GMT-3"],
    "Asia/Kathmandu": ["Oct 8 16:16", "updated 01:16 GMT+5:45"],
  };

  for (const [zone, [startText, updatedText]] of Object.entries(expected)) {
    test(`zone label and date in ${zone}`, () => {
      assert.deepEqual(freshness(since, asOf, zone), { start: startText, updated: updatedText });
      assert.doesNotMatch(freshness(asOf - 60_000, asOf, zone).start, /Oct|GMT|C[DS]T|UTC/);
    });
  }

  test("across midnight the earlier day is named", () => {
    const after = Date.UTC(2026, 9, 10, 0, 5);
    assert.deepEqual(freshness(after - 10 * 60_000, after, "UTC"), { start: "Oct 9 23:55", updated: "updated 00:05 UTC" });
  });

  test("a DST fall-back pair repeats the zone on since, never a negative age", () => {
    const rows = freshness(Date.UTC(2026, 10, 1, 6, 30), Date.UTC(2026, 10, 1, 7, 10), "America/Chicago");
    assert.deepEqual(rows, { start: "01:30 CDT", updated: "updated 01:10 CST" });
  });

  test("an unknown start is left out of row 3, never shown as unknown", () => {
    assert.equal(freshness(null, AS_OF, "UTC").start, null);
    assert.equal(rowText(build({ agent: "claude" }, "working", { sinceMs: null }).at(-1)), "Working · updated 14:31 UTC");
  });

  test("an unknown activity_time_zone falls back to the host zone", () => {
    assert.equal(displayTimeZone("Not/AZone"), displayTimeZone(null));
    assert.equal(displayTimeZone("UTC"), "UTC");
  });

  test("row 3 stays within 80 graphemes for every state, zone and date", () => {
    const zones = [...Object.keys(expected), "Australia/Adelaide", "Pacific/Chatham", "America/St_Johns"];
    for (const status of ["working", "blocked", "done"]) {
      for (const zone of zones) {
        for (const start of [null, AS_OF - 60_000, AS_OF - 40 * 3_600_000, Date.UTC(2026, 9, 18, 5, 31)]) {
          const rows = build({ agent: "claude" }, status, { timeZone: zone, sinceMs: start, asOfMs: AS_OF });
          const row3 = rowText(rows.at(-1));
          assert.ok(count(row3) <= ROW_LIMIT, row3);
          assert.equal(row3.endsWith("…"), false, row3);
        }
      }
    }
  });
});

suite("conversationalRows", () => {
  const working = { agent: "claude", name: "agent-a", agent_status: "working", terminal_title_stripped: "Refactor parser" };

  test("a working agent shows identity, its terminal title, and state with zoned times", () => {
    assert.deepEqual(build(working, "working"), [
      [{ text: "agent-a", bold: true }, { text: " · " }, { text: "Heeler" }],
      [{ text: "Refactor parser" }],
      [{ text: "Working", bold: true }, { text: " since 14:29", dim: true }, { text: " · " },
        { text: "updated 14:31 UTC", dim: true }],
    ]);
  });

  test("blocked shows the title and nothing about a question (no question path in this version)", () => {
    const programStatus = { records: [{ state: "blocked", current_generation: true, msg: "Allow?" }] };
    const rows = build({ ...working, agent_status: "blocked", program_status: programStatus }, "blocked");
    assert.equal(rowText(rows[1]), "Refactor parser");
    assert.equal(rowText(rows[2]), "Blocked since 14:29 · updated 14:31 UTC");
    assert.doesNotMatch(JSON.stringify(rows), /Allow|question/i);
  });

  test("with no title there are two rows and nothing is invented", () => {
    assert.equal(build({ agent: "claude" }, "blocked").length, 2);
  });

  test("done says the turn ended", () => {
    assert.equal(rowText(build(working, "done")[2]), "Turn ended at 14:29 · updated 14:31 UTC");
  });

  test("display_agent wins over name, then name over kind, then unknown", () => {
    assert.equal(rowText(build({ display_agent: "Reviewer", name: "agent-a", agent: "claude" }, "working", { workspace: null })[0]), "Reviewer");
    assert.equal(rowText(build({ name: "agent-a", agent: "claude" }, "working", { workspace: null })[0]), "agent-a");
    assert.equal(rowText(build({ agent: "claude" }, "working", { workspace: null })[0]), "claude");
    assert.equal(rowText(build({}, "working", { workspace: null })[0]), "unknown");
  });

  test("an agent kind of __proto__ or constructor is plain text (T-H11)", () => {
    for (const kind of ["__proto__", "constructor", "toString"]) {
      const rows = build({ agent: kind }, "working", { workspace: null });
      assert.equal(rowText(rows[0]), kind);
      assert.match(rowText(rows.at(-1)), /^Working since 14:29 · updated /);
    }
  });

  test("no U+202E survives in any row and the workspace label is cleaned before it is clipped (T-H5)", () => {
    const workspace = `‮${"w".repeat(79)}‬tail`;
    const rows = build({ ...working, name: "agent‮-a", terminal_title_stripped: "‮title" }, "working", { workspace });
    assert.doesNotMatch(JSON.stringify(rows), /‮|‬/);
    assert.equal(rows[0][0].text, "agent-a");
    assert.equal(rows[0].at(-1).text, `${"w".repeat(69)}…`);
  });

  test("never more than three rows, none empty, none over 80 graphemes, no colour", () => {
    for (const status of ["working", "blocked", "done"]) {
      const agent = { ...working, display_agent: FAMILY.repeat(90), terminal_title_stripped: FLAG.repeat(100) };
      const rows = build(agent, status, { workspace: E_ACUTE.repeat(100) });
      assert.ok(rows.length <= 3);
      for (const row of rows) {
        assert.ok(row.length > 0);
        assert.ok(count(rowText(row)) <= ROW_LIMIT);
        assert.equal(row.some((span) => "fg" in span), false);
      }
    }
  });

  test("hostile text survives the canonical JSON round trip as inert plain text", () => {
    const nasty = 'say "hi" \\ </script> **bold** [x](https://e.test) `code` \u{1F600} ‮evil‬ \u0000 \u001b[31mred';
    const rows = build({ ...working, terminal_title_stripped: nasty }, "working", { workspace: nasty });
    const wire = canonicalActivityPlaintext({
      agents: [{ kind: "claude", pane: "w1:p1", rows, status: "working" }], host: "example-host", v: 1,
    });
    const back = JSON.parse(wire).agents[0].rows;
    assert.deepEqual(back, rows);
    for (const span of back.flat()) assert.doesNotMatch(span.text, /[\u0000-\u001f\u007f‪-‮⁦-⁩]/u);
    assert.match(rowText(back[1]), /\*\*bold\*\* \[x\]\(https:\/\/e\.test\) `code`/);
  });
});

suite("shared vectors (conversational rows)", () => {
  const file = JSON.parse(readFileSync(new URL("../test-vectors/live-activity-content-v1.json", import.meta.url), "utf8"));
  const cases = file.valid.filter((vector) => vector.conversational);

  test("the vector file carries the conversational cases", () => {
    assert.ok(cases.length >= 3);
  });

  for (const vector of cases) {
    test(`herdr input builds the vector's rows: ${vector.name}`, () => {
      assert.equal(vector.conversational.agents.length, vector.payload.agents.length);
      vector.conversational.agents.forEach((input, index) => {
        const rows = conversationalRows({
          agent: input.agent, status: input.status, workspace: input.workspace,
          sinceMs: input.sinceMs, asOfMs: input.asOfMs, timeZone: vector.conversational.timeZone,
        });
        assert.deepEqual(rows, vector.payload.agents[index].rows);
      });
    });
  }
});
