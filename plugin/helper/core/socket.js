// Finds a session's socket as the app's locator does (ADR 0031): the session's
// core.lock, else the session's default socket path, because core.lock appears
// only once a core has started for that session. The default path follows
// herdr-core 0.1.13's paths.rs and platform endpoints. A core started under
// another XDG_STATE_HOME keeps its core.lock where this does not look (ADR 0033).

import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

function isDirectory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function readLock(stateFolder) {
  try {
    return readFileSync(join(stateFolder, "core.lock"), "utf8").replace(/\n+$/, "");
  } catch {
    return "";
  }
}

/**
 * Where the normalized `session`'s core listens or would listen, read afresh on
 * each call. It reads files and starts nothing. `runUserDirectory` is where the
 * core looks when XDG_RUNTIME_DIR is unset.
 */
export function locateCoreSocket(
  session,
  { env = process.env, runUserDirectory = `/run/user/${process.getuid()}` } = {},
) {
  const stateHome = env.XDG_STATE_HOME || join(env.HOME ?? "/", ".local/state");
  const stateFolder = join(stateHome, "herdr-core", session);
  const lock = readLock(stateFolder);
  if (lock !== "") return { path: lock, source: "lock" };
  const socketFolder = env.XDG_RUNTIME_DIR
    ? join(env.XDG_RUNTIME_DIR, "herdr-core")
    : isDirectory(runUserDirectory)
      ? join(runUserDirectory, "herdr-core")
      : stateFolder;
  return { path: join(socketFolder, `${session}.sock`), source: "default" };
}
