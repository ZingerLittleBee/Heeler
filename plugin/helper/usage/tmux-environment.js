// The global environment of one tmux server, which new panes inherit, in the
// shape `writeUsageRuntime` records (ADR 0033). `paths` is `{ executable,
// socket }` from the Helper's `tmux/<socket name>/paths.json`. A name the
// server leaves unset is null. The result is null when the server cannot be
// read, so the recorder keeps its last record. Asking never starts a server,
// and values are not logged. #697 calls this.

import { execFile } from "node:child_process";

import { ENVIRONMENT_NAMES } from "../shared/usage/runtime-record.js";

const TIMEOUT_MS = 3000;

function run(target) {
  return new Promise((resolve) => {
    execFile(
      target.tmux,
      ["-N", "-S", target.socket, "show-environment", "-g", "-s"],
      { timeout: TIMEOUT_MS, killSignal: "SIGKILL", maxBuffer: 1 << 20, encoding: "utf8" },
      (error, stdout) => resolve(error ? null : stdout),
    );
  });
}

// `show-environment -s` on tmux 3.3a and 3.7b: `NAME="value"; export NAME;`
// or `unset NAME;`. A name runs up to `="` or `;` (tmux names cannot contain
// `=`), so a bash function (`BASH_FUNC_module%%`) or a `.` or `-` in the name
// is one statement and is ignored unless Usage records that name. A value
// keeps its newlines inside the quotes, and `"`, `\`, `$` and `` ` `` are
// escaped with a backslash. Anything else is unreadable.
function parseShellEnvironment(text) {
  const found = new Map();
  let index = 0;
  const fail = () => {
    throw new Error("unreadable");
  };
  const skipSpace = () => {
    while (index < text.length && " \n\t\r".includes(text[index])) index += 1;
  };
  const readUntil = (marker) => {
    const at = text.indexOf(marker, index);
    if (at <= index) fail();
    const name = text.slice(index, at);
    index = at;
    return name;
  };
  const expect = (token) => {
    if (!text.startsWith(token, index)) fail();
    index += token.length;
  };
  const readQuoted = () => {
    let value = "";
    while (index < text.length) {
      const char = text[index];
      if (char === "\\") {
        if (index + 1 >= text.length) fail();
        value += text[index + 1];
        index += 2;
        continue;
      }
      if (char === '"') {
        index += 1;
        return value;
      }
      value += char;
      index += 1;
    }
    fail();
  };

  while (index < text.length) {
    skipSpace();
    if (index >= text.length) break;
    if (text.startsWith("unset ", index)) {
      index += "unset ".length;
      const name = readUntil(";");
      expect(";");
      found.set(name, null);
      continue;
    }
    const name = readUntil('="');
    expect('="');
    const value = readQuoted();
    expect(";");
    skipSpace();
    expect("export ");
    if (readUntil(";") !== name) fail();
    expect(";");
    found.set(name, value);
  }
  return found;
}

export async function readTmuxGlobalEnvironment(paths) {
  if (typeof paths?.executable !== "string" || paths.executable === ""
      || typeof paths?.socket !== "string" || paths.socket === "") return null;
  const stdout = await run({ tmux: paths.executable, socket: paths.socket });
  if (stdout === null) return null;
  let found;
  try {
    found = parseShellEnvironment(stdout);
  } catch {
    return null;
  }
  return Object.fromEntries(ENVIRONMENT_NAMES.map((name) => [name, found.has(name) ? found.get(name) : null]));
}
