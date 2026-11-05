import { readdirSync, realpathSync, statSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { USAGE_PROGRAMS } from "./programs.js";

const SUGGESTION_LIMIT = 8;
// The native call gives the stored case on a volume that ignores case, as the Accounts' check does.
const realPath = path => { try { return realpathSync.native(path); } catch { return null; } };
const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };

/**
 * Directories that look like the program's config directory, from one
 * listing of each of its parents (`$HOME`, and for Claude Code the XDG
 * config directory) and never recursively. The program's own markers tell
 * them apart from third-party folders with the same prefix.
 */
export function homeCandidates(runtime, program = "claude") {
  const { homeListings, looksLikeHome } = USAGE_PROGRAMS[program];
  const candidates = [];
  for (const [parent, prefix] of homeListings(runtime.env)) {
    let names;
    try { names = readdirSync(parent).sort(); } catch { continue; }
    for (const name of names) {
      const path = join(parent, name);
      if (name.startsWith(prefix) && isDirectory(path) && looksLikeHome(path)) candidates.push(path);
    }
  }
  return candidates;
}

/**
 * The directories offered as Accounts: running Agents' first, then the home
 * listing's, leaving out what the Accounts already count and what the user
 * dismissed. Of two with one real path the Agent's wins, since its string is
 * the one Claude Code was given.
 */
export function accountSuggestions({ agents, candidates, accounts, ignored }) {
  const known = [...accounts.flatMap(account => account.roots), ...ignored];
  const strings = new Set(known);
  const seen = new Set(known.map(realPath).filter(Boolean));
  const suggestions = [];
  for (const [directory, source] of [...agents.map(path => [path, "agent"]), ...candidates.map(path => [path, "home"])]) {
    if (suggestions.length === SUGGESTION_LIMIT) break;
    if (typeof directory !== "string" || !isAbsolute(directory) || strings.has(directory)) continue;
    // A directory gone since it was seen cannot be added.
    const real = isDirectory(directory) ? realPath(directory) : null;
    if (real === null || seen.has(real)) continue;
    seen.add(real);
    suggestions.push({ directory, name: basename(directory).replace(/^\./, ""), source });
  }
  return suggestions;
}
