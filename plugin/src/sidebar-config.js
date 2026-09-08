import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parse } from "smol-toml";

const BUILTIN_TOKENS = new Set([
  "state_icon", "state_text", "workspace", "tab", "pane", "agent",
  "terminal_title", "terminal_title_stripped",
]);
// Canonical labels from herdr v0.8.2 src/detect/mod.rs; aliases are invalid.
const AGENT_IDS = new Set([
  "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline",
  "omp", "mastracode", "opencode", "copilot", "kimi", "kiro", "droid",
  "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "maki",
]);
const STYLE_KEYS = new Set(["token", "fg", "bold", "dim"]);

export function resolveConfigPath(env = process.env) {
  if (env.HERDR_CONFIG_PATH !== undefined) return env.HERDR_CONFIG_PATH;
  if (env.XDG_CONFIG_HOME !== undefined) return join(env.XDG_CONFIG_HOME, "herdr", "config.toml");
  return join(env.HOME === undefined ? tmpdir() : join(env.HOME, ".config"), "herdr", "config.toml");
}

function defaults(diagnostics = []) {
  return {
    agent_panel_sort: "spaces",
    sidebar: { agents: {
      row_gap: 0,
      rows: [[{ token: "state_icon" }, { token: "workspace" }, { token: "tab" }], [{ token: "agent" }]],
      rows_by_agent: {},
    } },
    diagnostics,
  };
}

function table(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value) || value instanceof Date) {
    throw new Error("invalid_schema");
  }
  return value;
}

function token(value) {
  const input = typeof value === "string" ? { token: value } : table(value);
  if (Object.keys(input).some((key) => !STYLE_KEYS.has(key))) throw new Error("invalid_schema");
  if (typeof input.token !== "string" || input.token.trim() !== input.token ||
      (!BUILTIN_TOKENS.has(input.token) && !/^\$[A-Za-z0-9_-]{1,32}$/.test(input.token))) {
    throw new Error("invalid_token");
  }
  const result = { token: input.token };
  if (input.fg !== undefined) {
    if (typeof input.fg !== "string" || input.fg.trim() !== input.fg ||
        !/^#(?:[\da-fA-F]{3}|[\da-fA-F]{6})$/.test(input.fg)) {
      throw new Error("invalid_schema");
    }
    result.fg = input.fg;
  }
  for (const key of ["bold", "dim"]) {
    if (input[key] === undefined) continue;
    if (typeof input[key] !== "boolean") throw new Error("invalid_schema");
    result[key] = input[key];
  }
  return result;
}

function rows(value) {
  if (!Array.isArray(value) || value.length > 16) throw new Error("invalid_schema");
  return value.map((row) => {
    if (!Array.isArray(row) || row.length > 16) throw new Error("invalid_schema");
    return row.map(token);
  });
}

/** Normalize only the sidebar agent layout and sort; never expose raw TOML in diagnostics. */
export function parseSidebarConfig(toml) {
  let parsed;
  try {
    // Preserve integer types so row_gap = 1.0 is rejected like herdr's u16.
    parsed = parse(toml, { integersAsBigInt: true });
  } catch {
    return defaults(["parse_error"]);
  }
  try {
    const ui = table(parsed.ui ?? {});
    const agents = table(table(ui.sidebar ?? {}).agents ?? {});
    const result = defaults();
    const sort = ui.agent_panel_sort ?? "spaces";
    if (!["spaces", "workspaces", "priority"].includes(sort)) throw new Error("invalid_schema");
    result.agent_panel_sort = sort === "workspaces" ? "spaces" : sort;
    if (agents.row_gap !== undefined) {
      if (typeof agents.row_gap !== "bigint" || agents.row_gap < 0n || agents.row_gap > 65535n) {
        throw new Error("invalid_schema");
      }
      result.sidebar.agents.row_gap = Number(agents.row_gap);
    }
    if (agents.rows !== undefined) result.sidebar.agents.rows = rows(agents.rows);
    for (const [id, value] of Object.entries(table(agents.rows_by_agent ?? {}))) {
      if (!AGENT_IDS.has(id)) throw new Error("invalid_schema");
      result.sidebar.agents.rows_by_agent[id] = rows(value);
    }
    return result;
  } catch (error) {
    return defaults([error.message === "invalid_token" ? "invalid_token" : "invalid_schema"]);
  }
}

function writeAtomic(path, contents) {
  const temp = `${path}.tmp-${process.pid}`;
  // Exclusive creation prevents reusing a stale temporary file with a wider mode.
  writeFileSync(temp, contents, { mode: 0o600, flag: "wx" });
  try {
    renameSync(temp, path);
  } finally {
    rmSync(temp, { force: true });
  }
}

/** Refresh on source path/existence/mtime changes. Return the current snapshot. */
export function refreshSidebarSnapshot(configDir, { env = process.env, now = Date.now } = {}) {
  const path = resolveConfigPath(env);
  const destination = join(configDir, "sidebar.json");
  const source = { path, found: false, mtime_ms: null };
  let readError = false;
  try {
    source.mtime_ms = statSync(path).mtimeMs;
    source.found = true;
  } catch (error) {
    readError = error.code !== "ENOENT";
  }
  if (!readError) {
    try {
      const previous = JSON.parse(readFileSync(destination, "utf8"));
      if (previous.v === 1 && previous.source?.path === path &&
          previous.source.found === source.found && previous.source.mtime_ms === source.mtime_ms &&
          Array.isArray(previous.sidebar?.agents?.rows) && Array.isArray(previous.diagnostics) &&
          !previous.diagnostics.includes("read_error")) return previous;
    } catch { /* Missing or corrupt snapshots are replaced. */ }
  }
  let config = defaults(readError ? ["read_error"] : []);
  if (source.found) {
    try {
      config = parseSidebarConfig(readFileSync(path, "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") {
        source.found = false;
        source.mtime_ms = null;
        config = defaults();
      } else {
        config = defaults(["read_error"]);
      }
    }
  }
  const snapshot = { v: 1, generated_at: Math.floor(now() / 1000), source, ...config };
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  writeAtomic(destination, JSON.stringify(snapshot) + "\n");
  return snapshot;
}

/** A snapshot write failure must not prevent notification delivery. */
export function refreshSidebarSnapshotForEvent(configDir) {
  try {
    refreshSidebarSnapshot(configDir);
  } catch (error) {
    console.error(`sidebar-hook: snapshot refresh failed (${error.code ?? "write_error"})`);
  }
}
