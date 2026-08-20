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
import { commentOf, removeKeyLine, sweepExpiredBootstrapLines } from "./authorized-keys.js";
import {
  beginPairing,
  endPairing,
  expirePairing,
  readEnrollment,
  sweepExpiredStateFiles,
  PAIRING_TTL_SECONDS,
} from "./pairing-session.js";
import {
  createSelection,
  moveCursor,
  toggleCurrent,
  toggleAll,
  selectedAddresses,
} from "./select-list.js";
import { copyPairingCode, qrKeyAction } from "./copy-pairing-code.js";

const DEFAULT_SSH_PORT = 22;
// How often the QR screen checks whether Enrollment has completed. The pending
// -> enrolled transition happens on the server side in pair-accept.js; polling
// the record it leaves is simpler than an fs.watch and just as timely at human
// scale.
const ENROLL_POLL_MS = 400;

// 2J clears the visible screen only; a QR taller than the viewport pushes
// rows into scrollback, which would resurface above later screens. 3J drops
// the scrollback too.
const CLEAR = "\u001b[2J\u001b[3J\u001b[H";
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
    `${BOLD}Pair a Heeler device${RESET}`,
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

async function renderPairingCode(payload, { copied = false, printedCode = null } = {}) {
  const code = encodePairingCode(payload);
  const qr = await QRCode.toString(code, { type: "terminal", small: true });
  const expires = new Date(payload.expiresAt * 1000).toLocaleTimeString();
  // QR first, starting at row 1. Writing more lines than the pane has rows
  // scrolls the earliest ones off the top, and with a header above the QR
  // that meant the QR's top edge vanished into scrollback. Clamp to the
  // viewport instead, so any overflow costs trailing text, never the QR.
  const hint = copied
    ? `${BOLD}copied${RESET} ${DIM}-- any other key close${RESET}`
    : `${BOLD}Scan with Heeler${RESET} ${DIM}-- c: copy pairing code, any other key close${RESET}`;
  const lines = [
    ...qr.trimEnd().split("\n"),
    hint,
    `${BOLD}${payload.username}${RESET} on port ${BOLD}${payload.port}${RESET}`,
    `Host key ${payload.hostKeyFingerprint}`,
    `Addresses: ${payload.addresses.join(", ")}`,
    `Code valid until ${BOLD}${expires}${RESET}, single use`,
  ];
  const rows = process.stdout.rows;
  const visible = Number.isInteger(rows) && rows > 0 ? lines.slice(0, rows) : lines;
  process.stdout.write(CLEAR + visible.join("\n"));
  // pbcopy is macOS-only; when copy fails, print the exact envelope after the
  // clamped QR so it can be selected by hand even if the footer was trimmed.
  if (printedCode !== null) {
    process.stdout.write(`\n${printedCode}`);
  }
  return code;
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

function renderEnrolled(record) {
  const comment = commentOf(record.line);
  const label = comment.length > 0 ? `${BOLD}${comment}${RESET}` : `${DIM}(no label)${RESET}`;
  const lines = [
    `${BOLD}Device paired${RESET}`,
    "",
    "A device just enrolled its Device Key on this machine:",
    "",
    `  Fingerprint  ${BOLD}${record.fingerprint}${RESET}`,
    `  Label        ${label}`,
    "",
    "If this was not you, revoke it now to lock that device out.",
    "",
    `${DIM}r revoke this device, any other key close${RESET}`,
  ];
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

function renderRevoked(record) {
  const lines = [
    `${BOLD}Device Key revoked${RESET}`,
    "",
    `${DIM}${record.fingerprint}${RESET}`,
    "was removed from authorized_keys; that device can no longer connect.",
    "",
    `${DIM}Press any key to close.${RESET}`,
  ];
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

function renderRevokeFailed(message) {
  const lines = [
    `${BOLD}Could not revoke the Device Key${RESET}`,
    "",
    message,
    "",
    "Remove the enrolled line from ~/.ssh/authorized_keys by hand.",
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

  // Startup sweep: crashed or killed ceremonies must leave no residue —
  // neither authorized_keys lines nor pending/enrolled state files.
  await sweepExpiredBootstrapLines(home);
  sweepExpiredStateFiles(stateDir);

  let state = createSelection(candidates);
  let phase = "select";
  let confirmedAddresses = null;
  let session = null;
  let expiryTimer = null;
  let enrollWatch = null;
  let enrolled = null;
  let closing = false;
  let displayedCode = null;
  let lastPayload = null;
  let copiedTimer = null;

  async function cleanup() {
    if (copiedTimer !== null) {
      clearTimeout(copiedTimer);
      copiedTimer = null;
    }
    if (expiryTimer !== null) {
      clearTimeout(expiryTimer);
      expiryTimer = null;
    }
    if (enrollWatch !== null) {
      clearInterval(enrollWatch);
      enrollWatch = null;
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

  // A device enrolled: the Bootstrap Key has already self-revoked, so stop the
  // TTL clock and the poll and show the enrolled device with a one-key revoke.
  function enterEnrolled(record) {
    enrolled = record;
    if (enrollWatch !== null) {
      clearInterval(enrollWatch);
      enrollWatch = null;
    }
    if (expiryTimer !== null) {
      clearTimeout(expiryTimer);
      expiryTimer = null;
    }
    phase = "enrolled";
    renderEnrolled(record);
  }

  // Enrollment happens server-side (pair-accept.js as the sshd forced command)
  // and leaves a record in the state dir. Poll for it while the QR is up.
  function onEnrollmentPoll(pairingId) {
    if (closing || phase !== "qr") {
      return;
    }
    const record = readEnrollment(stateDir, pairingId);
    if (record === null) {
      return;
    }
    enterEnrolled(record);
  }

  // The TTL lapsed. A device can enroll inside the accept script's lock right
  // up to the deadline, after our last poll, so the check for its record runs
  // inside that same lock (expirePairing): either the Enrollment is honored,
  // or the cleanup wins and the accept script rejects. Anything else could
  // delete an enrolled device's record and never offer the revoke (ADR 0007's
  // compensating control).
  async function expireCeremony(pairingId) {
    phase = "expiring";
    if (enrollWatch !== null) {
      clearInterval(enrollWatch);
      enrollWatch = null;
    }
    const record = await expirePairing({ home, stateDir, pairingId });
    if (closing) {
      return;
    }
    if (record !== null) {
      enterEnrolled(record);
      return;
    }
    // expirePairing already dropped the bootstrap line and pending state.
    session = null;
    phase = "expired";
    renderExpired();
  }

  async function revokeEnrolledDevice() {
    if (enrolled === null) {
      void close(0);
      return;
    }
    // Hold an in-flight phase across the await so a second keypress can't fall
    // through to a terminal branch and close(0) before removeKeyLine settles.
    phase = "revoking";
    try {
      await removeKeyLine(home, enrolled.line);
    } catch (error) {
      phase = "revoked";
      renderRevokeFailed(error.message);
      return;
    }
    phase = "revoked";
    renderRevoked(enrolled);
  }

  async function startCeremony() {
    session = await beginPairing({ home, stateDir });
    const { pairingId } = session;
    expiryTimer = setTimeout(() => {
      expiryTimer = null;
      if (closing || phase !== "qr") {
        return;
      }
      void expireCeremony(pairingId);
    }, PAIRING_TTL_SECONDS * 1000);
    lastPayload = {
      addresses: confirmedAddresses,
      port: DEFAULT_SSH_PORT,
      username: os.userInfo().username,
      hostKeyFingerprint: hostKey.fingerprint,
      bootstrapSeed: session.seed,
      expiresAt: session.expiresAt,
    };
    displayedCode = await renderPairingCode(lastPayload);
    enrollWatch = setInterval(() => onEnrollmentPoll(pairingId), ENROLL_POLL_MS);
  }

  async function copyDisplayedCode() {
    if (displayedCode === null || lastPayload === null || closing || phase !== "qr") {
      return;
    }
    const result = await copyPairingCode(displayedCode);
    if (closing || phase !== "qr") {
      return;
    }
    if (copiedTimer !== null) {
      clearTimeout(copiedTimer);
      copiedTimer = null;
    }
    if (result.copied) {
      await renderPairingCode(lastPayload, { copied: true });
      copiedTimer = setTimeout(() => {
        copiedTimer = null;
        if (closing || phase !== "qr" || lastPayload === null) {
          return;
        }
        void renderPairingCode(lastPayload);
      }, 1500);
      return;
    }
    await renderPairingCode(lastPayload, { printedCode: displayedCode });
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
    // Ignore every key while a revoke or the expiry check is in flight; both
    // are fast and a stray press must not close the popup before they settle.
    if (phase === "revoking" || phase === "expiring") {
      return;
    }
    if (key.name === "q" || key.name === "escape" || (key.ctrl && key.name === "c")) {
      void close(0);
      return;
    }
    if (phase === "enrolled") {
      if (key.name === "r") {
        void revokeEnrolledDevice();
      } else {
        void close(0);
      }
      return;
    }
    if (phase === "revoked") {
      void close(0);
      return;
    }
    if (phase === "qr") {
      if (qrKeyAction(key) === "copy") {
        void copyDisplayedCode();
      } else {
        void close(0);
      }
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
