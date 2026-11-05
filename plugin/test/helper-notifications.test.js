// Agent Notifications from the Helper (ADR 0033): the fake core socket on one side
// and the fake Push Relay on the other, with the Helper's real listener between.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv } from "node:crypto";
import { createServer } from "node:http";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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
const KEY_C = Buffer.alloc(32, 7);
const TOKEN_C = "c".repeat(64);

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
    req.on("end", async () => {
      const request = { path: req.url, body: JSON.parse(raw) };
      const { status, body } = await respond(request, requests.length);
      requests.push(request);
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  running.push(() => new Promise((done) => server.close(done)));
  return { url: `http://127.0.0.1:${server.address().port}`, requests };
}

function writeConfig(relayUrl, debounceMs = DEBOUNCE_MS) {
  writeFileSync(join(directory, "notify.json"), JSON.stringify({ relay_url: relayUrl, debounce_ms: debounceMs, retry_delay_ms: 1 }));
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

function follow(listenerOptions = {}) {
  const log = (line) => logs.push(line);
  const handle = followCoreSession(SESSION, {
    env,
    runUserDirectory: join(root, "none"),
    listener: notificationListener({ directory, log, ...listenerOptions }),
    log,
    retryDelayMs: 5,
  });
  running.push(() => handle.stop());
  return handle;
}

/** A core and the Helper following it, past the subscribe snapshot. */
async function connected(terminals, listenerOptions) {
  const core = await startCore(terminals);
  follow(listenerOptions);
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

  test("a title reads without the activity glyph the harness draws in it", async () => {
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1", { title: "✳ Fix the bug" }), agent("t2", { title: "✳" })]);

    for (const terminal of ["t1", "t2"]) {
      status(core, terminal, "working");
      status(core, terminal, "blocked");
    }
    await waitFor(() => sentTo(KEY_A, "t1").length === 1 && sentTo(KEY_A, "t2").length === 1, "both notifications");

    assert.equal(open(sentTo(KEY_A, "t1")[0].envelope, KEY_A).title, "Fix the bug");
    assert.equal(open(sentTo(KEY_A, "t2")[0].envelope, KEY_A).title, undefined);
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

  test("reports that change nothing do not hold back a Blocked", async () => {
    writeFileSync(join(directory, "notify.json"), JSON.stringify({ relay_url: relay.url, debounce_ms: 80, retry_delay_ms: 1 }));
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    const reports = setInterval(() => status(core, "t1", "blocked"), 5);
    try {
      await waitFor(() => sentTo(KEY_A, "t1").length === 1, "the Blocked through the reports", 2000);
    } finally {
      clearInterval(reports);
    }
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

suite("one device's send that failed", () => {
  /** A relay that fails `token` while `failing.on`, and answers everyone else. */
  async function relayFailing(token) {
    const failing = { on: true };
    relay = await startRelay((request) => (failing.on && request.body.token === token ? { status: 500, body: {} } : { status: 200, body: {} }));
    writeConfig(relay.url);
    return failing;
  }

  const failedOnce = () => waitFor(() => logs.some((line) => line.includes("could not notify")), "the failure", 15_000);

  test("is tried at the next decision, for that device alone", async () => {
    const failing = await relayFailing(TOKEN_B);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await failedOnce();
    assert.equal(sentTo(KEY_A, "t1").length, 1);
    const tries = sentTo(KEY_B, "t1").length;

    failing.on = false;
    send(core, "foreground", "t1", CLAUDE);
    await waitFor(() => sentTo(KEY_B, "t1").length > tries, "the retry");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(sentTo(KEY_B, "t1").length, tries + 1);
    assert.equal(open(sentTo(KEY_B, "t1").at(-1).envelope, KEY_B).status, "blocked");
  });

  test("of a Done is dropped once that device has seen the turn", async () => {
    await relayFailing(TOKEN_B);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await failedOnce();
    const tries = sentTo(KEY_B, "t1").length;
    writeMark(KEY_B, [{ terminal: "t1", turn: 1, word: "done" }]);
    send(core, "foreground", "t1", CLAUDE);
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(sentTo(KEY_B, "t1").length, tries);
  });

  test("of a Done is tried again at the next decision", async () => {
    const failing = await relayFailing(TOKEN_B);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await failedOnce();
    const tries = sentTo(KEY_B, "t1").length;

    failing.on = false;
    send(core, "foreground", "t1", CLAUDE);
    await waitFor(() => sentTo(KEY_B, "t1").length > tries, "the retry");
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(open(sentTo(KEY_B, "t1").at(-1).envelope, KEY_B).status, "done");
  });

  test("goes when the Agent has moved on", async () => {
    const failing = await relayFailing(TOKEN_B);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await failedOnce();
    const tries = sentTo(KEY_B, "t1").length;

    failing.on = false;
    status(core, "t1", "working");
    await settled(core);
    assert.equal(sentTo(KEY_B, "t1").length, tries);

    status(core, "t1", "blocked");
    await waitFor(() => sentTo(KEY_B, "t1").length === tries + 1, "the new Blocked");
    assert.equal(sentTo(KEY_A, "t1").length, 2);
  });

  suite("tries again by itself", () => {
    /** The clock of a failed send's next try: a test ends each wait and reads how long it was. */
    function manualRetryTimers() {
      const armed = new Set();
      const delays = [];
      return {
        delays,
        get pending() {
          return armed.size;
        },
        set(run, ms) {
          const timer = { run };
          armed.add(timer);
          delays.push(ms);
          return timer;
        },
        clear(timer) {
          armed.delete(timer);
        },
        /** Ends the wait under way, and returns once its decision is made. */
        async fire() {
          const [timer] = armed;
          armed.delete(timer);
          await timer.run();
        },
      };
    }

    /** A Blocked Agent whose send to `TOKEN_B` failed, with the next try waiting. */
    async function blockedAndWaiting(terminals = [agent("t1")]) {
      const failing = await relayFailing(TOKEN_B);
      register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
      const retryTimers = manualRetryTimers();
      const core = await connected(terminals, { retryTimers });
      status(core, "t1", "working");
      status(core, "t1", "blocked");
      await failedOnce();
      await waitFor(() => retryTimers.pending === 1, "the next try");
      return { failing, retryTimers, core, tries: sentTo(KEY_B, "t1").length };
    }

    /** Returns once the core's earlier events have been folded, which a debounce would hide. */
    let nextMarker = 0;
    async function folded(core) {
      nextMarker += 1;
      const marker = `marker${nextMarker}`;
      send(core, "created", marker, agent(marker));
      const memory = join(directory, "state", "notify", `${SESSION}.json`);
      await waitFor(() => existsSync(memory) && marker in JSON.parse(readFileSync(memory, "utf8")).terminals, "the report");
    }

    /** What a failed `deliver` runs next has run: the promise chain is empty at a new turn. */
    const decisionsRun = () => new Promise((done) => setImmediate(done));

    test("with no event, once the relay recovers", async () => {
      const failing = await relayFailing(TOKEN_A);
      register(entry(KEY_A, TOKEN_A));
      const retryTimers = manualRetryTimers();
      const core = await connected([agent("t1")], { retryTimers });
      status(core, "t1", "working");
      status(core, "t1", "blocked");
      await failedOnce();
      await waitFor(() => retryTimers.pending === 1, "the next try");
      const tries = sentTo(KEY_A, "t1").length;

      failing.on = false;
      await retryTimers.fire();

      assert.equal(sentTo(KEY_A, "t1").length, tries + 1);
      assert.equal(open(sentTo(KEY_A, "t1").at(-1).envelope, KEY_A).status, "blocked");
      assert.equal(retryTimers.pending, 0);
      assert.deepEqual(retryTimers.delays, [30_000]);
    });

    test("for the failed device alone", async () => {
      const { failing, retryTimers, tries } = await blockedAndWaiting();

      failing.on = false;
      await retryTimers.fire();

      assert.equal(sentTo(KEY_A, "t1").length, 1);
      assert.equal(sentTo(KEY_B, "t1").length, tries + 1);
    });

    test("up to a limit, each wait double the last up to a ceiling", async () => {
      const { failing, retryTimers, core, tries } = await blockedAndWaiting();

      while (retryTimers.pending > 0) await retryTimers.fire();

      assert.deepEqual(retryTimers.delays, [30_000, 60_000, 120_000, 240_000, 300_000]);
      assert.equal(sentTo(KEY_B, "t1").length, tries * 6);

      // Past the limit a report's decision still tries, and arms nothing more.
      send(core, "foreground", "t1", CLAUDE);
      await waitFor(() => sentTo(KEY_B, "t1").length === tries * 7, "the report's try");
      await decisionsRun();
      assert.equal(retryTimers.pending, 0);
      assert.equal(retryTimers.delays.length, 5);

      failing.on = false;
      send(core, "foreground", "t1", CLAUDE);
      await waitFor(() => sentTo(KEY_B, "t1").length === tries * 7 + 1, "the recovered try");
      assert.equal(open(sentTo(KEY_B, "t1").at(-1).envelope, KEY_B).status, "blocked");
    });

    test("and stops when the Agent moves on, starting over at its next state", async () => {
      const { failing, retryTimers, core, tries } = await blockedAndWaiting();
      await retryTimers.fire();
      assert.deepEqual(retryTimers.delays, [30_000, 60_000]);
      const triesSoFar = sentTo(KEY_B, "t1").length;
      assert.equal(triesSoFar, tries * 2);

      status(core, "t1", "working");
      await waitFor(() => retryTimers.pending === 0, "the wait to go");
      assert.equal(sentTo(KEY_B, "t1").length, triesSoFar);

      status(core, "t1", "blocked");
      await waitFor(() => retryTimers.pending === 1, "the new Blocked's next try");
      assert.deepEqual(retryTimers.delays, [30_000, 60_000, 30_000]);

      failing.on = false;
      await retryTimers.fire();
      assert.equal(retryTimers.pending, 0);
      assert.equal(sentTo(KEY_A, "t1").length, 2);
    });

    test("and sends nothing for a Done that device has since seen", async () => {
      const failing = await relayFailing(TOKEN_B);
      register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
      const retryTimers = manualRetryTimers();
      const core = await connected([agent("t1")], { retryTimers });
      status(core, "t1", "working");
      finishTurn(core, "t1", 1);
      await failedOnce();
      await waitFor(() => retryTimers.pending === 1, "the next try");
      const tries = sentTo(KEY_B, "t1").length;

      failing.on = false;
      writeMark(KEY_B, [{ terminal: "t1", turn: 1, word: "done" }]);
      await retryTimers.fire();

      assert.equal(sentTo(KEY_B, "t1").length, tries);
      assert.equal(retryTimers.pending, 0);
    });

    test("leaving a change's debounce to run", async () => {
      const { failing, retryTimers, core, tries } = await blockedAndWaiting();
      failing.on = false;
      writeConfig(relay.url, 500);

      status(core, "t1", "error");
      await folded(core);
      await retryTimers.fire();

      // A status that has not held through its debounce says nothing yet.
      assert.equal(sentTo(KEY_A, "t1").length, 1);
      assert.equal(sentTo(KEY_B, "t1").length, tries);

      await waitFor(() => sentTo(KEY_A, "t1").length === 2, "the debounce's decision");
      assert.equal(open(sentTo(KEY_A, "t1").at(-1).envelope, KEY_A).status, "error");
    });

    test("and keeps its wait through a report's own try", async () => {
      const { retryTimers, core, tries } = await blockedAndWaiting();

      send(core, "foreground", "t1", CLAUDE);
      await waitFor(() => sentTo(KEY_B, "t1").length === tries * 2, "the report's try");
      await decisionsRun();

      assert.equal(retryTimers.pending, 1);
      assert.deepEqual(retryTimers.delays, [30_000]);
    });

    test("and goes with the Terminal", async () => {
      const { retryTimers, core } = await blockedAndWaiting();

      send(core, "removed", "t1", {});

      await waitFor(() => retryTimers.pending === 0, "the wait to go");
    });

    test("and goes with the connection", async () => {
      const { retryTimers, core } = await blockedAndWaiting();

      await core.stop();
      await waitFor(() => logs.some((line) => line.includes("ended")), "the connection's end");

      assert.equal(retryTimers.pending, 0);
      assert.equal(retryTimers.delays.length, 1);
    });

    test("but not after a connection that ended during the send", async () => {
      let answer;
      let isAsked = false;
      const answered = new Promise((done) => (answer = done));
      relay = await startRelay(async () => {
        isAsked = true;
        await answered;
        return { status: 500, body: {} };
      });
      writeConfig(relay.url);
      register(entry(KEY_A, TOKEN_A));
      const retryTimers = manualRetryTimers();
      const core = await connected([agent("t1")], { retryTimers });
      status(core, "t1", "working");
      status(core, "t1", "blocked");
      await waitFor(() => isAsked, "the send");

      await core.stop();
      await waitFor(() => logs.some((line) => line.includes("ended")), "the connection's end");
      answer();
      await failedOnce();
      await decisionsRun();

      assert.equal(retryTimers.pending, 0);
      assert.deepEqual(retryTimers.delays, []);
    });
  });

  test("goes when the device has left", async () => {
    const failing = await relayFailing(TOKEN_B);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await failedOnce();
    const tries = sentTo(KEY_B, "t1").length;

    failing.on = false;
    register(entry(KEY_A, TOKEN_A));
    send(core, "foreground", "t1", CLAUDE);
    await settled(core);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(sentTo(KEY_B, "t1").length, tries);
  });

  test("outlives the Helper process", async () => {
    const failing = await relayFailing(TOKEN_B);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B));
    const core = await connected([agent("t1")]);
    status(core, "t1", "working");
    status(core, "t1", "blocked");
    send(core, "turn", "t1", { turn: 1, state: "blocked" });
    await failedOnce();
    await waitFor(() => {
      const kept = join(directory, "state", "notify", `${SESSION}.json`);
      return existsSync(kept) && readFileSync(kept, "utf8").includes(TOKEN_B);
    }, "the memory of the failed send");
    const requests = relay.requests;
    failing.on = false;
    while (running.length > 0) await running.pop()();

    relay = await startRelay();
    writeConfig(relay.url);
    logs = [];
    const again = await connected([agent("t1", { turn: 1, status: { state: "blocked", app: "claude-code" } })]);
    await waitFor(() => sentTo(KEY_B, "t1").length === 1, "the retry");
    await settled(again);

    assert.ok(requests.length > 0);
    assert.equal(sentTo(KEY_A, "t1").length, 0);
    assert.equal(sentTo(KEY_B, "t1").length, 1);
  });
});

suite("a Helper killed during a send", () => {
  /** A relay that keeps its first request unanswered until `release`, and answers the rest. */
  async function relayHoldingTheFirstSend() {
    let release;
    const released = new Promise((done) => (release = done));
    let arrive;
    const arrived = new Promise((done) => (arrive = done));
    let isFirst = true;
    relay = await startRelay(async () => {
      if (isFirst) {
        isFirst = false;
        arrive();
        await released;
      }
      return { status: 200, body: {} };
    });
    writeConfig(relay.url);
    running.push(async () => release());
    return { arrived, release };
  }

  const memoryIn = (helper) => {
    const path = join(helper, "state", "notify", `${SESSION}.json`);
    return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : null;
  };

  /** A report while the send is out, saved to disk before this returns. */
  async function reportDuringTheSend(core) {
    send(core, "created", "reporter", agent("reporter"));
    status(core, "reporter", "working");
    await waitFor(() => memoryIn(directory)?.terminals.reporter !== undefined, "the report to be saved");
  }

  /**
   * Stops following and goes on from a copy of the Helper's directory as it stands:
   * what a killed process leaves. The first listener's send stays held, and it can
   * no longer change what the next one reads. Returns the directory it still writes.
   */
  async function killHelper() {
    await running.pop()();
    await running.pop()();
    const original = directory;
    directory = join(root, "left-behind");
    cpSync(original, directory, { recursive: true });
    relay = await startRelay();
    writeConfig(relay.url);
    logs = [];
    return original;
  }

  /** Answers the held send and waits for its listener to save, ahead of the directory's removal. */
  async function finishTheHeldSend(held, original, isSaved) {
    held.release();
    await waitFor(() => isSaved(memoryIn(original).terminals.t1), "the held send to be saved");
  }

  test("sends that Blocked after the restart", async () => {
    const held = await relayHoldingTheFirstSend();
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);
    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await held.arrived;
    await reportDuringTheSend(core);

    const original = await killHelper();
    const again = await connected([agent("t1", { turn: 1, status: { state: "blocked", app: "claude-code" } })]);
    await waitFor(() => sentTo(KEY_A, "t1").length === 1, "the Blocked after the restart");
    await settled(again);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(open(sentTo(KEY_A, "t1")[0].envelope, KEY_A).status, "blocked");
    await finishTheHeldSend(held, original, (terminal) => terminal.notified === "blocked");
  });

  test("sends that Done after the restart", async () => {
    const held = await relayHoldingTheFirstSend();
    register(entry(KEY_A, TOKEN_A));
    const core = await connected([agent("t1")]);
    status(core, "t1", "working");
    finishTurn(core, "t1", 1);
    await held.arrived;
    await reportDuringTheSend(core);

    const original = await killHelper();
    const again = await connected([agent("t1", { turn: 1, status: { state: "done", app: "claude-code" } })]);
    await waitFor(() => sentTo(KEY_A, "t1").length === 1, "the Done after the restart");
    await settled(again);

    assert.equal(sentTo(KEY_A, "t1").length, 1);
    assert.equal(open(sentTo(KEY_A, "t1")[0].envelope, KEY_A).status, "done");
    await finishTheHeldSend(held, original, (terminal) => terminal.notifiedTurn !== null);
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

  test("and cannot be removed leaves every other device's send as it stands", async () => {
    const failing = { on: true };
    relay = await startRelay((request) => {
      if (request.body.token === TOKEN_A) return { status: 410, body: {} };
      if (failing.on && request.body.token === TOKEN_B) return { status: 500, body: {} };
      return { status: 200, body: {} };
    });
    writeConfig(relay.url);
    register(entry(KEY_A, TOKEN_A), entry(KEY_B, TOKEN_B), entry(KEY_C, TOKEN_C));
    // The registration file's temporary name, taken: its rewrite throws.
    const inTheWay = join(directory, `notifications.json.tmp-${process.pid}`);
    mkdirSync(inTheWay);
    const core = await connected([agent("t1")]);

    status(core, "t1", "working");
    status(core, "t1", "blocked");
    await waitFor(() => logs.filter((line) => line.includes("could not")).length >= 2, "the failed send and removal", 15_000);
    assert.equal(sentTo(KEY_C, "t1").length, 1);
    const tries = sentTo(KEY_B, "t1").length;

    rmSync(inTheWay, { recursive: true });
    failing.on = false;
    send(core, "foreground", "t1", CLAUDE);
    await waitFor(() => sentTo(KEY_B, "t1").length > tries, "the retry");
    await settled(core);

    assert.equal(sentTo(KEY_B, "t1").length, tries + 1);
    assert.equal(sentTo(KEY_C, "t1").length, 1);
    const tokens = () => JSON.parse(readFileSync(join(directory, "notifications.json"), "utf8")).devices.map((device) => device.token);
    await waitFor(() => !tokens().includes(TOKEN_A), "the next 410 to remove the device");
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
    assert.equal(statSync(kept).mode & 0o777, 0o600);
    assert.equal(statSync(join(directory, "state", "notify")).mode & 0o777, 0o700);
  });
});
