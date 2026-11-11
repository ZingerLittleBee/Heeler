// Which Terminal is an Agent (ADR 0032): the app's HerdrCoreAgentRule read on the
// Host. A Terminal is one while a known agent program holds its foreground, or
// while any program but a shell does and it has a Program Status whose `app` is
// missing or unknown here. A known `app` counts only while it names the foreground,
// or under a `-NoExit` PowerShell that is not at its prompt: nothing ties a report
// to a process, and the core keeps the report after its program left. A `-NoExit`
// PowerShell, whose foreground never changes, is its shell while the Terminal's
// title is that PowerShell's own path.
//
// plugin/test-vectors/herdr-core-agent-rule-v1.json holds this rule's cases for both
// sides, so a change here changes that file and the app's rule in one commit.

/** What a harness calls itself in a Program Status, to the kind Heeler calls it. */
export const REPORTED_APPS = {
  "claude-code": "claude",
  codex: "codex",
  opencode: "opencode",
  pi: "pi",
  omp: "omp",
  "grok-build": "grok",
};

const reportedKind = (app) => (Object.hasOwn(REPORTED_APPS, app) ? REPORTED_APPS[app] : null);

// The app's SupportedAgentKind.
const SUPPORTED_KINDS = new Set([
  "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode", "copilot",
  "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "maki", "muse", "qwen",
]);

const ALIASES = new Map([
  ["claude-code", "claude"],
  ["claude code", "claude"],
  ["pi-cli", "pi"],
  ["cursor-agent", "cursor"],
  ["kiro-cli", "kiro"],
  ["antigravity", "agy"],
  ["github-copilot", "copilot"],
  ["grok-build", "grok"],
]);

const SHELLS = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh", "ion", "pwsh", "powershell", "cmd"]);
const INTERPRETERS = new Set(["node", "nodejs", "bun", "deno", "python", "python3", "ruby"]);

// The desktop app's `"$@"; exec "$0" -i`, and its remote and fish forms.
const CONTINUING_WRAPPER_BODIES = new Set(['"$@"; exec "$0" -i', '"$@"; exec "${SHELL:-sh}" -i', "command $argv[2..]; exec $argv[1] -i"]);
// The bodies whose arguments are the command to run: the desktop app's, and
// Heeler's own, which exec the agent and leave no shell behind.
const WRAPPER_BODIES = new Set([...CONTINUING_WRAPPER_BODIES, 'exec "$@"', "exec $argv[2..]"]);
// Options of a shell that take the next argument, which is no script.
const SHELL_VALUE_OPTIONS = new Set(["--rcfile", "--init-file", "--init-command", "-C", "-o", "+o", "-O", "+O"]);

// What leads a command and is not the program.
const COMMAND_PREFIXES = new Set(["exec", "command", "builtin", "nohup", "noglob"]);
// Commands that set a line up for the one after them.
const SETUP_COMMANDS = new Set(["cd", "pushd", "export", "unset", "set", "source", ".", ":", "true", "umask", "ulimit", "trap"]);

// Script entry points named for their package, not for the program.
const ENTRY_POINTS = [
  [["@anthropic-ai", "claude-code", "cli.js"], "claude"],
  [["@google", "gemini-cli", "dist", "index.js"], "gemini"],
  [["@mariozechner", "pi-coding-agent", "dist", "cli.js"], "pi"],
  [["@earendil-works", "pi-coding-agent", "dist", "cli.js"], "pi"],
  [["@earendil-works", "pi-coding-agent", "dist", "bundle", "cli.js"], "pi"],
  [["@openai", "codex", "bin", "codex.js"], "codex"],
];
// `npm exec` and its alias `npm x`, which `npx` runs.
const PACKAGE_RUNNER_COMMANDS = new Set(["exec", "x"]);
// Options of `npx` and `npm exec` that take no value.
const PACKAGE_RUNNER_FLAGS = new Set(["-y", "--yes", "--no", "--prefer-offline", "--prefer-online", "--offline", "-q", "--quiet", "--silent"]);
// Options that name the package whose command runs.
const PACKAGE_OPTIONS = new Set(["-p", "--package"]);
// npm packages whose name is not their program's.
const PACKAGES = new Map([
  ["@anthropic-ai/claude-code", "claude"],
  ["@google/gemini-cli", "gemini"],
  ["@mariozechner/pi-coding-agent", "pi"],
  ["@earendil-works/pi-coding-agent", "pi"],
  ["@openai/codex", "codex"],
  ["opencode-ai", "opencode"],
  ["@opencode/cli", "opencode"],
]);
const INTERPRETER_FLAGS = new Set(["--no-warnings", "--enable-source-maps", "--experimental-strip-types", "-u", "-B"]);
const INTERPRETER_VALUE_OPTIONS = new Set(["-r", "--require", "--import", "--loader", "--experimental-loader"]);

const MAXIMUM_DEPTH = 8;
const MAXIMUM_KIND_LENGTH = 32;

// Every word a table kept by program could take for one it knows. A generic kind
// spelled like one keeps a prefix, so it stays a word to show.
const RESERVED_KINDS = new Set([...SUPPORTED_KINDS, "cursor-agent", "kiro-cli", ...Object.keys(REPORTED_APPS), ...ALIASES.keys(), "unknown"]);

const SHELL_PROGRAM = { shell: true };
const known = (kind) => ({ known: kind });
const other = (name) => ({ other: name });

const strings = (values) => (Array.isArray(values) ? values.filter((value) => typeof value === "string") : []);
const text = (value) => (typeof value === "string" ? value : "");

const pathComponents = (path) => path.split(/[/\\]/).filter((part) => part !== "");

/** The last path component, in lower case, with a login shell's `-` and a Windows executable's extension gone. */
function baseName(path) {
  let name = (pathComponents(path).at(-1) ?? "").replace(/^-+/, "").toLowerCase();
  for (const suffix of [".exe", ".cmd"]) {
    if (name.endsWith(suffix)) name = name.slice(0, -suffix.length);
  }
  return name;
}

function knownKind(name) {
  if (ALIASES.has(name)) return ALIASES.get(name);
  return SUPPORTED_KINDS.has(name) ? name : null;
}

function scriptProgram(path) {
  const components = pathComponents(path).map((part) => part.toLowerCase());
  const last = components.at(-1);
  if (last === undefined) return other(path);
  for (const [suffix, kind] of ENTRY_POINTS) {
    if (suffix.length <= components.length && components.slice(-suffix.length).every((part, index) => part === suffix[index])) {
      return known(kind);
    }
  }
  const extension = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".sh"].find((suffix) => last.endsWith(suffix));
  const stem = extension === undefined ? last : last.slice(0, -extension.length);
  const kind = knownKind(stem);
  return kind === null ? other(stem) : known(kind);
}

/**
 * Only the script position counts: `node server.js claude` is `server`. An option
 * this does not know may take a value, and evaluated source is no script's name,
 * so either leaves the interpreter as the program.
 */
function readInterpreter(args, name) {
  let index = 1;
  if ((name === "bun" || name === "deno") && args[1] === "run") index = 2;
  while (index < args.length) {
    const argument = args[index];
    if (argument === "--") {
      index += 1;
      break;
    }
    if (!argument.startsWith("-")) break;
    if (INTERPRETER_FLAGS.has(argument)) index += 1;
    else if (INTERPRETER_VALUE_OPTIONS.has(argument)) index += 2;
    else return other(name);
  }
  return index < args.length ? scriptProgram(args[index]) : other(name);
}

/** `-c`, or several short options ending in it, as `-ic` and `-lc`. */
function isCommandOption(argument) {
  return argument.startsWith("-") && !argument.startsWith("--") && argument.includes("c") && /^\p{L}*$/u.test(argument.slice(1));
}

const isAssignment = (word) => {
  const equals = word.indexOf("=");
  return equals > 0 && /^[\p{L}\p{N}_]+$/u.test(word.slice(0, equals));
};

/** One command's words without assignments, prefixes and `env`'s own. */
function commandWords(words) {
  let rest = words;
  while (rest.length > 0) {
    const word = rest[0];
    if (isAssignment(word) || COMMAND_PREFIXES.has(word)) {
      rest = rest.slice(1);
    } else if (word === "env") {
      rest = rest.slice(1);
      while (rest[0]?.startsWith("-")) rest = rest.slice(1);
    } else {
      break;
    }
  }
  return rest;
}

/** A shell line's commands as words, quotes resolved and cut at each operator. Reads enough of the grammar to find a command's program. */
function shellCommands(line) {
  const commands = [];
  let words = [];
  let word = "";
  let inWord = false;
  let quote = null;
  let escaped = false;
  const endWord = () => {
    if (inWord) words.push(word);
    word = "";
    inWord = false;
  };
  const endCommand = () => {
    endWord();
    if (words.length > 0) commands.push(words);
    words = [];
  };
  for (const character of line) {
    if (escaped) {
      word += character;
      escaped = false;
    } else if (quote !== null) {
      if (character === quote) quote = null;
      else if (character === "\\" && quote === '"') escaped = true;
      else word += character;
    } else if (character === "'" || character === '"') {
      quote = character;
      inWord = true;
    } else if (character === "\\") {
      escaped = true;
      inWord = true;
    } else if (character === " " || character === "\t") {
      endWord();
    } else if ("\n;&|()".includes(character)) {
      endCommand();
    } else {
      word += character;
      inWord = true;
    }
  }
  endCommand();
  return commands;
}

/** The program of a `sh -c` line: its first command past any setup. Only command positions count: `echo claude` is `echo`. */
function readLine(line, depth) {
  const commands = shellCommands(line).map(commandWords).filter((words) => words.length > 0);
  for (const [position, words] of commands.entries()) {
    if (SETUP_COMMANDS.has(words[0]) && position < commands.length - 1) continue;
    return read(words, depth);
  }
  return SHELL_PROGRAM;
}

const POWERSHELL_QUOTES = new Set(["'", "‘", "’", "‚", "‛"]);

/** The desktop app's `powershell_line` read back: each word quoted, a quote inside one doubled. */
function powerShellWords(line) {
  if (!line.startsWith("& ")) return null;
  const characters = [...line.slice(2)];
  const words = [];
  let index = 0;
  while (index < characters.length) {
    if (characters[index] === " ") {
      index += 1;
      continue;
    }
    if (!POWERSHELL_QUOTES.has(characters[index])) return null;
    index += 1;
    let word = "";
    while (index < characters.length) {
      if (POWERSHELL_QUOTES.has(characters[index])) {
        if (!POWERSHELL_QUOTES.has(characters[index + 1])) break;
        index += 1;
      }
      word += characters[index];
      index += 1;
    }
    index += 1;
    words.push(word);
  }
  return words;
}

/** `pwsh -NoExit -Command "& 'prog' 'arg'"`, as the desktop app runs it, and `-Command "& 'prog' 'arg'; exit $LASTEXITCODE"`, as Heeler does. */
function readPowerShell(args, name, depth) {
  const option = args.findIndex((argument) => ["-command", "-c"].includes(argument.toLowerCase()));
  if (option === -1) {
    if (args.slice(1).some(isNoExitOption)) return other(name);
    return args.slice(1).some((argument) => !argument.startsWith("-")) ? other(name) : SHELL_PROGRAM;
  }
  if (option + 1 >= args.length) return SHELL_PROGRAM;
  const exit = "; exit $LASTEXITCODE";
  const line = args[option + 1].endsWith(exit) ? args[option + 1].slice(0, -exit.length) : args[option + 1];
  const words = powerShellWords(line);
  return words === null ? other(name) : read(words, depth + 1);
}

/** A wrapper, a line or a script is what the shell runs. A shell with options alone is the prompt, which ends the Agent. */
function readShell(args, name, depth) {
  if (name === "pwsh" || name === "powershell") return readPowerShell(args, name, depth);
  let index = 1;
  while (index < args.length) {
    const argument = args[index];
    if (name === "cmd" && ["/c", "/k"].includes(argument.toLowerCase())) return read(args.slice(index + 1), depth + 1);
    if (isCommandOption(argument)) {
      if (index + 1 >= args.length) return SHELL_PROGRAM;
      const body = args[index + 1];
      // After the body comes `$0`, then the command.
      if (WRAPPER_BODIES.has(body)) return read(args.slice(index + 3), depth + 1);
      return readLine(body, depth + 1);
    }
    if (SHELL_VALUE_OPTIONS.has(argument)) index += 2;
    else if (argument.startsWith("-") || argument.startsWith("+")) index += 1;
    else return scriptProgram(argument);
  }
  return SHELL_PROGRAM;
}

/**
 * npm sets its process title to `npm` and its positional arguments (npm 11
 * `lib/npm.js`), so on Linux the process reads as `npm exec claude` (hc-lab, `npx
 * claude`, 2026-11-02), which the arguments hold as one word, and a scoped package
 * keeps its `/` there. Its words, when it is one: the first word is `npx` or `npm`
 * itself, so a path never reads as one.
 */
function packageRunnerTitle(word) {
  const words = word.split(" ").filter((part) => part !== "");
  if (words.length < 2) return null;
  const isRunner = words[0] === "npx" || (words[0] === "npm" && PACKAGE_RUNNER_COMMANDS.has(words[1]));
  return isRunner ? words : null;
}

/** A package spec's name, without its version: `@scope/name@1.2.3` is `@scope/name`. */
function packageName(spec) {
  const lowered = spec.toLowerCase();
  const at = lowered.indexOf("@", lowered.startsWith("@") ? 1 : 0);
  return at === -1 ? lowered : lowered.slice(0, at);
}

/**
 * `npx [options] <package or command> [arguments]`: the agent the package or command
 * names. With `--package` the word is the package's command. An option this does not
 * know may take a value, and `--call` runs a line, so either leaves the runner as the
 * program.
 */
function readPackageRunner(args, name, depth) {
  let index = 0;
  let namesACommand = false;
  while (index < args.length) {
    const argument = args[index];
    if (argument === "--") {
      index += 1;
      break;
    }
    if (!argument.startsWith("-")) break;
    if (PACKAGE_RUNNER_FLAGS.has(argument)) index += 1;
    else if (PACKAGE_OPTIONS.has(argument)) {
      namesACommand = true;
      index += 2;
    } else if (argument.startsWith("--package=")) {
      namesACommand = true;
      index += 1;
    } else return other(name);
  }
  if (index >= args.length) return other(name);
  const word = args[index];
  if (namesACommand || (word.includes("/") && !word.startsWith("@")) || word.includes("\\")) return read([word], depth + 1);
  const pkg = packageName(word);
  const command = pkg.split("/").at(-1) ?? "";
  const kind = PACKAGES.get(pkg) ?? knownKind(command);
  if (kind !== null && kind !== undefined) return known(kind);
  return other(command === "" ? name : command);
}

function read(args, depth = 0) {
  if (depth >= MAXIMUM_DEPTH || args.length === 0) return SHELL_PROGRAM;
  if (args.slice(1).every((argument) => argument === "")) {
    const title = packageRunnerTitle(args[0]);
    if (title !== null) return read(title, depth + 1);
  }
  const name = baseName(args[0]);
  if (SHELLS.has(name)) return readShell(args, name, depth);
  if (INTERPRETERS.has(name)) return readInterpreter(args, name);
  if (name === "npx") return readPackageRunner(args.slice(1), name, depth);
  if (name === "npm" && args.length > 1 && PACKAGE_RUNNER_COMMANDS.has(args[1])) return readPackageRunner(args.slice(2), name, depth);
  const kind = knownKind(name);
  return kind === null ? other(name) : known(kind);
}

/**
 * A launch stands in for a foreground not sampled yet, and a record omits a cleared
 * one, so this can also be long after the launch. One that continues as a shell may
 * have outlived its command, so only a sample can name it.
 */
function continuesAsShell(args) {
  if (args.length === 0 || !SHELLS.has(baseName(args[0]))) return false;
  return args.slice(1).some((argument) => CONTINUING_WRAPPER_BODIES.has(argument) || ["-noexit", "/k"].includes(argument.toLowerCase()));
}

const readLaunch = (args) => (continuesAsShell(args) ? SHELL_PROGRAM : read(args));

/** `-NoExit` as PowerShell takes it: any case, `-`, `--` or `/`, and cut short as far as `-NoE`. */
function isNoExitOption(argument) {
  const option = argument.toLowerCase();
  const prefix = ["--", "-", "/"].find((candidate) => option.startsWith(candidate));
  if (prefix === undefined) return false;
  const name = option.slice(prefix.length);
  return [...name].length >= 3 && "noexit".startsWith(name);
}

/**
 * A pseudo console's foreground stays the desktop app's `-NoExit` PowerShell after its
 * program exits, so only the console's title shows the exit: it goes back to that
 * PowerShell's own path (ADR 0032). A console nothing has titled reads an empty title
 * instead, which keeps the foreground's reading.
 */
function showsPowerShellPrompt(args, title) {
  if (args.length === 0) return false;
  const name = baseName(args[0]);
  if ((name !== "powershell" && name !== "pwsh") || !args.slice(1).some(isNoExitOption)) return false;
  const trimmed = title.trim();
  return /[/\\]/.test(trimmed) && baseName(trimmed) === name;
}

/** The foreground, or without one what the Terminal launched. */
function programOf(record) {
  const launch = strings(record.argv);
  const foreground = record.foreground ?? null;
  if (foreground === null) return readLaunch(launch);
  const args = strings(foreground.argv);
  const name = text(foreground.name);
  if (args.length === 0) return name === "" ? readLaunch(launch) : read([name]);
  if (showsPowerShellPrompt(args, text(record.title))) return SHELL_PROGRAM;
  const program = read(args);
  // A process whose arguments say nothing known can still be known by its OS
  // name, as a native install running from a versioned path is.
  if (program.other !== undefined) {
    const kind = knownKind(baseName(name));
    if (kind !== null) return known(kind);
  }
  return program;
}

/** Done is per device, so a report of done reads idle here. */
function statusWord(state) {
  if (state === "idle" || state === "done") return "idle";
  return ["working", "blocked", "error"].includes(state) ? state : "unknown";
}

/** Lower-case ASCII letters and digits, `_` and single `-`, at most 32. Any process on the core can report any `app`. */
function sanitized(value) {
  let kept = "";
  for (const character of value.toLowerCase()) {
    if (/^[a-z0-9_]$/.test(character)) kept += character;
    else if (kept !== "" && !kept.endsWith("-")) kept += "-";
  }
  const kind = kept.slice(0, MAXIMUM_KIND_LENGTH).replace(/-+$/, "");
  return kind === "" ? null : kind;
}

function genericKind(app, program) {
  const kind = sanitized(app) ?? sanitized(program) ?? "program";
  return RESERVED_KINDS.has(kind) ? `other-${kind}` : kind;
}

/** Between losing a kept Terminal's program and its new shell: live, with no process and a reason that is not a first spawn still pending. */
function isRestarting(record) {
  return record.state === "live" && (record.pid ?? null) === null && typeof record.reason === "string" && record.reason !== "spawn_pending";
}

/**
 * The Agent a Terminal's record holds right now as `{kind, known, status}`, or null
 * for none. `status` is the Agent Status word: idle, working, blocked, error or
 * unknown. `known` is false for a program Heeler does not know.
 */
export function agentIn(record) {
  if (record.state === "finished" || isRestarting(record)) return null;
  const program = programOf(record);
  if (program.shell) return null;
  const report = record.status ?? null;
  const app = text(report?.app).trim();
  if (program.known !== undefined) {
    const reported = reportedKind(app.toLowerCase());
    const foreign = report === null || (reported !== null && reported !== program.known);
    return { kind: program.known, known: true, status: foreign ? "unknown" : statusWord(report.state) };
  }
  if (report === null) return null;
  const reported = reportedKind(app.toLowerCase());
  if (reported !== null) {
    if (!SHELLS.has(baseName(program.other))) return null;
    return { kind: reported, known: true, status: statusWord(report.state) };
  }
  return { kind: genericKind(app, program.other), known: false, status: statusWord(report.state) };
}
