import { randomUUID } from "node:crypto";
import { accessSync, constants, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { delimiter, isAbsolute, join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";

// Claude Code uses USER to locate its macOS keychain account. Usage Limits
// requests need herdr's proxy and CA settings on networks that require them;
// a proxy URL may embed credentials, so runtime.json stays private (0600).
const PROXY_NAMES = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
  "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE"];
const ENVIRONMENT_NAMES = ["PATH", "HOME", "USER", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", ...PROXY_NAMES];

function executableOnPath(name, path) {
  if (typeof path !== "string") return null;
  for (const directory of path.split(delimiter)) {
    const candidate = resolve(directory, name);
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Continue to the next PATH entry, as the shell does.
    }
  }
  return null;
}

function writeAtomic(path, contents) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, contents, { mode: 0o600, flag: "wx" });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}

/** Record only the environment that locates programs, accounts and Transcripts. */
export function recordUsageRuntime(configDir) {
  const stateDir = process.env.HERDR_PLUGIN_STATE_DIR;
  // Older callers can still refresh sidebar state, without inventing Usage roots.
  if (!stateDir || !process.env.HOME) return;
  const fields = {
    version: 1,
    node: process.execPath,
    codex: executableOnPath("codex", process.env.PATH),
    claude: executableOnPath("claude", process.env.PATH),
    herdr: isAbsolute(process.env.HERDR_BIN_PATH ?? "") ? process.env.HERDR_BIN_PATH : null,
    env: Object.fromEntries(ENVIRONMENT_NAMES.map((name) => [name, process.env[name] ?? null])),
    stateDir,
  };
  const runtimePath = join(configDir, "runtime.json");
  const nodePath = join(configDir, "runtime-node");
  let previous;
  try {
    const { recordedAt, ...recorded } = JSON.parse(readFileSync(runtimePath, "utf8"));
    previous = recorded;
  } catch {
    // A missing or interrupted previous write is repaired by this hook.
  }
  let previousNode;
  try { previousNode = readFileSync(nodePath, "utf8"); } catch { /* First hook. */ }
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  if (!isDeepStrictEqual(previous, fields)) {
    writeAtomic(runtimePath, JSON.stringify({ ...fields, recordedAt: new Date().toISOString() }) + "\n");
  }
  // Publish the bootstrap path only after its JSON record exists.
  if (previousNode !== fields.node + "\n") writeAtomic(nodePath, fields.node + "\n");
}

export function readUsageRuntime(configDir) {
  if (!configDir) return null;
  try {
    const runtime = JSON.parse(readFileSync(join(configDir, "runtime.json"), "utf8"));
    const node = readFileSync(join(configDir, "runtime-node"), "utf8");
    if (runtime?.version !== 1 || typeof runtime.node !== "string" || !isAbsolute(runtime.node)
        || node !== runtime.node + "\n" || typeof runtime.stateDir !== "string"
        || !isAbsolute(runtime.stateDir) || typeof runtime.env?.HOME !== "string"
        || !isAbsolute(runtime.env.HOME)) return null;
    return runtime;
  } catch {
    return null;
  }
}
