import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import { basename, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { executableOnPath } from "./runtime-record.js";

const count = value => Number.isFinite(value) && value >= 0 ? value : 0;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KNOWN_LABELS = new Map([
  ["orchestrator (carbon)", "gemini-pro-orchestrator"],
  ["orchestrator (argon)", "gemini-pro-orchestrator-argon"],
]);

/**
 * Transcripts in the window (`<root>/brain/<id>/.system_generated/logs/transcript_full.jsonl`).
 * An unreadable `brain/` root fails only when no existing root could be listed;
 * missing roots or conversations without a transcript yet are skipped quietly.
 */
export async function agyFiles(roots, cutoff) {
  const files = [];
  const unreadable = [];
  const failedRoots = [];
  let listedRoot = false;
  let older = false;
  const seenDirectories = new Set();
  const seenFiles = new Set();

  for (const root of roots) {
    const brainPath = join(root, "brain");
    let actualBrain;
    let entries;
    try {
      actualBrain = await realpath(brainPath);
      if (seenDirectories.has(actualBrain)) continue;
      seenDirectories.add(actualBrain);
      entries = await readdir(actualBrain, { withFileTypes: true });
    } catch (error) {
      if (error.code !== "ENOENT") failedRoots.push(actualBrain || brainPath);
      continue;
    }
    listedRoot = true;
    for (const entry of entries) {
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
      const candidate = join(actualBrain, entry.name, ".system_generated", "logs", "transcript_full.jsonl");
      let metadata;
      let actualFile;
      try {
        metadata = await stat(candidate);
        if (!metadata.isFile()) continue;
        if (metadata.mtimeMs < cutoff) {
          older = true;
          continue;
        }
        actualFile = await realpath(candidate);
      } catch (error) {
        if (error.code !== "ENOENT" && error.code !== "ENOTDIR") unreadable.push(candidate);
        continue;
      }
      if (seenFiles.has(actualFile)) continue;
      seenFiles.add(actualFile);
      const resolvedConversation = basename(resolve(actualFile, "../../..")) || entry.name;
      files.push({ path: actualFile, conversationId: resolvedConversation.toLowerCase(), ...metadata });
    }
  }
  const rootFailed = failedRoots.length > 0 && !listedRoot;
  if (!rootFailed) unreadable.push(...failedRoots);
  return { files: files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path)), unreadable, rootFailed, older };
}

function workspaceFromUri(value) {
  if (typeof value !== "string" || !value) return null;
  if (value.startsWith("file://")) {
    try {
      const path = fileURLToPath(value);
      return isAbsolute(path) ? path : null;
    } catch {
      return null;
    }
  }
  return isAbsolute(value) ? value : null;
}

function readHistoryDirectories(root, directories) {
  let text;
  try { text = readFileSync(join(root, "history.jsonl"), "utf8"); } catch { return; }
  for (const rawLine of text.split("\n")) {
    if (!rawLine) continue;
    try {
      const entry = JSON.parse(rawLine);
      if (typeof entry?.conversationId === "string" && typeof entry.workspace === "string" && isAbsolute(entry.workspace)) {
        directories.set(entry.conversationId.toLowerCase(), entry.workspace);
      }
    } catch { /* Ignore torn or malformed history lines. */ }
  }
}

function readSummaryDatabaseDirectories(root, env, directories, parents) {
  const dbPath = join(root, "conversation_summaries.db");
  if (!existsSync(dbPath)) return;
  const executable = executableOnPath("sqlite3", env?.PATH);
  if (!executable) return;
  const hasWal = existsSync(`${dbPath}-wal`);
  const uri = `file:${encodeURI(dbPath).replaceAll("#", "%23").replaceAll("?", "%3F")}?${hasWal ? "mode=ro" : "immutable=1"}`;
  const cleanEnv = Object.fromEntries(Object.entries(env || {}).filter(([, value]) => typeof value === "string"));
  const result = spawnSync(executable, [
    uri,
    "SELECT json_array(conversation_id, workspace_uris, parent_conversation_id) FROM conversation_summaries;",
  ], { env: cleanEnv, encoding: "utf8", timeout: 2_000, maxBuffer: 4 * 1024 * 1024 });
  if (result.status !== 0 || typeof result.stdout !== "string") return;
  for (const rawLine of result.stdout.split("\n")) {
    if (!rawLine) continue;
    try {
      const [id, rawWorkspaces, parentId] = JSON.parse(rawLine);
      if (typeof id !== "string" || !id) continue;
      const key = id.toLowerCase();
      if (typeof parentId === "string" && parentId) parents.set(key, parentId.toLowerCase());
      if (typeof rawWorkspaces === "string" && rawWorkspaces) {
        const uris = JSON.parse(rawWorkspaces);
        const workspace = Array.isArray(uris) ? workspaceFromUri(uris[0]) : null;
        if (workspace) directories.set(key, workspace);
      }
    } catch { /* Ignore unreadable summary rows. */ }
  }
}

/**
 * Best-effort map from lowercase `conversationId` to workspace path across an
 * Account's roots, walking `parent_conversation_id` so subagents inherit their
 * parent conversation's workspace.
 */
export function agyDirectories(roots, env) {
  const directories = new Map();
  const parents = new Map();
  for (const root of roots) {
    readHistoryDirectories(root, directories);
    readSummaryDatabaseDirectories(root, env, directories, parents);
  }
  for (const [id] of parents) {
    if (directories.has(id)) continue;
    let current = id;
    const seen = new Set([id]);
    for (let hop = 0; hop < 8; hop++) {
      const parent = parents.get(current);
      if (!parent || seen.has(parent)) break;
      seen.add(parent);
      const workspace = directories.get(parent);
      if (workspace) {
        directories.set(id, workspace);
        break;
      }
      current = parent;
    }
  }
  return directories;
}

/**
 * Normalizes a `<USER_SETTINGS_CHANGE>` `Model Selection` display label (such as
 * `"Gemini 4 Carbon (High)"` or `"Claude Opus 4.6 (Thinking)"`) to an `agy` slug.
 */
export function normalizeAgyModelLabel(rawLabel) {
  const trimmed = rawLabel.trim();
  if (!trimmed || trimmed === "None") return null;
  const known = KNOWN_LABELS.get(trimmed.toLowerCase());
  if (known) return known;
  if (!trimmed.includes(" ")) return trimmed.toLowerCase();
  let slug = trimmed.toLowerCase().replace(/[()]/g, " ");
  if (slug.startsWith("claude ")) slug = slug.replace(/(\d)\.(\d)/g, "$1-$2");
  slug = slug.replace(/[^a-z0-9.]+/g, "-").replace(/^-+|-+$/g, "");
  return slug || null;
}

/**
 * Extracts the latest `Model Selection` change outside `<USER_REQUEST>`, matching
 * `AgyStep.modelSelection` so pasted prompt text cannot spoof a model change.
 */
function extractModelSetting(content) {
  if (typeof content !== "string") return null;
  let search = content;
  if (content.includes("<USER_REQUEST>")) {
    const end = content.indexOf("</USER_REQUEST>");
    if (end < 0) return null;
    search = content.slice(end + "</USER_REQUEST>".length);
  }
  const prefix = "The user changed setting `Model Selection` from ";
  let latest = null;
  let cursor = 0;
  while (cursor < search.length) {
    const open = search.indexOf("<USER_SETTINGS_CHANGE>", cursor);
    if (open < 0) break;
    const close = search.indexOf("</USER_SETTINGS_CHANGE>", open + "<USER_SETTINGS_CHANGE>".length);
    if (close < 0) break;
    const block = search.slice(open + "<USER_SETTINGS_CHANGE>".length, close);
    for (const rawLine of block.split("\n")) {
      const line = rawLine.trim();
      if (!line.startsWith(prefix)) continue;
      let rest = line.slice(prefix.length);
      const comment = rest.indexOf(". No need to comment");
      if (comment >= 0) rest = rest.slice(0, comment);
      else if (rest.endsWith(".")) rest = rest.slice(0, -1);
      const sep = rest.indexOf(" to ");
      if (sep < 0) continue;
      const slug = normalizeAgyModelLabel(rest.slice(sep + 4));
      if (slug) latest = slug;
    }
    cursor = close + "</USER_SETTINGS_CHANGE>".length;
  }
  return latest;
}

function extractParentSender(content) {
  if (typeof content !== "string") return null;
  const match = /\[Message\][^\n]*?\bsender=([0-9a-f-]{36})\b/i.exec(content);
  return match && UUID_PATTERN.test(match[1]) ? match[1].toLowerCase() : null;
}

/**
 * Consumes one `transcript_full.jsonl` line, updating `carry` (`model`,
 * `parentId`, `directory`) and returning a contribution for `PLANNER_RESPONSE`
 * and `CHECKPOINT` steps inside the retention window.
 */
export function consumeAgyLine(carry, line, conversationId, account, cutoff, directories = null) {
  if (!line || typeof line !== "object") return null;
  if (line.type === "USER_INPUT") {
    const selected = extractModelSetting(line.content);
    if (selected) carry.model = selected;
    return null;
  }
  if (line.type === "SYSTEM_MESSAGE" && !carry.parentId) {
    const parentId = extractParentSender(line.content);
    if (parentId) carry.parentId = parentId;
    return null;
  }
  if (line.type === "PLANNER_RESPONSE" && typeof line.model === "string" && line.model.trim() && line.model !== "None") {
    carry.model = line.model.trim();
  }
  if (line.type !== "PLANNER_RESPONSE" && line.type !== "CHECKPOINT") return null;
  const timestamp = typeof line.created_at === "string" ? Date.parse(line.created_at) : NaN;
  if (!Number.isFinite(timestamp) || timestamp < cutoff) return null;
  const tokens = {
    input: count(line.input_tokens),
    cacheRead: count(line.cache_read_tokens),
    cacheWrite: 0,
    output: count(line.output_tokens),
    reasoning: 0,
  };
  tokens.total = tokens.input + tokens.cacheRead + tokens.output;
  if (!tokens.total) return null;
  const resolvedDirectory = directories?.get(conversationId)
    || (carry.parentId ? directories?.get(carry.parentId) : null)
    || carry.directory
    || "unknown";
  if (resolvedDirectory !== "unknown") carry.directory = resolvedDirectory;
  const stepKey = Number.isSafeInteger(line.step_index) ? line.step_index : line.created_at;
  return {
    key: JSON.stringify(account ? ["agy", account, conversationId, stepKey] : ["agy", conversationId, stepKey]),
    program: "agy",
    ...(account ? { account } : {}),
    model: carry.model || "unknown",
    directory: resolvedDirectory,
    timestamp,
    bucket: Math.floor(timestamp / 900_000) * 900_000,
    tokens,
  };
}
