// Enrollment accept entrypoint (ADR 0007).
//
// Runs as the sshd forced command behind a Bootstrap Key's restricted
// authorized_keys line: the app connects with the Bootstrap Key and writes
// its Device Key public line to stdin. On success the Device Key is appended
// atomically and the bootstrap line self-revokes (single use). Invalid
// submissions consume nothing, so the app may retry within the TTL.
//
// stdout speaks a one-line protocol the app parses:
//   HERDR-ENROLL:OK:<SHA256:fingerprint>
//   HERDR-ENROLL:ERR:<unknown_pairing|expired|invalid_key|no_input>
// Human-readable detail goes to stderr.

import { existsSync, readFileSync, rmSync } from "node:fs";
import { parseArgs } from "node:util";

import { editAuthorizedKeys, keyBlobOf, parseBootstrapLine } from "./authorized-keys.js";
import { parseDeviceKeyLine, DeviceKeyError } from "./device-key.js";
import { endPairing, pendingPath } from "./pairing-session.js";

const MAX_INPUT_BYTES = 4096;
const INPUT_TIMEOUT_MS = 30_000;

function ok(fingerprint) {
  process.stdout.write(`HERDR-ENROLL:OK:${fingerprint}\n`);
  process.exit(0);
}

function err(code, detail) {
  process.stdout.write(`HERDR-ENROLL:ERR:${code}\n`);
  process.stderr.write(`${detail}\n`);
  process.exit(1);
}

/** Read stdin until the first newline, EOF, a size cap, or a timeout. */
function readSubmission(stream) {
  return new Promise((resolve) => {
    let data = "";
    let done = false;
    const finish = () => {
      if (!done) {
        done = true;
        clearTimeout(timer);
        resolve(data.split("\n")[0]);
      }
    };
    const timer = setTimeout(finish, INPUT_TIMEOUT_MS);
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
      data += chunk;
      if (data.includes("\n") || data.length >= MAX_INPUT_BYTES) {
        finish();
      }
    });
    stream.on("end", finish);
    stream.on("error", finish);
  });
}

const { values } = parseArgs({
  options: {
    "state-dir": { type: "string" },
    "pairing-id": { type: "string" },
  },
});
const stateDir = values["state-dir"];
const pairingId = values["pairing-id"];
const home = process.env.HOME;
if (!stateDir || !pairingId || !home) {
  err("unknown_pairing", "pair-accept requires --state-dir, --pairing-id, and HOME");
}

let pending = null;
try {
  pending = JSON.parse(readFileSync(pendingPath(stateDir, pairingId), "utf8"));
} catch {
  // Unknown, already completed, or already cleaned up. Self-heal any
  // leftover line for this id before rejecting.
  await endPairing({ home, stateDir, pairingId });
  err("unknown_pairing", `no pending pairing ${pairingId}`);
}

if (Math.floor(Date.now() / 1000) > pending.expiresAt) {
  await endPairing({ home, stateDir, pairingId });
  err("expired", `pairing ${pairingId} expired; regenerate the Pairing Code`);
}

const submission = await readSubmission(process.stdin);
if (submission.trim().length === 0) {
  err("no_input", "expected a Device Key public line on stdin");
}

let deviceKey;
try {
  deviceKey = parseDeviceKeyLine(submission);
} catch (error) {
  if (error instanceof DeviceKeyError) {
    err("invalid_key", `rejected Device Key line: ${error.message}`);
  }
  throw error;
}

// One locked edit enrolls the Device Key and self-revokes the bootstrap
// line. Pending state is deleted inside the critical section so a racing
// second connection cannot enroll twice with the same Bootstrap Key.
let alreadyUsed = false;
let expired = false;
await editAuthorizedKeys(home, (lines) => {
  if (!existsSync(pendingPath(stateDir, pairingId))) {
    alreadyUsed = true;
    return null;
  }
  const kept = lines.filter((line) => parseBootstrapLine(line)?.pairingId !== pairingId);
  rmSync(pendingPath(stateDir, pairingId), { force: true });
  // Re-validate expiry inside the lock: the stdin read can block for up to
  // INPUT_TIMEOUT_MS, so the TTL may have lapsed since the pre-read check.
  // Still revoke the bootstrap line, but do not enroll the Device Key.
  if (Math.floor(Date.now() / 1000) > pending.expiresAt) {
    expired = true;
    return kept;
  }
  if (!kept.some((line) => keyBlobOf(line) === keyBlobOf(deviceKey.line))) {
    kept.push(deviceKey.line);
  }
  return kept;
});
if (alreadyUsed) {
  err("unknown_pairing", `pairing ${pairingId} was already used`);
}
if (expired) {
  err("expired", `pairing ${pairingId} expired; regenerate the Pairing Code`);
}

ok(deviceKey.fingerprint);
