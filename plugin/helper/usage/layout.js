// Where Usage's files sit in the Helper's directory. The app's Usage script reads
// the same `sessions/<session>` paths, and makes the folder of the session it asks
// about, which is how a session no device registered comes to be followed.

import { readdirSync } from "node:fs";
import { join } from "node:path";

export const helperStateDirectory = (directory) => join(directory, "state");
export const sessionRuntimeDirectory = (directory, session) => join(directory, "sessions", session);

/** The sessions with a folder here. */
export function usageSessions(directory) {
  try {
    return readdirSync(join(directory, "sessions"), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  } catch {
    return [];
  }
}
