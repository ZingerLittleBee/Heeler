import { parseArgs } from "node:util";
import { lstatSync, mkdirSync, readdirSync, rmSync, statSync } from "node:fs";
import { join, sep } from "node:path";
import { setPriority } from "node:os";
import { readUsageRuntime } from "./runtime-record.js";
import { cacheDirectory, readJSON, writeJSON, releaseWorker, activeLock, recordFailure, clearFailures, RETENTION } from "./cache.js";
import { claudeFiles, transcriptEntries, claudeContribution } from "./claude-scanner.js";
import { loadCheckpoint, startLog, openLog, saveCheckpoint, matchFiles, removeAbandonedTemporaries } from "./checkpoint.js";
import { changeBucket } from "./buckets.js";
import { priceContribution, pricingVersion } from "./pricing.js";
import { codexFiles, codexLines, ArchiveUnavailableError } from "./codex-files.js";
import { createCodexState, consumeCodexLine, finishCodexRead, codexTotalSignature } from "./codex-scanner.js";
import { readCodexLimits, codexRolloutLimits, codexLimitsWithFallback, codexAccountRuntime, codexLimitsEntries, nextCodexRead } from "./codex-limits.js";
import { readClaudeLimits, cacheClaudeLimits, claudeVersion, accountRuntime, claudeLimitsEntries, nextClaudeRead } from "./claude-limits.js";
import { readClaudeAccounts, readProgramAccounts } from "./accounts.js";
import { homeCandidates } from "./account-suggestions.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
class LockLostError extends Error {}
/** The cache or lock could not be written: the run fails, unlike one unreadable Transcript. */
class CacheWriteError extends Error {}
const cacheWrite = write => {
  try { return write(); } catch (error) { throw new CacheWriteError("Could not write the usage cache.", { cause: error }); }
};
/** Transcripts are append-only, so the first timestamped line is the earliest. */
function noteFirstRecord(state, line) {
  if (Number.isFinite(state.firstAt) || typeof line?.timestamp !== "string") return;
  const timestamp = Date.parse(line.timestamp);
  if (Number.isFinite(timestamp)) state.firstAt = timestamp;
}
const runFailure = error => error instanceof LockLostError || error instanceof CacheWriteError;
/** A cache's last write: its snapshot, or, before a first commit, its newest entry. */
function lastWritten(directory) {
  try { return statSync(join(directory, "buckets.json")).mtimeMs; }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  let newest = lstatSync(directory).mtimeMs;
  for (const name of readdirSync(directory)) newest = Math.max(newest, lstatSync(join(directory, name)).mtimeMs);
  return newest;
}
/**
 * One worker run, from its command line. `--config` holds the runtime record, and
 * `--accounts` the Account file when that sits elsewhere. `readClaudeLimitsElsewhere`,
 * when given, reads an Account's limits in a session that can; null asks to read in place.
 */
export async function runUsageWorker({ readClaudeLimitsElsewhere = null } = {}) {
  const { values } = parseArgs({ options: { config: { type: "string" }, accounts: { type: "string" }, "lock-token": { type: "string" }, "claude-limits": { type: "boolean", default: false } } });
  try { setPriority(10); } catch { /* Lower priority is best effort on the Host. */ }
  const runtime = readUsageRuntime(values.config);
  if (!runtime) return;
  const directory = cacheDirectory(runtime);
  const lockPath = join(directory, "worker.lock");
  let lock;
  for (let i = 0; i < 100; i++) {
    lock = readJSON(lockPath);
    if (lock?.token !== values["lock-token"]) return;
    if (lock.pid === process.pid) break;
    await sleep(10);
  }
  if (lock?.pid !== process.pid) return;
  const heartbeat = () => {
    if (readJSON(lockPath)?.token !== lock.token) throw new LockLostError("worker lock lost");
    lock.heartbeat = Date.now();
    cacheWrite(() => writeJSON(lockPath, lock));
  };
  try {
    const now = Date.now();
    const cutoff = now - RETENTION;
    // Only directories are caches; the programs' agents files sit beside them.
    for (const entry of readdirSync(join(runtime.stateDir, "usage"), { withFileTypes: true })) {
      const sibling = join(runtime.stateDir, "usage", entry.name);
      if (sibling === directory || !entry.isDirectory()) continue;
      try { if (lastWritten(sibling) < cutoff && !activeLock(sibling)) rmSync(sibling, { recursive: true, force: true }); }
      catch { /* An unreadable sibling is left for its owner. */ }
    }
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    cacheWrite(() => removeAbandonedTemporaries(directory));
    const previousSnapshot = readJSON(join(directory, "buckets.json"));
    const limits = readJSON(join(directory, "limits.json")) || {};
    const maintainHeartbeat = () => { if (Date.now() - lock.heartbeat >= 1000) heartbeat(); };
    const previous = await loadCheckpoint(directory, previousSnapshot, maintainHeartbeat);
    const accounts = readClaudeAccounts(values.accounts ?? values.config, runtime).filter(account => account.state === "ok");
    const counted = new Set(accounts.map(account => account.id));
    const codexAccounts = readProgramAccounts(values.accounts ?? values.config, runtime, "codex").filter(account => account.state === "ok");
    const codexCounted = new Set(codexAccounts.map(account => account.id));
    const addedCodexAccounts = codexAccounts.filter(account => !account.isDefault);
    // The query suggests these as Accounts against the Account file it reads.
    const claudeCandidates = homeCandidates(runtime);
    const codexCandidates = homeCandidates(runtime, "codex");
    limits.claude = claudeLimitsEntries(limits.claude, accounts);
    limits.codexAccounts = codexLimitsEntries(limits.codexAccounts, addedCodexAccounts);
    // An Account no longer counted (removed, missing, a duplicate) leaves with
    // its files and records, without a rebuild; one that returns is read anew.
    // Codex records without an Account are the Default Account's, from before Accounts.
    const leaving = record => record.program === "claude" ? !counted.has(record.account)
      : record.program === "codex" && record.account !== undefined && !codexCounted.has(record.account);
    const previousFiles = Object.fromEntries(Object.entries(previous?.files || {}).filter(([, state]) => !leaving(state)));
    let left = false;
    for (const [key, record] of previous?.keys || []) {
      if (!leaving(record)) continue;
      changeBucket(previous.buckets, record, -1);
      previous.keys.delete(key);
      left = true;
    }
    for (const group of previous?.groups.keys() || []) if (!counted.has(JSON.parse(group)[0])) previous.groups.delete(group);
    const errors = {};
    const found = [];
    const listed = new Set();
    const unlistedPaths = [];
    const failedSources = new Set();
    const claudeReason = "Could not read the Claude Code Transcripts.";
    const codexReason = "Could not read the Codex Transcripts.";
    let olderTranscripts = false;
    // One unreadable entry is skipped and counted; only a root that cannot be
    // listed hides its Account or program. Neither makes its known files look deleted.
    // Codex's Default Account keeps its files unmarked, as before Accounts.
    for (const { source, program, account, list, reason } of [
      ...accounts.map(({ id, roots: accountRoots }) => ({ source: `claude:${id}`, program: "claude", account: id,
        list: () => claudeFiles(accountRoots, cutoff), reason: claudeReason })),
      ...codexAccounts.map(({ id, isDefault, roots: accountRoots }) => ({ source: `codex:${id}`, program: "codex",
        account: isDefault ? undefined : id, list: () => codexFiles(accountRoots, cutoff), reason: codexReason })),
    ]) {
      let listing;
      try { listing = await list(); } catch { listing = { files: [], unreadable: [], rootFailed: true, older: false }; }
      olderTranscripts ||= listing.older;
      for (const file of listing.files) {
        // A Transcript that two Accounts reach (a symbolic link) counts in the first.
        if (account && listed.has(file.path)) continue;
        listed.add(file.path);
        found.push({ ...file, program, ...(account ? { account } : {}) });
      }
      // Two Accounts that share a tree report its unreadable entries once.
      for (const path of listing.unreadable) if (!unlistedPaths.includes(path)) unlistedPaths.push(path);
      if (listing.rootFailed) { failedSources.add(source); errors[source] = reason; }
    }
    // A program's own error is for when none of its Accounts could be listed.
    if (accounts.every(({ id }) => failedSources.has(`claude:${id}`))) errors.claude = claudeReason;
    if (codexAccounts.every(({ id }) => failedSources.has(`codex:${id}`))) errors.codex = codexReason;
    const unlisted = (path, state) => failedSources.has(`${state.program}:${state.account ?? "default"}`)
      || unlistedPaths.some(unlisted => path === unlisted || path.startsWith(unlisted + sep));
    // A Transcript stays with the Account whose kept state holds it while that
    // Account cannot list it: another one reaching it would read on from its offset.
    const files = found.filter(file => {
      const state = previousFiles[file.path];
      return state === undefined || state.account === file.account || !unlisted(file.path, state);
    });
    files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path));
    const match = matchFiles(files, previousFiles, now, unlisted);
    const rebuilding = !previous || match.rebuild || previousSnapshot?.limitsVersion !== 1;
    const preserveSnapshot = previousSnapshot !== null && (rebuilding || previousSnapshot.rebuilding);
    const buckets = rebuilding ? new Map() : previous.buckets;
    const keys = rebuilding ? new Map() : previous.keys;
    const groups = rebuilding ? new Map() : previous.groups;
    // The log must no longer hold the records of an Account that left.
    const newGeneration = rebuilding || previous.prune || left;
    const log = cacheWrite(() => newGeneration ? startLog(directory, keys, groups) : openLog(directory, previous.generation));
    const fileStates = rebuilding ? {} : match.states;
    let lastSnapshot = performance.now();
    const snapshot = (complete, final = false) => {
      heartbeat();
      // A routine incremental run only adds to the totals: until it finishes,
      // it keeps the previous run's scan state, coverage, age and Accounts,
      // so the next query restarts a worker that died mid-run.
      const scan = final ? { complete, coveredThrough: new Date(now).toISOString(), generatedAt: new Date().toISOString(),
        countedAccounts: [...counted], countedCodexAccounts: [...codexCounted] }
        : { complete: !rebuilding && previousSnapshot?.complete === true, coveredThrough: previousSnapshot?.coveredThrough ?? null,
          generatedAt: previousSnapshot?.generatedAt ?? new Date().toISOString(), countedAccounts: previousSnapshot?.countedAccounts,
          countedCodexAccounts: previousSnapshot?.countedCodexAccounts };
      // Commit parser progress even when a rebuild is still resolving a burst.
      // The query keeps the old aggregates; the next worker resumes the new log.
      const progress = { ...scan, pricingVersion, breakdownsVersion: 1, buckets: [...buckets.values()], errors, claudeCandidates, codexCandidates,
        // Each program's reading stays its Default Account's, for apps that ignore Accounts.
        limitsVersion: 1, usageLimits: { codex: limits.codex?.report, claude: limits.claude.default?.report,
          claudeAccounts: Object.fromEntries(accounts.map(({ id }) => [id, limits.claude[id]?.report])),
          codexAccounts: Object.fromEntries(addedCodexAccounts.map(({ id }) => [id, limits.codexAccounts[id]?.report])) },
        nextLimitsAt: nextCodexRead(limits, addedCodexAccounts), nextClaudeLimitsAt: nextClaudeRead(limits.claude, accounts),
        skippedArchives: Object.values(fileStates).filter(file => file.skipped).length,
        unreadableFiles: unlistedPaths.length + files.filter(file => fileStates[file.logicalPath || file.path]?.unreadable).length,
        // Coverage starts at the earliest record any remaining Transcript holds;
        // one older than the window covers the window's start.
        coveredSince: Object.values(fileStates).reduce((earliest, file) => Number.isFinite(file.firstAt) && (earliest === null || file.firstAt < earliest)
          ? file.firstAt : earliest, olderTranscripts ? cutoff : null) };
      cacheWrite(() => saveCheckpoint(directory, fileStates, log, preserveSnapshot && !scan.complete
        ? { ...previousSnapshot, complete: false, rebuilding: true, limitsVersion: 1, claudeCandidates, codexCandidates,
          usageLimits: progress.usageLimits, nextLimitsAt: progress.nextLimitsAt, nextClaudeLimitsAt: progress.nextClaudeLimitsAt }
        : { ...progress, rebuilding: false }));
      lastSnapshot = performance.now();
    };
    // Each snapshot rewrites files.json and buckets.json, so progress commits at
    // most once a second. Callers check only at line boundaries: the offset then
    // points past a line whose contributions are all in the log.
    const snapshotDue = () => { if (performance.now() - lastSnapshot >= 1000) snapshot(false); };
    // Commit a new generation at once: until then the old checkpoint no longer matches the log.
    if (newGeneration) snapshot(false);
    const appendKey = record => cacheWrite(() => log.append(record));
    const threads = new Map();
    const parentTotals = new Map();
    const threadKey = (account, id) => JSON.stringify([account ?? "default", id]);
    let pendingPrefix = false;
    // Old copied forks may be read before their parent in newest-first order.
    // Parent copies in another Account must not determine this Account's inherited prefix.
    for (const file of files.filter(file => file.program === "codex")) {
      const saved = fileStates[file.logicalPath];
      if (saved?.carry.threadId || saved?.finished) {
        const key = threadKey(file.account, saved.carry.threadId);
        if (saved.carry.threadId && !threads.has(key)) threads.set(key, file);
        continue;
      }
      try {
        for await (const { line } of codexLines(file, runtime, maintainHeartbeat)) {
          if (line?.type === "session_meta" && typeof line.payload?.id === "string") {
            const key = threadKey(file.account, line.payload.id);
            if (!threads.has(key)) threads.set(key, file);
          }
          break;
        }
      } catch (error) { if (runFailure(error)) throw error; /* The main pass reports unavailable or unreadable archives. */ }
    }
    const totalsForParent = async (account, id) => {
      const key = threadKey(account, id);
      if (!id || !threads.has(key)) return null;
      if (!parentTotals.has(key)) {
        const totals = [];
        try {
          for await (const { line } of codexLines(threads.get(key), runtime, maintainHeartbeat)) {
            if (line?.type === "event_msg" && line.payload?.type === "token_count" && line.payload.info?.total_token_usage) totals.push(codexTotalSignature(line.payload.info.total_token_usage));
          }
          parentTotals.set(key, totals);
        } catch (error) { if (runFailure(error)) throw error; parentTotals.set(key, null); }
      }
      return parentTotals.get(key);
    };
    for (const file of files) {
      const logicalPath = file.logicalPath || file.path;
      const state = fileStates[logicalPath] ||= { dev: file.dev, ino: file.ino, size: file.size, mtimeMs: file.mtimeMs,
        program: file.program, ...(file.account ? { account: file.account } : {}), compressed: Boolean(file.compressed), offset: 0, finished: false,
        carry: file.program === "codex" ? createCodexState(logicalPath) : {} };
      if (state.finished && !state.carry.pending?.length) continue;
      if (file.program === "codex") {
        const carry = state.carry;
        const account = state.account;
        // Only a copied fork whose inherited prefix has not ended is matched
        // against its parent; a forked subagent ends on its own markers.
        const needsParent = () => carry.inheritance === "fork" && !carry.inheritedEnded;
        let parent = needsParent() ? await totalsForParent(account, carry.parentId) : null;
        // An added Account's responses count once within it, beside the same
        // responses copied into another Account.
        const countContributions = contributions => {
          for (const contribution of contributions) {
            const candidate = priceContribution(account === undefined ? contribution
              : { ...contribution, account, key: JSON.stringify([account, contribution.key]) });
            if (keys.has(candidate.key)) continue;
            keys.set(candidate.key, candidate);
            changeBucket(buckets, candidate, 1);
            appendKey(candidate);
          }
        };
        try {
          if (!state.finished) for await (const entry of codexLines(file, runtime, maintainHeartbeat, state.offset)) {
            state.offset = entry.offset;
            noteFirstRecord(state, entry.line);
            const reading = codexRolloutLimits(entry.line);
            if (reading && (!carry.latestLimits || reading.observedAt >= carry.latestLimits.observedAt)) carry.latestLimits = reading;
            countContributions(consumeCodexLine(carry, entry.line, state.offset, cutoff, parent));
            snapshotDue();
            if (parent === null && needsParent()) parent = await totalsForParent(account, carry.parentId);
          }
          countContributions(finishCodexRead(carry, Date.now(), parent));
          pendingPrefix ||= carry.pending.length > 0;
          state.finished = true;
          state.skipped = false;
          state.unreadable = false;
        } catch (error) {
          if (runFailure(error)) throw error;
          // The file stays unfinished and is retried by the next run. Only
          // this run's failure counts, so a file is never skipped and unreadable.
          state.skipped = error instanceof ArchiveUnavailableError;
          state.unreadable = !state.skipped;
        }
        snapshotDue();
        continue;
      }
      try {
        if (!state.finished) for await (const { line, offset } of transcriptEntries(file.path, maintainHeartbeat, state.offset)) {
          // The previous line is complete here.
          snapshotDue();
          state.offset = offset;
          noteFirstRecord(state, line);
          if (typeof line?.cwd === "string") state.carry.directory = line.cwd;
          const contribution = claudeContribution(line, file.path, file.account, cutoff, state.carry.directory);
          if (!contribution) continue;
          const candidate = priceContribution(contribution);
          const peers = groups.get(candidate.group) || new Set();
          groups.set(candidate.group, peers);
          const existing = keys.get(candidate.key);
          // A counted record carries its own group; only a candidate that loses
          // needs an alias line to keep suppressing later replays.
          const newAlias = !peers.has(candidate.key);
          peers.add(candidate.key);
          const remember = () => { if (newAlias) appendKey({ alias: { group: candidate.group, key: candidate.key } }); };
          const siblings = [...peers].map(key => keys.get(key)).filter(Boolean);
          if (candidate.sidechain && siblings.some(record => !record.sidechain)) { remember(); continue; }
          const collisions = [existing, ...siblings.filter(record => record.sidechain)].filter(Boolean);
          // A stable final comparison makes even equal-size streamed copies order independent.
          const collisionFields = ({ estimatedCostUSD, unpricedTokens, ...record }) => JSON.stringify(record);
          const preferred = (a, b) => Number(!a.sidechain) - Number(!b.sidechain) || a.tokens.total - b.tokens.total || collisionFields(a).localeCompare(collisionFields(b));
          const winner = collisions.reduce((best, record) => preferred(record, best) >= 0 ? record : best, candidate);
          const removed = [...new Set(collisions.filter(record => record !== winner && (winner === candidate || !candidate.sidechain)).map(record => record.key))];
          for (const key of removed) {
            const old = keys.get(key);
            if (old) { changeBucket(buckets, old, -1); keys.delete(key); }
          }
          if (winner !== candidate) {
            remember();
            if (removed.length) appendKey({ replaces: removed });
            continue;
          }
          keys.set(candidate.key, candidate);
          changeBucket(buckets, candidate, 1);
          appendKey({ ...candidate, replaces: removed });
        }
        state.finished = true;
        state.unreadable = false;
      } catch (error) {
        if (runFailure(error)) throw error;
        state.unreadable = true;
      }
      snapshotDue();
    }
    snapshot(!pendingPrefix, true);
    // Reserve each program's cadence before starting it, so a worker that dies
    // mid-read still throttles the next one.
    if (!limits.codex || !Number.isFinite(limits.codex.nextAllowedAt) || Date.now() >= limits.codex.nextAllowedAt) {
      limits.codex = { ...limits.codex, nextAllowedAt: Date.now() + 60_000 };
      writeJSON(join(directory, "limits.json"), limits);
      limits.codex = { service: await readCodexLimits(runtime, directory), nextAllowedAt: Date.now() + 60_000 };
      heartbeat();
    }
    // An added Codex Account runs Codex with its own CODEX_HOME, on its own cadence.
    for (const account of addedCodexAccounts) {
      const entry = limits.codexAccounts[account.id];
      if (Number.isFinite(entry?.nextAllowedAt) && Date.now() < entry.nextAllowedAt) continue;
      limits.codexAccounts[account.id] = { ...entry, nextAllowedAt: Date.now() + 60_000 };
      writeJSON(join(directory, "limits.json"), limits);
      limits.codexAccounts[account.id] = { service: await readCodexLimits(codexAccountRuntime(runtime, account), directory),
        nextAllowedAt: Date.now() + 60_000 };
      heartbeat();
    }
    // Each Account keeps its own cadence, back-off and last good reading;
    // one check of the recorded claude's version serves them all.
    let version;
    for (const account of values["claude-limits"] ? accounts : []) {
      const entry = limits.claude[account.id];
      if (Number.isFinite(entry?.nextAllowedAt) && Date.now() < entry.nextAllowedAt) continue;
      limits.claude[account.id] = { ...entry, nextAllowedAt: Date.now() + 60_000 };
      writeJSON(join(directory, "limits.json"), limits);
      if (version === undefined) {
        version = await claudeVersion(runtime, directory, limits.claudeVersion);
        limits.claudeVersion = version ?? undefined;
      }
      const elsewhere = readClaudeLimitsElsewhere ? await readClaudeLimitsElsewhere(runtime, directory, version?.version, {
        account, wait: async () => { await sleep(100); maintainHeartbeat(); } }) : null;
      const reading = elsewhere ?? await readClaudeLimits(accountRuntime(runtime, account), directory, version?.version);
      limits.claude[account.id] = cacheClaudeLimits(limits.claude[account.id], reading);
      heartbeat();
    }
    // Each Account falls back to the latest limits its own sessions recorded.
    const fallback = accountID => Object.values(fileStates).filter(file => file.program === "codex" && file.account === accountID)
      .map(file => file.carry.latestLimits).filter(reading => reading?.windows?.length)
      .sort((a, b) => b.observedAt.localeCompare(a.observedAt))[0];
    // A reservation whose read never finished has no reading of its own.
    const report = (entry, accountID) => codexLimitsWithFallback(entry.service || entry.report
      || { state: "error", reason: "requestFailed" }, fallback(accountID));
    limits.codex.report = report(limits.codex, undefined);
    for (const { id } of addedCodexAccounts) limits.codexAccounts[id].report = report(limits.codexAccounts[id], id);
    writeJSON(join(directory, "limits.json"), limits);
    snapshot(!pendingPrefix, true);
    log.close();
    clearFailures(directory);
  } catch (error) {
    // A displaced worker did not fail; its successor owns the refresh.
    if (!(error instanceof LockLostError)) {
      try { recordFailure(directory); } catch { /* The query's own writes fail too. */ }
    }
    throw error;
  } finally { releaseWorker(directory, values["lock-token"]); }
}
