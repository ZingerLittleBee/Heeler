import { createReadStream } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import { join, sep } from "node:path";
import { jsonLines } from "./json-lines.js";

/**
 * Transcripts in the window. An entry that cannot be listed is skipped and its
 * path returned in `unreadable`, and so is a `projects/` root while another
 * root can be listed; `rootFailed` means no existing root could be. `older`
 * tells whether a Transcript older than the window exists, which means the
 * Host kept records from before it.
 */
export async function claudeFiles(roots, cutoff) {
  const files = [];
  const unreadable = [];
  const failedRoots = [];
  let listedRoot = false;
  let older = false;
  const seenDirectories = new Set();
  const seenFiles = new Set();
  const skip = (path, root) => (root ? failedRoots : unreadable).push(path);
  async function visit(path, root) {
    let actual;
    let entries;
    try {
      actual = await realpath(path);
      if (seenDirectories.has(actual)) return;
      seenDirectories.add(actual);
      entries = await readdir(actual, { withFileTypes: true });
    } catch (error) { if (error.code !== "ENOENT") skip(actual || path, root); return; }
    if (root) listedRoot = true;
    for (const entry of entries) {
      const child = join(actual, entry.name);
      if (entry.isDirectory()) await visit(child, false);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        let metadata;
        try { metadata = await stat(child); }
        catch (error) { if (error.code !== "ENOENT") skip(child, false); continue; }
        if (metadata.mtimeMs < cutoff) older = true;
        if (metadata.mtimeMs < cutoff || seenFiles.has(child)) continue;
        seenFiles.add(child);
        files.push({ path: child, ...metadata });
      }
    }
  }
  for (const root of roots) await visit(join(root, "projects"), true);
  const rootFailed = failedRoots.length > 0 && !listedRoot;
  if (!rootFailed) unreadable.push(...failedRoots);
  return { files: files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path)), unreadable, rootFailed, older };
}
export async function* transcriptEntries(path, onChunk = () => {}, start = 0) {
  yield* jsonLines(createReadStream(path, { start }), start, 0, onChunk);
}
const count = value => Number.isFinite(value) && value >= 0 ? value : 0;
/**
 * One record's contribution to its Account. Keys and groups carry the
 * Account, so deduplication runs within one Account: copies of a Transcript in
 * two Accounts count in each, as they would on their own.
 */
export function claudeContribution(line, path, account, cutoff, sessionDirectory) {
  if (line?.type !== "assistant" || !line.message?.usage || line.message.model === "<synthetic>" || typeof line.message.id !== "string") return null;
  const timestamp = typeof line.timestamp === "string" ? Date.parse(line.timestamp) : NaN;
  if (!Number.isFinite(timestamp) || timestamp < cutoff) return null;
  const usage = line.message.usage;
  const split = usage.cache_creation;
  const hasSplit = Number.isFinite(split?.ephemeral_5m_input_tokens) || Number.isFinite(split?.ephemeral_1h_input_tokens);
  const write5m = hasSplit ? count(split.ephemeral_5m_input_tokens) : count(usage.cache_creation_input_tokens);
  const write1h = hasSplit ? count(split.ephemeral_1h_input_tokens) : 0;
  const tokens = { input: count(usage.input_tokens), cacheRead: count(usage.cache_read_input_tokens), cacheWrite: write5m + write1h, output: count(usage.output_tokens), reasoning: 0 };
  tokens.total = tokens.input + tokens.cacheRead + tokens.cacheWrite + tokens.output;
  const sessionId = typeof line.sessionId === "string" ? line.sessionId : "";
  const requestId = typeof line.requestId === "string" && line.requestId ? line.requestId : null;
  const components = path.split(sep);
  const project = components[components.lastIndexOf("projects") + 1] || "unknown";
  const directory = typeof line.cwd === "string" ? line.cwd : sessionDirectory || project.replaceAll("-", "/");
  return {
    key: JSON.stringify(requestId ? ["claude", account, line.message.id, requestId] : ["claude", account, line.message.id, sessionId, line.timestamp]),
    group: JSON.stringify([account, line.message.id, sessionId]), sessionId, sidechain: line.isSidechain === true,
    program: "claude", account, model: typeof line.message.model === "string" ? line.message.model : "unknown", directory,
    timestamp, bucket: Math.floor(timestamp / 900_000) * 900_000, tokens, write5m, write1h, speed: usage.speed === "fast" ? "fast" : "standard",
  };
}
