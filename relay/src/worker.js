// herdr Push Relay (ADR 0008): a stateless forwarder from Hosts to APNs.
//
// One endpoint, POST /push. Bodies without `kind` are the original alert
// path (plugin notify hook): device token, APNs environment, encrypted
// envelope, optional collapse key. The relay signs the APNs provider JWT
// with the deploy-time .p8 secret, wraps the envelope verbatim in a
// mutable-content alert push, forwards it, and relays Apple's verdict
// back — 410 Unregistered included, so the plugin can prune dead tokens.
//
// `kind: "liveactivity"` is the Live Activity path (see
// docs/agents/live-activity-contract.md): same JWT and host selection, a
// derived `${APNS_TOPIC}.push-type.liveactivity` topic, and an `aps`
// content-state that carries plaintext counts plus the still-opaque
// envelope. The alert path rejects any body that carries a `kind` field.
//
// No accounts, no database, no queue, no retries (the plugin retries).
// The relay never parses the envelope: it sees ciphertext and a token,
// nothing else. Nothing here may depend on the deployment origin — callers
// can point plugin and app at any base URL.

import { createApnsSigner } from "./apns-jwt.js";
import { createFixedWindowLimiter } from "./rate-limit.js";

const APNS_HOSTS = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
};

// APNs caps alert-push and live-activity payloads at 4 KB; the request cap
// just bounds the work spent on garbage before validation.
const MAX_APNS_PAYLOAD_BYTES = 4096;
const MAX_REQUEST_BYTES = 8192;
// APNs caps apns-collapse-id at 64 bytes.
const MAX_COLLAPSE_ID_BYTES = 64;
// Lowercase hex per the registration file contract; bounded but not pinned
// to 64 chars, since Apple says token length may change.
const TOKEN_PATTERN = /^[0-9a-f]{16,200}$/;

const DEFAULT_IP_LIMIT_PER_MIN = 120;
const DEFAULT_TOKEN_LIMIT_PER_MIN = 60;

// Live Activity timestamp must land in [now − 86400, now + 300] seconds.
const TIMESTAMP_PAST_SECONDS = 86_400;
const TIMESTAMP_FUTURE_SECONDS = 300;
const COUNT_MAX = 999;

// The extension rewrites title and body after decrypting; this generic text
// is what iOS shows if that fails, so it must never look alarming.
const FALLBACK_ALERT = { title: "Heeler", body: "Agent update" };

const encoder = new TextEncoder();

function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function configString(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** @returns {{teamId: string, keyId: string, p8: string, topic: string} | null} */
function readConfig(env) {
  const teamId = configString(env.APNS_TEAM_ID);
  const keyId = configString(env.APNS_KEY_ID);
  const p8 = configString(env.APNS_KEY_P8);
  const topic = configString(env.APNS_TOPIC);
  if (teamId === null || keyId === null || p8 === null || topic === null) {
    return null;
  }
  return { teamId, keyId, p8, topic };
}

function clientIp(request) {
  const connectingIp = request.headers.get("cf-connecting-ip");
  if (connectingIp !== null) {
    return connectingIp;
  }
  const forwarded = request.headers.get("x-forwarded-for");
  if (forwarded !== null) {
    return forwarded.split(",")[0].trim();
  }
  return "unknown";
}

function limitPerMinute(value, fallback) {
  const limit = Number(value);
  return Number.isInteger(limit) && limit > 0 ? limit : fallback;
}

/**
 * Validate an alert-path push request body. Any body that carries a `kind`
 * field is rejected so the discriminator cannot leak onto this path.
 *
 * @returns {{error: string} | {token: string, environment: "production"|"sandbox", envelope: string, collapse: string|undefined}}
 */
function validatePush(body) {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "bad_json" };
  }
  if ("kind" in body) {
    return { error: "bad_kind" };
  }
  const { token, env, envelope, collapse } = body;
  if (typeof token !== "string" || !TOKEN_PATTERN.test(token)) {
    return { error: "bad_token" };
  }
  if (env !== "production" && env !== "sandbox") {
    return { error: "bad_env" };
  }
  if (typeof envelope !== "string" || envelope.length === 0) {
    return { error: "bad_envelope" };
  }
  if (collapse !== undefined) {
    if (
      typeof collapse !== "string" ||
      collapse.length === 0 ||
      encoder.encode(collapse).byteLength > MAX_COLLAPSE_ID_BYTES
    ) {
      return { error: "bad_collapse" };
    }
  }
  return { token, environment: env, envelope, collapse };
}

/**
 * Validate a Live Activity push request body. Envelope is accepted as a
 * non-empty string and never parsed; collapse must be absent.
 *
 * @param {unknown} body
 * @param {number} nowSeconds
 * @returns {{error: string} | {
 *   token: string,
 *   environment: "production"|"sandbox",
 *   event: "update"|"end",
 *   priority: 5|10,
 *   timestamp: number,
 *   staleDate: number|undefined,
 *   dismissalDate: number|undefined,
 *   counts: {working: number, blocked: number, done: number},
 *   envelope: string,
 * }}
 */
function validateActivity(body, nowSeconds) {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "bad_json" };
  }
  const { token, env, event, priority, timestamp, stale_date, dismissal_date, counts, envelope } =
    body;
  if (typeof token !== "string" || !TOKEN_PATTERN.test(token)) {
    return { error: "bad_token" };
  }
  if (env !== "production" && env !== "sandbox") {
    return { error: "bad_env" };
  }
  if (event !== "update" && event !== "end") {
    return { error: "bad_event" };
  }
  if (!Number.isInteger(priority) || (priority !== 5 && priority !== 10)) {
    return { error: "bad_priority" };
  }
  if (
    !Number.isInteger(timestamp) ||
    timestamp <= 0 ||
    timestamp < nowSeconds - TIMESTAMP_PAST_SECONDS ||
    timestamp > nowSeconds + TIMESTAMP_FUTURE_SECONDS
  ) {
    return { error: "bad_timestamp" };
  }
  if (stale_date !== undefined && (!Number.isInteger(stale_date) || stale_date <= timestamp)) {
    return { error: "bad_stale_date" };
  }
  if (dismissal_date !== undefined && (event !== "end" || !Number.isInteger(dismissal_date))) {
    return { error: "bad_dismissal_date" };
  }
  if (!validCounts(counts)) {
    return { error: "bad_counts" };
  }
  if (priority === 10 && counts.blocked < 1) {
    return { error: "bad_priority" };
  }
  if (typeof envelope !== "string" || envelope.length === 0) {
    return { error: "bad_envelope" };
  }
  if ("collapse" in body) {
    return { error: "bad_collapse" };
  }
  return {
    token,
    environment: env,
    event,
    priority,
    timestamp,
    staleDate: stale_date,
    dismissalDate: dismissal_date,
    counts: { working: counts.working, blocked: counts.blocked, done: counts.done },
    envelope,
  };
}

function validCounts(counts) {
  if (typeof counts !== "object" || counts === null || Array.isArray(counts)) {
    return false;
  }
  const keys = Object.keys(counts);
  if (keys.length !== 3) {
    return false;
  }
  for (const key of ["working", "blocked", "done"]) {
    if (!Object.hasOwn(counts, key)) {
      return false;
    }
    const value = counts[key];
    if (!Number.isInteger(value) || value < 0 || value > COUNT_MAX) {
      return false;
    }
  }
  return true;
}

/**
 * Build the Live Activity APNs JSON body. The envelope string is embedded
 * as a JSON value without parsing so the relay never inspects ciphertext.
 */
function buildLiveActivityApnsBody(activity) {
  const countsJson = JSON.stringify(activity.counts);
  let aps = `"timestamp":${activity.timestamp},"event":${JSON.stringify(activity.event)},"content-state":{"counts":${countsJson},"envelope":${activity.envelope}}`;
  if (activity.staleDate !== undefined) {
    aps += `,"stale-date":${activity.staleDate}`;
  }
  if (activity.dismissalDate !== undefined) {
    aps += `,"dismissal-date":${activity.dismissalDate}`;
  }
  return `{"aps":{${aps}}}`;
}

function rateLimited(verdict) {
  return json(429, { error: "rate_limited" }, { "retry-after": String(verdict.retryAfterSeconds) });
}

/**
 * Build a relay instance: the fetch handler plus its per-instance JWT cache
 * and rate-limit windows. Exported so tests get a fresh instance each; the
 * default export below is the one Cloudflare runs.
 */
export function createRelay() {
  const signer = createApnsSigner();
  const ipLimiter = createFixedWindowLimiter();
  const tokenLimiter = createFixedWindowLimiter();

  return {
    /**
     * @param {Request} request
     * @param {Record<string, string>} env
     * @returns {Promise<Response>}
     */
    async fetch(request, env) {
      const url = new URL(request.url);
      if (url.pathname !== "/push") {
        return json(404, { error: "not_found" });
      }
      if (request.method !== "POST") {
        return json(405, { error: "method_not_allowed" }, { allow: "POST" });
      }
      const config = readConfig(env);
      if (config === null) {
        return json(500, { error: "relay_misconfigured" });
      }

      const nowMs = Date.now();
      const ipVerdict = ipLimiter.check(
        clientIp(request),
        limitPerMinute(env.RATE_LIMIT_IP_PER_MIN, DEFAULT_IP_LIMIT_PER_MIN),
        nowMs,
      );
      if (!ipVerdict.allowed) {
        return rateLimited(ipVerdict);
      }

      const bodyText = await request.text();
      if (encoder.encode(bodyText).byteLength > MAX_REQUEST_BYTES) {
        return json(413, { error: "request_too_large" });
      }
      let parsed;
      try {
        parsed = JSON.parse(bodyText);
      } catch {
        return json(400, { error: "bad_json" });
      }

      let token;
      let environment;
      let apnsBody;
      /** @type {Record<string, string>} */
      let apnsHeaders;

      if (
        typeof parsed === "object" &&
        parsed !== null &&
        !Array.isArray(parsed) &&
        parsed.kind === "liveactivity"
      ) {
        const activity = validateActivity(parsed, Math.floor(nowMs / 1000));
        if ("error" in activity) {
          return json(400, { error: activity.error });
        }
        token = activity.token;
        environment = activity.environment;
        apnsBody = buildLiveActivityApnsBody(activity);
        apnsHeaders = {
          "apns-topic": `${config.topic}.push-type.liveactivity`,
          "apns-push-type": "liveactivity",
          "apns-priority": String(activity.priority),
          "content-type": "application/json",
        };
      } else {
        const push = validatePush(parsed);
        if ("error" in push) {
          return json(400, { error: push.error });
        }
        token = push.token;
        environment = push.environment;
        apnsBody = JSON.stringify({
          aps: { alert: FALLBACK_ALERT, "mutable-content": 1 },
          envelope: push.envelope,
        });
        apnsHeaders = {
          "apns-topic": config.topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        };
        if (push.collapse !== undefined) {
          apnsHeaders["apns-collapse-id"] = push.collapse;
        }
      }

      const tokenVerdict = tokenLimiter.check(
        token,
        limitPerMinute(env.RATE_LIMIT_TOKEN_PER_MIN, DEFAULT_TOKEN_LIMIT_PER_MIN),
        nowMs,
      );
      if (!tokenVerdict.allowed) {
        return rateLimited(tokenVerdict);
      }

      if (encoder.encode(apnsBody).byteLength > MAX_APNS_PAYLOAD_BYTES) {
        return json(413, { error: "payload_too_large" });
      }

      let jwt;
      try {
        jwt = await signer.getToken(config, nowMs);
      } catch {
        return json(500, { error: "relay_misconfigured" });
      }

      const headers = {
        authorization: `bearer ${jwt}`,
        ...apnsHeaders,
      };

      let apnsResponse;
      try {
        apnsResponse = await fetch(`https://${APNS_HOSTS[environment]}/3/device/${token}`, {
          method: "POST",
          headers,
          body: apnsBody,
        });
      } catch {
        return json(502, { error: "apns_unreachable" });
      }

      if (apnsResponse.status === 200) {
        return json(200, { apnsId: apnsResponse.headers.get("apns-id") });
      }
      let detail = null;
      try {
        detail = await apnsResponse.json();
      } catch {
        // Non-JSON APNs body; relay the status alone.
      }
      const relayed = {
        reason: typeof detail?.reason === "string" ? detail.reason : null,
      };
      if (typeof detail?.timestamp === "number") {
        relayed.timestamp = detail.timestamp;
      }
      return json(apnsResponse.status, relayed);
    },
  };
}

export default createRelay();
