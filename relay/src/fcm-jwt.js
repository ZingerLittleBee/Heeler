// FCM HTTP v1 authorization: exchange a signed Google service-account JWT
// for a short-lived OAuth token. WebCrypto only, so this runs unchanged in a
// Cloudflare Worker and Node's built-in test runner.

export const FCM_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const FCM_OAUTH_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

const ASSERTION_LIFETIME_SECONDS = 60 * 60;
const ACCESS_TOKEN_REFRESH_SKEW_MS = 60 * 1000;
const encoder = new TextEncoder();

export class FcmCredentialError extends Error {}
export class FcmAuthorizationError extends Error {
  constructor(status) {
    super("FCM OAuth authorization failed");
    this.status = status;
  }
}
class FcmTransportError extends Error {}

/** @param {Uint8Array} bytes */
function base64UrlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** Decode PEM framing around a PKCS#8 RSA private key. */
function pemToDer(pem) {
  const body = pem.replace(/-----(?:BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function sameConfig(cached, config) {
  return (
    cached !== null &&
    cached.projectId === config.projectId &&
    cached.clientEmail === config.clientEmail &&
    cached.privateKeyPkcs8 === config.privateKeyPkcs8
  );
}

/**
 * Exchange service-account credentials for a cached FCM OAuth access token.
 * The caller supplies `fetcher` so the Worker and tests use the same code.
 */
export function createFcmTokenProvider() {
  /** @type {{projectId: string, clientEmail: string, privateKeyPkcs8: string, accessToken: string, refreshAtMs: number} | null} */
  let cached = null;

  return {
    /**
     * @param {{projectId: string, clientEmail: string, privateKeyPkcs8: string}} config
     * @param {number} nowMs
     * @param {typeof fetch} fetcher
     */
    async getAccessToken(config, nowMs, fetcher) {
      if (sameConfig(cached, config) && nowMs < cached.refreshAtMs) {
        return cached.accessToken;
      }

      let assertion;
      try {
        const key = await crypto.subtle.importKey(
          "pkcs8",
          pemToDer(config.privateKeyPkcs8),
          { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
          false,
          ["sign"],
        );
        const nowSeconds = Math.floor(nowMs / 1000);
        const header = base64UrlEncode(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
        const claims = base64UrlEncode(
          encoder.encode(
            JSON.stringify({
              iss: config.clientEmail,
              scope: FCM_OAUTH_SCOPE,
              aud: FCM_OAUTH_TOKEN_URL,
              iat: nowSeconds,
              exp: nowSeconds + ASSERTION_LIFETIME_SECONDS,
            }),
          ),
        );
        const signingInput = `${header}.${claims}`;
        const signature = await crypto.subtle.sign(
          { name: "RSASSA-PKCS1-v1_5" },
          key,
          encoder.encode(signingInput),
        );
        assertion = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
      } catch {
        throw new FcmCredentialError("FCM service-account private key is invalid");
      }

      let response;
      try {
        response = await fetcher(FCM_OAUTH_TOKEN_URL, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
            assertion,
          }).toString(),
        });
      } catch {
        throw new FcmTransportError("FCM OAuth endpoint is unreachable");
      }
      if (!response.ok) {
        throw new FcmAuthorizationError(response.status);
      }

      let token;
      try {
        token = await response.json();
      } catch {
        throw new FcmAuthorizationError(response.status);
      }
      if (
        typeof token?.access_token !== "string" ||
        token.access_token.length === 0 ||
        typeof token.expires_in !== "number" ||
        !Number.isFinite(token.expires_in) ||
        token.expires_in <= 0
      ) {
        throw new FcmAuthorizationError(response.status);
      }

      cached = {
        ...config,
        accessToken: token.access_token,
        refreshAtMs: nowMs + Math.max(0, token.expires_in * 1000 - ACCESS_TOKEN_REFRESH_SKEW_MS),
      };
      return cached.accessToken;
    },
  };
}
