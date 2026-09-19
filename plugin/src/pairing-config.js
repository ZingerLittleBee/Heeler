// Persistent custom pairing addresses (ADR 0007).
//
// Clients can reach this machine through DNS names no local interface carries:
// Tailscale MagicDNS, split-DNS, or ordinary hostnames. Those names live in
// `pairing.json` inside the plugin's herdr-managed config directory, so they
// survive plugin updates -- never in the plugin checkout itself. The file is
// additive and versioned; readers that find any other `v` treat it as absent
// (defaults only), and unknown fields are preserved across writes.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { parseCustomAddress } from "./addresses.js";

// Bounded so one runaway paste cannot make an unusable QR or checklist.
export const MAX_CUSTOM_ADDRESSES = 16;

const CONFIG_FILE_NAME = "pairing.json";

function isValidCustomList(value) {
  return (
    Array.isArray(value) &&
    value.length <= MAX_CUSTOM_ADDRESSES &&
    value.every(
      (entry) => typeof entry === "string" && parseCustomAddress(entry).address !== undefined,
    )
  );
}

/**
 * Read the custom pairing addresses from `<configDir>/pairing.json`.
 *
 * A missing, unreadable, or malformed file yields an empty list -- pairing
 * must keep working from interface discovery alone. A version other than 1
 * is treated the same way, matching the notification registration reader.
 *
 * @param {string} configDir
 * @returns {{addresses: string[]}}
 */
export function readPairingConfig(configDir) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(join(configDir, CONFIG_FILE_NAME), "utf8"));
  } catch {
    return { addresses: [] };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { addresses: [] };
  }
  if (parsed.v !== 1 || !isValidCustomList(parsed.custom_addresses)) {
    return { addresses: [] };
  }
  return { addresses: [...parsed.custom_addresses] };
}

/**
 * Atomically persist the custom pairing addresses (temp file + rename,
 * preserving unknown fields so a future plugin version can migrate).
 *
 * @param {string} configDir
 * @param {string[]} addresses validated custom addresses, in list order
 */
export function writePairingConfig(configDir, addresses) {
  let file = {};
  try {
    file = JSON.parse(readFileSync(join(configDir, CONFIG_FILE_NAME), "utf8"));
    if (file === null || typeof file !== "object" || Array.isArray(file)) {
      file = {};
    }
  } catch {
    file = {};
  }
  file.v = 1;
  file.custom_addresses = [...addresses];
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const path = join(configDir, CONFIG_FILE_NAME);
  const temp = `${path}.tmp-${process.pid}`;
  writeFileSync(temp, JSON.stringify(file));
  renameSync(temp, path);
}
