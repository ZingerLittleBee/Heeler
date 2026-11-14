// The global environment of one tmux server, which new panes inherit, in the
// shape `writeUsageRuntime` records (ADR 0033, ADR 0045). `paths` is
// `{ executable, socket }` from the Helper's `tmux/<socket name>/paths.json`.
// Each variable in `ENVIRONMENT_NAMES` is queried by name so unrelated secrets
// in the server's environment are never dumped. A name the server leaves unset
// is null. The result is null when the server cannot be read, so the recorder
// keeps its last record. Asking never starts a server, and values are not logged.

import { execFile } from "node:child_process";

import { ENVIRONMENT_NAMES } from "../shared/usage/runtime-record.js";

const TIMEOUT_MS = 3000;

const EQ_QUOTE = Buffer.from('="', "utf8");
const UNSET_PREFIX = Buffer.from("unset ", "utf8");
const EXPORT_PREFIX = Buffer.from("export ", "utf8");
const SEMICOLON = Buffer.from(";", "utf8");

function runNamed(target, name, timeoutMs) {
  return new Promise((resolve) => {
    execFile(
      target.tmux,
      ["-N", "-S", target.socket, "-u", "show-environment", "-g", "-s", name],
      { timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer: 1 << 20, encoding: "buffer" },
      (error, stdout, stderr) => {
        if (!error) {
          resolve({ ok: true, stdout });
          return;
        }
        const message = Buffer.isBuffer(stderr) ? stderr.toString("utf8").trim() : String(stderr ?? "").trim();
        if (error.code === 1 && !error.killed && error.signal == null && message === `unknown variable: ${name}`) {
          resolve({ ok: true, stdout: null });
          return;
        }
        resolve({ ok: false, stdout: null });
      },
    );
  });
}

function cEscapeByte(code) {
  switch (code) {
    case 0x61:
      return 0x07; // \a
    case 0x62:
      return 0x08; // \b
    case 0x66:
      return 0x0c; // \f
    case 0x72:
      return 0x0d; // \r
    case 0x76:
      return 0x0b; // \v
    default:
      return -1;
  }
}

function isOctalDigit(code) {
  return code >= 0x30 && code <= 0x37;
}

// `show-environment -s` on tmux 3.3+: `NAME="value"; export NAME;` or
// `unset NAME;`. A name runs up to `="` or `;` (tmux names cannot contain `=`),
// so a bash function (`BASH_FUNC_module%%`) or a `.` or `-` in the name is one
// statement and is ignored unless Usage records that name. Inside the quotes,
// `cmd_show_environment_escape` prefixes `"`, `\`, `$` and `` ` `` with `\`; on
// tmux 3.4 and 3.5a, `cmdq_print` also applies `strvis` (`\a\b\f\r\v`, `\ooo`,
// and in 3.4 `\$` before `[A-Za-z_{]`, turning `\$VAR` into `\\$VAR`).
function parseShellEnvironment(input) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input, "utf8");
  const found = new Map();
  let index = 0;
  const fail = () => {
    throw new Error("unreadable");
  };
  const isSpace = (b) => b === 0x20 || b === 0x0a || b === 0x09 || b === 0x0d;
  const skipSpace = () => {
    while (index < buffer.length && isSpace(buffer[index])) index += 1;
  };
  const startsWith = (token) =>
    index + token.length <= buffer.length && buffer.subarray(index, index + token.length).equals(token);
  const readUntil = (marker) => {
    const at = buffer.indexOf(marker, index);
    if (at <= index) fail();
    const name = buffer.subarray(index, at).toString("utf8");
    index = at;
    return name;
  };
  const expect = (token) => {
    if (!startsWith(token)) fail();
    index += token.length;
  };
  const readQuoted = () => {
    const bytes = [];
    while (index < buffer.length) {
      let slashes = 0;
      while (index < buffer.length && buffer[index] === 0x5c) {
        slashes += 1;
        index += 1;
      }
      if (index >= buffer.length) fail();
      const b = buffer[index];

      if (slashes === 0) {
        if (b === 0x22) {
          index += 1;
          return Buffer.from(bytes).toString("utf8");
        }
        if (b === 0x24 || b === 0x60) fail();
        bytes.push(b);
        index += 1;
        continue;
      }

      if (b === 0x24) {
        const rawSlashes = Math.floor((slashes - 1) / 2);
        for (let k = 0; k < rawSlashes; k += 1) bytes.push(0x5c);
        bytes.push(0x24);
        index += 1;
        continue;
      }

      const half = Math.floor(slashes / 2);
      for (let k = 0; k < half; k += 1) bytes.push(0x5c);
      if (slashes % 2 === 0) continue;

      if (b === 0x22 || b === 0x60) {
        bytes.push(b);
        index += 1;
        continue;
      }

      const cEsc = cEscapeByte(b);
      if (cEsc >= 0) {
        bytes.push(cEsc);
        index += 1;
        continue;
      }

      if (
        index + 2 < buffer.length &&
        isOctalDigit(b) &&
        isOctalDigit(buffer[index + 1]) &&
        isOctalDigit(buffer[index + 2])
      ) {
        const value = ((b - 0x30) << 6) | ((buffer[index + 1] - 0x30) << 3) | (buffer[index + 2] - 0x30);
        if (value > 0xff) fail();
        bytes.push(value);
        index += 3;
        continue;
      }

      fail();
    }
    fail();
  };

  while (index < buffer.length) {
    skipSpace();
    if (index >= buffer.length) break;
    if (startsWith(UNSET_PREFIX)) {
      index += UNSET_PREFIX.length;
      const name = readUntil(SEMICOLON);
      expect(SEMICOLON);
      found.set(name, null);
      continue;
    }
    const name = readUntil(EQ_QUOTE);
    expect(EQ_QUOTE);
    const value = readQuoted();
    expect(SEMICOLON);
    skipSpace();
    expect(EXPORT_PREFIX);
    if (readUntil(SEMICOLON) !== name) fail();
    expect(SEMICOLON);
    found.set(name, value);
  }
  return found;
}

export async function readTmuxGlobalEnvironment(paths) {
  if (typeof paths?.executable !== "string" || paths.executable === ""
      || typeof paths?.socket !== "string" || paths.socket === "") return null;
  const target = { tmux: paths.executable, socket: paths.socket };
  const deadline = Date.now() + TIMEOUT_MS;
  const environment = {};
  for (const name of ENVIRONMENT_NAMES) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return null;
    const step = await runNamed(target, name, remaining);
    if (!step.ok) return null;
    if (step.stdout === null) {
      environment[name] = null;
      continue;
    }
    let found;
    try {
      found = parseShellEnvironment(step.stdout);
    } catch {
      return null;
    }
    if (found.size !== 1 || !found.has(name)) return null;
    environment[name] = found.get(name);
  }
  return environment;
}
