// One pairing ceremony on the server side (ADR 0007).
//
// beginPairing mints a Bootstrap Key, writes its restricted authorized_keys
// line (restrict + forced command at the Enrollment accept entrypoint), and
// records pending state under the plugin state directory. endPairing undoes
// both; it runs on popup exit, on TTL expiry, and is idempotent so crashed
// ceremonies can be cleaned up twice without harm.
//
// The forced command embeds absolute paths because sshd runs it with a bare
// login-shell environment: no herdr plugin env, possibly no node on PATH.

import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { generateBootstrapKey } from "./bootstrap-key.js";
import {
  bootstrapLine,
  editAuthorizedKeys,
  parseBootstrapLine,
  removeBootstrapLine,
} from "./authorized-keys.js";

export const PAIRING_TTL_SECONDS = 120;

const ACCEPT_SCRIPT = fileURLToPath(new URL("./pair-accept.js", import.meta.url));

export function pendingPath(stateDir, pairingId) {
  return join(stateDir, "pending", `${pairingId}.json`);
}

export function enrolledPath(stateDir, pairingId) {
  return join(stateDir, "enrolled", `${pairingId}.json`);
}

/**
 * Record a completed Enrollment so the popup can show the enrolled fingerprint
 * and offer a one-key revoke. Written by pair-accept.js inside the
 * authorized_keys lock, atomically with the Device Key append; the popup polls
 * for it as its Enrollment signal and expirePairing checks it under that lock.
 *
 * @param {object} options
 * @param {string} options.stateDir plugin state directory
 * @param {string} options.pairingId the completed pairing's id
 * @param {string} options.fingerprint enrolled Device Key SHA256 fingerprint
 * @param {string} options.line canonical enrolled authorized_keys line (revoke target)
 */
export function recordEnrollment({ stateDir, pairingId, fingerprint, line }) {
  mkdirSync(join(stateDir, "enrolled"), { recursive: true, mode: 0o700 });
  writeFileSync(
    enrolledPath(stateDir, pairingId),
    `${JSON.stringify({ pairingId, fingerprint, line })}\n`,
    { mode: 0o600 },
  );
}

/** Read a completed Enrollment record, or null if none exists yet. */
export function readEnrollment(stateDir, pairingId) {
  try {
    return JSON.parse(readFileSync(enrolledPath(stateDir, pairingId), "utf8"));
  } catch {
    return null;
  }
}

function singleQuoted(path, what) {
  // The whole forced command lives inside authorized_keys double quotes and
  // is then parsed by the login shell; single-quoting the paths keeps both
  // layers happy as long as the path has no quote characters of its own.
  if (/['"\n\r]/.test(path)) {
    throw new Error(`${what} must not contain quotes or newlines: ${path}`);
  }
  return `'${path}'`;
}

function acceptCommand(stateDir, pairingId) {
  return [
    singleQuoted(process.execPath, "node binary path"),
    singleQuoted(ACCEPT_SCRIPT, "accept script path"),
    "--state-dir",
    singleQuoted(stateDir, "plugin state dir"),
    "--pairing-id",
    pairingId,
  ].join(" ");
}

/**
 * Start a pairing ceremony: Bootstrap Key + restricted line + pending state.
 *
 * @param {object} options
 * @param {string} options.home account home (owns ~/.ssh/authorized_keys)
 * @param {string} options.stateDir plugin state directory (HERDR_PLUGIN_STATE_DIR)
 * @param {number} [options.now] unix seconds, defaults to the clock
 * @param {number} [options.ttlSeconds] Bootstrap Key TTL
 * @returns {Promise<{pairingId: string, seed: Buffer, expiresAt: number, publicLine: string}>}
 */
export async function beginPairing({
  home,
  stateDir,
  now = Math.floor(Date.now() / 1000),
  ttlSeconds = PAIRING_TTL_SECONDS,
}) {
  const pairingId = randomBytes(6).toString("hex");
  const expiresAt = now + ttlSeconds;
  const { seed, publicLine } = generateBootstrapKey();
  const line = bootstrapLine({
    publicLine,
    pairingId,
    expiresAt,
    command: acceptCommand(stateDir, pairingId),
  });

  mkdirSync(join(stateDir, "pending"), { recursive: true, mode: 0o700 });
  writeFileSync(
    pendingPath(stateDir, pairingId),
    `${JSON.stringify({ pairingId, expiresAt, publicLine })}\n`,
    { mode: 0o600 },
  );
  try {
    await editAuthorizedKeys(home, (lines) => [...lines, line]);
  } catch (error) {
    rmSync(pendingPath(stateDir, pairingId), { force: true });
    throw error;
  }

  return { pairingId, seed, expiresAt, publicLine };
}

/**
 * Expire a ceremony from the popup's TTL timer. Like endPairing, but the
 * enrolled-record check runs inside the authorized_keys lock — the same lock
 * under which pair-accept.js commits an Enrollment — so exactly one outcome
 * is possible: either the record is visible here (return it, touch nothing,
 * the popup shows the revoke screen), or this cleanup consumes the pending
 * state first and the accept script rejects. No interleaving can enroll a
 * device silently (ADR 0007's compensating control depends on that).
 *
 * @returns {Promise<object | null>} the Enrollment record, if a device enrolled
 */
export async function expirePairing({ home, stateDir, pairingId }) {
  let record = null;
  await editAuthorizedKeys(home, (lines) => {
    record = readEnrollment(stateDir, pairingId);
    if (record !== null) {
      return null;
    }
    rmSync(pendingPath(stateDir, pairingId), { force: true });
    const kept = lines.filter((line) => parseBootstrapLine(line)?.pairingId !== pairingId);
    return kept.length === lines.length ? null : kept;
  });
  return record;
}

/**
 * End a ceremony: drop the bootstrap line, pending state, and any Enrollment
 * record. Idempotent, so crashed ceremonies can be cleaned up twice.
 */
export async function endPairing({ home, stateDir, pairingId }) {
  await removeBootstrapLine(home, pairingId);
  rmSync(pendingPath(stateDir, pairingId), { force: true });
  rmSync(enrolledPath(stateDir, pairingId), { force: true });
}
