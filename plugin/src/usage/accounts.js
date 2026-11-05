import { readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { USAGE_PROGRAMS } from "./programs.js";

// The app offers at most three added Accounts per program; more come only from a hand-edited file.
const ACCOUNT_LIMIT = 3;
const ACCOUNT_ID = /^[A-Za-z0-9_-]{8,32}$/;
// Ids key plain objects (limits.json's entries), so a name every object already has is refused.
const validId = id => typeof id === "string" && ACCOUNT_ID.test(id) && !(id in Object.prototype);
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const named = value => typeof value === "string" && value.trim() !== "";
// The native call, as the scanner's: it also gives the stored case on a volume that ignores case.
const realPath = path => { try { return realpathSync.native(path); } catch { return null; } };
const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };

/**
 * A program's section of the file: Claude Code's is `claude`, as before
 * programs had sections; every other program's is under `programs`, keyed by
 * its herdr agent kind. `programs.claude` is never Claude Code's.
 */
function section(file, program) {
  if (program === "claude") return file.claude;
  return object(file.programs) && Object.hasOwn(file.programs, program) ? file.programs[program] : null;
}

/**
 * One program's valid entries in `usage-accounts.json`, which only the app
 * writes. A missing or unreadable file, or one of another version (an app
 * newer than the plugin), adds nothing; an entry that breaks the rules is
 * skipped.
 */
export function readAccountFile(configDir, program = "claude") {
  const empty = { defaultName: null, accounts: [], ignored: [] };
  let file;
  try { file = JSON.parse(readFileSync(join(configDir, "usage-accounts.json"), "utf8")); } catch { return empty; }
  if (!object(file) || file.version !== 1) return empty;
  const entries = section(file, program);
  if (!object(entries)) return empty;
  const defaultName = named(entries.defaultName) ? entries.defaultName : null;
  const ids = new Set();
  const names = new Set(defaultName === null ? [] : [defaultName]);
  const accounts = [];
  for (const entry of Array.isArray(entries.accounts) ? entries.accounts : []) {
    if (!object(entry) || !validId(entry.id) || ids.has(entry.id)
        || typeof entry.directory !== "string" || !isAbsolute(entry.directory) || !named(entry.name) || names.has(entry.name)) continue;
    ids.add(entry.id);
    names.add(entry.name);
    // Kept as chosen: Claude Code keys its keychain item by the string it is given.
    accounts.push({ id: entry.id, directory: entry.directory, name: entry.name });
  }
  const ignored = Array.isArray(entries.ignored) ? entries.ignored.filter(path => typeof path === "string" && isAbsolute(path)) : [];
  return { defaultName, accounts, ignored };
}

/**
 * The Default Account, then the added ones in the file's order. Only `ok`
 * Accounts count; a directory that resolves to one already counted would
 * count its Transcripts twice, so it is a `duplicate`.
 */
export function programAccounts(runtime, file, program) {
  const roots = USAGE_PROGRAMS[program].defaultRoots(runtime);
  const seen = new Set(roots.map(realPath).filter(Boolean));
  let counted = 0;
  const added = file.accounts.map(({ id, directory, name }) => {
    const real = isDirectory(directory) ? realPath(directory) : null;
    let state = "missing";
    if (real && seen.has(real)) state = "duplicate";
    else if (real) {
      seen.add(real);
      state = counted++ < ACCOUNT_LIMIT ? "ok" : "overLimit";
    }
    return { id, isDefault: false, name, directory, roots: [directory], state };
  });
  return [{ id: "default", isDefault: true, name: file.defaultName, directory: roots[0], roots, state: "ok" }, ...added];
}

export function claudeAccounts(runtime, file) {
  return programAccounts(runtime, file, "claude");
}

export function readProgramAccounts(configDir, runtime, program) {
  return programAccounts(runtime, readAccountFile(configDir, program), program);
}

export function readClaudeAccounts(configDir, runtime) {
  return readProgramAccounts(configDir, runtime, "claude");
}
