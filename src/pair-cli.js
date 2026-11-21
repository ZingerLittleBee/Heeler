#!/usr/bin/env node
// `heeler-pair`: the pairing screens on a machine without herdr, such as one
// whose Servers are herdr-core or tmux (ADR 0057). herdr never runs this; it
// is published to npm from plugin/pair-cli and started by `npx heeler-pair`.
// It shows a machine code (Pairing Code v3), which names no server: the app
// looks for the machine's Servers itself once the device is enrolled.

import { mkdirSync, readFileSync } from "node:fs";
import os from "node:os";
import { isAbsolute, join } from "node:path";
import { parseArgs } from "node:util";

import { DEFAULT_SSH_PORT } from "./pairing-config.js";
import { runPairing } from "./pairing-ui.js";

const USAGE = `Usage: heeler-pair [--port <port>] [--address <address>]...

Shows a Pairing Code for the Heeler app to scan. Run it in a terminal on the
machine Heeler should connect to, as the account it should sign in to.

  --port <port>        the port this machine's OpenSSH answers the phone on
                       (default ${DEFAULT_SSH_PORT})
  --address <address>  an address the phone reaches this machine on that is
                       not one of its own, such as a NAS that forwards a port
                       to a container; repeat it for more than one
  --version            print the version
  --help               print this help
`;

function fail(message) {
  process.stderr.write(`heeler-pair: ${message}\n\n${USAGE}`);
  process.exit(2);
}

function readOptions(argv) {
  let values;
  try {
    ({ values } = parseArgs({
      args: argv,
      options: {
        port: { type: "string" },
        address: { type: "string", multiple: true },
        version: { type: "boolean" },
        help: { type: "boolean", short: "h" },
      },
    }));
  } catch (error) {
    fail(error.message);
  }
  let sshPort = DEFAULT_SSH_PORT;
  if (values.port !== undefined) {
    sshPort = Number(values.port);
    if (!/^\d+$/.test(values.port) || sshPort < 1 || sshPort > 65535) {
      fail(`--port ${JSON.stringify(values.port)} is not a port from 1 to 65535`);
    }
  }
  // The rule the Pairing Code envelope enforces: non-empty, no whitespace.
  const addresses = [...new Set(values.address ?? [])];
  for (const address of addresses) {
    if (address.length === 0 || /\s/.test(address)) {
      fail(`--address ${JSON.stringify(address)} is not an address`);
    }
  }
  return { sshPort, addresses, version: values.version === true, help: values.help === true };
}

/** `$XDG_STATE_HOME/heeler/pairing`, where a relative value counts as unset. */
function stateDirectory(env, home) {
  const base = isAbsolute(env.XDG_STATE_HOME ?? "") ? env.XDG_STATE_HOME : join(home, ".local", "state");
  return join(base, "heeler", "pairing");
}

const options = readOptions(process.argv.slice(2));
if (options.help) {
  process.stdout.write(USAGE);
  process.exit(0);
}
if (options.version) {
  const manifest = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  process.stdout.write(`${manifest.name} ${manifest.version}\n`);
  process.exit(0);
}
// Enrollment writes ~/.ssh/authorized_keys for OpenSSH's forced command.
if (process.platform !== "darwin" && process.platform !== "linux") {
  process.stderr.write("heeler-pair runs on macOS and Linux. Add a Windows Host by hand in Heeler.\n");
  process.exit(1);
}

const stateDir = stateDirectory(process.env, os.homedir());
mkdirSync(stateDir, { recursive: true, mode: 0o700 });

await runPairing({
  stateDir,
  readConfig: () => ({
    sshPort: options.sshPort,
    warning: null,
    addresses: options.addresses,
    addressesWarning: null,
    launcher: null,
    launcherWarning: null,
  }),
  machine: true,
  portSource: "--port",
  addressSource: "--address",
  portAdvice: "Run heeler-pair again with --port set to a port OpenSSH listens on.",
  notATerminal: "heeler-pair shows a QR code, so it needs a terminal to run in.",
});
