import { before, suite, test } from "node:test";
import assert from "node:assert/strict";

import {
  FCM_OAUTH_SCOPE,
  FCM_OAUTH_TOKEN_URL,
  createFcmTokenProvider,
} from "../src/fcm-jwt.js";

function derToPem(der) {
  const b64 = Buffer.from(der).toString("base64");
  const lines = b64.match(/.{1,64}/g).join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
}

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

suite("createFcmTokenProvider", () => {
  const nowMs = 1_753_305_600_000;
  /** @type {{projectId: string, clientEmail: string, privateKeyPkcs8: string}} */
  let config;
  /** @type {CryptoKey} */
  let publicKey;

  before(async () => {
    const pair = await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    );
    publicKey = pair.publicKey;
    const der = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    config = {
      projectId: "heeler-notifications",
      clientEmail: "relay@heeler-notifications.iam.gserviceaccount.com",
      privateKeyPkcs8: derToPem(der),
    };
  });

  test("mints an RS256 service-account assertion with Google's required claims", async () => {
    const requests = [];
    const provider = createFcmTokenProvider();
    const accessToken = await provider.getAccessToken(config, nowMs, async (url, init) => {
      requests.push({ url: String(url), init });
      return new Response(
        JSON.stringify({ access_token: "oauth-access-token", expires_in: 3600, token_type: "Bearer" }),
        { status: 200 },
      );
    });

    assert.equal(accessToken, "oauth-access-token");
    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, FCM_OAUTH_TOKEN_URL);
    assert.equal(requests[0].init.method, "POST");
    assert.equal(requests[0].init.headers["content-type"], "application/x-www-form-urlencoded");

    const form = new URLSearchParams(requests[0].init.body);
    assert.equal(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
    const assertion = form.get("assertion");
    assert.notEqual(assertion, null);
    const [header64, claims64, signature64] = assertion.split(".");
    assert.deepEqual(decodeSegment(header64), { alg: "RS256", typ: "JWT" });
    assert.deepEqual(decodeSegment(claims64), {
      iss: config.clientEmail,
      scope: FCM_OAUTH_SCOPE,
      aud: FCM_OAUTH_TOKEN_URL,
      iat: nowMs / 1000,
      exp: nowMs / 1000 + 3600,
    });
    const verified = await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      publicKey,
      Buffer.from(signature64, "base64url"),
      Buffer.from(`${header64}.${claims64}`, "utf8"),
    );
    assert.equal(verified, true);
  });

  test("reuses the OAuth access token before its expiry", async () => {
    let calls = 0;
    const provider = createFcmTokenProvider();
    const fetcher = async () => {
      calls += 1;
      return new Response(
        JSON.stringify({ access_token: `token-${calls}`, expires_in: 3600, token_type: "Bearer" }),
        { status: 200 },
      );
    };

    assert.equal(await provider.getAccessToken(config, nowMs, fetcher), "token-1");
    assert.equal(await provider.getAccessToken(config, nowMs + 30 * 60_000, fetcher), "token-1");
    assert.equal(calls, 1);
  });
});
