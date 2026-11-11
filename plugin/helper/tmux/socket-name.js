// The socket name and stored paths of a tmux server in the Helper's directory
// (`tmux/<socket>/paths.json`, ADRs 0042 and 0044). Matches `TmuxSocketName`
// and `TmuxPaths` in the app.

import { readFileSync, readdirSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";

const AROUND = /^\p{White_Space}+|\p{White_Space}+$/gu;
const VALID_SOCKET_NAME = /^[A-Za-z0-9._-]+$/;
const MAXIMUM_UTF8_LENGTH = 64;

/** A valid tmux socket name (`default` when blank), or null. */
export function normalizeTmuxSocketName(raw) {
  if (typeof raw !== "string") return null;
  const name = raw.replace(AROUND, "") || "default";
  if (
    name === "." ||
    name === ".." ||
    name.startsWith("-") ||
    Buffer.byteLength(name, "utf8") > MAXIMUM_UTF8_LENGTH ||
    !VALID_SOCKET_NAME.test(name)
  ) {
    return null;
  }
  return name;
}

function isQuotableAbsolute(path) {
  return (
    typeof path === "string" &&
    path.length > 1 &&
    isAbsolute(path) &&
    !path.endsWith("/") &&
    !path.includes("\0") &&
    !path.includes("\n") &&
    !path.includes("\r")
  );
}

/** Reads `tmux/<socket>/paths.json` when it names `socket`, else null. */
export function readStoredTmuxPaths(directory, socket) {
  const normalized = normalizeTmuxSocketName(socket);
  if (normalized === null || normalized !== socket) return null;
  try {
    const parsed = JSON.parse(readFileSync(join(directory, "tmux", socket, "paths.json"), "utf8"));
    const executable = parsed?.executable;
    const socketPath = parsed?.socket;
    if (!isQuotableAbsolute(executable) || !isQuotableAbsolute(socketPath)) return null;
    if (basename(socketPath) !== socket) return null;
    return { executable, socket: socketPath };
  } catch {
    return null;
  }
}

/** Every valid stored tmux server under `directory/tmux`, keyed by socket name. */
export function storedTmuxServers(directory) {
  const servers = new Map();
  let entries;
  try {
    entries = readdirSync(join(directory, "tmux"), { withFileTypes: true });
  } catch {
    return servers;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const paths = readStoredTmuxPaths(directory, entry.name);
    if (paths !== null) servers.set(entry.name, paths);
  }
  return servers;
}
