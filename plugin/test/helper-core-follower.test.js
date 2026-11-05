// The Helper follows the core the way the app does, and never starts one: it
// waits while no socket answers, and a restart gets a fresh handshake (ADR 0033).

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { followCoreSession, followRegisteredSessions } from "../helper/core/follower.js";
import { FakeCore, exchange, waitFor } from "./support/fake-core.js";

const STATUS = exchange("server-status").result;
const FAST = { retryDelayMs: 10, pollMs: 10 };

let root;
let env;
const running = [];

beforeEach(() => {
  root = mkdtempSync("/tmp/hh-");
  env = { HOME: root, XDG_RUNTIME_DIR: join(root, "r") };
});

afterEach(async () => {
  while (running.length > 0) await running.pop()();
  rmSync(root, { recursive: true, force: true });
});

const socketFor = (session) => join(root, "r", "herdr-core", `${session}.sock`);

async function core(session, options) {
  const fake = await FakeCore.start(socketFor(session), options);
  running.push(() => fake.stop().catch(() => {}));
  return fake;
}

function recorder() {
  const seen = { connected: [], ended: [], replaced: [], events: [], logs: [] };
  return {
    seen,
    log: (line) => seen.logs.push(line),
    listener: {
      connected: (report) => seen.connected.push(report),
      ended: (report) => seen.ended.push(report),
      inventoryReplaced: (report) => seen.replaced.push(report),
      event: (report) => seen.events.push(report),
    },
  };
}

function follow(session, options = {}) {
  const { listener, log, seen } = recorder();
  const handle = followCoreSession(session, { env, runUserDirectory: join(root, "none"), listener, log, ...FAST, ...options });
  running.push(() => handle.stop());
  return { handle, seen };
}

const restartedStatus = (pid) => ({ ...STATUS, pid });
const snapshot = (...addresses) => ({ channel: 1, seq: 1, terminals: addresses.map((address) => ({ address })) });

suite("a handshake that fails after `connected`", () => {
  test("a bad early line still tells the listener the connection ended", async () => {
    await core("work", { snapshot: snapshot("t1"), earlyEvents: ["not json\n"] });
    const { seen } = follow("work");
    await waitFor(() => seen.connected.length >= 1 && seen.ended.length >= 1, "connected and ended");
    assert.equal(seen.ended[0].session, "work");
    assert.equal(seen.ended[0].pid, STATUS.pid);
    assert.match(seen.ended[0].reason.message, /./);
  });
});

suite("waiting for a core", () => {
  test("waits while no socket answers and connects once one does", async () => {
    const { seen } = follow("work");
    await waitFor(() => seen.logs.length > 0, "the waiting line");
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(seen.connected.length, 0);
    const fake = await core("work");
    await waitFor(() => seen.connected.length === 1, "the connection");
    assert.equal(seen.connected[0].session, "work");
    assert.equal(seen.connected[0].pid, STATUS.pid);
    assert.deepEqual(fake.last.methods, ["hello", "server.status", "events.subscribe"]);
  });

  test("says it is waiting once, not on every try", async () => {
    const { seen } = follow("work");
    await new Promise((done) => setTimeout(done, 100));
    assert.equal(seen.logs.filter((line) => line.includes("waiting")).length, 1);
  });

  test("a stale socket file with nothing behind it reads as no core", async () => {
    const socket = socketFor("work");
    const fake = await core("work");
    // Closing a server unlinks its socket's path, so the socket hides under
    // another name meanwhile. It comes back with nothing behind it, as a killed
    // core leaves it.
    renameSync(socket, `${socket}.moved`);
    await fake.stop();
    renameSync(`${socket}.moved`, socket);
    const { seen } = follow("work");
    await waitFor(() => seen.logs.length > 0, "the waiting line");
    assert.match(seen.logs[0], /waiting/);
    assert.equal(seen.connected.length, 0);
  });

  test("a core.lock written while waiting is followed to its socket", async () => {
    const { seen } = follow("work");
    await waitFor(() => seen.logs.length > 0, "the waiting line");
    const elsewhere = join(root, "e", "work.sock");
    const fake = await FakeCore.start(elsewhere);
    running.push(() => fake.stop().catch(() => {}));
    const state = join(root, ".local/state/herdr-core/work");
    mkdirSync(state, { recursive: true });
    writeFileSync(join(state, "core.lock"), elsewhere);
    await waitFor(() => seen.connected.length === 1, "the connection");
    assert.equal(seen.connected[0].socketPath, elsewhere);
  });

  test("a core it cannot use is retried, and said once", async () => {
    const fake = await core("work", { helloReply: '{"id":"hello","jsonrpc":"2.0","result":{"generation":2}}' });
    const { seen } = follow("work");
    await waitFor(() => fake.connections.length >= 3, "more tries");
    assert.equal(seen.connected.length, 0);
    assert.equal(seen.logs.filter((line) => line.includes("generation")).length, 1);
  });

  test("stopping while waiting ends the follow at once", async () => {
    const { handle } = follow("work", { retryDelayMs: 60_000 });
    await new Promise((done) => setTimeout(done, 20));
    await handle.stop();
  });

  test("stopping during a handshake closes it", async () => {
    const fake = await core("work", { answersHello: false });
    const { handle } = follow("work");
    await waitFor(() => fake.last?.helloLine != null, "hello");
    await handle.stop();
    await waitFor(() => fake.last.closed, "the close");
  });
});

suite("a core restart", () => {
  test("a new core gets a fresh hello, status and snapshot, and its pid is reported", async () => {
    const first = await core("work", { status: restartedStatus(100), snapshot: snapshot("t1", "t2") });
    const { seen } = follow("work");
    await waitFor(() => seen.connected.length === 1, "the first connection");
    assert.equal(seen.connected[0].pid, 100);
    assert.deepEqual([...seen.connected[0].inventory.keys()], ["t1", "t2"]);

    await first.stop();
    await waitFor(() => seen.ended.length === 1, "the end");
    assert.equal(seen.ended[0].pid, 100);

    const second = await core("work", { status: restartedStatus(200), snapshot: snapshot("t9") });
    await waitFor(() => seen.connected.length === 2, "the second connection");
    assert.equal(seen.connected[1].pid, 200);
    assert.deepEqual([...seen.connected[1].inventory.keys()], ["t9"]);
    assert.deepEqual(second.last.methods, ["hello", "server.status", "events.subscribe"]);
  });

  test("event numbers do not carry across connections", async () => {
    const first = await core("work", { snapshot: { channel: 1, seq: 500, terminals: [{ address: "t1" }] } });
    const { seen } = follow("work");
    await waitFor(() => seen.connected.length === 1, "the first connection");
    await first.stop();

    // A new core process counts from zero again.
    const second = await core("work", { snapshot: { channel: 1, seq: 0, terminals: [{ address: "t1" }] } });
    await waitFor(() => seen.connected.length === 2, "the second connection");
    second.last.sendEvents(`${JSON.stringify({ method: "event", params: { seq: 1, type: "title", terminal: "t1", data: { title: "new" } } })}\n`);
    await waitFor(() => seen.events.length === 1, "the event");
    assert.equal(seen.events[0].inventory.get("t1").title, "new");
  });

  test("a connection that dropped while the core stays up reconnects and rebuilds", async () => {
    const fake = await core("work", { snapshot: snapshot("t1") });
    const { seen } = follow("work");
    await waitFor(() => seen.connected.length === 1, "the first connection");
    fake.snapshot = snapshot("t2");
    fake.last.destroy();
    await waitFor(() => seen.connected.length === 2, "the second connection");
    assert.deepEqual([...seen.connected[1].inventory.keys()], ["t2"]);
    assert.equal(fake.connections.length, 2);
  });

  test("`missed` reaches the listener with its session and the new inventory", async () => {
    const fake = await core("work", { snapshot: snapshot("t1") });
    const { seen } = follow("work");
    await waitFor(() => seen.connected.length === 1, "the connection");
    fake.last.sendEvents(`${JSON.stringify({ method: "missed", params: { seq: 9, terminals: [{ address: "t7" }] } })}\n`);
    await waitFor(() => seen.replaced.length === 1, "the replacement");
    assert.equal(seen.replaced[0].session, "work");
    assert.deepEqual([...seen.replaced[0].inventory.keys()], ["t7"]);
  });
});

suite("sessions from the registrations", () => {
  let helperDirectory;

  beforeEach(() => {
    helperDirectory = join(root, "helper");
    mkdirSync(helperDirectory);
  });

  function register(...sessions) {
    const devices = sessions.map((session) => (session === undefined ? {} : { session }));
    const path = join(helperDirectory, "notifications.json");
    writeFileSync(`${path}.tmp`, JSON.stringify({ v: 1, devices }));
    renameSync(`${path}.tmp`, path);
  }

  function followAll(options = {}) {
    const { listener, log, seen } = recorder();
    const handle = followRegisteredSessions({
      directory: helperDirectory,
      env,
      runUserDirectory: join(root, "none"),
      listener,
      log,
      ...FAST,
      ...options,
    });
    running.push(() => handle.stop());
    return { handle, seen };
  }

  const connectedSessions = (seen) => seen.connected.map((report) => report.session).sort();

  test("one connection per session named, and none for a session nobody names", async () => {
    const work = await core("work");
    const fallback = await core("default");
    const other = await core("other");
    register("work", "default");
    const { seen } = followAll();
    await waitFor(() => seen.connected.length === 2, "two connections");
    await new Promise((done) => setTimeout(done, 50));
    assert.deepEqual(connectedSessions(seen), ["default", "work"]);
    assert.equal(work.connections.length, 1);
    assert.equal(fallback.connections.length, 1);
    assert.equal(other.connections.length, 0);
  });

  test("two devices on one session share one connection", async () => {
    const work = await core("work");
    register("work", "work");
    const { seen } = followAll();
    await waitFor(() => seen.connected.length === 1, "the connection");
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(work.connections.length, 1);
  });

  test("names are normalized, so spellings of one session share a connection", async () => {
    const work = await core("work");
    const fallback = await core("default");
    register(" work ", "work\n", "", "   ");
    const { seen } = followAll();
    await waitFor(() => seen.connected.length === 2, "two connections");
    await new Promise((done) => setTimeout(done, 50));
    assert.deepEqual(connectedSessions(seen), ["default", "work"]);
    assert.equal(work.connections.length, 1);
    assert.equal(fallback.connections.length, 1);
  });

  test("a name the core refuses gets no connection and is said once", async () => {
    register("a/b");
    const { seen } = followAll();
    await waitFor(() => seen.logs.some((line) => line.includes("a/b")), "the log line");
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(seen.logs.filter((line) => line.includes("a/b")).length, 1);
    assert.equal(seen.connected.length, 0);
  });

  test("an entry naming no session opens nothing", async () => {
    const fallback = await core("default");
    register(undefined);
    followAll();
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(fallback.connections.length, 0);
  });

  test("no registration file opens nothing, and one arriving later is followed", async () => {
    const work = await core("work");
    const { seen } = followAll();
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(work.connections.length, 0);
    register("work");
    await waitFor(() => seen.connected.length === 1, "the connection");
  });

  test("a session no longer named has its connection closed", async () => {
    const work = await core("work");
    const fallback = await core("default");
    register("work", "default");
    const { seen } = followAll();
    await waitFor(() => seen.connected.length === 2, "two connections");
    const workConnection = work.last;
    register("default");
    await waitFor(() => workConnection.closed, "the closed connection");
    assert.equal(fallback.last.closed, false);
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(work.connections.length, 1);
  });

  test("a session waited for stays followed through a rewrite of the file", async () => {
    register("work");
    const { seen } = followAll();
    await waitFor(() => seen.logs.some((line) => line.includes("waiting")), "the waiting line");
    register("work", "work");
    await new Promise((done) => setTimeout(done, 30));
    assert.equal(seen.logs.filter((line) => line.includes("waiting")).length, 1);
    await core("work");
    await waitFor(() => seen.connected.length === 1, "the connection");
  });

  test("stopping closes every connection", async () => {
    const work = await core("work");
    register("work");
    const { handle, seen } = followAll();
    await waitFor(() => seen.connected.length === 1, "the connection");
    await handle.stop();
    await waitFor(() => work.last.closed, "the close");
    assert.equal(seen.ended.length, 1);
  });
});
