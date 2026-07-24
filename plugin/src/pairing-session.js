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
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { generateBootstrapKey } from "./bootstrap-key.js";
import { bootstrapLine, editAuthorizedKeys, removeBootstrapLine } from "./authorized-keys.js";

export const PAIRING_TTL_SECONDS = 120;

const ACCEPT_SCRIPT = fileURLToPath(new URL("./pair-accept.js", import.meta.url));

export function pendingPath(stateDir, pairingId) {
  return join(stateDir, "pending", `${pairingId}.json`);
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

/** End a ceremony: drop the bootstrap line and pending state. Idempotent. */
export async function endPairing({ home, stateDir, pairingId }) {
  await removeBootstrapLine(home, pairingId);
  rmSync(pendingPath(stateDir, pairingId), { force: true });
}
