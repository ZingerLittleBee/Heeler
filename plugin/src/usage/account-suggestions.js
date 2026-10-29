import { readdirSync, realpathSync, statSync } from "node:fs";
import { basename, isAbsolute, join, resolve } from "node:path";

const SUGGESTION_LIMIT = 8;
const realPath = path => { try { return realpathSync(path); } catch { return null; } };
const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };
const isFile = path => { try { return statSync(path).isFile(); } catch { return false; } };

/**
 * Directories in `$HOME` and the XDG config directory that look like a Claude
 * Code config directory, from one listing of each and never recursively.
 * Claude Code's own `.claude.json` or `projects/` tells them apart from
 * third-party folders such as `~/.claude-squad`; the config directory's prefix
 * is case-sensitive because Claude Desktop uses `Claude`.
 */
export function homeCandidates(runtime) {
  const home = runtime.env.HOME;
  const candidates = [];
  for (const [parent, prefix] of [[home, ".claude"], [resolve(home, runtime.env.XDG_CONFIG_HOME || join(home, ".config")), "claude"]]) {
    let names;
    try { names = readdirSync(parent).sort(); } catch { continue; }
    for (const name of names) {
      const path = join(parent, name);
      if (name.startsWith(prefix) && isDirectory(path) && (isFile(join(path, ".claude.json")) || isDirectory(join(path, "projects")))) candidates.push(path);
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
