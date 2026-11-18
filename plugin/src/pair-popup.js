// Pairing popup pane (ADR 0007, herdr `[[panes]]` entrypoint "pair"): the
// pairing screens inside herdr, which hands this process its state and
// config directories and whose own socket decides the Herdr Endpoint.

import { resolveEndpoint } from "./endpoint.js";
import { MISSING_STATE_DIR } from "./pair-fatal.js";
import { readPairingConfig } from "./pairing-config.js";
import { runPairing } from "./pairing-ui.js";

const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;

await runPairing({
  stateDir: process.env.HERDR_PLUGIN_STATE_DIR,
  missingStateDir: MISSING_STATE_DIR,
  readConfig: () => readPairingConfig(configDir),
  resolveEndpoint: ({ home, launcher }) => resolveEndpoint({ env: process.env, home, launcher }),
  portSource: "pair.json ssh_port",
  notATerminal: "pair-popup must run inside a terminal pane",
});
