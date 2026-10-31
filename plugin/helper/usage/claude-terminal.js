// Which process in a Terminal's record is a running Claude Code Agent. A narrow
// reading of the shared Agent rule (ADR 0032), for suggesting directories only: a
// report of Claude Code says nothing unless Claude Code holds the foreground, and
// lines and scripts a shell runs are left unread, so a suggestion may be missing but
// none comes from another program's environment.

const SHELLS = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh", "ion", "pwsh", "powershell", "cmd"]);
const NODE_PROGRAMS = new Set(["node", "nodejs", "bun"]);
const NPM_ENTRY = "/@anthropic-ai/claude-code/cli.js";

// The desktop app's wrappers and Heeler's own: what follows `$0` is the command.
const CONTINUING_WRAPPERS = new Set(['"$@"; exec "$0" -i', '"$@"; exec "${SHELL:-sh}" -i', "command $argv[2..]; exec $argv[1] -i"]);
const WRAPPERS = new Set([...CONTINUING_WRAPPERS, 'exec "$@"', "exec $argv[2..]"]);

const lastPart = (path) => (typeof path === "string" ? path.split(/[/\\]/).pop().toLowerCase().replace(/^-+/, "") : "");
const namesClaude = (value) => ["claude", "claude-code", "claude code"].includes(lastPart(value));

function holdsClaude(argv, name) {
  if (argv.length === 0) return namesClaude(name);
  if (SHELLS.has(lastPart(argv[0]))) {
    const body = argv.findIndex((argument) => WRAPPERS.has(argument));
    return body > 1 && holdsClaude(argv.slice(body + 2), "");
  }
  if (NODE_PROGRAMS.has(lastPart(argv[0])) && (argv[1]?.endsWith(NPM_ENTRY) ?? false)) return true;
  return namesClaude(argv[0]) || namesClaude(name);
}

const strings = (values) => (Array.isArray(values) ? values.filter((value) => typeof value === "string") : []);

/** The record's Claude Code process, or null when it holds no Claude Code Agent. */
export function claudeAgentPid(record) {
  // A live Terminal with no pid is between a lost process and its restart.
  if (record?.state !== "live" || !Number.isSafeInteger(record.pid) || record.pid <= 0) return null;
  const foreground = record.foreground ?? null;
  if (foreground === null) {
    // One that continues as a shell may have outlived its command.
    const launch = strings(record.argv);
    return !launch.some((argument) => CONTINUING_WRAPPERS.has(argument)) && holdsClaude(launch, "") ? record.pid : null;
  }
  if (!holdsClaude(strings(foreground.argv), foreground.name)) return null;
  return Number.isSafeInteger(foreground.pid) && foreground.pid > 0 ? foreground.pid : record.pid;
}
