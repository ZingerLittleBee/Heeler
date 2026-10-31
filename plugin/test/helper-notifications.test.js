// Agent Notifications from the Helper (ADR 0033): the fake core socket on one side
// and the fake Push Relay on the other, with the Helper's real listener between.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { followCoreSession } from "../helper/core/follower.js";
import { notificationListener } from "../helper/notifications/notifier.js";
import { seenMarkFileName } from "../helper/notifications/seen-marks.js";
import { encryptNotificationEnvelope, notificationKeyId } from "../helper/shared/notification-envelope.js";
import { FakeCore, exchange, waitFor } from "./support/fake-core.js";

const STATUS = exchange("server-status").result;
const CORE = STATUS.core.id;
const CHANNEL = exchange("events-subscribe").result.channel;
const SESSION = "work";
const DEBOUNCE_MS = 15;

const KEY_A = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const KEY_B = Buffer.from(Array.from({ length: 32 }, (_, i) => 255 - i));
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);

const CLAUDE = { pid: 4242, name: "claude", argv: ["claude"], cwd: "/work/app" };
const SHELL = { pid: 4243, name: "zsh", argv: ["-zsh"], cwd: "/work/app" };

let root;
let directory;
let env;
let relay;
let logs;
const running = [];

async function startRelay(respond = () => ({ status: 200, body: {} })) {
  const requests = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const request = { path: req.url, body: JSON.parse(raw) };
      const { status, body } = respond(request, requests.length);
      requests.push(request);
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  running.push(() => new Promise((done) => server.close(done)));
  return { url: `http://127.0.0.1:${server.address().port}`, requests };
}

function writeConfig(relayUrl) {
  writeFileSync(join(directory, "notify.json"), JSON.stringify({ relay_url: relayUrl, debounce_ms: DEBOUNCE_MS, retry_delay_ms: 1 }));
}

function entry(key, token, { session = SESSION, blocked = true, done = true } = {}) {
  return { token, key: key.toString("base64url"), env: "sandbox", session, notify: { blocked, done } };
}

function register(...devices) {
  writeFileSync(join(directory, "notifications.json"), JSON.stringify({ v: 1, devices }));
}

function writeMark(key, marks, core = CORE) {
  const device = notificationKeyId(key);
  writeFileSync(join(directory, seenMarkFileName(device)), JSON.stringify({ core, device, marks, v: 1 }));
}

function open(envelope, key) {
  const wire = JSON.parse(envelope);
  const nonce = Buffer.from(wire.n, "base64url");
  const sealed = Buffer.from(wire.ct, "base64url");
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from("HERDR-NOTIFY:1", "utf8"));
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(sealed.subarray(0, sealed.length - 16)), decipher.final()]).toString("utf8"));
}

function agent(address, fields = {}) {
  return {
    address,
    state: "live",
    pid: 7,
    argv: ["/bin/zsh"],
    cwd: "/work/app",
    title: "Fix the bug",
    foreground: CLAUDE,
    status: { state: "idle", app: "claude-code" },
    reported: true,
    turn: 0,
    ...fields,
  };
}

async function startCore(terminals, seq = 1) {
  const socket = join(root, "r", "herdr-core", `${SESSION}.sock`);
  const core = await FakeCore.start(socket, { status: STATUS, snapshot: { seq, channel: CHANNEL, terminals } });
  running.push(() => core.stop().catch(() => {}));
  return core;
}

function follow() {
  const log = (line) => logs.push(line);
  const handle = followCoreSession(SESSION, {
    env,
    runUserDirectory: join(root, "none"),
    listener: notificationListener({ directory, log }),
    log,
    retryDelayMs: 5,
  });
  running.push(() => handle.stop());
  return handle;
}

/** A core and the Helper following it, past the subscribe snapshot. */
async function connected(terminals) {
  const core = await startCore(terminals);
  follow();
  await waitFor(() => core.last?.methods.includes("events.subscribe"), "the subscription");
  await waitFor(() => logs.some((line) => line.includes("connected to core")), "the connection");
  return core;
}

let nextSeq = 100;
function send(core, type, terminal, data) {
  nextSeq += 1;
  core.last.sendEvents(`${JSON.stringify({ jsonrpc: "2.0", method: "event", params: { seq: nextSeq, type, terminal, data } })}\n`);
}

const status = (core, terminal, state, app = "claude-code") =>
  send(core, "status", terminal, { status: state === null ? null : { state, app }, records: {}, reported: true });

/** Working to Done as the core sends it: the count moves, then status, then turn. */
function finishTurn(core, terminal, turn) {
  status(core, terminal, "done");
  send(core, "turn", terminal, { turn, state: "done" });
}

let nextSentinel = 0;

/** Everything sent before this has been decided: a new Agent's Blocked comes after them. */
async function settled(core) {
  const before = relay.requests.length;
  nextSentinel += 1;
  const sentinel = `sentinel${nextSentinel}`;
  send(core, "created", sentinel, agent(sentinel));
  status(core, sentinel, "working");
  status(core, sentinel, "blocked");
  await waitFor(() => relay.requests.length > before, "the sentinel's notification");
  await new Promise((done) => setTimeout(done, DEBOUNCE_MS * 3));
}

const sentTo = (key, terminal) =>
  relay.requests.map((request) => request.body).filter((body) => {
    if (JSON.parse(body.envelope).kid !== notificationKeyId(key)) return false;
    return open(body.envelope, key).pane === terminal;
  });

beforeEach(async () => {
  root = mkdtempSync("/tmp/hh-");
  directory = join(root, "helper");
  mkdirSync(directory, { mode: 0o700 });
  env = { HOME: root, XDG_RUNTIME_DIR: join(root, "r") };
  logs = [];
  relay = await startRelay();
  writeConfig(relay.url);
});

afterEach(async () => {
  while (running.length > 0) await running.pop()();
  rmSync(root, { recursive: true, force: true });
});

suite("the Helper's sealing", () => {
  const vectors = JSON.parse(readFileSync(new URL("../test-vectors/notification-payload-v1.json", import.meta.url), "utf8"));
  const errors = vectors.valid.filter((vector) => vector.payload.status === "error");

  test("reproduces the shared Error case byte for byte", () => {
    assert.equal(errors.length, 1);
    for (const vector of errors) {
      const nonce = Buffer.from(JSON.parse(vector.envelope).n, "base64url");
      assert.equal(encryptNotificationEnvelope(vector.payload, Buffer.from(vector.key, "base64url"), { nonce }), vector.envelope);
    }
  });
});

suite("a Terminal that enters Blocked, Error or Done", () => {
  test("Blocked reaches each registered device, sealed with that device's key", async () => {
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => relay.requests.length === 2, "two notifications");

    const byToken = new Map(relay.requests.map(({ path, body }) => {
      assert.equal(path, "/push");
      assert.equal(body.env, "sandbox");
      return [body.token, body];
    }));
    for (const [token, key] of [[TOKEN_A, KEY_A], [TOKEN_B, KEY_B]]) {
      const body = byToken.get(token);
      assert.equal(JSON.parse(body.envelope).kid, notificationKeyId(key));
      const payload = open(body.envelope, key);
      assert.equal(payload.pane, "t1");
      assert.equal(payload.kind, "claude");
      assert.equal(payload.status, "blocked");
      assert.equal(payload.project, "app");
      assert.equal(payload.title, "Fix the bug");
      assert.ok(Number.isInteger(payload.ts) && payload.ts > 0);
    }
    assert.notEqual(byToken.get(TOKEN_A).collapse, byToken.get(TOKEN_B).collapse);
  });

  test("Error is sent under the Blocked trigger, in its own word", async () => {
    register(entry(KEY_A, TOKEN_A, { done: false }), entry(KEY_B, TOKEN_B, { blocked: false }));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "error");
    await waitFor(() => relay.requests.length > 0, "a notification");
    await new Promise((done) => setTimeout(done, DEBOUNCE_MS * 3));

    assert.equal(relay.requests.length, 1);
    assert.equal(relay.requests[0].body.token, TOKEN_A);
    assert.equal(open(relay.requests[0].body.envelope, KEY_A).status, "error");
  });

  test("Done reaches a device whose settings allow it and no other", async () => {
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B, { done: false }));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await waitFor(() => sentTo(KEY_A, "t1").length > 0, "Done");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(open(sentTo(KEY_A, "t1")[0].envelope, KEY_A).status, "done");
    assert.equal(sentTo(KEY_B, "t1").length, 0);
  });

  test("a program not known to report done ends a turn at Working to Idle", async () => {
    register(entry(KEY_A, TOKEN_A));
    const aider = { pid: 50, name: "aider", argv: ["aider"], cwd: "/work/app" };
    const core = await connected([agent("t1", { foreground: aider, status: { state: "idle", app: "aider" } })]);

    status(core, "t1", "working", "aider");
    status(core, "t1", "idle", "aider");
    await waitFor(() => relay.requests.length > 0, "Done");

    assert.equal(open(relay.requests[0].body.envelope, KEY_A).status, "done");
    assert.equal(open(relay.requests[0].body.envelope, KEY_A).kind, "aider");
  });

  test("only a device of this core session hears it", async () => {
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B, { session: "elsewhere" }));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => relay.requests.length > 0, "a notification");
    await new Promise((done) => setTimeout(done, DEBOUNCE_MS * 3));

    assert.deepEqual(relay.requests.map((request) => request.body.token), [TOKEN_A]);
  });

  test("a status that does not hold through the debounce sends nothing", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    status(core, "t1", "working");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });

  test("Blocked again after moving on is a new notification, and staying Blocked is not", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => sentTo(KEY_A, "t1").length === 1, "the first Blocked");
    send(core, "title", "t1", { title: "Still blocked" });
    await settled(core);
    assert.equal(sentTo(KEY_A, "t1").length, 1);

    status(core, "t1", "working");
    await settled(core);
    status(core, "t1", "blocked");
    await waitFor(() => sentTo(KEY_A, "t1").length === 2, "the second Blocked");
  });
});

suite("a Terminal that holds no Agent", () => {
  test("a Terminal that is no Agent sends nothing", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1", { foreground: SHELL })]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    status(core, "t1", "done");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });

  test("an Agent a shell foreground ended sends nothing", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    send(core, "foreground", "t1", SHELL);
    status(core, "t1", "done");
    send(core, "turn", "t1", { turn: 1, state: "done" });
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });

  test("an Agent a shell foreground ended inside the debounce sends nothing", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    send(core, "foreground", "t1", SHELL);
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });

  test("a report of another known program under Claude Code is no Blocked", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "blocked", "codex");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });
});

suite("Done per device", () => {
  test("is withheld from a device whose mark covers the turn, and sent to one without such a mark", async () => {
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);
    writeMark(KEY_A, [{ terminal: "t1", turn: 1, word: "done" }]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await waitFor(() => sentTo(KEY_B, "t1").length > 0, "Done on the other device");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
    assert.equal(sentTo(KEY_B, "t1").length, 1);
  });

  test("a mark from an earlier turn withholds nothing", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1", { turn: 3 })]);
    writeMark(KEY_A, [{ terminal: "t1", turn: 3, word: "done" }]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 4);
    await waitFor(() => relay.requests.length > 0, "Done");

    assert.equal(open(relay.requests[0].body.envelope, KEY_A).status, "done");
  });

  test("a mark made while Blocked withholds nothing of the Done that follows", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    send(core, "turn", "t1", { turn: 1, state: "blocked" });
    await waitFor(() => sentTo(KEY_A, "t1").length === 1, "Blocked");
    writeMark(KEY_A, [{ terminal: "t1", turn: 1, word: "blocked" }]);
    status(core, "t1", "done");
    await waitFor(() => sentTo(KEY_A, "t1").length === 2, "Done");

    assert.equal(open(sentTo(KEY_A, "t1")[1].envelope, KEY_A).status, "done");
  });

  test("a mark for another core does not apply", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);
    writeMark(KEY_A, [{ terminal: "t1", turn: 1, word: "done" }], "an-earlier-core");

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await waitFor(() => relay.requests.length > 0, "Done");
  });

  test("Blocked and Error ignore marks", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);
    writeMark(KEY_A, [{ terminal: "t1", turn: 5, word: "blocked" }]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => relay.requests.length > 0, "Blocked");
  });

  test("a turn the mark withheld is not sent later", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);
    writeMark(KEY_A, [{ terminal: "t1", turn: 1, word: "done" }]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await settled(core);
    rmSync(join(directory, seenMarkFileName(notificationKeyId(KEY_A))));
    send(core, "foreground", "t1", CLAUDE);
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });
});

suite("across connections", () => {
  test("what a core already shows at first sight sends nothing", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([
      agent("t1", { turn: 6, status: { state: "done", app: "claude-code" } }),
      agent("t2", { status: { state: "blocked", app: "claude-code" } }),
      agent("t3", { status: { state: "error", app: "claude-code" } }),
    ]);

    await settled(core);

    for (const terminal of ["t1", "t2", "t3"]) assert.equal(sentTo(KEY_A, terminal).length, 0, terminal);
  });

  test("a new Helper process does not send again what the last one sent", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1"), agent("t2", { status: { state: "working", app: "claude-code" } })]);
    status(core, "t1", "working");
    status(core, "t1", "blocked");
    send(core, "turn", "t1", { turn: 1, state: "blocked" });
    await waitFor(() => sentTo(KEY_A, "t1").length === 1, "Blocked");
    await settled(core);
    while (running.length > 0) await running.pop()();
    relay = await startRelay();
    writeConfig(relay.url);

    const again = await connected([
      agent("t1", { turn: 1, status: { state: "blocked", app: "claude-code" } }),
      // What moved while no Helper ran still counts: its memory was on disk.
      agent("t2", { turn: 1, status: { state: "done", app: "claude-code" } }),
    ]);
    await waitFor(() => sentTo(KEY_A, "t2").length === 1, "the Done it missed");
    await settled(again);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
    assert.equal(sentTo(KEY_A, "t2").length, 1);
  });

  test("a turn that ended while the Helper was away is sent once it is back", async () => {
    register(entry(KEY_A, TOKEN_A));
    const first = await connected([agent("t1", { status: { state: "working", app: "claude-code" } })]);
    await new Promise((done) => setTimeout(done, DEBOUNCE_MS));
    await first.stop();

    const core = await startCore([agent("t1", { turn: 1, status: { state: "done", app: "claude-code" } })]);
    await waitFor(() => relay.requests.length > 0, "Done");

    assert.equal(open(relay.requests[0].body.envelope, KEY_A).status, "done");
    assert.ok(core.last.methods.includes("events.subscribe"));
  });

  test("a missed stretch of events is read from its snapshot", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1", { status: { state: "working", app: "claude-code" } })]);

    nextSeq += 1;
    const terminals = [agent("t1", { turn: 1, status: { state: "blocked", app: "claude-code" } })];
    core.last.sendEvents(`${JSON.stringify({ jsonrpc: "2.0", method: "missed", params: { seq: nextSeq, terminals } })}\n`);
    await waitFor(() => relay.requests.length > 0, "Blocked");

    assert.equal(open(relay.requests[0].body.envelope, KEY_A).status, "blocked");
  });

  test("another core id starts over", async () => {
    register(entry(KEY_A, TOKEN_A));
    const first = await connected([agent("t1", { status: { state: "working", app: "claude-code" } })]);
    await first.stop();

    const socket = join(root, "r", "herdr-core", `${SESSION}.sock`);
    const terminals = [agent("t1", { turn: 1, status: { state: "done", app: "claude-code" } })];
    const core = await FakeCore.start(socket, {
      status: { ...STATUS, core: { ...STATUS.core, id: "another-core" } },
      snapshot: { seq: 1, channel: CHANNEL, terminals },
    });
    running.push(() => core.stop().catch(() => {}));
    await waitFor(() => core.last?.methods.includes("events.subscribe"), "the subscription");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });

  test("a device that left and came back hears nothing of the turns between", async () => {
    register(entry(KEY_A, TOKEN_A));
    const first = await connected([agent("t1", { status: { state: "working", app: "claude-code" } })]);
    register();
    await first.stop();
    await waitFor(() => logs.some((line) => line.includes("ended")), "the connection's end");

    register(entry(KEY_A, TOKEN_A));
    const core = await startCore([agent("t1", { turn: 1, status: { state: "done", app: "claude-code" } })]);
    await waitFor(() => core.last?.methods.includes("events.subscribe"), "the subscription");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 0);
  });

  test("a relay that cannot be reached leaves the notification to try again", async () => {
    register(entry(KEY_A, TOKEN_A));
    writeConfig("http://127.0.0.1:9");
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => logs.some((line) => line.includes("could not notify")), "the failure", 15_000);
    writeConfig(relay.url);
    send(core, "foreground", "t1", CLAUDE);
    await waitFor(() => relay.requests.length > 0, "the retry");
  });
});

suite("a device the relay says is gone", () => {
  test("leaves the registrations, with its marks", async () => {
    relay = await startRelay((request) => (request.body.token === TOKEN_A ? { status: 410, body: {} } : { status: 200, body: {} }));
    writeConfig(relay.url);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    writeMark(KEY_A, []);
    writeMark(KEY_B, []);
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(
      () => !existsSync(join(directory, seenMarkFileName(notificationKeyId(KEY_A)))),
      "the gone device's marks to leave",
    );

    const file = JSON.parse(readFileSync(join(directory, "notifications.json"), "utf8"));
    assert.deepEqual(file.devices.map((device) => device.token), [TOKEN_B]);
    assert.equal(existsSync(join(directory, seenMarkFileName(notificationKeyId(KEY_B)))), true);
  });
});

suite("what the Helper keeps", () => {
  test("is private to the user and leaves a session's folder alone", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);
    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => relay.requests.length > 0, "Blocked");

    assert.equal(existsSync(join(directory, "sessions")), false);
    const kept = join(directory, "state", "notify", `${SESSION}.json`);
    await waitFor(() => existsSync(kept), "the memory file");
  });
});
