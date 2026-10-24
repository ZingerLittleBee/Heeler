import { createHash, randomUUID } from "node:crypto";
import { readFileSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { writeJSON, DAY } from "./cache.js";
import { transcriptEntries } from "./claude-scanner.js";
import { changeBucket } from "./buckets.js";
import { pricingFingerprint } from "./pricing.js";

const digest = text => createHash("sha256").update(text).digest("hex");

/** A committed snapshot binds offsets to exactly one prefix of the contribution log. */
export async function loadCheckpoint(directory, snapshot, heartbeat) {
  const checkpoint = snapshot?.checkpoint;
  if (checkpoint?.version !== 1 || checkpoint.pricingFingerprint !== pricingFingerprint) return null;
  try {
    const filesText = readFileSync(join(directory, "files.json"), "utf8");
    const logPath = join(directory, "keys.log");
    if (digest(filesText) !== checkpoint.filesHash || !Number.isSafeInteger(checkpoint.keyBytes)
        || statSync(logPath).size < checkpoint.keyBytes) return null;
    const keys = new Map();
    const groups = new Map();
    let generation;
    let bytes = 0;
    let expired = false;
    const cutoff = Date.now() - 31 * DAY;
    for await (const { line, offset } of transcriptEntries(logPath, heartbeat)) {
      if (offset > checkpoint.keyBytes) break;
      if (!line) return null;
      bytes = offset;
      if (line.generation) { if (generation) return null; generation = line.generation; continue; }
      if (line.alias) {
        const peers = groups.get(line.alias.group) || new Set();
        peers.add(line.alias.key); groups.set(line.alias.group, peers);
      }
      for (const key of line.replaces || []) keys.delete(key);
      if (line.key) {
        const { replaces, ...record } = line;
        keys.set(line.key, record);
        expired ||= line.timestamp < cutoff;
      }
    }
    if (bytes !== checkpoint.keyBytes || generation !== checkpoint.generation) return null;
    // A killed worker may have appended contributions without committing offsets.
    truncateSync(logPath, checkpoint.keyBytes);
    const buckets = new Map();
    for (const [key, value] of keys) {
      if (value.timestamp < cutoff) { keys.delete(key); expired = true; }
      else changeBucket(buckets, value, 1);
    }
    for (const [group, peers] of groups) {
      for (const key of peers) if (!keys.has(key)) peers.delete(key);
      if (!peers.size) groups.delete(group);
    }
    return { files: JSON.parse(filesText), keys, groups, buckets, generation, expired };
  } catch { return null; }
}

export function startLog(path, keys = new Map(), groups = new Map()) {
  const generation = randomUUID();
  writeFileSync(path, JSON.stringify({ generation }) + "\n", { mode: 0o600 });
  // Rewrite only at rebuild/prune boundaries, never at each batch.
  const entries = [];
  for (const value of keys.values()) { const { replaces, ...record } = value; entries.push(JSON.stringify(record)); }
  for (const [group, peers] of groups) for (const key of peers) entries.push(JSON.stringify({ alias: { group, key } }));
  if (entries.length) writeFileSync(path, entries.join("\n") + "\n", { flag: "a" });
  return generation;
}

export function saveCheckpoint(directory, files, generation, snapshot) {
  writeJSON(join(directory, "files.json"), files);
  const filesText = readFileSync(join(directory, "files.json"), "utf8");
  writeJSON(join(directory, "buckets.json"), { ...snapshot, checkpoint: {
    version: 1, pricingFingerprint, generation, filesHash: digest(filesText), keyBytes: statSync(join(directory, "keys.log")).size,
  } });
}

/** Match paths before inodes so moves retain their parser identity and response keys. */
export function matchFiles(files, previous, now) {
  const states = {};
  const claimed = new Set();
  const currentPaths = new Set(files.map(file => file.logicalPath || file.path));
  const byIdentity = new Map();
  const identity = file => JSON.stringify([file.program, file.dev, file.ino]);
  for (const [path, state] of Object.entries(previous)) {
    if (currentPaths.has(path)) continue;
    const candidates = byIdentity.get(identity(state)) || [];
    candidates.push(path);
    byIdentity.set(identity(state), candidates);
  }
  let rebuild = false;
  for (const file of files) {
    const path = file.logicalPath || file.path;
    const oldPath = Object.hasOwn(previous, path) ? path
      : byIdentity.get(identity(file))?.find(candidate => !claimed.has(candidate));
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
      finished: old.finished && (representationChanged ? file.compressed : file.size === old.size) };
  }
  for (const [path, state] of Object.entries(previous)) if (!claimed.has(path) && state.mtimeMs >= now - 30 * DAY) rebuild = true;
  return { states, rebuild };
}
