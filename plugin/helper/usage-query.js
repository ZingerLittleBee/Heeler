#!/usr/bin/env node
// The Helper's Usage query, which the app runs in one bounded SSH exec. It serves
// the report the plugin serves on Herdr TUI, rooted at the Helper's directory.

import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import { normalizeSessionName } from "./core/session-name.js";
import { usageReport } from "./shared/usage/query.js";
import { sessionRuntimeDirectory } from "./usage/layout.js";

try {
  const { values } = parseArgs({
    options: {
      tz: { type: "string" },
      session: { type: "string", default: "" },
      "claude-limits": { type: "boolean", default: false },
    },
    allowPositionals: false,
  });
  const session = normalizeSessionName(values.session);
  if (session === null) throw new Error("invalid session");
  // This file is in the Helper directory's `app` folder.
  const directory = fileURLToPath(new URL("..", import.meta.url));
  const runtimeDirectory = sessionRuntimeDirectory(directory, session);
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
