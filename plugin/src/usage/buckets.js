import { expireLimitWindows } from "./codex-limits.js";
import { pricingVersion } from "./pricing.js";

export const zeroTokens = () => ({ input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0 });
export function addTokens(target, tokens, multiplier = 1) {
  for (const key of Object.keys(target)) target[key] += (tokens[key] || 0) * multiplier;
}
export function contributionBucket(record) {
  return JSON.stringify([record.bucket, record.program, record.model]);
}
export function changeBucket(buckets, record, multiplier) {
  // Separate dimensions keep directory attribution out of the overall totals.
  for (const dimension of [{ model: record.model }, { directory: record.directory || "unknown" }]) {
    const key = "model" in dimension ? contributionBucket(record)
      : JSON.stringify([record.bucket, record.program, "directory", dimension.directory]);
    let bucket = buckets.get(key);
    if (!bucket) {
      bucket = { timestamp: record.bucket, program: record.program, ...dimension, tokens: zeroTokens(), estimatedCostUSD: 0, unpricedTokens: 0 };
      buckets.set(key, bucket);
    }
    addTokens(bucket.tokens, record.tokens, multiplier);
    bucket.estimatedCostUSD += (record.estimatedCostUSD || 0) * multiplier;
    bucket.unpricedTokens += (record.unpricedTokens || 0) * multiplier;
    if (bucket.tokens.total === 0) buckets.delete(key);
  }
}
function calendarDays(timeZone) {
  const formatter = new Intl.DateTimeFormat("en", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  const dates = new Map();
  // Keep the formatter and timestamp cache local to one report: devices may
  // query the same snapshot in different time zones.
  return timestamp => {
    if (!dates.has(timestamp)) {
      const parts = Object.fromEntries(formatter.formatToParts(new Date(timestamp)).map(part => [part.type, part.value]));
      dates.set(timestamp, `${parts.year}-${parts.month}-${parts.day}`);
    }
    return dates.get(timestamp);
  };
}
export function reportFromSnapshot(snapshot, timeZone, refreshing, now = Date.now(), claudeLimits = false) {
  const dayInZone = calendarDays(timeZone);
  const today = dayInZone(now);
  const dates = Array.from({ length: 30 }, (_, index) => new Date(Date.parse(today + "T12:00:00Z") - (29 - index) * 86_400_000).toISOString().slice(0, 10));
  const programs = ["claude", "codex"].map(program => {
    const daily = dates.map(date => ({ date, tokens: zeroTokens(), estimatedCostUSD: 0, unpricedTokens: 0 }));
    const byDay = new Map(daily.map(day => [day.date, day]));
    const models = new Map();
    const directories = new Map();
    let hasData = false;
    for (const bucket of snapshot?.buckets || []) {
      if (bucket.program !== program) continue;
      const day = byDay.get(dayInZone(bucket.timestamp));
      if (!day) continue;
      const unpricedTokens = bucket.unpricedTokens ?? (typeof bucket.estimatedCostUSD === "number" ? 0 : bucket.tokens.total);
      const isDirectory = "directory" in bucket;
      const groups = isDirectory ? directories : models;
      const name = isDirectory ? bucket.directory : bucket.model;
      if (!groups.has(name)) groups.set(name, { ...(isDirectory ? { path: name } : { model: name }), tokens: zeroTokens(), estimatedCostUSD: 0, unpricedTokens: 0 });
      const group = groups.get(name);
      addTokens(group.tokens, bucket.tokens);
      group.estimatedCostUSD += bucket.estimatedCostUSD || 0;
      group.unpricedTokens += unpricedTokens;
      if (!isDirectory) {
        addTokens(day.tokens, bucket.tokens);
        day.estimatedCostUSD += bucket.estimatedCostUSD || 0;
        day.unpricedTokens += unpricedTokens;
        hasData = true;
      }
    }
    const sum = entries => {
      const total = { tokens: zeroTokens(), estimatedCostUSD: 0, unpricedTokens: 0 };
      for (const entry of entries) {
        addTokens(total.tokens, entry.tokens);
        total.estimatedCostUSD += entry.estimatedCostUSD || 0;
        total.unpricedTokens += entry.unpricedTokens || 0;
      }
      return pricedSummary(total);
    };
    return { program, tokenUsage: snapshot?.errors?.[program] ? { state: "error", reason: snapshot.errors[program] } : hasData ? {
      state: "ok", totals: { today: sum(daily.slice(-1)), last7Days: sum(daily.slice(-7)), last30Days: sum(daily) }, daily: daily.map(pricedSummary),
      models: [...models.values()].sort((a, b) => b.tokens.total - a.tokens.total || a.model.localeCompare(b.model)).map(model => ({ ...pricedSummary(model), priced: model.unpricedTokens === 0 })),
      directories: [...directories.values()].sort((a, b) => b.tokens.total - a.tokens.total || a.path.localeCompare(b.path)).slice(0, 10).map(pricedSummary),
    } : { state: "noData" }, usageLimits: program === "claude" ? (claudeLimits
      ? expireLimitWindows(snapshot?.usageLimits?.claude || { state: "unavailable", reason: "programMissing" }, now)
      : { state: "disabled" })
      : expireLimitWindows(snapshot?.usageLimits?.codex || { state: "unavailable", reason: "programMissing" }, now) };
  });
  let covered = null;
  for (const bucket of snapshot?.buckets || []) {
    const date = dayInZone(bucket.timestamp);
    if (date >= dates[0] && date <= today && (covered === null || date < covered)) covered = date;
  }
  return { version: 1, pricingVersion: snapshot?.pricingVersion || pricingVersion, generatedAt: new Date(now).toISOString(), timeZone, runtime: "recorded", refreshing,
    scan: { state: snapshot?.complete ? "complete" : "partial", coveredFrom: covered, coveredThrough: snapshot?.coveredThrough || null, skippedArchives: snapshot?.skippedArchives || 0 }, programs };
}

function pricedSummary(summary) {
  return { ...summary, estimatedCostUSD: summary.tokens.total > 0 && summary.unpricedTokens === summary.tokens.total ? null : Math.max(0, summary.estimatedCostUSD) };
}
