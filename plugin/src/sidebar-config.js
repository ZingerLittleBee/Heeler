import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { parse, TomlError } from "smol-toml";

const BUILTIN_TOKENS = new Set([
  "state_icon", "state_text", "machine", "workspace", "tab", "pane", "agent",
  "terminal_title", "terminal_title_stripped",
]);
// Canonical labels verified against herdr v0.9.4 src/detect/mod.rs; aliases are invalid.
const AGENT_IDS = new Set([
  "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline",
  "omp", "mastracode", "opencode", "copilot", "kimi", "kiro", "droid",
  "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "letta", "maki", "muse",
]);
const STYLE_KEYS = new Set(["token", "fg", "bold", "dim", "rules"]);
// Rule fields of herdr v0.9.4 src/config/sidebar/rules.rs, exported in its order.
const RULE_CONDITIONS = ["equals", "contains", "starts_with", "gt", "lt"];
const RULE_KEYS = new Set([...RULE_CONDITIONS, "ignore_case", "fg", "bold", "dim", "hide"]);

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

function color(value) {
  if (typeof value !== "string" || value.trim() !== value ||
      !/^#(?:[\da-fA-F]{3}|[\da-fA-F]{6})$/.test(value)) {
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
  if (input.fg !== undefined) result.fg = color(input.fg);
  booleans(input, ["bold", "dim"], result);
  if (input.rules !== undefined) {
    if (!Array.isArray(input.rules) || input.rules.length > 16) throw new Error("invalid_schema");
    if (input.rules.length > 0) {
      // herdr requires a text-valued token for rules, so state_icon takes only rules = [].
      if (input.token === "state_icon") throw new Error("invalid_schema");
      result.rules = input.rules.map(rule);
    }
  }
  return result;
}

function booleans(input, keys, result) {
  for (const key of keys) {
    if (input[key] === undefined) continue;
    if (typeof input[key] !== "boolean") throw new Error("invalid_schema");
    result[key] = input[key];
  }
}

/** Exactly one condition: text for equals, contains and starts_with, a number for gt and lt. */
function rule(value) {
  const input = table(value);
  if (Object.keys(input).some((key) => !RULE_KEYS.has(key))) throw new Error("invalid_schema");
  const conditions = RULE_CONDITIONS.filter((key) => input[key] !== undefined);
  if (conditions.length !== 1) throw new Error("invalid_schema");
  const [condition] = conditions;
  const result = {};
  if (condition === "gt" || condition === "lt") {
    // herdr rejects ignore_case next to gt or lt, even ignore_case = false.
    if (input.ignore_case !== undefined) throw new Error("invalid_schema");
    result[condition] = threshold(input[condition]);
  } else {
    if (typeof input[condition] !== "string") throw new Error("invalid_schema");
    result[condition] = input[condition];
  }
  booleans(input, ["ignore_case"], result);
  if (input.fg !== undefined) result.fg = color(input.fg);
  booleans(input, ["bold", "dim", "hide"], result);
  return result;
}

// herdr reads thresholds as finite f64. smol-toml returns TOML integers as
// BigInt, which Number.isFinite rejects and JSON cannot hold.
function threshold(value) {
  const number = typeof value === "bigint" ? Number(value) : value;
  if (!Number.isFinite(number)) throw new Error("invalid_schema");
  return number;
}

function rows(value) {
  if (!Array.isArray(value) || value.length > 16) throw new Error("invalid_schema");
  return value.map((row) => {
    if (!Array.isArray(row) || row.length > 16) throw new Error("invalid_schema");
    return row.map(token);
  });
}

const BOM = "\uFEFF";

// Where 1-based `line` starts, splitting lines as smol-toml's TomlError counts them.
function lineStart(text, line) {
  const breaks = /\r\n|\n|\r/g;
  let offset = 0;
  for (let current = 1; current < line; current += 1) {
    const match = breaks.exec(text);
    if (match === null) return -1;
    offset = match.index + match[0].length;
  }
  return offset;
}

/**
 * Parse with herdr 0.9.4's byte-order mark handling for a leading mark and one
 * displaced to a line start: strip a leading U+FEFF, then remove a U+FEFF at
 * the start of a line only while the parse error points at it. A U+FEFF that
 * is string data parses, so it is kept.
 */
function parseToml(toml) {
  let text = toml.startsWith(BOM) ? toml.slice(BOM.length) : toml;
  for (;;) {
    try {
      // Preserve integer types so row_gap = 1.0 is rejected like herdr's u16.
      return parse(text, { integersAsBigInt: true });
    } catch (error) {
      const offset = error instanceof TomlError && error.column === 1 ? lineStart(text, error.line) : -1;
      if (offset < 0 || !text.startsWith(BOM, offset)) throw error;
      text = text.slice(0, offset) + text.slice(offset + BOM.length);
    }
  }
}

/** Normalize only the sidebar agent layout and sort; never expose raw TOML in diagnostics. */
export function parseSidebarConfig(toml) {
  let parsed;
  try {
    parsed = parseToml(toml);
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

/**
 * Refresh on source path/existence/mtime changes. Return the current snapshot.
 * A snapshot with diagnostics is checked again, because an older plugin may
 * have rejected what this one accepts, and rewritten only when its result changes.
 */
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
  let previous;
  if (!readError) {
    try {
      const cached = JSON.parse(readFileSync(destination, "utf8"));
      if (cached.v === 1 && cached.source?.path === path &&
          cached.source.found === source.found && cached.source.mtime_ms === source.mtime_ms &&
          Array.isArray(cached.sidebar?.agents?.rows) && Array.isArray(cached.diagnostics)) {
        if (cached.diagnostics.length === 0) return cached;
        previous = cached;
      }
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
  if (previous !== undefined) {
    const { v, generated_at, ...result } = previous;
    if (isDeepStrictEqual(result, { source, ...config })) return previous;
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
