// The Host Helper's entry point: Heeler's background service on a herdr-core
// Host (ADR 0033). The user service keeps this process running.

import { readFileSync } from "node:fs";

const { version } = JSON.parse(readFileSync(new URL("./version.json", import.meta.url), "utf8"));

console.log(`Heeler Host Helper ${version} started`);

// Nothing else holds the event loop open yet.
setInterval(() => {}, 2 ** 31 - 1);

// A stop asked for is a clean exit, so the service's result stays success.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => process.exit(0));
}
