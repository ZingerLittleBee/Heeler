#!/usr/bin/env node
// The Helper's Usage query, which the app runs in one bounded SSH exec. It serves
// the report the plugin serves on Herdr TUI, rooted at the Helper's directory.

import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import { normalizeSessionName } from "./core/session-name.js";
import { usageReport } from "./shared/usage/query.js";
import { normalizeTmuxSocketName } from "./tmux/socket-name.js";
import { sessionRuntimeDirectory, tmuxRuntimeDirectory } from "./usage/layout.js";

try {
  const { values } = parseArgs({
    options: {
      tz: { type: "string" },
      session: { type: "string" },
      tmux: { type: "string" },
      "claude-limits": { type: "boolean", default: false },
    },
    allowPositionals: false,
  });
  // This file is in the Helper directory's `app` folder.
  const directory = fileURLToPath(new URL("..", import.meta.url));
  let runtimeDirectory;
  if (values.tmux !== undefined) {
    if (values.session !== undefined) throw new Error("ambiguous runtime target");
    const socket = normalizeTmuxSocketName(values.tmux);
    if (socket === null) throw new Error("invalid tmux socket");
    runtimeDirectory = tmuxRuntimeDirectory(directory, socket);
  } else {
    const session = normalizeSessionName(values.session ?? "");
    if (session === null) throw new Error("invalid session");
    runtimeDirectory = sessionRuntimeDirectory(directory, session);
  }
  console.log(JSON.stringify(usageReport({
    timeZone: values.tz,
    claudeLimits: values["claude-limits"],
    runtimeDirectory,
    accountDirectory: directory,
    worker: {
      path: fileURLToPath(new URL("./usage-worker.js", import.meta.url)),
      args: ["--config", runtimeDirectory, "--accounts", directory],
      env: {},
    },
  })));
} catch {
  // Never echo arguments or Host configuration into the response.
  console.error("usage-query: invalid query");
  process.exitCode = 1;
}
