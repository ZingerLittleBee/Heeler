// Pairing popup pane (ADR 0007, herdr `[[panes]]` entrypoint "pair").
//
// Flow: sweep stale bootstrap lines -> enumerate candidate addresses -> user
// confirms the checklist -> mint a Bootstrap Key and render the Pairing Code
// QR. The Bootstrap Key's restricted authorized_keys line lives exactly as
// long as this popup and its 2-minute TTL, whichever ends first; Enrollment
// itself happens in pair-accept.js, invoked by sshd as the forced command.

import os from "node:os";
import { emitKeypressEvents } from "node:readline";
import QRCode from "qrcode";

import { candidateAddresses } from "./addresses.js";
import { readHostKeyFingerprint } from "./host-key.js";
import { encodePairingCode } from "./envelope.js";
import { sweepExpiredBootstrapLines } from "./authorized-keys.js";
import { beginPairing, endPairing, PAIRING_TTL_SECONDS } from "./pairing-session.js";
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
  const expires = new Date(payload.expiresAt * 1000).toLocaleTimeString();
  const lines = [
    `${BOLD}Scan with herdr-mobile${RESET}`,
    "",
    qr.trimEnd(),
    "",
    `${BOLD}${payload.username}${RESET} on port ${BOLD}${payload.port}${RESET}`,
    `Host key ${payload.hostKeyFingerprint}`,
    `Addresses: ${payload.addresses.join(", ")}`,
    `Code valid until ${BOLD}${expires}${RESET}, single use`,
    "",
    `${DIM}Press any key to close.${RESET}`,
  ];
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

function renderExpired() {
  const lines = [
    `${BOLD}Pairing Code expired${RESET}`,
    "",
    "The Bootstrap Key was removed; the old QR is now useless.",
    "",
    `${DIM}enter generate a new code, any other key close${RESET}`,
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

  const stateDir = process.env.HERDR_PLUGIN_STATE_DIR;
  if (!stateDir) {
    fatal("HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr.");
    return;
  }
  const home = os.homedir();

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

  // Startup sweep: crashed or killed ceremonies must leave no residue.
  await sweepExpiredBootstrapLines(home);

  let state = createSelection(candidates);
  let phase = "select";
  let confirmedAddresses = null;
  let session = null;
  let expiryTimer = null;
  let closing = false;

  async function cleanup() {
    if (expiryTimer !== null) {
      clearTimeout(expiryTimer);
      expiryTimer = null;
    }
    if (session !== null) {
      const { pairingId } = session;
      session = null;
      await endPairing({ home, stateDir, pairingId });
    }
  }

  async function close(code) {
    if (closing) {
      return;
    }
    closing = true;
    try {
      await cleanup();
    } finally {
      process.exit(code);
    }
  }

  // herdr closes a popup by ending the pane; make sure the bootstrap line
  // dies with us. SIGKILL is covered by the startup sweep instead.
  for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) {
    process.on(signal, () => void close(0));
  }

  async function startCeremony() {
    session = await beginPairing({ home, stateDir });
    expiryTimer = setTimeout(() => {
      expiryTimer = null;
      phase = "expired";
      void cleanup().then(renderExpired);
    }, PAIRING_TTL_SECONDS * 1000);
    await renderPairingCode({
      addresses: confirmedAddresses,
      port: DEFAULT_SSH_PORT,
      username: os.userInfo().username,
      hostKeyFingerprint: hostKey.fingerprint,
      bootstrapSeed: session.seed,
      expiresAt: session.expiresAt,
    });
  }

  function startCeremonyOrDie() {
    startCeremony().catch((error) => {
      fatal(`Could not start pairing: ${error.message}`);
      void close(1);
    });
  }

  process.stdout.write(HIDE_CURSOR);
  process.on("exit", () => process.stdout.write(SHOW_CURSOR));
  renderChecklist(state);

  readKeys((key) => {
    if (closing) {
      return;
    }
    if (key.name === "q" || key.name === "escape" || (key.ctrl && key.name === "c")) {
      void close(0);
      return;
    }
    if (phase === "qr") {
      void close(0);
      return;
    }
    if (phase === "expired") {
      if (key.name === "return") {
        phase = "qr";
        startCeremonyOrDie();
      } else {
        void close(0);
      }
      return;
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
        confirmedAddresses = addresses;
        startCeremonyOrDie();
        return;
      }
      default:
        return;
    }
    renderChecklist(state);
  });
}

await main();
