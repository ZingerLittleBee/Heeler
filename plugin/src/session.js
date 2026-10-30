// The herdr session a hook process runs under, and what it scopes.
//
// Every herdr session of one remote user runs this plugin's hooks with the
// same HERDR_PLUGIN_CONFIG_DIR and HERDR_PLUGIN_STATE_DIR, and pane ids repeat
// across sessions. A Notification Registration entry therefore names the
// session it was written for (`session`, README.md), and each hook delivers
// only to entries of its own session plus legacy entries without one
// (`deliversToSession`, src/delivery/registrations.js).
//
// The session comes from HERDR_SOCKET_PATH (observed on herdr 0.9.3), not
// HERDR_SESSION, which hooks inherit from the server's environment and can
// be stale under a socket override. herdr places sockets at
// `<config>/herdr/herdr.sock` for the default session and
// `<config>/herdr/sessions/<name>/herdr.sock` for a named one.

import { join } from "node:path";

const NAMED_SOCKET = /\/herdr\/sessions\/([^/]+)\/herdr\.sock$/;
const DEFAULT_SOCKET_SUFFIX = "/herdr/herdr.sock";
const MAX_SESSION_NAME_BYTES = 64;
const SESSION_NAME_BYTES = /^[0-9A-Za-z._-]+$/;

/**
 * herdr's session name rule, matching the app's HerdrSessionName.isValid:
 * 1-64 bytes of ASCII letters, digits, `.`, `_` and `-`, excluding `.` and
 * `..`. Every allowed character is one byte, so the length is the byte count.
 */
export function isValidSessionName(name) {
  if (typeof name !== "string" || name === "." || name === "..") return false;
  return name.length <= MAX_SESSION_NAME_BYTES && SESSION_NAME_BYTES.test(name);
}

/**
 * Map a socket path to the session it serves: "" for the default session,
 * the name for a named session, null when the shape is unknown. The named
 * shape is checked first so a session literally named "herdr" is not read as
 * the default.
 */
export function sessionFromSocketPath(socketPath) {
  if (typeof socketPath !== "string" || socketPath.length === 0) return "";
  const named = NAMED_SOCKET.exec(socketPath);
  if (named !== null && isValidSessionName(named[1])) return named[1];
  if (socketPath.endsWith(DEFAULT_SOCKET_SUFFIX)) return "";
  return null;
}

/** The session of the current hook process (see sessionFromSocketPath). */
export function hookSession(env = process.env) {
  return sessionFromSocketPath(env.HERDR_SOCKET_PATH);
}

/**
 * The state directory for one session's dedupe and claim files. Named
 * sessions get `<state>/sessions/<name>`; the default and unknown sessions
 * keep the plugin state directory itself, where earlier versions wrote.
 */
export function sessionStateDir(stateDir, session) {
  if (typeof session !== "string" || session.length === 0) return stateDir;
  return join(stateDir, "sessions", session);
}
