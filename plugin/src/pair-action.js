// "Pair a mobile device" action: opens the pairing popup pane.
//
// Actions run headless; the interactive checklist and QR live in the popup
// pane entrypoint (placement = "popup" in herdr-plugin.toml). Calling back
// through HERDR_BIN_PATH keeps this portable across socket transports.

import { spawnSync } from "node:child_process";

const herdr = process.env.HERDR_BIN_PATH ?? "herdr";
const plugin = process.env.HERDR_PLUGIN_ID ?? "herdr-mobile.pairing";

const result = spawnSync(
  herdr,
  ["plugin", "pane", "open", "--plugin", plugin, "--entrypoint", "pair"],
  { stdio: "inherit" },
);

if (result.error) {
  process.stderr.write(`failed to run herdr: ${result.error.message}\n`);
}
process.exit(result.status ?? 1);
