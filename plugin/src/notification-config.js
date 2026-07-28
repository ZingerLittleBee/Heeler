import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_RELAY_URL = "https://herdr-apns.bybee.dev";

const LEGACY_DEFAULT_RELAY_URL = "https://herdr-push-relay.69709991236.workers.dev";
const DEFAULT_DEBOUNCE_MS = 5000;
const DEFAULT_RETRY_DELAY_MS = 1000;

function normalizeRelayURL(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().replace(/\/+$/, "");
  if (normalized.length === 0 || normalized === LEGACY_DEFAULT_RELAY_URL) {
    return null;
  }
  return normalized;
}

/**
 * Read the plugin-side `notify.json`. A missing relay URL uses the production
 * endpoint; an explicit URL remains available to self-built app deployments.
 */
export function readNotificationConfig(configDir) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(join(configDir, "notify.json"), "utf8"));
  } catch {
    parsed = {};
  }
  const positiveInt = (value, fallback) =>
    Number.isInteger(value) && value >= 0 ? value : fallback;
  return {
    relayUrl: normalizeRelayURL(parsed.relay_url) ?? DEFAULT_RELAY_URL,
    debounceMs: positiveInt(parsed.debounce_ms, DEFAULT_DEBOUNCE_MS),
    retryDelayMs: positiveInt(parsed.retry_delay_ms, DEFAULT_RETRY_DELAY_MS),
  };
}
