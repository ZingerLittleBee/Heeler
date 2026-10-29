import { test } from "node:test";
import assert from "node:assert/strict";
import { reportFromSnapshot } from "../src/usage/buckets.js";

const claude = { accounts: [{ id: "default", isDefault: true, name: null, directory: "/home/u/.claude", state: "ok" }] };

function snapshotFor(timestamps) {
  return { complete: true, coveredSince: Date.parse(timestamps[0]), buckets: timestamps.flatMap(timestamp =>
    ["claude", "codex"].flatMap(program =>
      [{ model: "model" }, { directory: "/project" }].map(dimension => ({
        timestamp, program, ...dimension,
        tokens: { input: 1, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 1 },
        estimatedCostUSD: 0.25, unpricedTokens: 0,
      })))) };
}

test("calendar conversion work scales with timestamps, not bucket dimensions", (t) => {
  const OriginalFormatter = Intl.DateTimeFormat;
  let formatters = 0;
  let conversions = 0;
  t.mock.method(Intl, "DateTimeFormat", class extends OriginalFormatter {
    constructor(...args) { super(...args); formatters++; }
    formatToParts(...args) { conversions++; return super.formatToParts(...args); }
  });
  const timestamps = ["2026-03-08T09:30:00Z", "2026-03-08T10:30:00Z"];
  const snapshot = snapshotFor(timestamps);
  // Multiple models/directories and both programs share each hourly timestamp;
  // only coverage and now add a conversion of their own.
  const report = reportFromSnapshot(snapshot, "America/Los_Angeles", false, Date.parse("2026-03-08T12:00:00Z"), false, claude);
  assert.equal(report.programs[0].tokenUsage.totals.today.tokens.total, 2);
  assert.equal(report.scan.coveredFrom, "2026-03-08");
  assert.equal(formatters, 1);
  assert.ok(conversions <= timestamps.length + 2, `${conversions} calendar conversions for two bucket timestamps, coverage and now`);
});

test("coverage is the first recorded day clamped to the calendar, with or without usage", () => {
  const now = Date.parse("2026-03-09T00:30:00Z");
  const report = coveredSince => reportFromSnapshot({ complete: true, buckets: [], coveredSince }, "UTC", false, now, false, claude);
  assert.equal(report(Date.parse("2026-03-01T23:00:00Z")).scan.coveredFrom, "2026-03-01");
  assert.equal(report(Date.parse("2026-03-01T23:00:00Z")).programs[0].tokenUsage.state, "noData");
  assert.equal(report(Date.parse("2025-12-01T00:00:00Z")).scan.coveredFrom, "2026-02-08");
  assert.equal(report(Date.parse("2026-03-10T00:00:00Z")).scan.coveredFrom, "2026-03-09");
  assert.equal(report(undefined).scan.coveredFrom, null);
});

test("daily totals and coverage honor DST and remain isolated between query time zones", () => {
  const snapshot = snapshotFor([
    "2026-03-08T07:30:00Z", // Previous day in Los Angeles.
    "2026-03-08T09:30:00Z", // Before the spring-forward gap.
    "2026-03-08T10:30:00Z", // After the spring-forward gap.
    "2026-03-08T20:00:00Z", // Next day in Kolkata.
    "2026-03-09T00:15:00Z",
  ]);
  for (const [zone, expected] of [
    ["America/Los_Angeles", { "2026-03-07": 1, "2026-03-08": 4 }],
    ["UTC", { "2026-03-08": 4, "2026-03-09": 1 }],
    ["Asia/Kolkata", { "2026-03-08": 3, "2026-03-09": 2 }],
    ["America/Los_Angeles", { "2026-03-07": 1, "2026-03-08": 4 }],
  ]) {
    const report = reportFromSnapshot(snapshot, zone, false, Date.parse("2026-03-09T00:30:00Z"), false, claude);
    assert.equal(report.scan.coveredFrom, Object.keys(expected)[0]);
    for (const { tokenUsage } of report.programs) {
      assert.deepEqual(Object.fromEntries(tokenUsage.daily.filter(day => day.tokens.total)
        .map(day => [day.date, day.tokens.total])), expected);
      assert.equal(tokenUsage.totals.today.tokens.total, Object.values(expected).at(-1));
      assert.equal(tokenUsage.totals.last30Days.tokens.total, 5);
      assert.equal(tokenUsage.totals.last30Days.estimatedCostUSD, 1.25);
      assert.equal(tokenUsage.models[0].tokens.total, 5);
      assert.equal(tokenUsage.directories[0].tokens.total, 5);
    }
  }
});
