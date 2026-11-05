import { statSync } from "node:fs";
import { join, resolve } from "node:path";
import { usageRoots } from "./cache.js";

const isDirectory = path => { try { return statSync(path).isDirectory(); } catch { return false; } };
const isFile = path => { try { return statSync(path).isFile(); } catch { return false; } };

/**
 * The programs Usage reads, each with what its Accounts need: the variable
 * that names its config directory, the Default Account's roots in the
 * recorded environment, where one listing finds candidate directories, and
 * what marks a directory as the program's own. Adding a program to Usage's
 * Accounts means adding an entry here and a scanner for its Transcripts.
 */
export const USAGE_PROGRAMS = {
  claude: {
    program: "claude",
    executable: "claude",
    variable: "CLAUDE_CONFIG_DIR",
    defaultRoots: runtime => usageRoots(runtime).claude,
    // The config directory's prefix is case-sensitive because Claude Desktop uses `Claude`.
    homeListings: env => [[env.HOME, ".claude"], [resolve(env.HOME, env.XDG_CONFIG_HOME || join(env.HOME, ".config")), "claude"]],
    // Claude Code's own `.claude.json` or `projects/` tells it apart from
    // third-party folders such as `~/.claude-squad`.
    looksLikeHome: path => isFile(join(path, ".claude.json")) || isDirectory(join(path, "projects")),
  },
  codex: {
    program: "codex",
    executable: "codex",
    variable: "CODEX_HOME",
    defaultRoots: runtime => usageRoots(runtime).codex,
    homeListings: env => [[env.HOME, ".codex"]],
    // A Codex home holds its sign-in or its sessions.
    looksLikeHome: path => isFile(join(path, "auth.json")) || isDirectory(join(path, "sessions")),
  },
};

/** The programs Usage reads Accounts for, in report order. */
export const ACCOUNT_PROGRAMS = Object.keys(USAGE_PROGRAMS);
