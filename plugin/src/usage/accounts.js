import { readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { usageRoots } from "./cache.js";

// The app offers at most three added Accounts; more come only from a hand-edited file.
const ACCOUNT_LIMIT = 3;
const ACCOUNT_ID = /^[A-Za-z0-9_-]{8,32}$/;
// Ids key plain objects (limits.json's entries), so a name every object already has is refused.
const validId = id => typeof id === "string" && ACCOUNT_ID.test(id) && !(id in Object.prototype);
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const named = value => typeof value === "string" && value.trim() !== "";
const realPath = path => { try { return realpathSync(path); } catch { return null; } };
const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };

/**
 * The valid entries of `usage-accounts.json`, which only the app writes. A
 * missing or unreadable file, or one of another version (an app newer than
 * the plugin), adds nothing; an entry that breaks the rules is skipped.
 */
export function readAccountFile(configDir) {
  const empty = { defaultName: null, accounts: [], ignored: [] };
  let file;
  try { file = JSON.parse(readFileSync(join(configDir, "usage-accounts.json"), "utf8")); } catch { return empty; }
  if (!object(file) || file.version !== 1 || !object(file.claude)) return empty;
  const defaultName = named(file.claude.defaultName) ? file.claude.defaultName : null;
  const ids = new Set();
  const names = new Set(defaultName === null ? [] : [defaultName]);
  const accounts = [];
  for (const entry of Array.isArray(file.claude.accounts) ? file.claude.accounts : []) {
    if (!object(entry) || !validId(entry.id) || ids.has(entry.id)
        || typeof entry.directory !== "string" || !isAbsolute(entry.directory) || !named(entry.name) || names.has(entry.name)) continue;
    ids.add(entry.id);
    names.add(entry.name);
    // Kept as chosen: Claude Code keys its keychain item by the string it is given.
    accounts.push({ id: entry.id, directory: entry.directory, name: entry.name });
  }
  const ignored = Array.isArray(file.claude.ignored) ? file.claude.ignored.filter(path => typeof path === "string" && isAbsolute(path)) : [];
  return { defaultName, accounts, ignored };
}

/**
 * The Default Account, then the added ones in the file's order. Only `ok`
 * Accounts count; a directory that resolves to one already counted would
 * count its Transcripts twice, so it is a `duplicate`.
 */
export function claudeAccounts(runtime, file) {
  const roots = usageRoots(runtime).claude;
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

export function readClaudeAccounts(configDir, runtime) {
  return claudeAccounts(runtime, readAccountFile(configDir));
}
