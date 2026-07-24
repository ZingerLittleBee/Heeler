// APNs provider-token signing: ES256 over the deploy-time .p8 secret.
//
// Apple rejects tokens older than 60 minutes and throttles keys that
// re-sign more often than every 20, so the signed JWT is cached and reused
// for ~50 minutes (per worker instance; APNs accepts concurrent tokens from
// the same key, so several isolates each holding one is fine).
//
// WebCrypto only — no Node built-ins — so the module runs unchanged on
// Cloudflare Workers and under Node's test runner.

export const JWT_MAX_AGE_MS = 50 * 60 * 1000;

const encoder = new TextEncoder();

/** @param {Uint8Array} bytes */
function base64UrlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** Decode the PEM framing of a .p8 file to PKCS#8 DER bytes. */
function pemToDer(pem) {
  const body = pem.replace(/-----(?:BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const binary = atob(body); // throws on invalid base64
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * A caching APNs JWT signer. One per relay instance.
 */
export function createApnsSigner() {
  /** @type {{teamId: string, keyId: string, p8: string, jwt: string, issuedAtMs: number} | null} */
  let cached = null;

  return {
    /**
     * Return a JWT for the given signing config, reusing the cached one
     * while it is younger than {@link JWT_MAX_AGE_MS} and the config is
     * unchanged.
     *
     * @param {{teamId: string, keyId: string, p8: string}} config
     * @param {number} nowMs
     * @returns {Promise<string>}
     * @throws on a malformed .p8 (surfaced by the worker as misconfiguration)
     */
    async getToken({ teamId, keyId, p8 }, nowMs) {
      if (
        cached !== null &&
        cached.teamId === teamId &&
        cached.keyId === keyId &&
        cached.p8 === p8 &&
        nowMs - cached.issuedAtMs < JWT_MAX_AGE_MS
      ) {
        return cached.jwt;
      }

      const key = await crypto.subtle.importKey(
        "pkcs8",
        pemToDer(p8),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
      );
      const header = base64UrlEncode(encoder.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
      const claims = base64UrlEncode(
        encoder.encode(JSON.stringify({ iss: teamId, iat: Math.floor(nowMs / 1000) })),
      );
      const signingInput = `${header}.${claims}`;
      // WebCrypto ECDSA signatures are raw r||s — exactly the JWS format.
      const signature = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        encoder.encode(signingInput),
      );
      const jwt = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
      cached = { teamId, keyId, p8, jwt, issuedAtMs: nowMs };
      return jwt;
    },
  };
}
