// Which process in a Terminal's record is a running Claude Code Agent, by what the
// core reports of its foreground. A plain shell in the foreground means the Agent
// has exited, whatever its report still says.

const SHELLS = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh"]);
const NODE_PROGRAMS = new Set(["node", "nodejs", "bun"]);
const NPM_ENTRY = "/@anthropic-ai/claude-code/cli.js";

const lastPart = (path) => (typeof path === "string" ? path.split("/").pop().toLowerCase() : "");
const namesClaude = (value) => ["claude", "claude-code", "claude code"].includes(lastPart(value));

function isPlainShell(argv) {
  if (argv.length === 0 || !SHELLS.has(lastPart(argv[0]).replace(/^-+/, ""))) return false;
  return argv.slice(1).every((option) => /^-[il]+$/.test(option) || ["--interactive", "--login", "--norc", "--noprofile"].includes(option));
}

/** The record's Claude Code process, or null when it holds no Claude Code Agent. */
export function claudeAgentPid(record) {
  if (record?.state !== "live") return null;
  const foreground = record.foreground ?? null;
  const argv = Array.isArray(foreground?.argv) ? foreground.argv.filter((value) => typeof value === "string") : [];
  if (isPlainShell(argv)) return null;
  const running = namesClaude(foreground?.name) || namesClaude(argv[0])
    || (NODE_PROGRAMS.has(lastPart(argv[0])) && (argv[1]?.endsWith(NPM_ENTRY) ?? false));
  if (!running && !namesClaude(record.status?.app)) return null;
  const pid = foreground?.pid ?? record.pid;
  return Number.isSafeInteger(pid) && pid > 0 ? pid : null;
}
