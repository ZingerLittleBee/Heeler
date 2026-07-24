// Atomic authorized_keys editing for the Bootstrap Key lifecycle (ADR 0007).
//
// Every mutation goes through editAuthorizedKeys: take an exclusive lock,
// read, rewrite through a temp file in the same directory, rename. The file
// mode is preserved (0600 for a fresh file) so sshd's StrictModes keeps
// accepting it. Bootstrap lines are tagged with a marker comment
// "herdr-pairing:<id>:exp:<unix-seconds>" so cleanup and the startup sweep
// can find them without any state beyond the file itself.

import {
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { join } from "node:path";

const BOOTSTRAP_COMMENT_PATTERN = /(?:^|\s)herdr-pairing:([A-Za-z0-9-]+):exp:(\d+)$/;
const LOCK_RETRY_MS = 25;
const LOCK_TIMEOUT_MS = 5_000;
// A crashed editor leaves its lock behind; edits are millisecond-scale, so a
// lock this old is garbage, not contention.
const LOCK_STALE_MS = 10_000;

export function authorizedKeysPath(home) {
  return join(home, ".ssh", "authorized_keys");
}

/**
 * Compose a restricted Bootstrap Key authorized_keys line.
 *
 * @param {object} options
 * @param {string} options.publicLine bare "ssh-ed25519 <blob>" public line
 * @param {string} options.pairingId marker id, alphanumeric/hyphen
 * @param {number} options.expiresAt unix-seconds expiry, embedded in the marker
 * @param {string} options.command forced command (Enrollment accept entrypoint)
 */
export function bootstrapLine({ publicLine, pairingId, expiresAt, command }) {
  if (/["\n\r]/.test(command)) {
    throw new Error("forced command must not contain double quotes or newlines");
  }
  if (!/^[A-Za-z0-9-]+$/.test(pairingId)) {
    throw new Error("pairing id must be alphanumeric/hyphen");
  }
  if (!Number.isInteger(expiresAt) || expiresAt <= 0) {
    throw new Error("expiresAt must be a positive unix-seconds integer");
  }
  return `restrict,command="${command}" ${publicLine} herdr-pairing:${pairingId}:exp:${expiresAt}`;
}

/** Parse the marker comment of a Bootstrap Key line, or null for other lines. */
export function parseBootstrapLine(line) {
  const match = BOOTSTRAP_COMMENT_PATTERN.exec(line);
  if (match === null) {
    return null;
  }
  return { pairingId: match[1], expiresAt: Number(match[2]) };
}

async function acquireLock(lockPath) {
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  for (;;) {
    try {
      const fd = openSync(lockPath, "wx", 0o600);
      writeSync(fd, `${process.pid}\n`);
      closeSync(fd);
      return;
    } catch (error) {
      if (error.code !== "EEXIST") {
        throw error;
      }
      try {
        if (Date.now() - statSync(lockPath).mtimeMs > LOCK_STALE_MS) {
          rmSync(lockPath, { force: true });
          continue;
        }
      } catch {
        continue; // lock vanished between open and stat; retry immediately
      }
      if (Date.now() > deadline) {
        throw new Error(`timed out waiting for authorized_keys lock ${lockPath}`);
      }
      await sleep(LOCK_RETRY_MS);
    }
  }
}

/**
 * Atomically edit authorized_keys under an exclusive lock.
 *
 * @param {string} home the account's home directory (sshd reads
 *   `~/.ssh/authorized_keys` under StrictModes)
 * @param {(lines: string[]) => string[] | null} edit receives the current
 *   lines (no trailing empty line) and returns the new lines, or null to
 *   leave the file untouched
 * @returns {Promise<boolean>} whether the file was rewritten
 */
export async function editAuthorizedKeys(home, edit) {
  const sshDir = join(home, ".ssh");
  const path = authorizedKeysPath(home);
  mkdirSync(sshDir, { recursive: true, mode: 0o700 });

  const lockPath = `${path}.herdr-pairing.lock`;
  await acquireLock(lockPath);
  try {
    let content = null;
    try {
      content = readFileSync(path, "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
    }
    const lines = content === null ? [] : content.split("\n");
    if (lines.at(-1) === "") {
      lines.pop();
    }

    const edited = edit([...lines]);
    if (edited === null) {
      return false;
    }

    const mode = content === null ? 0o600 : statSync(path).mode & 0o777;
    const tempPath = `${path}.herdr-pairing.${process.pid}.tmp`;
    const body = edited.length === 0 ? "" : `${edited.join("\n")}\n`;
    try {
      writeFileSync(tempPath, body, { mode });
      renameSync(tempPath, path);
    } catch (error) {
      rmSync(tempPath, { force: true });
      throw error;
    }
    return true;
  } finally {
    unlinkSync(lockPath);
  }
}

/** Remove the Bootstrap Key line with the given pairing id, if present. */
export async function removeBootstrapLine(home, pairingId) {
  return editAuthorizedKeys(home, (lines) => {
    const kept = lines.filter((line) => parseBootstrapLine(line)?.pairingId !== pairingId);
    return kept.length === lines.length ? null : kept;
  });
}

/**
 * Startup sweep: remove every Bootstrap Key line whose embedded expiry has
 * passed. Lines still inside their TTL are left alone (another pairing may
 * legitimately be in flight).
 *
 * @returns {Promise<number>} how many stale lines were removed
 */
export async function sweepExpiredBootstrapLines(home, now = Math.floor(Date.now() / 1000)) {
  let removed = 0;
  await editAuthorizedKeys(home, (lines) => {
    const kept = lines.filter((line) => {
      const marker = parseBootstrapLine(line);
      return marker === null || marker.expiresAt > now;
    });
    removed = lines.length - kept.length;
    return removed === 0 ? null : kept;
  });
  return removed;
}

/** The "<type> <blob>" identity of a public key line, ignoring the comment. */
export function keyBlobOf(line) {
  const words = line.trim().split(/\s+/);
  // Skip an options word if present; bare public lines start with the type.
  const start = words[0]?.startsWith("ssh-") || words[0]?.startsWith("ecdsa-") ? 0 : 1;
  return words.slice(start, start + 2).join(" ");
}
