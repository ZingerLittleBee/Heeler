import { accessSync, constants, existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

import { registeredSessions } from "../shared/delivery/registrations.js";

export const REX_SESSION = "rex";

function isValidUnixSocketPath(path) {
  return (
    typeof path === "string" &&
    path.length > 1 &&
    isAbsolute(path) &&
    !path.endsWith("/") &&
    !path.includes("\0") &&
    !path.includes("\n") &&
    !path.includes("\r") &&
    !path.startsWith("npipe://")
  );
}

export function readStoredRexSocket(directory) {
  try {
    const parsed = JSON.parse(readFileSync(join(directory, "rex", "socket.json"), "utf8"));
    const candidate = typeof parsed?.socket === "string" ? parsed.socket : parsed?.path;
    return isValidUnixSocketPath(candidate) ? candidate : null;
  } catch {
    return null;
  }
}

export function discoverRexSocket({
  env = process.env,
  platform = process.platform,
  home = homedir(),
  uid = process.getuid?.(),
} = {}) {
  const candidates = [];
  if (platform === "darwin") {
    if (typeof home === "string" && home !== "") {
      candidates.push(join(home, "Library", "Application Support", "rex", "server.sock"));
    }
  } else if (platform === "linux") {
    if (typeof env.REX_RUNTIME_DIR === "string" && env.REX_RUNTIME_DIR !== "") {
      candidates.push(join(env.REX_RUNTIME_DIR, "server.sock"));
    }
    if (typeof env.XDG_RUNTIME_DIR === "string" && env.XDG_RUNTIME_DIR !== "") {
      candidates.push(join(env.XDG_RUNTIME_DIR, "rex", "server.sock"));
    }
    if (Number.isInteger(uid)) {
      candidates.push(`/run/user/${uid}/rex/server.sock`);
    }
    if (typeof home === "string" && home !== "") {
      candidates.push(join(home, ".local", "state", "rex", "run", "server.sock"));
    }
    candidates.push("/run/rex/server.sock");
    candidates.push("/var/run/rex/server.sock");
  }
  const seen = new Set();
  let fallback = null;
  for (const candidate of candidates) {
    if (!isValidUnixSocketPath(candidate) || seen.has(candidate)) continue;
    seen.add(candidate);
    try {
      const info = statSync(candidate);
      if (!info.isSocket()) continue;
      accessSync(candidate, constants.R_OK | constants.W_OK);
      if (Number.isInteger(uid) && info.uid === uid) return candidate;
      if (fallback === null) fallback = candidate;
    } catch {}
  }
  return fallback;
}

export function resolveRexSocket(directory, options) {
  return readStoredRexSocket(directory) ?? discoverRexSocket(options);
}

export function wantsRexFollower(directory) {
  if (registeredSessions(directory).includes(REX_SESSION)) return true;
  if (readStoredRexSocket(directory) !== null) return true;
  return existsSync(join(directory, "rex"));
}
