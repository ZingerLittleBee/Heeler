// Notification Registrations: which devices receive a delivery.
//
// Reads and prunes `notifications.json` (contract in README.md) in the
// directory the caller names, for the session the caller names. The notify
// and activity hooks pass their plugin config directory; this module knows
// nothing of herdr's environment, because it is shared with the Host Helper
// (ADR 0033).

import { createHash } from "node:crypto";
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { parseActivityRowLayout } from "../activity-rows.js";
import { optionalText } from "../display-text.js";
import { KEY_BYTES } from "../seal-envelope.js";

const REGISTRATIONS_FILE = "notifications.json";
const APNS_ENVIRONMENTS = new Set(["production", "sandbox"]);
const ACTIVITY_TOKEN_PATTERN = /^[0-9a-f]{16,200}$/;

/**
 * The registration file's current contents, or null when it is absent, corrupt
 * or of a foreign version: all of those mean "send nothing, rewrite nothing".
 */
function readRegistrationFile(dir) {
  let file;
  try {
    file = JSON.parse(readFileSync(join(dir, REGISTRATIONS_FILE), "utf8"));
  } catch {
    return null;
  }
  return file?.v === 1 && Array.isArray(file.devices) ? file : null;
}

function decodedKey(entry) {
  const key = typeof entry.key === "string" ? Buffer.from(entry.key, "base64url") : null;
  return key?.length === KEY_BYTES ? key : null;
}

/**
 * Whether a registration entry receives this session's deliveries. Entries
 * without a string `session` predate session scoping and receive every
 * session's deliveries, as before. An unknown session (null) delivers to
 * legacy entries only. Names compare exactly.
 */
export function deliversToSession(entry, session) {
  if (typeof entry?.session !== "string") return true;
  return session !== null && entry.session === session;
}

/**
 * Each session the registrations name, once, as written. An entry that predates
 * session scoping names none.
 */
export function registeredSessions(dir) {
  const file = readRegistrationFile(dir);
  if (file === null) return [];
  return [...new Set(file.devices.map((entry) => entry?.session).filter((session) => typeof session === "string"))];
}

/**
 * Devices that want an Agent Notification gated on `flag`, a key of each
 * entry's `notify` preferences. A malformed entry is skipped, never fatal for
 * its neighbors.
 */
export function readAlertDevices(dir, flag, session) {
  const file = readRegistrationFile(dir);
  if (file === null) return [];
  const devices = [];
  for (const entry of file.devices) {
    if (typeof entry?.token !== "string" || entry.token.length === 0) continue;
    if (!deliversToSession(entry, session)) continue;
    if (!APNS_ENVIRONMENTS.has(entry.env)) continue;
    // Per the v1 contract a missing notify flag means do not send (fail closed).
    if (entry.notify?.[flag] !== true) continue;
    const key = decodedKey(entry);
    if (key === null) continue;
    devices.push({ token: entry.token, env: entry.env, key });
  }
  return devices;
}

/**
 * Devices whose registration entry carries a usable Live Activity token.
 * `notify` flags do not apply; a missing `live_activity` object means skip.
 */
export function readLiveActivityDevices(dir, session) {
  const file = readRegistrationFile(dir);
  if (file === null) return [];
  const devices = [];
  for (const entry of file.devices) {
    if (!deliversToSession(entry, session)) continue;
    const live = entry?.live_activity;
    if (typeof live !== "object" || live === null || Array.isArray(live)) continue;
    if (typeof live.token !== "string" || !ACTIVITY_TOKEN_PATTERN.test(live.token)) continue;
    const env = APNS_ENVIRONMENTS.has(live.env) ? live.env : entry.env;
    if (!APNS_ENVIRONMENTS.has(env)) continue;
    const key = decodedKey(entry);
    if (key === null) continue;
    devices.push({
      token: live.token,
      env,
      key,
      pinnedPaneIds: live.pinned_pane_ids,
      rowLayout: parseActivityRowLayout(live.row_layout),
      rowHostName: optionalText(live.host_name),
    });
  }
  return devices;
}

/**
 * A digest of what the devices chose to see, so a sender can tell a preference
 * change from a repeated status. Senders persist it between runs, so its input
 * shape is part of what they compare against.
 */
export function liveActivityPreferences(devices) {
  return createHash("sha256").update(JSON.stringify(devices.map((device) => ({
    token: device.token, env: device.env, pins: device.pinnedPaneIds,
    layout: device.rowLayout, host: device.rowHostName,
  })).sort((left, right) => left.token.localeCompare(right.token)))).digest("hex");
}

// Atomic temp-file + rename, like every writer of this file; a concurrent
// app-side rewrite is last-writer-wins, and the next 410 re-prunes. Fields this
// code does not understand survive: additive v1 metadata must outlive a rewrite.
function writeRegistrationFile(dir, file) {
  const path = join(dir, REGISTRATIONS_FILE);
  const temp = `${path}.tmp-${process.pid}`;
  writeFileSync(temp, JSON.stringify(file));
  renameSync(temp, path);
}

/** Remove the entries of dead alert tokens (APNs 410 Unregistered). */
export function pruneAlertTokens(dir, tokens) {
  const file = readRegistrationFile(dir);
  if (file === null) return;
  file.devices = file.devices.filter((entry) => !tokens.has(entry?.token));
  writeRegistrationFile(dir, file);
}

/**
 * Drop `live_activity` from entries holding a dead Live Activity token,
 * preserving the alert token, key and notify flags beside it.
 */
export function pruneLiveActivityTokens(dir, tokens) {
  const file = readRegistrationFile(dir);
  if (file === null) return;
  for (const entry of file.devices) {
    if (tokens.has(entry?.live_activity?.token)) {
      delete entry.live_activity;
    }
  }
  writeRegistrationFile(dir, file);
}
