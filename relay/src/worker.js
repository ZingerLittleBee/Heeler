// herdr Push Relay (ADR 0008): a stateless forwarder from Hosts to APNs or
// FCM. One endpoint, POST /push. The caller (the plugin's notify hook)
// supplies a provider, device token, APNs environment when applicable, the
// encrypted notification envelope, and an opaque collapse key.
//
// APNs receives the unchanged v1 mutable-content alert path, signed with the
// deploy-time .p8 secret. FCM receives the envelope verbatim as a data message
// after a deploy-time service-account key is exchanged for OAuth. Provider
// verdicts relay back; APNs 410 and FCM UNREGISTERED/404 become the same
// prunable 410 semantics. No accounts, database, queue, or retries live here
// (the plugin retries).
//
// The relay never parses the envelope: it sees ciphertext and a token,
// nothing else. Nothing here may depend on the deployment origin — callers
// can point plugin and app at any base URL.

import { createApnsSigner } from "./apns-jwt.js";
import {
  FcmAuthorizationError,
  FcmCredentialError,
  createFcmTokenProvider,
} from "./fcm-jwt.js";
import { createFixedWindowLimiter } from "./rate-limit.js";

const APNS_HOSTS = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
};
// FCM caps the keys and values in a data message at 4 KB.
const MAX_FCM_PAYLOAD_BYTES = 4096;

// APNs caps alert-push payloads at 4 KB; the request cap just bounds the
// work spent on garbage before validation.
const MAX_APNS_PAYLOAD_BYTES = 4096;
const MAX_REQUEST_BYTES = 8192;
// APNs caps apns-collapse-id at 64 bytes.
const MAX_COLLAPSE_ID_BYTES = 64;
// Lowercase hex per the registration file contract; bounded but not pinned
// to 64 chars, since Apple says token length may change.
const TOKEN_PATTERN = /^[0-9a-f]{16,200}$/;

const DEFAULT_IP_LIMIT_PER_MIN = 120;
const DEFAULT_TOKEN_LIMIT_PER_MIN = 60;

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

/** @returns {{projectId: string, clientEmail: string, privateKeyPkcs8: string} | null} */
function readFcmConfig(env) {
  const projectId = configString(env.FCM_PROJECT_ID);
  const clientEmail = configString(env.FCM_SA_CLIENT_EMAIL);
  const privateKeyPkcs8 = configString(env.FCM_SA_PRIVATE_KEY_PKCS8);
  if (projectId === null || clientEmail === null || privateKeyPkcs8 === null) {
    return null;
  }
  return { projectId, clientEmail, privateKeyPkcs8 };
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
 * Validate the push request body.
 *
 * @returns {{error: string} | {provider: "apns"|"fcm", token: string, environment: "production"|"sandbox"|undefined, envelope: string, collapse: string|undefined}}
 */
function validatePush(body) {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "bad_json" };
  }
  const { provider = "apns", token, env, envelope, collapse } = body;
  if (provider !== "apns" && provider !== "fcm") {
    return { error: "bad_provider" };
  }
  if (
    typeof token !== "string" ||
    token.length === 0 ||
    (provider === "apns" && !TOKEN_PATTERN.test(token))
  ) {
    return { error: "bad_token" };
  }
  if (provider === "apns") {
    if (env !== "production" && env !== "sandbox") {
      return { error: "bad_env" };
    }
  } else if (env !== undefined) {
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
  return {
    provider,
    token,
    environment: provider === "apns" ? env : undefined,
    envelope,
    collapse,
  };
}

/** FCM identifies a dead registration with a typed error detail, not text. */
function isFcmUnregistered(detail) {
  return detail?.error?.details?.some(
    (entry) =>
      entry?.["@type"] === "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
      entry.errorCode === "UNREGISTERED",
  );
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
  const fcmTokenProvider = createFcmTokenProvider();
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
      // Keep the legacy (provider omitted -> APNs) misconfiguration response
      // ahead of request validation. FCM is the only provider that needs the
      // body parsed before deciding which optional deploy config is required.
      const apnsConfig = readConfig(env);
      let bodyText;
      let parsed;
      if (apnsConfig === null) {
        bodyText = await request.text();
        try {
          parsed = JSON.parse(bodyText);
        } catch {
          return json(500, { error: "relay_misconfigured" });
        }
        if (parsed?.provider === undefined) {
          return json(500, { error: "relay_misconfigured" });
        }
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

      if (bodyText === undefined) {
        bodyText = await request.text();
      }
      if (encoder.encode(bodyText).byteLength > MAX_REQUEST_BYTES) {
        return json(413, { error: "request_too_large" });
      }
      if (parsed === undefined) {
        try {
          parsed = JSON.parse(bodyText);
        } catch {
          return json(400, { error: "bad_json" });
        }
      }
      const requestedProvider = parsed?.provider === undefined ? "apns" : parsed.provider;
      const fcmConfig = requestedProvider === "fcm" ? readFcmConfig(env) : null;
      if (requestedProvider === "fcm" && fcmConfig === null) {
        return json(500, { error: "relay_misconfigured" });
      }
      const push = validatePush(parsed);
      if ("error" in push) {
        return json(400, { error: push.error });
      }
      if (push.provider === "apns" && apnsConfig === null) {
        return json(500, { error: "relay_misconfigured" });
      }

      const tokenVerdict = tokenLimiter.check(
        push.token,
        limitPerMinute(env.RATE_LIMIT_TOKEN_PER_MIN, DEFAULT_TOKEN_LIMIT_PER_MIN),
        nowMs,
      );
      if (!tokenVerdict.allowed) {
        return rateLimited(tokenVerdict);
      }

      if (push.provider === "fcm") {
        const fcmData = { envelope: push.envelope };
        if (encoder.encode(JSON.stringify(fcmData)).byteLength > MAX_FCM_PAYLOAD_BYTES) {
          return json(413, { error: "payload_too_large" });
        }
        const fcmBody = JSON.stringify({
          message: {
            token: push.token,
            data: fcmData,
            android: {
              priority: "high",
              ...(push.collapse === undefined ? {} : { collapse_key: push.collapse }),
            },
          },
        });
        let accessToken;
        try {
          accessToken = await fcmTokenProvider.getAccessToken(fcmConfig, nowMs, fetch);
        } catch (error) {
          if (
            error instanceof FcmCredentialError ||
            (error instanceof FcmAuthorizationError &&
              (error.status === 400 || error.status === 401 || error.status === 403))
          ) {
            return json(500, { error: "relay_misconfigured" });
          }
          return json(502, { error: "fcm_unreachable" });
        }

        let fcmResponse;
        try {
          fcmResponse = await fetch(
            `https://fcm.googleapis.com/v1/projects/${fcmConfig.projectId}/messages:send`,
            {
              method: "POST",
              headers: {
                authorization: `Bearer ${accessToken}`,
                "content-type": "application/json",
              },
              body: fcmBody,
            },
          );
        } catch {
          return json(502, { error: "fcm_unreachable" });
        }

        if (fcmResponse.ok) {
          let result = null;
          try {
            result = await fcmResponse.json();
          } catch {
            // FCM success responses normally carry a message name, but the
            // plugin only needs the 2xx acknowledgement.
          }
          return json(200, { fcmName: typeof result?.name === "string" ? result.name : null });
        }
        let detail = null;
        try {
          detail = await fcmResponse.json();
        } catch {
          // Non-JSON FCM body; relay the status alone.
        }
        if (fcmResponse.status === 404 && isFcmUnregistered(detail)) {
          // Preserve APNs-equivalent semantics so the plugin prunes the dead
          // registration through its existing 410 path.
          return json(410, { reason: "Unregistered" });
        }
        return json(fcmResponse.status, {
          reason: typeof detail?.error?.status === "string" ? detail.error.status : null,
        });
      }

      const apnsBody = JSON.stringify({
        aps: { alert: FALLBACK_ALERT, "mutable-content": 1 },
        envelope: push.envelope,
      });
      if (encoder.encode(apnsBody).byteLength > MAX_APNS_PAYLOAD_BYTES) {
        return json(413, { error: "payload_too_large" });
      }

      let jwt;
      try {
        jwt = await signer.getToken(apnsConfig, nowMs);
      } catch {
        return json(500, { error: "relay_misconfigured" });
      }

      const headers = {
        authorization: `bearer ${jwt}`,
        "apns-topic": apnsConfig.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      };
      if (push.collapse !== undefined) {
        headers["apns-collapse-id"] = push.collapse;
      }

      let apnsResponse;
      try {
        apnsResponse = await fetch(`https://${APNS_HOSTS[push.environment]}/3/device/${push.token}`, {
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
