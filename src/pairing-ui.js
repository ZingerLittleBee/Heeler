// The pairing screens (ADR 0007), behind both entrypoints: herdr's popup pane
// (pair-popup.js) and the `heeler-pair` command for a machine without herdr
// (pair-cli.js, ADR 0057).
//
// Flow: sweep stale bootstrap lines -> enumerate candidate addresses -> user
// confirms the checklist -> mint a Bootstrap Key and render the Pairing Code
// QR. The Bootstrap Key's restricted authorized_keys line lives exactly as
// long as these screens and its 2-minute TTL, whichever ends first;
// Enrollment itself happens in pair-accept.js, invoked by sshd as the forced
// command.

import os from "node:os";
import { emitKeypressEvents } from "node:readline";
import QRCode from "qrcode";

import { candidateAddresses, withConfiguredAddresses } from "./addresses.js";
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
  detectTailscaleSSH,
  mayBeTailscaleAddress,
  tailscaleSSHConflict,
} from "./tailscale-ssh.js";
import {
  createSelection,
  moveCursor,
  toggleCurrent,
  toggleAll,
  selectedAddresses,
} from "./select-list.js";
import { copyPairingCode, qrKeyAction } from "./copy-pairing-code.js";
import {
  MISSING_ADDRESS,
  MISSING_HOST_KEY,
  fatalLines,
  pairingStartFailed,
} from "./pair-fatal.js";

const NO_ENDPOINT = { endpoint: null, error: null, warning: null, note: null };

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

function paintFatal(message) {
  const lines = [...fatalLines(message)];
  lines[0] = `${BOLD}${lines[0]}${RESET}`;
  lines[lines.length - 1] = `${DIM}${lines[lines.length - 1]}${RESET}`;
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

// herdr closes the popup when this process exits. Hold the error until a
// keypress so the user can read it.
function waitForAnyKey() {
  return new Promise((resolve) => {
    emitKeypressEvents(process.stdin);
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.once("keypress", () => resolve());
  });
}

async function holdFatal(message) {
  paintFatal(message);
  await waitForAnyKey();
  process.exit(1);
}

function renderChecklist(state, config, warning) {
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
  lines.push(`SSH port ${BOLD}${config.sshPort}${RESET} ${DIM}(${config.portSource})${RESET}`);
  // A rejected override stays on screen next to the port it failed to change:
  // the transient warning below is spent on checklist mistakes instead.
  if (config.warning) {
    lines.push(`${BOLD}${config.warning} Advertising ${config.sshPort}.${RESET}`);
  }
  if (config.addressesWarning) {
    lines.push(`${BOLD}${config.addressesWarning}${RESET}`);
  }
  if (config.launcherWarning) {
    lines.push(`${BOLD}${config.launcherWarning}${RESET}`);
  }
  const { endpoint, warning: endpointWarning, note } = config.endpoint;
  if (endpoint) {
    const generated = endpoint.generated ? " (generated)" : "";
    lines.push(`${DIM}Endpoint ${endpoint.socketPath} via ${endpoint.herdrPath}${generated}${RESET}`);
  }
  if (endpointWarning) {
    lines.push(`${BOLD}${endpointWarning}${RESET}`);
  }
  if (note) {
    lines.push(`${DIM}${note}${RESET}`);
  }
  // Follows the selection: checking a tailnet address raises it, unchecking
  // it again takes it away.
  const conflict = tailscaleSSHConflict({
    addresses: selectedAddresses(state),
    sshPort: config.sshPort,
    tailscale: config.tailscale,
    advice: config.portAdvice,
  });
  if (conflict) {
    for (const line of conflict.split("\n")) {
      lines.push(`${BOLD}${line}${RESET}`);
    }
  }
  lines.push(`${DIM}up/down move, space toggle, a all, enter confirm, q quit${RESET}`);
  if (warning) {
    lines.push("");
    lines.push(`${BOLD}${warning}${RESET}`);
  }
  process.stdout.write(CLEAR + lines.join("\n") + "\n");
}

const visibleWidth = (line) => line.replace(/\u001b\[[0-9;]*m/g, "").length;

/**
 * What to paint in place of a QR code the terminal would cut, or null when
 * it fits or the size is unknown. A cut code looks whole and never scans, so
 * it is not shown at all: a split tmux pane is often shorter than the code.
 *
 * @param {string[]} qrLines the rendered code, one terminal row each
 * @param {{rows?: number, columns?: number}} size the terminal's size
 * @returns {string[] | null}
 */
export function tooSmallLines(qrLines, { rows, columns }) {
  const neededRows = qrLines.length + 1;
  const neededColumns = Math.max(...qrLines.map(visibleWidth));
  const short = Number.isInteger(rows) && rows > 0 && rows < neededRows;
  const narrow = Number.isInteger(columns) && columns > 0 && columns < neededColumns;
  if (!short && !narrow) return null;
  return [
    `${BOLD}This terminal is too small for the Pairing Code${RESET}`,
    "",
    `It needs ${neededRows} rows and ${neededColumns} columns; this one has ${rows} by ${columns}.`,
    "Enlarge the window, or zoom this pane, and the code appears.",
    "",
    `${DIM}c: copy pairing code, any other key close${RESET}`,
  ];
}

async function renderPairingCode(payload, { copied = false, printedCode = null } = {}) {
  const code = encodePairingCode(payload);
  const qr = await QRCode.toString(code, { type: "terminal", small: true });
  const tooSmall = tooSmallLines(qr.trimEnd().split("\n"), process.stdout);
  if (tooSmall !== null) {
    if (copied) {
      tooSmall[tooSmall.length - 1] = `${BOLD}copied${RESET} ${DIM}-- any other key close${RESET}`;
    }
    process.stdout.write(CLEAR + tooSmall.join("\n"));
    if (printedCode !== null) {
      process.stdout.write(`\n${printedCode}`);
    }
    return code;
  }
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
    ...(payload.socketPath ? [`Endpoint ${payload.socketPath}`] : []),
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

/**
 * Run the pairing screens in this terminal until the user closes them.
 *
 * @param {object} options
 * @param {string | undefined} options.stateDir where pending and enrolled
 *   records live; unset paints `missingStateDir` and stops
 * @param {string} [options.missingStateDir] what to say when `stateDir` is unset
 * @param {() => object} options.readConfig the SSH port, extra addresses and
 *   launcher to use, in `readPairingConfig`'s shape
 * @param {(input: {home: string, launcher: string | null}) => object} [options.resolveEndpoint]
 *   the Herdr Endpoint for a code shown inside herdr (endpoint.js); a
 *   machine has none
 * @param {boolean} [options.machine] emit a machine code (v3): one shown
 *   outside herdr, which names no server
 * @param {string} options.portSource what sets the SSH port, shown beside it
 * @param {string} [options.addressSource] what names the extra addresses,
 *   shown beside each in place of an interface
 * @param {string} [options.portAdvice] how to change the port, for the
 *   Tailscale SSH warning
 * @param {string} options.notATerminal what to print when there is no terminal
 */
export async function runPairing({
  stateDir,
  missingStateDir = "No state directory to keep the pairing in.",
  readConfig,
  resolveEndpoint = () => NO_ENDPOINT,
  machine = false,
  portSource,
  addressSource,
  portAdvice,
  notATerminal,
}) {
  if (!process.stdout.isTTY || !process.stdin.isTTY) {
    process.stderr.write(`${notATerminal}\n`);
    process.exitCode = 1;
    return;
  }

  process.stdout.write(HIDE_CURSOR);
  process.on("exit", () => process.stdout.write(SHOW_CURSOR));

  if (!stateDir) {
    await holdFatal(missingStateDir);
    return;
  }
  const home = os.homedir();
  // Re-read on every checklist repaint. The warnings below tell the operator
  // to edit pair.json, so an edit made in another pane has to take effect
  // here without reopening the popup -- reading one small file is cheap.
  let checklistConfig = {
    ...readConfig(),
    portSource,
    portAdvice,
    tailscale: { enabled: false, addresses: [] },
    endpoint: NO_ENDPOINT,
  };
  function currentConfig() {
    checklistConfig = {
      ...checklistConfig,
      ...readConfig(),
    };
    return checklistConfig;
  }

  const hostKey = readHostKeyFingerprint();
  if (hostKey === null) {
    await holdFatal(MISSING_HOST_KEY);
    return;
  }
  // Configured addresses are read once: the checklist is built from them.
  const candidates = withConfiguredAddresses(
    candidateAddresses(),
    readConfig().addresses,
    addressSource,
  );
  if (candidates.length === 0) {
    await holdFatal(MISSING_ADDRESS);
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
      port: currentConfig().sshPort,
      username: os.userInfo().username,
      hostKeyFingerprint: hostKey.fingerprint,
      bootstrapSeed: session.seed,
      expiresAt: session.expiresAt,
    };
    const { endpoint } = checklistConfig.endpoint;
    if (endpoint) {
      lastPayload.socketPath = endpoint.socketPath;
      lastPayload.herdrPath = endpoint.herdrPath;
    }
    if (machine) {
      lastPayload.machine = true;
    }
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
      phase = "fatal";
      if (expiryTimer !== null) {
        clearTimeout(expiryTimer);
        expiryTimer = null;
      }
      if (enrollWatch !== null) {
        clearInterval(enrollWatch);
        enrollWatch = null;
      }
      paintFatal(pairingStartFailed(error.message));
    });
  }

  renderChecklist(state, currentConfig());

  // Probed after that first paint, and only where a tailnet address is on
  // offer: spawnSync blocks, and a wedged tailscaled must not hold the
  // checklist off the screen.
  if (candidates.some((candidate) => mayBeTailscaleAddress(candidate.address))) {
    checklistConfig.tailscale = detectTailscaleSSH();
    if (checklistConfig.tailscale.enabled) {
      renderChecklist(state, currentConfig());
    }
  }

  // Also after the first paint: generating and probing the launcher runs
  // herdr once, bounded by the probe's timeout. pair.json's launcher is
  // read here only, so changing it takes a new popup.
  checklistConfig.endpoint = resolveEndpoint({ home, launcher: readConfig().launcher });
  if (checklistConfig.endpoint.error) {
    await holdFatal(checklistConfig.endpoint.error);
    return;
  }
  if (Object.values(checklistConfig.endpoint).some((value) => value !== null)) {
    renderChecklist(state, currentConfig());
  }

  // A code that did not fit is painted once the terminal is large enough,
  // and one that fit is repainted for its new size.
  process.stdout.on("resize", () => {
    if (closing || phase !== "qr" || lastPayload === null || copiedTimer !== null) {
      return;
    }
    void renderPairingCode(lastPayload);
  });

  readKeys((key) => {
    if (closing) {
      return;
    }
    // Ignore every key while a revoke or the expiry check is in flight; both
    // are fast and a stray press must not close the popup before they settle.
    if (phase === "revoking" || phase === "expiring") {
      return;
    }
    if (phase === "fatal") {
      void close(1);
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
          renderChecklist(state, currentConfig(), "Select at least one address.");
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
    renderChecklist(state, currentConfig());
  });
}
