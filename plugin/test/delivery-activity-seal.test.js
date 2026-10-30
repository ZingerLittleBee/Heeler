// Sealing Live Activity content to fit and delivering it, observed from the
// fake relay: the bytes it receives open with the device's key.

import { afterEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

import { decryptActivityEnvelope } from "../src/activity-envelope.js";
import { deliverLiveActivity } from "../src/delivery/activity-seal.js";

const KEY = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const DEVICE = { token: "c".repeat(64), env: "sandbox", key: KEY };
const COUNTS = { working: 1, blocked: 0, done: 0 };
const TIMESTAMP = 1_700_000_000;
const REQUEST = { event: "update", priority: 5, timestamp: TIMESTAMP, counts: COUNTS };
const TOO_LARGE = { status: 413, body: { error: "payload_too_large" } };
const ACCEPTED = { status: 200, body: {} };

let relay;

afterEach(async () => {
  await relay?.close();
  relay = undefined;
});

function startFakeRelay(respond = () => ACCEPTED) {
  const bodies = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const { status, body } = respond(bodies.length);
      bodies.push(JSON.parse(raw));
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      relay = {
        config: { relayUrl: `http://127.0.0.1:${server.address().port}`, retryDelayMs: 1 },
        bodies,
        close: () => new Promise((done) => server.close(done)),
      };
      resolve(relay);
    });
  });
}

const agent = (overrides = {}) => ({
  kind: "claude",
  pane: "w1:p2",
  rows: [[{ text: "row" }]],
  status: "working",
  title: "a title",
  workspace: "Heeler",
  ...overrides,
});
const content = (agents) => ({ agents, host: "lab", v: 1 });
const opened = (index) => decryptActivityEnvelope(relay.bodies[index].envelope, KEY);

suite("Live Activity delivery", () => {
  test("an update carries a stale date and content that opens with the device's key", async () => {
    await startFakeRelay();
    const outcome = await deliverLiveActivity(relay.config, DEVICE, content([agent()]), REQUEST);
    assert.equal(outcome, "ok");
    const { envelope, ...fields } = relay.bodies[0];
    assert.deepEqual(fields, {
      kind: "liveactivity",
      token: DEVICE.token,
      env: "sandbox",
      event: "update",
      priority: 5,
      timestamp: TIMESTAMP,
      counts: COUNTS,
      stale_date: TIMESTAMP + 900,
    });
    assert.equal(typeof envelope, "string");
    assert.deepEqual(opened(0), content([agent()]));
  });

  test("an end carries a dismissal date instead", async () => {
    await startFakeRelay();
    await deliverLiveActivity(relay.config, DEVICE, content([]), { ...REQUEST, event: "end" });
    assert.equal(relay.bodies[0].dismissal_date, TIMESTAMP);
    assert.equal("stale_date" in relay.bodies[0], false);
  });

  test("a dead token comes back as pruned", async () => {
    await startFakeRelay(() => ({ status: 410, body: {} }));
    assert.equal(await deliverLiveActivity(relay.config, DEVICE, content([agent()]), REQUEST), "pruned");
  });

  test("content over budget is sealed without titles before the first send", async () => {
    await startFakeRelay();
    const titled = Array.from({ length: 12 }, (_, index) =>
      agent({ pane: `w1:p${index}`, title: "t".repeat(200), rows: undefined }));
    await deliverLiveActivity(relay.config, DEVICE, content(titled), REQUEST);
    assert.equal(relay.bodies.length, 1);
    assert.equal(opened(0).agents.length, 12);
    assert.equal(opened(0).agents.some((entry) => "title" in entry), false);
  });

  test("each relay 413 sheds titles, then rows, then agents", async () => {
    await startFakeRelay((index) => (index < 3 ? TOO_LARGE : ACCEPTED));
    assert.equal(await deliverLiveActivity(relay.config, DEVICE, content([agent()]), REQUEST), "ok");
    assert.deepEqual(opened(0).agents, [agent()]);
    const { title, ...withoutTitle } = agent();
    assert.equal(title, "a title");
    assert.deepEqual(opened(1).agents, [withoutTitle]);
    const { rows, ...withoutRows } = withoutTitle;
    assert.ok(Array.isArray(rows));
    assert.deepEqual(opened(2).agents, [withoutRows]);
    assert.deepEqual(opened(3), content([]));
  });

  test("a relay 413 with nothing left to shed is a conclusive failure", async () => {
    await startFakeRelay(() => TOO_LARGE);
    await assert.rejects(
      () => deliverLiveActivity(relay.config, DEVICE, content([agent()]), REQUEST),
      /push for token cccccccc… failed: payload too large/,
    );
    assert.equal(relay.bodies.length, 4);
  });
});
