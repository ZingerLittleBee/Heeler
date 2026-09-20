// Tailscale SSH conflict detection for the pairing checklist (#355).
//
// Tailscale SSH intercepts port 22 for connections arriving over the tailnet:
// it answers with tailscaled's own host key and never reads authorized_keys,
// so the forced command that performs Enrollment cannot run (#358). A Pairing
// Code advertising a Tailscale address on port 22 therefore fails after the
// scan, on the phone, with nothing on the Host to explain it. Say so while
// the checklist is still open and `pair.json` can still be edited.

import { spawnSync } from "node:child_process";

// The only port Tailscale SSH takes over.
const INTERCEPTED_PORT = 22;

// The macOS builds do not put the CLI on PATH; these are the paths inside the
// app bundle, in both spellings shipped over the years -- a case-sensitive
// volume gets only the one it has.
const TAILSCALE_COMMANDS = [
  "tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/tailscale",
];

// Two probes run back to back before the warning can appear, and a wedged
// tailscaled reaches the timeout rather than answering. Keep the pair short
// enough that the checklist is never unresponsive for long.
const COMMAND_TIMEOUT_MS = 800;

/**
 * Whether an address is one Tailscale hands out, and so one whose port 22
 * tailscaled may be answering.
 *
 * @param {string} address
 * @returns {boolean}
 */
export function isTailscaleAddress(address) {
  if (typeof address !== "string") return false;
  const [a, b] = address.split(".").map(Number);
  if (a === 100 && b >= 64 && b <= 127) return true; // 100.64/10 CGNAT
  return /^fd7a:115c:a1e0\b/i.test(address); // fd7a:115c:a1e0::/48
}

/**
 * Run `tailscale <args>` at the first location that answers, or null when
 * none does. A missing binary, a non-zero exit (logged out, wrong build) and
 * a timeout are all "no answer".
 *
 * @param {string[]} args
 * @param {{spawnFn?: typeof spawnSync}} [deps]
 * @returns {string | null}
 */
export function runTailscale(args, { spawnFn = spawnSync } = {}) {
  for (const command of TAILSCALE_COMMANDS) {
    const result = spawnFn(command, args, {
      encoding: "utf8",
      timeout: COMMAND_TIMEOUT_MS,
    });
    if (result.error || result.status !== 0) continue;
    return result.stdout;
  }
  return null;
}

function parse(output) {
  if (typeof output !== "string") return null;
  try {
    const parsed = JSON.parse(output);
    return parsed !== null && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

// `tailscale status --json` reports this node's own SSH host keys once it is
// serving SSH. Documented as "the node's SSH host keys, if known", which is
// why an absent field is not read as a no: it only ever answers yes here.
function statusSaysEnabled(output) {
  const keys = parse(output)?.Self?.sshHostKeys;
  return Array.isArray(keys) && keys.length > 0;
}

// `tailscale debug prefs` is a debug surface with no stability promise, so it
// is the second opinion rather than the first.
function prefsSayEnabled(output) {
  return parse(output)?.RunSSH === true;
}

/**
 * Whether Tailscale SSH is serving on this machine.
 *
 * Both probes are treated as yes-only: a machine without the CLI, a logged-out
 * tailscaled, or an output shape that changed all read as "not enabled" and
 * warn about nothing. Under-warning leaves today's behavior; over-warning
 * would put a false alarm on every pairing.
 *
 * @param {{run?: (args: string[]) => string | null}} [deps]
 * @returns {boolean}
 */
export function detectTailscaleSSH({ run = runTailscale } = {}) {
  if (statusSaysEnabled(run(["status", "--json"]))) return true;
  return prefsSayEnabled(run(["debug", "prefs"]));
}

/**
 * The checklist warning for a Pairing Code that would send the phone at
 * tailscaled instead of OpenSSH, or null when the selection is fine.
 *
 * @param {{addresses: string[], sshPort: number, tailscaleSSHEnabled: boolean}} input
 * @returns {string | null}
 */
export function tailscaleSSHConflict({ addresses, sshPort, tailscaleSSHEnabled }) {
  if (!tailscaleSSHEnabled || sshPort !== INTERCEPTED_PORT) return null;
  const intercepted = (addresses ?? []).filter(isTailscaleAddress);
  if (intercepted.length === 0) return null;
  return (
    `Tailscale SSH answers port ${INTERCEPTED_PORT} on ${intercepted.join(", ")}.\n` +
    "Pairing there reaches tailscaled, not OpenSSH, and cannot finish.\n" +
    "Set ssh_port in pair.json to a port OpenSSH listens on."
  );
}
