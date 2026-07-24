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
import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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
 * @param {number} options.expiresAt the ceremony's expiry (unix seconds); lets
 *   the startup sweep age out records a killed popup never cleaned up
 * @param {string} options.fingerprint enrolled Device Key SHA256 fingerprint
 * @param {string} options.line canonical enrolled authorized_keys line (revoke target)
 */
export function recordEnrollment({ stateDir, pairingId, expiresAt, fingerprint, line }) {
  mkdirSync(join(stateDir, "enrolled"), { recursive: true, mode: 0o700 });
  writeFileSync(
    enrolledPath(stateDir, pairingId),
    `${JSON.stringify({ pairingId, expiresAt, fingerprint, line })}\n`,
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

// How far past its ceremony's expiry an enrolled record must be before the
// sweep may call it orphaned. A live popup reads the record within a poll
// interval of the accept writing it, so anything a full TTL late is garbage.
const STATE_SWEEP_GRACE_SECONDS = PAIRING_TTL_SECONDS;

/**
 * Startup sweep for the plugin state dir, the file-side twin of
 * sweepExpiredBootstrapLines: a SIGKILLed popup never runs endPairing, so its
 * pending/enrolled records would otherwise live forever. Only provably stale
 * files go — pending records past their embedded expiry, enrolled records a
 * grace period past theirs — so a concurrent popup's live ceremony is never
 * clobbered.
 *
 * @returns {number} how many stale files were removed
 */
export function sweepExpiredStateFiles(stateDir, now = Math.floor(Date.now() / 1000)) {
  return (
    sweepDir(join(stateDir, "pending"), now, (record) => record.expiresAt) +
    sweepDir(join(stateDir, "enrolled"), now, (record) => record.expiresAt + STATE_SWEEP_GRACE_SECONDS)
  );
}

function sweepDir(dir, now, keepUntilOf) {
  let names;
  try {
    names = readdirSync(dir);
  } catch (error) {
    if (error.code === "ENOENT") {
      return 0;
    }
    throw error;
  }
  let removed = 0;
  for (const name of names) {
    const path = join(dir, name);
    if (keepUntil(path, keepUntilOf) <= now) {
      rmSync(path, { force: true });
      removed += 1;
    }
  }
  return removed;
}

/** Unix-seconds instant until which a state file must be kept. */
function keepUntil(path, keepUntilOf) {
  try {
    const value = keepUntilOf(JSON.parse(readFileSync(path, "utf8")));
    if (Number.isFinite(value)) {
      return value;
    }
  } catch {
    // Unreadable or malformed: fall through to the mtime rule below.
  }
  // Garbage still ages out, but by mtime and with full TTL + grace slack so
  // a concurrent writer's file mid-write is never misjudged as stale.
  try {
    return (
      Math.floor(statSync(path).mtimeMs / 1000) + PAIRING_TTL_SECONDS + STATE_SWEEP_GRACE_SECONDS
    );
  } catch {
    return Infinity; // vanished mid-sweep: someone else already cleaned it up
  }
}
