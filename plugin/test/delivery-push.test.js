// Sending through the Push Relay, driven against a fake relay that records
// what it receives. An alert and a Live Activity differ on a 413: only a Live
// Activity can resend smaller, so an alert must never read one as a dead token.

import { afterEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

import { collapseKeyFor, sendAlertPush, sendLiveActivityPush } from "../src/delivery/push.js";

const RETRY_DELAY_MS = 1;
const DEVICE = { token: "a".repeat(64), env: "sandbox", key: Buffer.alloc(32, 7) };
const ACTIVITY_BODY = { kind: "liveactivity", token: "c".repeat(64), env: "production", envelope: "{}" };

let relay;

afterEach(async () => {
  await relay?.close();
  relay = undefined;
});

/** `respond(index)` answers `{ status, text }`. */
function startFakeRelay(respond) {
  const requests = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const { status, text } = respond(requests.length);
      requests.push({ method: req.method, path: req.url, contentType: req.headers["content-type"], raw });
      res.writeHead(status);
      res.end(text);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      relay = {
        url: `http://127.0.0.1:${server.address().port}`,
        requests,
        close: () => new Promise((done) => server.close(done)),
      };
      resolve(relay);
    });
  });
}

const answering = (...answers) => (index) => answers[Math.min(index, answers.length - 1)];
const sendAlert = () => sendAlertPush(relay.url, DEVICE, "ENVELOPE", "COLLAPSE", RETRY_DELAY_MS);
const sendActivity = () => sendLiveActivityPush(relay.url, ACTIVITY_BODY, RETRY_DELAY_MS);

suite("alert push", () => {
  test("posts the relay's alert body and reads 2xx as ok", async () => {
    await startFakeRelay(answering({ status: 200, text: "{}" }));
    assert.equal(await sendAlert(), "ok");
    assert.deepEqual(relay.requests, [{
      method: "POST",
      path: "/push",
      contentType: "application/json",
      raw: `{"token":"${DEVICE.token}","env":"sandbox","envelope":"ENVELOPE","collapse":"COLLAPSE"}`,
    }]);
  });

  test("a 410 means the token is dead, without a retry", async () => {
    await startFakeRelay(answering({ status: 410, text: "{}" }));
    assert.equal(await sendAlert(), "pruned");
    assert.equal(relay.requests.length, 1);
  });

  test("a relay-origin 413 fails conclusively and keeps the token", async () => {
    await startFakeRelay(answering({ status: 413, text: '{"error":"payload_too_large"}' }));
    await assert.rejects(sendAlert, /push for token aaaaaaaa… failed: relay answered 413/);
    assert.equal(relay.requests.length, 1);
  });

  test("429 and 5xx retry up to three attempts", async () => {
    await startFakeRelay(answering({ status: 429, text: "" }, { status: 503, text: "" }, { status: 200, text: "" }));
    assert.equal(await sendAlert(), "ok");
    assert.equal(relay.requests.length, 3);
  });

  test("a failure on every attempt reports the last answer", async () => {
    await startFakeRelay(answering({ status: 500, text: "boom" }));
    await assert.rejects(sendAlert, /relay answered 500: boom/);
    assert.equal(relay.requests.length, 3);
  });

  test("an unreachable relay retries and reports it", async () => {
    await startFakeRelay(answering({ status: 200, text: "" }));
    const { url } = relay;
    await relay.close();
    relay = undefined;
    await assert.rejects(
      () => sendAlertPush(url, DEVICE, "ENVELOPE", "COLLAPSE", RETRY_DELAY_MS),
      /relay unreachable/,
    );
  });
});

suite("Live Activity push", () => {
  test("posts the body it was given and reads 2xx as ok", async () => {
    await startFakeRelay(answering({ status: 200, text: "{}" }));
    assert.equal(await sendActivity(), "ok");
    assert.equal(relay.requests[0].raw, JSON.stringify(ACTIVITY_BODY));
  });

  test("a 410 means the token is dead", async () => {
    await startFakeRelay(answering({ status: 410, text: "{}" }));
    assert.equal(await sendActivity(), "pruned");
  });

  test("a relay-origin 413 asks for a smaller envelope, without a retry", async () => {
    await startFakeRelay(answering({ status: 413, text: '{"error":"payload_too_large"}' }));
    assert.equal(await sendActivity(), "too_large");
    assert.equal(relay.requests.length, 1);
  });

  test("a 413 from anything but the relay fails conclusively", async () => {
    await startFakeRelay(answering({ status: 413, text: "<html>too large</html>" }));
    await assert.rejects(sendActivity, /push for token cccccccc… failed: relay answered 413/);
    assert.equal(relay.requests.length, 1);
  });
});

suite("collapse key", () => {
  test("is opaque, stable per device and pane, and fits APNs' 64-byte cap", () => {
    const key = Buffer.alloc(32, 7);
    // Known-good value: sha256(key || "HERDR-NOTIFY-COLLAPSE:" || "w1:p2"), first 16 bytes.
    assert.equal(collapseKeyFor(key, "w1:p2"), "XKrMXM2p0TpEW8MoCz0crg");
    assert.notEqual(collapseKeyFor(key, "w1:p3"), collapseKeyFor(key, "w1:p2"));
    assert.notEqual(collapseKeyFor(Buffer.alloc(32, 8), "w1:p2"), collapseKeyFor(key, "w1:p2"));
  });
});
