// The Host Helper's entry point: Heeler's background service on a herdr-core
// Host (ADR 0033). The user service keeps this process running.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { followRegisteredSessions } from "./core/follower.js";

const { version } = JSON.parse(readFileSync(new URL("./version.json", import.meta.url), "utf8"));

console.log(`Heeler Host Helper ${version} started`);

// This file is in the Helper directory's `app` folder, which an update replaces.
// The registrations sit beside that folder.
followRegisteredSessions({
  directory: fileURLToPath(new URL("..", import.meta.url)),
  log: (line) => console.log(line),
});

// A stop asked for is a clean exit, so the service's result stays success.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => process.exit(0));
}
