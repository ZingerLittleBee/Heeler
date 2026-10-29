import { expireLimitWindows } from "./codex-limits.js";
import { pricingVersion } from "./pricing.js";

export const zeroTokens = () => ({ input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0 });
export function addTokens(target, tokens, multiplier = 1) {
  for (const key of Object.keys(target)) target[key] += (tokens[key] || 0) * multiplier;
}
// Claude Code records carry their Account; Codex has only its Default one.
const scope = record => record.account === undefined ? [record.bucket, record.program] : [record.bucket, record.program, record.account];
export function contributionBucket(record) {
  return JSON.stringify([...scope(record), record.model]);
}
export function changeBucket(buckets, record, multiplier) {
  // Separate dimensions keep directory attribution out of the overall totals.
  for (const dimension of [{ model: record.model }, { directory: record.directory || "unknown" }]) {
    const key = "model" in dimension ? contributionBucket(record) : JSON.stringify([...scope(record), "directory", dimension.directory]);
    let bucket = buckets.get(key);
    if (!bucket) {
      bucket = { timestamp: record.bucket, program: record.program, ...(record.account === undefined ? {} : { account: record.account }),
        ...dimension, tokens: zeroTokens(), estimatedCostUSD: 0, unpricedTokens: 0 };
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
/** Token Usage over buckets already chosen for one program or Account. */
function tokenUsage(buckets, dates, dayInZone) {
  const daily = dates.map(date => ({ date, tokens: zeroTokens(), estimatedCostUSD: 0, unpricedTokens: 0 }));
  const byDay = new Map(daily.map(day => [day.date, day]));
  const models = new Map();
  const directories = new Map();
  let hasData = false;
  for (const bucket of buckets) {
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
  return hasData ? {
    state: "ok", totals: { today: sum(daily.slice(-1)), last7Days: sum(daily.slice(-7)), last30Days: sum(daily) }, daily: daily.map(pricedSummary),
    models: [...models.values()].sort((a, b) => b.tokens.total - a.tokens.total || a.model.localeCompare(b.model)).map(model => ({ ...pricedSummary(model), priced: model.unpricedTokens === 0 })),
    directories: [...directories.values()].sort((a, b) => b.tokens.total - a.tokens.total || a.path.localeCompare(b.path)).slice(0, 10).map(pricedSummary),
  } : { state: "noData" };
}
/**
 * The `usage` v1 report. `accounts` are Claude Code's Accounts as the Account
 * file names them now: an Account that just left adds nothing, even before
 * the next run removes its buckets. A bucket written before Accounts belongs
 * to the Default Account.
 */
export function reportFromSnapshot(snapshot, timeZone, refreshing, now = Date.now(), claudeLimits = false,
  { accounts, suggestions = [] }) {
  const dayInZone = calendarDays(timeZone);
  const today = dayInZone(now);
  const dates = Array.from({ length: 30 }, (_, index) => new Date(Date.parse(today + "T12:00:00Z") - (29 - index) * 86_400_000).toISOString().slice(0, 10));
  const errors = snapshot?.errors || {};
  const usage = (buckets, error) => error ? { state: "error", reason: error } : tokenUsage(buckets, dates, dayInZone);
  // Without a reading, limits are not read yet while a run will read them;
  // with no run (failures paused it, or none could start) that read failed.
  const limits = reading => expireLimitWindows(reading
    || (refreshing ? { state: "unavailable", reason: "notReadYet" } : { state: "error", reason: "requestFailed" }), now);
  const claudeLimitsOf = reading => claudeLimits ? limits(reading) : { state: "disabled" };
  const counted = new Map(accounts.filter(account => account.state === "ok").map(account => [account.id, []]));
  const codex = [];
  for (const bucket of snapshot?.buckets || []) {
    if (bucket.program === "claude") counted.get(bucket.account ?? "default")?.push(bucket);
    else if (bucket.program === "codex") codex.push(bucket);
  }
  // The program's error covers the Accounts its snapshot counted (before
  // Accounts, the Default one); an Account added since is not counted yet.
  const countedBefore = Array.isArray(snapshot?.countedAccounts) ? snapshot.countedAccounts : ["default"];
  const claude = { program: "claude", tokenUsage: usage([...counted.values()].flat(), errors.claude),
    usageLimits: claudeLimitsOf(snapshot?.usageLimits?.claude),
    accounts: accounts.map(({ id, isDefault, name, directory, state }) => state !== "ok" ? { id, isDefault, name, directory, state } : {
      id, isDefault, name, directory, state,
      tokenUsage: usage(counted.get(id), errors[`claude:${id}`] ?? (countedBefore.includes(id) ? errors.claude : undefined)),
      usageLimits: claudeLimitsOf(snapshot?.usageLimits?.claudeAccounts?.[id] ?? (isDefault ? snapshot?.usageLimits?.claude : undefined)),
    }),
    accountSuggestions: suggestions };
  const programs = [claude, { program: "codex", tokenUsage: usage(codex, errors.codex), usageLimits: limits(snapshot?.usageLimits?.codex) }];
  // Clamp the first recorded day into the requested 30-day calendar.
  const since = Number.isFinite(snapshot?.coveredSince) ? dayInZone(snapshot.coveredSince) : null;
  const covered = since === null ? null : since < dates[0] ? dates[0] : since > today ? today : since;
  return { version: 1, pricingVersion: snapshot?.pricingVersion || pricingVersion, generatedAt: new Date(now).toISOString(), timeZone, runtime: "recorded", refreshing,
    scan: { state: snapshot?.complete ? "complete" : "partial", coveredFrom: covered, coveredThrough: snapshot?.coveredThrough || null, skippedArchives: snapshot?.skippedArchives || 0,
      unreadableFiles: snapshot?.unreadableFiles || 0 }, programs };
}

function pricedSummary(summary) {
  return { ...summary, estimatedCostUSD: summary.tokens.total > 0 && summary.unpricedTokens === summary.tokens.total ? null : Math.max(0, summary.estimatedCostUSD) };
}
