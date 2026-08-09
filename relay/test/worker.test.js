// Boundary tests for the Push Relay: drive the worker's fetch handler as
// Cloudflare would (Request in, Response out) with APNs stubbed at the
// network edge — the outbound `fetch` call is replaced, nothing inside the
// worker is.

import { test, suite, before } from "node:test";
import assert from "node:assert/strict";

import { createRelay } from "../src/worker.js";

const nowMs = 1_753_305_600_000;

/** @type {{APNS_TEAM_ID: string, APNS_KEY_ID: string, APNS_TOPIC: string, APNS_KEY_P8: string}} */
let baseEnv;
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
  const b64 = Buffer.from(der).toString("base64");
  baseEnv = {
    APNS_TEAM_ID: "TEAM123456",
    APNS_KEY_ID: "KEY1234567",
    APNS_TOPIC: "dev.bybee.heeler",
    APNS_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`,
  };
});

const goodBody = {
  token: "ab".repeat(32),
  env: "production",
  envelope: '{"v":1,"kid":"5-CJJlt5uLU","n":"AAECAwQFBgcICQoL","ct":"opaque"}',
  collapse: "%5",
};

function pushRequest(body, { ip = "203.0.113.7", method = "POST", path = "/push", origin = "https://relay.example" } = {}) {
  return new Request(origin + path, {
    method,
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
}

function apnsOk(id = "0BAD0C6E-0000-0000-0000-000000000000") {
  return new Response(null, { status: 200, headers: { "apns-id": id } });
}

/**
 * Stub the network edge: replace global fetch, record every outbound call,
 * and answer with `respond`.
 */
function stubApns(t, respond = () => apnsOk()) {
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, init) => {
    calls.push({ url: String(url), init, headers: new Headers(init.headers) });
    return respond(calls.length);
  });
  return calls;
}

function freezeTime(t, ms = nowMs) {
  return t.mock.method(Date, "now", () => ms);
}

suite("routing", () => {
  test("only POST is allowed on /push", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(undefined, { method: "GET" }), baseEnv);
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "POST");
    assert.equal(calls.length, 0);
  });

  test("unknown paths are 404", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody, { path: "/pushx" }), baseEnv);
    assert.equal(res.status, 404);
    assert.equal(calls.length, 0);
  });
});

suite("forwarding to APNs", () => {
  test("forwards the envelope verbatim with the APNs shape from ADR 0008", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);

    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { apnsId: "0BAD0C6E-0000-0000-0000-000000000000" });

    assert.equal(calls.length, 1);
    const call = calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${goodBody.token}`);
    assert.equal(call.init.method, "POST");
    assert.equal(call.headers.get("apns-topic"), "dev.bybee.heeler");
    assert.equal(call.headers.get("apns-push-type"), "alert");
    assert.equal(call.headers.get("apns-priority"), "10");
    assert.equal(call.headers.get("apns-collapse-id"), "%5");
    assert.equal(call.headers.get("content-type"), "application/json");

    const payload = JSON.parse(call.init.body);
    assert.equal(payload.aps["mutable-content"], 1);
    assert.equal(payload.aps.alert.title, "Heeler");
    assert.equal(payload.aps.alert.body, "Agent update");
    assert.equal(payload.envelope, goodBody.envelope);
  });

  test("signs the APNs JWT with ES256 and Apple's claims", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    await relay.fetch(pushRequest(goodBody), baseEnv);

    const auth = calls[0].headers.get("authorization");
    assert.match(auth, /^bearer /);
    const [header64, claims64, signature64] = auth.slice("bearer ".length).split(".");
    assert.deepEqual(JSON.parse(Buffer.from(header64, "base64url").toString()), {
      alg: "ES256",
      kid: "KEY1234567",
    });
    assert.deepEqual(JSON.parse(Buffer.from(claims64, "base64url").toString()), {
      iss: "TEAM123456",
      iat: nowMs / 1000,
    });
    const verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      Buffer.from(signature64, "base64url"),
      Buffer.from(`${header64}.${claims64}`, "utf8"),
    );
    assert.equal(verified, true);
  });

  test("reuses the JWT across requests and re-signs after ~50 minutes", async (t) => {
    const calls = stubApns(t);
    const clock = freezeTime(t);
    const relay = createRelay();
    await relay.fetch(pushRequest(goodBody), baseEnv);
    clock.mock.mockImplementation(() => nowMs + 49 * 60_000);
    await relay.fetch(pushRequest(goodBody), baseEnv);
    clock.mock.mockImplementation(() => nowMs + 51 * 60_000);
    await relay.fetch(pushRequest(goodBody), baseEnv);

    const auths = calls.map((call) => call.headers.get("authorization"));
    assert.equal(auths[1], auths[0]);
    assert.notEqual(auths[2], auths[0]);
  });

  test("env=sandbox goes to the sandbox APNs host", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest({ ...goodBody, env: "sandbox" }), baseEnv);
    assert.equal(res.status, 200);
    assert.equal(calls[0].url, `https://api.sandbox.push.apple.com/3/device/${goodBody.token}`);
  });

  test("an omitted collapse key sends no apns-collapse-id", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const { collapse, ...withoutCollapse } = goodBody;
    await relay.fetch(pushRequest(withoutCollapse), baseEnv);
    assert.equal(calls[0].headers.get("apns-collapse-id"), null);
  });

  test("assumes nothing about its own origin", async (t) => {
    stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest(goodBody, { origin: "http://localhost:8787" }),
      baseEnv,
    );
    assert.equal(res.status, 200);
  });
});

suite("APNs status passthrough", () => {
  test("410 Unregistered is relayed with its reason and timestamp", async (t) => {
    stubApns(t, () =>
      new Response(JSON.stringify({ reason: "Unregistered", timestamp: 1753305600000 }), {
        status: 410,
      }),
    );
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 410);
    assert.deepEqual(await res.json(), { reason: "Unregistered", timestamp: 1753305600000 });
  });

  test("400 BadDeviceToken is relayed", async (t) => {
    stubApns(t, () => new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 }));
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { reason: "BadDeviceToken" });
  });

  test("a non-JSON APNs error body relays the status with a null reason", async (t) => {
    stubApns(t, () => new Response("gateway exploded", { status: 503 }));
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 503);
    assert.deepEqual(await res.json(), { reason: null });
  });

  test("an unreachable APNs is 502, not a crash", async (t) => {
    t.mock.method(globalThis, "fetch", async () => {
      throw new TypeError("network down");
    });
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 502);
    assert.deepEqual(await res.json(), { error: "apns_unreachable" });
  });
});

suite("request validation", () => {
  const cases = [
    ["non-JSON body", "not json {", "bad_json"],
    ["JSON scalar body", '"push"', "bad_json"],
    ["missing token", { ...goodBody, token: undefined }, "bad_token"],
    ["uppercase hex token", { ...goodBody, token: "AB".repeat(32) }, "bad_token"],
    ["non-hex token", { ...goodBody, token: "zz".repeat(32) }, "bad_token"],
    ["too-short token", { ...goodBody, token: "abcd" }, "bad_token"],
    ["missing env", { ...goodBody, env: undefined }, "bad_env"],
    ["unknown env", { ...goodBody, env: "prod" }, "bad_env"],
    ["missing envelope", { ...goodBody, envelope: undefined }, "bad_envelope"],
    ["empty envelope", { ...goodBody, envelope: "" }, "bad_envelope"],
    ["non-string envelope", { ...goodBody, envelope: { v: 1 } }, "bad_envelope"],
    ["non-string collapse", { ...goodBody, collapse: 5 }, "bad_collapse"],
    ["empty collapse", { ...goodBody, collapse: "" }, "bad_collapse"],
    ["collapse over 64 bytes", { ...goodBody, collapse: "x".repeat(65) }, "bad_collapse"],
  ];

  for (const [name, body, error] of cases) {
    test(`rejects ${name} without calling APNs`, async (t) => {
      const calls = stubApns(t);
      const relay = createRelay();
      const res = await relay.fetch(pushRequest(body), baseEnv);
      assert.equal(res.status, 400);
      assert.deepEqual(await res.json(), { error });
      assert.equal(calls.length, 0);
    });
  }

  test("a collapse key of exactly 64 bytes passes", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodBody, collapse: "x".repeat(64) }),
      baseEnv,
    );
    assert.equal(res.status, 200);
    assert.equal(calls[0].headers.get("apns-collapse-id"), "x".repeat(64));
  });

  test("missing APNs config is 500 relay_misconfigured", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const { APNS_KEY_P8, ...withoutKey } = baseEnv;
    const res = await relay.fetch(pushRequest(goodBody), withoutKey);
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "relay_misconfigured" });
    assert.equal(calls.length, 0);
  });

  test("a garbage .p8 is 500 relay_misconfigured", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), {
      ...baseEnv,
      APNS_KEY_P8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
    });
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "relay_misconfigured" });
    assert.equal(calls.length, 0);
  });
});

suite("payload caps", () => {
  test("rejects when the APNs payload would exceed 4 KB, without calling APNs", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodBody, envelope: "x".repeat(4100) }),
      baseEnv,
    );
    assert.equal(res.status, 413);
    assert.deepEqual(await res.json(), { error: "payload_too_large" });
    assert.equal(calls.length, 0);
  });

  test("caps the request body itself", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodBody, envelope: "x".repeat(9000) }),
      baseEnv,
    );
    assert.equal(res.status, 413);
    assert.deepEqual(await res.json(), { error: "request_too_large" });
    assert.equal(calls.length, 0);
  });
});

suite("rate limits", () => {
  test("limits per IP and answers 429 with retry-after", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const env = { ...baseEnv, RATE_LIMIT_IP_PER_MIN: "2" };

    assert.equal((await relay.fetch(pushRequest(goodBody), env)).status, 200);
    assert.equal((await relay.fetch(pushRequest(goodBody), env)).status, 200);
    const limited = await relay.fetch(pushRequest(goodBody), env);
    assert.equal(limited.status, 429);
    assert.deepEqual(await limited.json(), { error: "rate_limited" });
    assert.equal(limited.headers.get("retry-after"), "60");
    assert.equal(calls.length, 2);

    // Another IP is not affected.
    const other = await relay.fetch(pushRequest(goodBody, { ip: "198.51.100.9" }), env);
    assert.equal(other.status, 200);
  });

  test("limits per token across source IPs", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const env = { ...baseEnv, RATE_LIMIT_TOKEN_PER_MIN: "2" };

    for (let i = 0; i < 2; i += 1) {
      const res = await relay.fetch(pushRequest(goodBody, { ip: `203.0.113.${i}` }), env);
      assert.equal(res.status, 200);
    }
    const limited = await relay.fetch(pushRequest(goodBody, { ip: "203.0.113.99" }), env);
    assert.equal(limited.status, 429);
    assert.equal(calls.length, 2);

    // Another token from yet another IP still goes through.
    const other = await relay.fetch(
      pushRequest({ ...goodBody, token: "cd".repeat(32) }, { ip: "203.0.113.100" }),
      env,
    );
    assert.equal(other.status, 200);
  });
});
