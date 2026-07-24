import { test, suite, before } from "node:test";
import assert from "node:assert/strict";

import { createApnsSigner, JWT_MAX_AGE_MS } from "../src/apns-jwt.js";

/** Wrap a PKCS#8 DER export in the PEM framing a real .p8 file uses. */
function derToPem(der) {
  const b64 = Buffer.from(der).toString("base64");
  const lines = b64.match(/.{1,64}/g).join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
}

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

suite("createApnsSigner", () => {
  const nowMs = 1_753_305_600_000;
  /** @type {{teamId: string, keyId: string, p8: string}} */
  let config;
  /** @type {CryptoKey} */
  let publicKey;

  before(async () => {
    const pair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    );
    publicKey = pair.publicKey;
    const der = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    config = { teamId: "TEAM123456", keyId: "KEY1234567", p8: derToPem(der) };
  });

  test("signs an ES256 JWT with Apple's claims", async () => {
    const signer = createApnsSigner();
    const jwt = await signer.getToken(config, nowMs);
    const [header64, claims64, signature64] = jwt.split(".");
    assert.deepEqual(decodeSegment(header64), { alg: "ES256", kid: "KEY1234567" });
    assert.deepEqual(decodeSegment(claims64), { iss: "TEAM123456", iat: nowMs / 1000 });
    const verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      Buffer.from(signature64, "base64url"),
      Buffer.from(`${header64}.${claims64}`, "utf8"),
    );
    assert.equal(verified, true);
  });

  test("reuses the cached token until it nears Apple's 60-minute limit", async () => {
    const signer = createApnsSigner();
    const first = await signer.getToken(config, nowMs);
    assert.equal(await signer.getToken(config, nowMs + JWT_MAX_AGE_MS - 1000), first);
  });

  test("re-signs once the cached token is ~50 minutes old", async () => {
    const signer = createApnsSigner();
    const first = await signer.getToken(config, nowMs);
    const second = await signer.getToken(config, nowMs + JWT_MAX_AGE_MS);
    assert.notEqual(second, first);
    const [, claims64] = second.split(".");
    assert.equal(decodeSegment(claims64).iat, (nowMs + JWT_MAX_AGE_MS) / 1000);
  });

  test("re-signs when the signing config changes", async () => {
    const signer = createApnsSigner();
    const first = await signer.getToken(config, nowMs);
    const second = await signer.getToken({ ...config, keyId: "OTHERKEY01" }, nowMs);
    assert.notEqual(second, first);
    assert.equal(decodeSegment(second.split(".")[0]).kid, "OTHERKEY01");
  });

  test("rejects a malformed .p8", async () => {
    const signer = createApnsSigner();
    await assert.rejects(signer.getToken({ ...config, p8: "not a key" }, nowMs));
    await assert.rejects(
      signer.getToken(
        { ...config, p8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n" },
        nowMs,
      ),
    );
  });
});
