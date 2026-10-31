// Where Usage's files sit in the Helper's directory. The app's Usage script reads
// the same `sessions/<session>` paths.

import { join } from "node:path";

export const helperStateDirectory = (directory) => join(directory, "state");
export const sessionRuntimeDirectory = (directory, session) => join(directory, "sessions", session);
