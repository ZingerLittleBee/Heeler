// Sending through the Push Relay.
//
// The relay never retries by design (ADR 0008), so senders do: transient
// failures (network errors, 429, 5xx) retry up to SEND_ATTEMPTS. Shared by the
// notify and activity hooks and the Host Helper (ADR 0033).

import { createHash } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";

const SEND_ATTEMPTS = 3;
const REQUEST_TIMEOUT_MS = 10_000;

/**
 * The `apns-collapse-id` passed through the relay so a newer status replaces
 * an older notification for the same pane. Keyed by the device's Notification
 * Key so it stays opaque: the relay can neither read nor dictionary-guess the
 * pane id behind it. 16 bytes -> 22 chars, well under APNs' 64-byte cap.
 */
export function collapseKeyFor(key, paneId) {
  return createHash("sha256")
    .update(key)
    .update("HERDR-NOTIFY-COLLAPSE:")
    .update(paneId, "utf8")
    .digest()
    .subarray(0, 16)
    .toString("base64url");
}

function isRelayOrigin413(detail) {
  try {
    const parsed = JSON.parse(detail);
    return typeof parsed?.error === "string";
  } catch {
    return false;
  }
}

/**
 * POST one push body. Returns "ok", "pruned" (APNs 410 Unregistered: the token
 * is dead), "too_large" only when the sender can resend smaller, or throws for
 * a delivery that conclusively failed.
 */
async function postPush(relayUrl, body, retryDelayMs, { canResendSmaller }) {
  const payload = JSON.stringify(body);
  let lastFailure = "";
  for (let attempt = 1; attempt <= SEND_ATTEMPTS; attempt += 1) {
    if (attempt > 1) await sleep(retryDelayMs);
    let response;
    try {
      response = await fetch(`${relayUrl}/push`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: payload,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (error) {
      lastFailure = `relay unreachable: ${error.message}`;
      continue;
    }
    if (response.ok) return "ok";
    const detail = (await response.text().catch(() => "")).slice(0, 200);
    if (response.status === 410) return "pruned";
    if (canResendSmaller && response.status === 413 && isRelayOrigin413(detail)) return "too_large";
    lastFailure = `relay answered ${response.status}: ${detail}`;
    if (response.status !== 429 && response.status < 500) break;
  }
  throw new Error(`push for token ${body.token.slice(0, 8)}… failed: ${lastFailure}`);
}

/**
 * Send one Agent Notification. Returns "ok" or "pruned"; a conclusive failure,
 * a 413 included, throws and leaves the token registered.
 */
export function sendAlertPush(relayUrl, device, envelope, collapse, retryDelayMs) {
  const body = { token: device.token, env: device.env, envelope, collapse };
  return postPush(relayUrl, body, retryDelayMs, { canResendSmaller: false });
}

/**
 * Send one Live Activity body. Returns "ok", "pruned" or "too_large" (a
 * relay-origin 413, so the caller can seal less content); others throw.
 */
export function sendLiveActivityPush(relayUrl, body, retryDelayMs) {
  return postPush(relayUrl, body, retryDelayMs, { canResendSmaller: true });
}
