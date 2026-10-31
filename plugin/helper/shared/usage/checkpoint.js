import { createHash, randomUUID } from "node:crypto";
import { closeSync, fstatSync, fsyncSync, openSync, readFileSync, readSync, readdirSync, renameSync, rmSync, statSync, truncateSync, writeSync } from "node:fs";
import { basename, join } from "node:path";
import { writeJSON, DAY } from "./cache.js";
import { changeBucket } from "./buckets.js";
import { pricingFingerprint } from "./pricing.js";

/**
 * The layout of the cache files. Version 2 records each file's first
 * timestamp; version 3 drops the alias lines a counted record implies.
 */
export const CHECKPOINT_VERSION = 3;
/**
 * Bump whenever a change to parsing, deduplication or attribution changes what
 * a Transcript counts: every cache built under another version rebuilds once.
 * Version 2 recovers rollout tails appended before Codex compressed them;
 * version 3 leaves unknown Codex service tiers unpriced; version 4 attributes
 * Claude Code records to Accounts.
 */
export const SCANNER_VERSION = 4;
const CHUNK = 1 << 20;

const digest = text => createHash("sha256").update(text).digest("hex");

/** True when a snapshot's checkpoint was written by this format, scanner and price table. */
export function checkpointCurrent(checkpoint) {
  return checkpoint?.version === CHECKPOINT_VERSION && checkpoint.scannerVersion === SCANNER_VERSION
    && checkpoint.pricingFingerprint === pricingFingerprint;
}

/** A worker killed mid-write leaves its temporary files behind; only the lock holder writes these. */
export function removeAbandonedTemporaries(directory) {
  for (const name of readdirSync(directory)) {
    if (/^(?:keys\.log|files\.json|buckets\.json|limits\.json)\..+\.tmp$/.test(name)) rmSync(join(directory, name), { force: true });
  }
}

/** Complete lines of the first `length` bytes, read in large chunks; null for a torn prefix. */
function* logLines(path, length, onChunk) {
  const fd = openSync(path, "r");
  try {
    const buffer = Buffer.allocUnsafe(CHUNK);
    let carry = Buffer.alloc(0);
    let position = 0;
    while (position < length) {
      onChunk();
      const read = readSync(fd, buffer, 0, Math.min(CHUNK, length - position), position);
      if (read <= 0) { yield null; return; }
      position += read;
      const data = carry.length ? Buffer.concat([carry, buffer.subarray(0, read)]) : buffer.subarray(0, read);
      let from = 0;
      let newline;
      while ((newline = data.indexOf(10, from)) >= 0) {
        try { yield JSON.parse(data.toString("utf8", from, newline)); } catch { yield null; }
        from = newline + 1;
      }
      carry = Buffer.from(data.subarray(from));
    }
    if (carry.length) yield null;
  } finally { closeSync(fd); }
}

/**
 * A committed snapshot binds offsets to exactly one prefix of the contribution
 * log. Keys older than 31 days leave the totals at once; the log itself is
 * rewritten (`prune`) only once a whole UTC day of it has expired.
 */
export async function loadCheckpoint(directory, snapshot, heartbeat) {
  const checkpoint = snapshot?.checkpoint;
  if (!checkpointCurrent(checkpoint)) return null;
  try {
    const filesText = readFileSync(join(directory, "files.json"), "utf8");
    const logPath = join(directory, "keys.log");
    if (digest(filesText) !== checkpoint.filesHash || !Number.isSafeInteger(checkpoint.keyBytes)
        || statSync(logPath).size < checkpoint.keyBytes) return null;
    const keys = new Map();
    const groups = new Map();
    const alias = (group, key) => {
      const peers = groups.get(group) || new Set();
      peers.add(key); groups.set(group, peers);
    };
    let generation;
    let prune = false;
    const cutoff = Date.now() - 31 * DAY;
    const expiredDays = Math.floor(cutoff / DAY) * DAY;
    for (const line of logLines(logPath, checkpoint.keyBytes, heartbeat)) {
      if (!line) return null;
      if (line.generation) { if (generation) return null; generation = line.generation; continue; }
      if (line.alias) alias(line.alias.group, line.alias.key);
      for (const key of line.replaces || []) keys.delete(key);
      if (line.key) {
        const { replaces, ...record } = line;
        keys.set(line.key, record);
        // A counted Claude record is its own alias.
        if (typeof line.group === "string") alias(line.group, line.key);
        prune ||= line.timestamp < expiredDays;
      }
    }
    if (generation !== checkpoint.generation) return null;
    // A killed worker may have appended contributions without committing offsets.
    truncateSync(logPath, checkpoint.keyBytes);
    const buckets = new Map();
    for (const [key, value] of keys) {
      if (value.timestamp < cutoff) keys.delete(key);
      else changeBucket(buckets, value, 1);
    }
    for (const [group, peers] of groups) {
      for (const key of peers) if (!keys.has(key)) peers.delete(key);
      if (!peers.size) groups.delete(group);
    }
    return { files: JSON.parse(filesText), keys, groups, buckets, generation, prune };
  } catch { return null; }
}

function writeAll(fd, text) {
  const buffer = Buffer.from(text);
  for (let done = 0; done < buffer.length;) done += writeSync(fd, buffer, done, buffer.length - done);
}

/**
 * Appends through one descriptor in buffered chunks. A crash loses only
 * buffered lines, which no checkpoint covers yet: `bytes` flushes before it
 * reports the length a checkpoint commits.
 */
class ContributionLog {
  constructor(fd, generation) { this.fd = fd; this.generation = generation; this.chunks = []; this.length = 0; }
  append(record) {
    const text = JSON.stringify(record) + "\n";
    this.chunks.push(text);
    this.length += text.length;
    if (this.length >= CHUNK) this.flush();
  }
  flush() {
    if (!this.chunks.length) return;
    const text = this.chunks.join("");
    this.chunks = [];
    this.length = 0;
    writeAll(this.fd, text);
  }
  bytes() { this.flush(); return fstatSync(this.fd).size; }
  close() { closeSync(this.fd); }
}

/** Continue the log a checkpoint was loaded from; it was already truncated to that checkpoint. */
export function openLog(directory, generation) {
  return new ContributionLog(openSync(join(directory, "keys.log"), "a"), generation);
}

/**
 * Write a new generation holding the live keys into a temporary file and
 * rename it into place, so the old log stays intact until the new one is
 * complete. Until a snapshot commits the new generation, the old checkpoint no
 * longer matches the log and the next run rebuilds.
 */
export function startLog(directory, keys = new Map(), groups = new Map()) {
  const path = join(directory, "keys.log");
  const generation = randomUUID();
  const temporary = `${path}.${generation}.tmp`;
  const log = new ContributionLog(openSync(temporary, "ax", 0o600), generation);
  try {
    log.append({ generation });
    for (const value of keys.values()) { const { replaces, ...record } = value; log.append(record); }
    for (const [group, peers] of groups) for (const key of peers) if (keys.get(key)?.group !== group) log.append({ alias: { group, key } });
    log.flush();
    fsyncSync(log.fd);
    renameSync(temporary, path);
    return log;
  } catch (error) {
    try { log.close(); } catch { /* The write error is the one to report. */ }
    rmSync(temporary, { force: true });
    throw error;
  }
}

export function saveCheckpoint(directory, files, log, snapshot) {
  // Flush first: the committed length must cover every contribution behind these offsets.
  const keyBytes = log.bytes();
  writeJSON(join(directory, "files.json"), files);
  const filesText = readFileSync(join(directory, "files.json"), "utf8");
  writeJSON(join(directory, "buckets.json"), { ...snapshot, checkpoint: {
    version: CHECKPOINT_VERSION, scannerVersion: SCANNER_VERSION, pricingFingerprint, generation: log.generation, filesHash: digest(filesText), keyBytes,
  } });
}

/**
 * Match paths before inodes so moves retain their parser identity and response
 * keys. Archiving keeps the base name; a freed inode reused by another file
 * does not, so an identity claim also requires the same logical base name.
 * A state belongs to its Account: a path listed under another one is a new
 * file there. A state the listing could not see (`unlisted`) is kept rather
 * than deleted.
 */
export function matchFiles(files, previous, now, unlisted = () => false) {
  const states = {};
  const claimed = new Set();
  const currentPaths = new Set(files.map(file => file.logicalPath || file.path)
    .filter((path, index) => Object.hasOwn(previous, path) && previous[path].account === files[index].account));
  const byIdentity = new Map();
  const identity = (file, path) => JSON.stringify([file.program, file.account ?? null, file.dev, file.ino, basename(path)]);
  for (const [path, state] of Object.entries(previous)) {
    if (currentPaths.has(path)) continue;
    const candidates = byIdentity.get(identity(state, path)) || [];
    candidates.push(path);
    byIdentity.set(identity(state, path), candidates);
  }
  let rebuild = false;
  for (const file of files) {
    const path = file.logicalPath || file.path;
    const oldPath = currentPaths.has(path) ? path
      : byIdentity.get(identity(file, path))?.find(candidate => !claimed.has(candidate));
    if (!oldPath) continue;
    claimed.add(oldPath);
    const old = previous[oldPath];
    const sameIdentity = old.dev === file.dev && old.ino === file.ino;
    const representationChanged = file.program === "codex" && old.compressed !== file.compressed;
    if (representationChanged) {
      if (!file.compressed && file.size < old.offset) rebuild = true;
    } else if (!sameIdentity || file.size < old.size || file.mtimeMs < old.mtimeMs
        || (file.mtimeMs !== old.mtimeMs && file.size === old.size)
        || (file.compressed && file.size !== old.size)) rebuild = true;
    states[path] = { ...old, dev: file.dev, ino: file.ino, size: file.size, mtimeMs: file.mtimeMs, compressed: Boolean(file.compressed),
      // Codex copies the source mtime when it compresses, so an unchanged mtime
      // means nothing was appended since the last read. A copy coarser than a
      // millisecond only costs one read from the saved offset.
      finished: old.finished && (representationChanged
        ? file.compressed && Math.abs(file.mtimeMs - old.mtimeMs) < 1 : file.size === old.size) };
  }
  for (const [path, state] of Object.entries(previous)) {
    if (claimed.has(path)) continue;
    if (unlisted(path, state)) states[path] = state;
    else if (state.mtimeMs >= now - 30 * DAY) rebuild = true;
  }
  return { states, rebuild };
}
