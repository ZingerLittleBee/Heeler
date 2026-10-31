// Live Activity updates from the Helper (ADR 0033, docs/agents/live-activity-contract.md):
// the fake core socket on one side and the fake Push Relay on the other, with the
// Helper's real listener between.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { followCoreSession } from "../helper/core/follower.js";
import { liveActivityListener } from "../helper/notifications/activity.js";
import { seenMarkFileName } from "../helper/notifications/seen-marks.js";
import { notificationKeyId } from "../helper/shared/notification-envelope.js";
import { decryptActivityEnvelope } from "../src/activity-envelope.js";
import { FakeCore, exchange, waitFor } from "./support/fake-core.js";

const STATUS = exchange("server-status").result;
const CORE = STATUS.core.id;
const CHANNEL = exchange("events-subscribe").result.channel;
const SESSION = "work";
const DEBOUNCE_MS = 15;
const HOST = "studio";

const KEY_A = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const KEY_B = Buffer.from(Array.from({ length: 32 }, (_, i) => 255 - i));
const ALERT_A = "a".repeat(64);
const ALERT_B = "b".repeat(64);
const ACTIVITY_A = "c0".repeat(32);
const ACTIVITY_B = "d0".repeat(32);

const contentVectors = JSON.parse(readFileSync(new URL("../test-vectors/live-activity-content-v1.json", import.meta.url), "utf8"));
const markVectors = JSON.parse(readFileSync(new URL("../test-vectors/herdr-core-seen-mark-v1.json", import.meta.url), "utf8"));

const APP_OF_KIND = { claude: "claude-code", codex: "codex", pi: "pi" };
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
  writeFileSync(join(directory, "notify.json"), JSON.stringify({ relay_url: relayUrl, activity_debounce_ms: DEBOUNCE_MS, retry_delay_ms: 1 }));
}

function entry(key, alert, activity, { session = SESSION, live = {} } = {}) {
  return {
    token: alert,
    key: key.toString("base64url"),
    env: "sandbox",
    session,
    notify: { blocked: true, done: true },
    ...(activity === null ? {} : { live_activity: { token: activity, started_at: "2026-10-31T00:00:00Z", ...live } }),
  };
}

function register(...devices) {
  writeFileSync(join(directory, "notifications.json"), JSON.stringify({ v: 1, devices }));
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
    status: { state: "working", app: "claude-code" },
    reported: true,
    turn: 0,
    ...fields,
  };
}

async function startCore(terminals, { core = CORE, seq = 1 } = {}) {
  const socket = join(root, "r", "herdr-core", `${SESSION}.sock`);
  const fake = await FakeCore.start(socket, {
    status: { ...STATUS, core: { ...STATUS.core, id: core } },
    snapshot: { seq, channel: CHANNEL, terminals },
  });
  running.push(() => fake.stop().catch(() => {}));
  return fake;
}

function follow() {
  const log = (line) => logs.push(line);
  const handle = followCoreSession(SESSION, {
    env,
    runUserDirectory: join(root, "none"),
    listener: liveActivityListener({ directory, log, hostName: HOST }),
    log,
    retryDelayMs: 5,
  });
  running.push(() => handle.stop());
  return handle;
}

async function connected(terminals, options) {
  const core = await startCore(terminals, options);
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
  send(core, "status", terminal, { status: { state, app }, records: {}, reported: true });

const updatesTo = (token) => relay.requests.map((request) => request.body).filter((body) => body.token === token);
const lastTo = (token) => updatesTo(token).at(-1);
const opened = (body, key) => decryptActivityEnvelope(body.envelope, key);
const quiet = () => new Promise((done) => setTimeout(done, DEBOUNCE_MS * 4));

/** Waits for `token` to have been sent `count` pushes. */
const pushes = (token, count) => waitFor(() => updatesTo(token).length >= count, `${count} pushes to the token`);

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

suite("an update to a registered activity token", () => {
  test("is sealed with that device's key and carries the relay's shape", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A), entry(KEY_B, ALERT_B, ACTIVITY_B));
    await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);
    await pushes(ACTIVITY_B, 1);

    for (const [token, key] of [[ACTIVITY_A, KEY_A], [ACTIVITY_B, KEY_B]]) {
      const request = relay.requests.find((candidate) => candidate.body.token === token);
      assert.equal(request.path, "/push");
      const { body } = request;
      assert.equal(body.kind, "liveactivity");
      assert.equal(body.env, "sandbox");
      assert.equal(body.event, "update");
      assert.equal(body.priority, 5);
      assert.deepEqual(body.counts, { working: 1, blocked: 0, done: 0 });
      assert.equal(body.stale_date, body.timestamp + 900);
      assert.equal(JSON.parse(body.envelope).kid, notificationKeyId(key));
      assert.deepEqual(opened(body, key), {
        v: 1,
        host: HOST,
        agents: [{ kind: "claude", pane: "t1", status: "working", title: "Fix the bug", workspace: "app" }],
      });
    }
  });

  test("reproduces the shared vector's content, with Error under Blocked", async () => {
    const vector = contentVectors.valid.find((candidate) => candidate.inventory?.some((item) => item.agent_status === "error"));
    assert.ok(vector, "the shared vectors hold an Error case");
    const key = Buffer.from(vector.key, "base64url");
    register(entry(key, ALERT_A, ACTIVITY_A));
    const terminals = vector.inventory.map((item) =>
      agent(item.pane_id, {
        cwd: "",
        title: "",
        foreground: { pid: 8, name: item.agent, argv: [item.agent], cwd: "" },
        status: { state: item.agent_status, app: APP_OF_KIND[item.agent] },
        // A Done at first sight is a report at a count above zero.
        turn: item.agent_status === "done" ? 1 : 0,
      }),
    );

    await connected(terminals);
    await pushes(ACTIVITY_A, 1);

    const body = lastTo(ACTIVITY_A);
    assert.deepEqual(body.counts, vector.counts);
    assert.equal(JSON.stringify(opened(body, key)), JSON.stringify(vector.payload));
    assert.equal(body.priority, 10);
  });

  test("only Working, Blocked, Error and Done are shown, and a Terminal that is no Agent is not", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    await connected([
      agent("t1"),
      agent("t2", { status: { state: "idle", app: "claude-code" } }),
      agent("t3", { foreground: SHELL }),
      agent("t4", { foreground: null, status: null }),
      agent("t5", { state: "finished" }),
    ]);
    await pushes(ACTIVITY_A, 1);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 0, done: 0 });
    assert.deepEqual(opened(lastTo(ACTIVITY_A), KEY_A).agents.map((item) => item.pane), ["t1"]);
  });

  test("names the Agent, its title without an activity glyph and the folder it runs in", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    await connected([
      agent("t1", {
        name: "reviewer",
        title: "✳ Fix the bug",
        foreground: { ...CLAUDE, cwd: "/work/other" },
      }),
    ]);
    await pushes(ACTIVITY_A, 1);

    assert.deepEqual(opened(lastTo(ACTIVITY_A), KEY_A).agents, [
      { kind: "claude", name: "reviewer", pane: "t1", status: "working", title: "Fix the bug", workspace: "other" },
    ]);
  });

  test("follows this device's pins and layout, each device its own", async () => {
    const layout = { rows: [[{ token: "agent" }, { token: "status" }, { token: "$branch" }]] };
    register(
      entry(KEY_A, ALERT_A, ACTIVITY_A, { live: { pinned_pane_ids: ["t2"], row_layout: layout, host_name: "My Mac" } }),
      entry(KEY_B, ALERT_B, ACTIVITY_B),
    );
    await connected([
      agent("t1", { status: { state: "blocked", app: "claude-code" } }),
      agent("t2", { labels: { branch: "main" } }),
    ]);
    await pushes(ACTIVITY_A, 1);
    await pushes(ACTIVITY_B, 1);

    const pinned = opened(lastTo(ACTIVITY_A), KEY_A).agents;
    assert.deepEqual(pinned.map((item) => item.pane), ["t2", "t1"]);
    assert.deepEqual(pinned[0].rows, [[{ text: "claude" }, { text: " · " }, { text: "Working" }, { text: " · " }, { text: "main" }]]);
    const plain = opened(lastTo(ACTIVITY_B), KEY_B).agents;
    assert.deepEqual(plain.map((item) => item.pane), ["t1", "t2"]);
    assert.equal(plain[0].rows, undefined);
  });

  test("goes only to devices of this core session with an activity token", async () => {
    register(
      entry(KEY_A, ALERT_A, ACTIVITY_A),
      entry(KEY_B, ALERT_B, ACTIVITY_B, { session: "elsewhere" }),
      entry(KEY_B, ALERT_B, null),
    );
    await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);
    await quiet();

    assert.deepEqual([...new Set(relay.requests.map((request) => request.body.token))], [ACTIVITY_A]);
  });

  test("a device with no activity token hears nothing", async () => {
    register(entry(KEY_A, ALERT_A, null));
    await connected([agent("t1")]);
    await quiet();

    assert.equal(relay.requests.length, 0);
  });
});

suite("when it is sent", () => {
  test("a status that does not hold through the debounce is not sent", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    status(core, "t1", "blocked");
    status(core, "t1", "working");
    await quiet();

    assert.equal(updatesTo(ACTIVITY_A).length, 1);
  });

  test("nothing is sent while what a device sees has not changed", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    send(core, "foreground", "t1", CLAUDE);
    send(core, "turn", "t1", { turn: 1, state: "working" });
    await quiet();

    assert.equal(updatesTo(ACTIVITY_A).length, 1);
  });

  test("a move from Blocked to Error sends nothing, since both read as Blocked", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1", { status: { state: "blocked", app: "claude-code" } })]);
    await pushes(ACTIVITY_A, 1);

    status(core, "t1", "error");
    await quiet();

    assert.equal(updatesTo(ACTIVITY_A).length, 1);
  });

  test("priority is 10 only for what newly entered Blocked or Error", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1"), agent("t2")]);
    await pushes(ACTIVITY_A, 1);
    assert.equal(lastTo(ACTIVITY_A).priority, 5);

    status(core, "t1", "error");
    await pushes(ACTIVITY_A, 2);
    assert.equal(lastTo(ACTIVITY_A).priority, 10);
    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 1, done: 0 });

    status(core, "t2", "blocked");
    await pushes(ACTIVITY_A, 3);
    assert.equal(lastTo(ACTIVITY_A).priority, 10);

    status(core, "t2", "working");
    await pushes(ACTIVITY_A, 4);
    assert.equal(lastTo(ACTIVITY_A).priority, 5);
  });

  test("a changed pin goes out with the next change of any Terminal", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1"), agent("t2")]);
    await pushes(ACTIVITY_A, 1);

    register(entry(KEY_A, ALERT_A, ACTIVITY_A, { live: { pinned_pane_ids: ["t2"] } }));
    send(core, "foreground", "t1", CLAUDE);
    await pushes(ACTIVITY_A, 2);

    assert.deepEqual(opened(lastTo(ACTIVITY_A), KEY_A).agents.map((item) => item.pane), ["t2", "t1"]);
  });

  test("a new token is told what shows now, however often the old one was", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    register(entry(KEY_A, ALERT_A, ACTIVITY_B));
    send(core, "foreground", "t1", CLAUDE);
    await pushes(ACTIVITY_B, 1);

    assert.deepEqual(lastTo(ACTIVITY_B).counts, { working: 1, blocked: 0, done: 0 });
  });
});

suite("the end", () => {
  test("is sent once nothing is left to show, with zero counts and no agents", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    status(core, "t1", "idle");
    await pushes(ACTIVITY_A, 2);

    const body = lastTo(ACTIVITY_A);
    assert.equal(body.event, "end");
    assert.equal(body.priority, 5);
    assert.deepEqual(body.counts, { working: 0, blocked: 0, done: 0 });
    assert.equal(body.dismissal_date, body.timestamp);
    assert.equal(body.stale_date, undefined);
    assert.deepEqual(opened(body, KEY_A), { v: 1, host: HOST, agents: [] });
  });

  test("is not sent twice, and something new after it is an update again", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);
    status(core, "t1", "idle");
    await pushes(ACTIVITY_A, 2);

    send(core, "foreground", "t1", CLAUDE);
    await quiet();
    assert.equal(updatesTo(ACTIVITY_A).length, 2);

    // Not even when what the device chose to see changes.
    register(entry(KEY_A, ALERT_A, ACTIVITY_A, { live: { pinned_pane_ids: ["t1"] } }));
    send(core, "foreground", "t1", CLAUDE);
    await quiet();
    assert.equal(updatesTo(ACTIVITY_A).length, 2);

    status(core, "t1", "working");
    await pushes(ACTIVITY_A, 3);
    assert.equal(lastTo(ACTIVITY_A).event, "update");
  });

  test("is sent when the last Agent's Terminal goes", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    send(core, "removed", "t1", {});
    await pushes(ACTIVITY_A, 2);

    assert.equal(lastTo(ACTIVITY_A).event, "end");
  });

  test("is sent when a shell foreground ends the last Agent", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    send(core, "foreground", "t1", SHELL);
    await pushes(ACTIVITY_A, 2);

    assert.equal(lastTo(ACTIVITY_A).event, "end");
  });
});

suite("Done per device", () => {
  const vector = markVectors.files[0];
  const markedKey = Buffer.from(vector.key, "base64url");
  const finished = () => agent(vector.marks[0].terminal, {
    turn: vector.marks[0].turn,
    status: { state: "done", app: "claude-code" },
  });

  test("a device whose shared-vector mark covers the turn does not count it; another does", async () => {
    register(entry(markedKey, ALERT_A, ACTIVITY_A), entry(KEY_B, ALERT_B, ACTIVITY_B));
    writeFileSync(join(directory, vector.fileName), vector.contents);
    await connected([finished(), agent("t9")], { core: vector.core });
    await pushes(ACTIVITY_A, 1);
    await pushes(ACTIVITY_B, 1);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 0, done: 0 });
    assert.deepEqual(opened(lastTo(ACTIVITY_A), markedKey).agents.map((item) => item.pane), ["t9"]);
    assert.deepEqual(lastTo(ACTIVITY_B).counts, { working: 1, blocked: 0, done: 1 });
    assert.deepEqual(
      opened(lastTo(ACTIVITY_B), KEY_B).agents.map((item) => [item.pane, item.status]),
      [["t1", "done"], ["t9", "working"]],
    );
  });

  test("a device that has seen everything is ended while another keeps its activity", async () => {
    register(entry(markedKey, ALERT_A, ACTIVITY_A), entry(KEY_B, ALERT_B, ACTIVITY_B));
    writeFileSync(join(directory, vector.fileName), vector.contents);
    await connected([finished()], { core: vector.core });
    await pushes(ACTIVITY_A, 1);
    await pushes(ACTIVITY_B, 1);

    assert.equal(lastTo(ACTIVITY_A).event, "end");
    assert.equal(lastTo(ACTIVITY_B).event, "update");
    assert.deepEqual(lastTo(ACTIVITY_B).counts, { working: 0, blocked: 0, done: 1 });
  });

  test("a mark for another core does not apply", async () => {
    register(entry(markedKey, ALERT_A, ACTIVITY_A));
    writeFileSync(join(directory, vector.fileName), vector.contents);
    await connected([finished()], { core: "another-core" });
    await pushes(ACTIVITY_A, 1);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 0, blocked: 0, done: 1 });
  });

  test("a turn that ends live counts as Done, and working again takes it back", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    status(core, "t1", "done");
    send(core, "turn", "t1", { turn: 1, state: "done" });
    await pushes(ACTIVITY_A, 2);
    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 0, blocked: 0, done: 1 });

    status(core, "t1", "working");
    await pushes(ACTIVITY_A, 3);
    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 0, done: 0 });
  });

  test("a mark written later counts at the next change", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1"), agent("t2", { turn: 2, status: { state: "done", app: "claude-code" } })]);
    await pushes(ACTIVITY_A, 1);
    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 0, done: 1 });

    const device = notificationKeyId(KEY_A);
    writeFileSync(
      join(directory, seenMarkFileName(device)),
      JSON.stringify({ core: CORE, device, marks: [{ terminal: "t2", turn: 2, word: "done" }], v: 1 }),
    );
    send(core, "foreground", "t1", CLAUDE);
    await pushes(ACTIVITY_A, 2);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 0, done: 0 });
  });
});

suite("across connections", () => {
  test("a new Helper process does not send again what the last one sent", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const first = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);
    await quiet();
    await first.stop();
    while (running.length > 0) await running.pop()();
    relay = await startRelay();
    writeConfig(relay.url);
    logs = [];

    await connected([agent("t1")]);
    await quiet();

    assert.equal(relay.requests.length, 0);
  });

  test("what moved while no Helper ran is sent once it is back", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const first = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);
    await first.stop();

    await startCore([agent("t1", { turn: 1, status: { state: "blocked", app: "claude-code" } })]);
    await pushes(ACTIVITY_A, 2);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 0, blocked: 1, done: 0 });
    assert.equal(lastTo(ACTIVITY_A).priority, 10);
  });

  test("a missed stretch of events is read from its snapshot", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);

    nextSeq += 1;
    const terminals = [agent("t1", { turn: 1, status: { state: "blocked", app: "claude-code" } })];
    core.last.sendEvents(`${JSON.stringify({ jsonrpc: "2.0", method: "missed", params: { seq: nextSeq, terminals } })}\n`);
    await pushes(ACTIVITY_A, 2);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 0, blocked: 1, done: 0 });
  });

  test("another core id starts its turns over", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const first = await connected([agent("t1", { turn: 4, status: { state: "done", app: "claude-code" } })]);
    await pushes(ACTIVITY_A, 1);
    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 0, blocked: 0, done: 1 });
    await first.stop();

    // At the same count, a turn kept from the last core would still read as Done.
    await startCore([agent("t1", { turn: 4, status: { state: "idle", app: "claude-code" } })], { core: "another-core" });
    await pushes(ACTIVITY_A, 2);

    assert.equal(lastTo(ACTIVITY_A).event, "end");
  });

  test("a relay that cannot be reached leaves the update to try again", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    writeConfig("http://127.0.0.1:9");
    const core = await connected([agent("t1")]);
    await waitFor(() => logs.some((line) => line.includes("could not update")), "the failure", 15_000);

    writeConfig(relay.url);
    send(core, "foreground", "t1", CLAUDE);
    await pushes(ACTIVITY_A, 1);
  });

  test("a failed update leaves what the token last heard, so a Blocked it knows is not new", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1", { status: { state: "blocked", app: "claude-code" } })]);
    await pushes(ACTIVITY_A, 1);
    assert.equal(lastTo(ACTIVITY_A).priority, 10);

    writeConfig("http://127.0.0.1:9");
    send(core, "created", "t2", agent("t2"));
    await waitFor(() => logs.some((line) => line.includes("could not update")), "the failure", 15_000);
    writeConfig(relay.url);
    send(core, "foreground", "t1", CLAUDE);
    await pushes(ACTIVITY_A, 2);

    assert.deepEqual(lastTo(ACTIVITY_A).counts, { working: 1, blocked: 1, done: 0 });
    assert.equal(lastTo(ACTIVITY_A).priority, 5);
  });
});

suite("a token the relay says is gone", () => {
  test("leaves only its Live Activity field, and the alert token stays", async () => {
    relay = await startRelay((request) => (request.body.token === ACTIVITY_A ? { status: 410, body: {} } : { status: 200, body: {} }));
    writeConfig(relay.url);
    register(entry(KEY_A, ALERT_A, ACTIVITY_A), entry(KEY_B, ALERT_B, ACTIVITY_B));
    const device = notificationKeyId(KEY_A);
    writeFileSync(join(directory, seenMarkFileName(device)), JSON.stringify({ core: CORE, device, marks: [], v: 1 }));
    await connected([agent("t1")]);

    await waitFor(() => {
      const file = JSON.parse(readFileSync(join(directory, "notifications.json"), "utf8"));
      return file.devices[0].live_activity === undefined;
    }, "the token to leave");

    const file = JSON.parse(readFileSync(join(directory, "notifications.json"), "utf8"));
    assert.deepEqual(file.devices.map((item) => item.token), [ALERT_A, ALERT_B]);
    assert.equal(file.devices[0].notify.blocked, true);
    assert.equal(file.devices[1].live_activity.token, ACTIVITY_B);
    assert.equal(existsSync(join(directory, seenMarkFileName(device))), true);
  });
});

suite("what the Helper keeps", () => {
  test("is private to the user, and goes when no registration names the session", async () => {
    register(entry(KEY_A, ALERT_A, ACTIVITY_A));
    const core = await connected([agent("t1")]);
    await pushes(ACTIVITY_A, 1);
    const kept = join(directory, "state", "activity", `${SESSION}.json`);
    await waitFor(() => existsSync(kept), "the memory file");
    assert.equal(statSync(kept).mode & 0o777, 0o600);

    register();
    await core.stop();
    await waitFor(() => !existsSync(kept), "the memory file to go");
  });
});
