// Pairing popup pane (ADR 0007, herdr `[[panes]]` entrypoint "pair").
//
// Flow: enumerate candidate addresses -> user confirms the checklist ->
// render the Pairing Code QR. This ticket ships the config-only Pairing Code
// (no Bootstrap Key yet); the Enrollment ceremony arrives with the Bootstrap
// Key lifecycle.

import os from "node:os";
import { emitKeypressEvents } from "node:readline";
import QRCode from "qrcode";

import { candidateAddresses } from "./addresses.js";
import { readHostKeyFingerprint } from "./host-key.js";
import { encodePairingCode } from "./envelope.js";
import {
  createSelection,
  moveCursor,
  toggleCurrent,
  toggleAll,
  selectedAddresses,
} from "./select-list.js";

const DEFAULT_SSH_PORT = 22;

const CLEAR = "\u001b[2J\u001b[H";
const HIDE_CURSOR = "\u001b[?25l";
const SHOW_CURSOR = "\u001b[?25h";
const BOLD = "\u001b[1m";
const DIM = "\u001b[2m";
const REVERSE = "\u001b[7m";
const RESET = "\u001b[0m";

function fatal(message) {
  process.stdout.write(`${CLEAR}${BOLD}Pairing cannot start${RESET}\n\n${message}\n`);
  process.exitCode = 1;
}

function renderChecklist(state, warning) {
  const lines = [
    `${BOLD}Pair a herdr-mobile device${RESET}`,
    "",
    "Select the addresses the phone can reach this machine on:",
    "",
  ];
  state.items.forEach((item, index) => {
    const cursor = index === state.cursor ? `${REVERSE}>` : " ";
    const box = item.checked ? "[x]" : "[ ]";
    const label = `${item.address} ${DIM}(${item.interfaceName}, ${item.family})${RESET}`;
    lines.push(` ${cursor} ${box} ${label}${RESET}`);
  });
  lines.push("");
  lines.push(`${DIM}up/down move, space toggle, a all, enter confirm, q quit${RESET}`);
  if (warning) {
    lines.push("");
    lines.push(`${BOLD}${warning}${RESET}`);
  }
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

async function renderPairingCode(payload) {
  const code = encodePairingCode(payload);
  const qr = await QRCode.toString(code, { type: "terminal", small: true });
  const lines = [
    `${BOLD}Scan with herdr-mobile${RESET}`,
    "",
    qr.trimEnd(),
    "",
    `${BOLD}${payload.username}${RESET} on port ${BOLD}${payload.port}${RESET}`,
    `Host key ${payload.hostKeyFingerprint}`,
    `Addresses: ${payload.addresses.join(", ")}`,
    "",
    `${DIM}Press any key to close.${RESET}`,
  ];
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

function readKeys(onKey) {
  emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on("keypress", (_chunk, key) => onKey(key ?? {}));
}

async function main() {
  if (!process.stdout.isTTY || !process.stdin.isTTY) {
    process.stderr.write("pair-popup must run inside a terminal pane\n");
    process.exitCode = 1;
    return;
  }

  const hostKey = readHostKeyFingerprint();
  if (hostKey === null) {
    fatal("No SSH host key found under /etc/ssh. Is an OpenSSH server set up here?");
    return;
  }
  const candidates = candidateAddresses();
  if (candidates.length === 0) {
    fatal("No routable network address found. Connect to a LAN or VPN and retry.");
    return;
  }

  let state = createSelection(candidates);
  let phase = "select";
  process.stdout.write(HIDE_CURSOR);
  process.on("exit", () => process.stdout.write(SHOW_CURSOR));
  renderChecklist(state);

  readKeys((key) => {
    if (key.name === "q" || key.name === "escape" || (key.ctrl && key.name === "c")) {
      process.exit(0);
    }
    if (phase === "qr") {
      process.exit(0);
    }
    switch (key.name) {
      case "up":
      case "k":
        state = moveCursor(state, -1);
        break;
      case "down":
      case "j":
        state = moveCursor(state, 1);
        break;
      case "space":
        state = toggleCurrent(state);
        break;
      case "a":
        state = toggleAll(state);
        break;
      case "return": {
        const addresses = selectedAddresses(state);
        if (addresses.length === 0) {
          renderChecklist(state, "Select at least one address.");
          return;
        }
        phase = "qr";
        renderPairingCode({
          addresses,
          port: DEFAULT_SSH_PORT,
          username: os.userInfo().username,
          hostKeyFingerprint: hostKey.fingerprint,
        }).catch((error) => {
          fatal(`Could not render the Pairing Code: ${error.message}`);
          process.exit(1);
        });
        return;
      }
      default:
        return;
    }
    renderChecklist(state);
  });
}

await main();
