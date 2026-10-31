// One connection to the core, against a fake socket fed by the shared vectors:
// hello, server.status, events.subscribe, then the events stream.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";

import { connectCore } from "../helper/core/client.js";
import { FakeCore, eventLine, exchange, frame, vectors, waitFor } from "./support/fake-core.js";

const STATUS = exchange("server-status");
const SUBSCRIBE = exchange("events-subscribe");
const FIRST_ADDRESSES = SUBSCRIBE.result.terminals.map((terminal) => terminal.address);

let root;
let socketPath;
const open = [];

beforeEach(() => {
  // Short: a Unix socket path has a low limit, and tmpdir() can be long.
  root = mkdtempSync("/tmp/hh-");
  socketPath = join(root, "core.sock");
});

afterEach(async () => {
  while (open.length > 0) await open.pop().close?.();
  rmSync(root, { recursive: true, force: true });
});

function recorder() {
  const seen = { connected: [], replaced: [], events: [] };
  return {
    seen,
    connected: (report) => seen.connected.push(report),
    inventoryReplaced: (report) => seen.replaced.push(report),
    event: (report) => seen.events.push(report),
  };
}

async function fakeCore(options) {
  const core = await FakeCore.start(socketPath, options);
  open.push({ close: () => core.stop() });
  return core;
}

async function connect(listener = recorder(), options = {}) {
  const connection = await connectCore(socketPath, { listener, ...options });
  open.push(connection);
  return { connection, listener };
}

suite("the handshake", () => {
  test("is hello, server.status and events.subscribe, in that order, in the vectors' exact bytes", async () => {
    const core = await fakeCore();
    await connect();
    assert.deepEqual(core.last.methods, ["hello", "server.status", "events.subscribe"]);
    assert.equal(core.last.requests[0].hex, STATUS.requestFrame);
    assert.equal(core.last.requests[1].hex, SUBSCRIBE.requestFrame);
  });

  test("hello is generation 1, framed, and has no core key", async () => {
    const core = await fakeCore();
    await connect();
    const { params } = JSON.parse(core.last.helloLine);
    assert.deepEqual(params, { generation: 1, framed: true });
    assert.equal("core" in params, false);
  });

  test("reports the core's pid and id, and the inventory the snapshot holds", async () => {
    await fakeCore();
    const { connection, listener } = await connect();
    assert.equal(connection.pid, STATUS.result.pid);
    assert.equal(connection.coreId, STATUS.result.core.id);
    assert.deepEqual([...connection.inventory.keys()], FIRST_ADDRESSES);
    assert.deepEqual(connection.inventory.get(FIRST_ADDRESSES[0]), SUBSCRIBE.result.terminals[0]);
    assert.equal(listener.seen.connected.length, 1);
    assert.equal(listener.seen.connected[0].pid, STATUS.result.pid);
    assert.deepEqual([...listener.seen.connected[0].inventory.keys()], FIRST_ADDRESSES);
  });

  test("leaves a federated Terminal out of the inventory", async () => {
    await fakeCore({
      snapshot: { channel: 1, seq: 1, terminals: [{ address: "t1" }, { address: "lab/t1" }] },
    });
    const { connection } = await connect();
    assert.deepEqual([...connection.inventory.keys()], ["t1"]);
  });

  const refusals = {
    "a core of another generation": { helloReply: '{"id":"hello","jsonrpc":"2.0","result":{"generation":2}}' },
    "a core refusing the generation": {
      helloReply: vectors.errors.find((vector) => vector.name === "unsupported-generation").line.replace('"id":"1"', '"id":"hello"'),
    },
    "a reply that is not JSON": { helloReply: "not json" },
    "a status with no pid": { status: { core: { id: "c" } } },
    "a snapshot with no channel": { snapshot: { seq: 1, terminals: [] } },
    "a snapshot with no terminals": { snapshot: { channel: 1, seq: 1 } },
  };
  for (const [name, options] of Object.entries(refusals)) {
    test(`refuses ${name}`, async () => {
      await fakeCore(options);
      await assert.rejects(connectCore(socketPath, { listener: recorder() }));
    });
  }

  test("refuses a hello line with no end before it holds too much", async () => {
    const core = await fakeCore({ answersHello: false });
    const attempt = connectCore(socketPath, { listener: recorder() });
    await waitFor(() => core.last?.helloLine != null, "hello");
    core.last.write(Buffer.alloc(1024 * 1024 + 1, 0x41));
    await assert.rejects(attempt, /hello/i);
  });

  test("gives up on a core that never answers", async () => {
    await fakeCore({ answersHello: false });
    await assert.rejects(
      connectCore(socketPath, { listener: recorder(), handshakeTimeoutMs: 30 }),
      /did not answer/,
    );
  });

  test("rejects when nothing listens", async () => {
    await assert.rejects(connectCore(socketPath, { listener: recorder() }), { code: "ENOENT" });
  });
});

suite("the events stream", () => {
  test("applies events to the inventory and returns credit for what it consumed", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 5, terminals: [{ address: "t3", title: "old" }] } });
    const { connection, listener } = await connect();
    const line = eventLine("title");
    core.last.sendEvents(line);
    await waitFor(() => core.last.creditFor(1) > 0, "credit");
    assert.equal(core.last.creditFor(1), Buffer.byteLength(line));
    assert.equal(connection.inventory.get("t3").title, "Working");
    assert.equal(listener.seen.events.length, 1);
    assert.equal(listener.seen.events[0].event.type, "title");
    assert.equal(listener.seen.events[0].event.terminal, "t3");
  });

  test("credit also covers a partial line, so a long line cannot stall the window", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 5, terminals: [{ address: "t3" }] } });
    const { connection } = await connect();
    const line = eventLine("title");
    const cut = 20;
    core.last.sendEvents(line.slice(0, cut));
    await waitFor(() => core.last.creditFor(1) === cut, "credit for the partial line");
    assert.equal(connection.inventory.get("t3").title, undefined);
    core.last.sendEvents(line.slice(cut));
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(line), "credit for the rest");
    assert.equal(connection.inventory.get("t3").title, "Working");
  });

  test("handles the captured frame holding two lines and the captured line across two frames", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 1, terminals: [{ address: "t1" }] } });
    const { listener } = await connect();
    const [twoLines, acrossFrames] = vectors.eventFrames;
    // Captured in this order: the line across frames carries the lower sequence.
    core.last.write(Buffer.from(acrossFrames.bytes, "hex"));
    core.last.write(Buffer.from(twoLines.bytes, "hex"));
    await waitFor(() => listener.seen.events.length === 3, "three events");
    assert.deepEqual(listener.seen.events.map((report) => report.event.type), ["labels", "labels", "labels"]);
  });

  test("`missed` replaces the inventory from its snapshot, and older events stay dropped after it", async () => {
    const core = await fakeCore({
      snapshot: { channel: 1, seq: 1, terminals: [{ address: "gone" }, { address: "t3", title: "old" }] },
    });
    const { connection, listener } = await connect();
    const missed = JSON.parse(eventLine("missed"));
    const addresses = missed.params.terminals.map((terminal) => terminal.address);
    core.last.sendEvents(eventLine("missed"));
    await waitFor(() => listener.seen.replaced.length === 1, "the replacement");
    assert.deepEqual([...connection.inventory.keys()], addresses);
    assert.deepEqual([...listener.seen.replaced[0].inventory.keys()], addresses);
    assert.equal(connection.inventory.has("gone"), false);

    const stale = `${JSON.stringify({ jsonrpc: "2.0", method: "event", params: { type: "removed", terminal: addresses[0], data: {}, seq: 1 } })}\n`;
    core.last.sendEvents(stale);
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(eventLine("missed")) + Buffer.byteLength(stale), "credit");
    assert.equal(connection.inventory.has(addresses[0]), true);
  });

  test("an event at or below the snapshot's sequence is dropped", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 8, terminals: [{ address: "t3", title: "old" }] } });
    const { connection, listener } = await connect();
    core.last.sendEvents(eventLine("title"));
    await waitFor(() => core.last.creditFor(1) > 0, "credit");
    assert.equal(connection.inventory.get("t3").title, "old");
    assert.equal(listener.seen.events.length, 0);
  });

  test("a stream's first data before the reply naming its channel is kept and applied after the snapshot", async () => {
    const line = eventLine("title");
    const core = await fakeCore({
      snapshot: { channel: 1, seq: 1, terminals: [{ address: "t3", title: "old" }] },
      earlyEvents: [line],
    });
    const { connection } = await connect();
    assert.equal(connection.inventory.get("t3").title, "Working");
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(line), "credit");
  });

  test("a heartbeat changes nothing and is credited", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 30, terminals: [{ address: "t3" }] } });
    const { connection, listener } = await connect();
    core.last.sendEvents(eventLine("heartbeat"));
    await waitFor(() => core.last.creditFor(1) > 0, "credit");
    assert.deepEqual([...connection.inventory.keys()], ["t3"]);
    assert.equal(listener.seen.events.length, 0);
  });

  test("a notification of a newer core is ignored and credited", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 1, terminals: [{ address: "t3" }] } });
    const { connection } = await connect();
    const line = `${JSON.stringify({ jsonrpc: "2.0", method: "newer", params: {} })}\n`;
    core.last.sendEvents(line);
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(line), "credit");
    assert.deepEqual([...connection.inventory.keys()], ["t3"]);
  });

  for (const [name, bad] of [
    ["a line that is not JSON", "not json\n"],
    ["an event with no sequence", `${JSON.stringify({ method: "event", params: { type: "title", terminal: "t3", data: {} } })}\n`],
    ["an event with no type", `${JSON.stringify({ method: "event", params: { seq: 99, terminal: "t3", data: {} } })}\n`],
    ["a Terminal's event with no address", `${JSON.stringify({ method: "event", params: { seq: 99, type: "title", data: {} } })}\n`],
    ["a `missed` with no terminals", `${JSON.stringify({ method: "missed", params: { seq: 99 } })}\n`],
  ]) {
    test(`${name} ends the connection, for a fresh snapshot on the next`, async () => {
      const core = await fakeCore({ snapshot: { channel: 1, seq: 1, terminals: [{ address: "t3" }] } });
      const { connection } = await connect();
      core.last.sendEvents(bad);
      assert.match((await connection.closed).message, /./);
      await waitFor(() => core.last.closed, "the socket to close");
    });
  }

  test("the core closing the events channel ends the connection", async () => {
    const core = await fakeCore();
    const { connection } = await connect();
    core.last.closeEvents();
    assert.match((await connection.closed).message, /closed the events channel/);
  });

  test("a CLOSE on another channel, and DATA on one, change nothing", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 1, terminals: [{ address: "t3" }] } });
    const { connection, listener } = await connect();
    core.last.closeEvents(9);
    core.last.sendEvents(eventLine("title"), 9);
    const line = `${JSON.stringify({ method: "heartbeat", params: { seq: 2 } })}\n`;
    core.last.sendEvents(line);
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(line), "credit");
    assert.equal(core.last.creditFor(9), 0);
    assert.equal(listener.seen.events.length, 0);
    assert.equal(core.last.closed, false);
    assert.equal(connection.inventory.size, 1);
  });

  test("a stream sending past what it was given before its reply ends the connection", async () => {
    const big = Buffer.alloc(256 * 1024 + 1, 0x20);
    const core = await fakeCore({
      answers: {
        "events.subscribe": () => frame(1, 0, big),
      },
    });
    await assert.rejects(connectCore(socketPath, { listener: recorder() }), /credit/);
    assert.equal(core.last.methods.at(-1), "events.subscribe");
  });

  test("a frame over the limit ends the connection", async () => {
    const core = await fakeCore();
    const { connection } = await connect();
    const header = Buffer.alloc(9);
    header.writeUInt32LE(1, 0);
    header.writeUInt32LE(16 * 1024 * 1024 + 1, 5);
    core.last.write(header);
    assert.match((await connection.closed).message, /16 MiB/);
  });

  test("the core going away ends the connection", async () => {
    const core = await fakeCore();
    const { connection } = await connect();
    core.last.destroy();
    assert.match((await connection.closed).message, /connection closed/i);
  });

  test("a core gone silent past the idle limit ends the connection", async () => {
    const core = await fakeCore();
    const { connection } = await connect(recorder(), { idleTimeoutMs: 30 });
    assert.match((await connection.closed).message, /silent/);
    await waitFor(() => core.last.closed, "the socket to close");
  });

  test("a heartbeat holds the idle limit off", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 1, terminals: [] } });
    const { connection } = await connect(recorder(), { idleTimeoutMs: 150 });
    const started = Date.now();
    while (Date.now() - started < 300) {
      core.last.sendEvents(`${JSON.stringify({ method: "heartbeat", params: { seq: 2 } })}\n`);
      await new Promise((done) => setTimeout(done, 20));
    }
    assert.equal(core.last.closed, false);
    await connection.close();
  });

  test("close is final and idempotent", async () => {
    const core = await fakeCore();
    const { connection } = await connect();
    await connection.close();
    await connection.close();
    assert.equal((await connection.closed).message, "closed");
    await waitFor(() => core.last.closed || core.connections.length === 1, "the close");
  });
});

suite("the inventory follows events", () => {
  const applied = async (start, name) => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 0, terminals: [start] } });
    const { connection } = await connect();
    const line = eventLine(name);
    core.last.sendEvents(line);
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(line), "credit");
    return connection.inventory;
  };

  const cases = [
    ["size", { address: "t3" }, { cols: 100, rows: 30 }],
    ["title", { address: "t3" }, { title: "Working" }],
    [
      "foreground",
      { address: "t3" },
      { foreground: { argv: ["/bin/zsh"], cwd: "/home/user", name: "zsh", pid: 8805 } },
    ],
    ["foreground-cleared", { address: "t6", foreground: { pid: 1 } }, { foreground: null }],
    [
      "status",
      { address: "t3" },
      { records: {}, reported: true, status: { app: "claude-code", progress: 10, state: "working" } },
    ],
    ["status-cleared", { address: "t3", status: { state: "working" } }, { records: {}, reported: true, status: null }],
    ["turn", { address: "t3", turn: 0 }, { turn: 1 }],
    ["labels", { address: "t3", labels: {} }, { labels: { "heeler.workspace": "w2" } }],
    ["keep", { address: "t3", keep: true }, { keep: false }],
    ["lost", { address: "t3", pid: 9, foreground: { pid: 9 } }, { pid: null, foreground: null, reason: "signaled" }],
    [
      "finished",
      { address: "t4", state: "live", pid: 9, foreground: { pid: 9 } },
      { state: "finished", pid: null, foreground: null, reason: "exited", exit_code: 0, signal: null, finished_ms: 1793393947567 },
    ],
  ];
  for (const [name, start, expected] of cases) {
    test(`${name} is applied`, async () => {
      const inventory = await applied(start, name);
      assert.deepEqual(inventory.get(start.address), { ...start, ...expected });
    });
  }

  test("created adds the record, keyed by its address", async () => {
    const inventory = await applied({ address: "t1" }, "created");
    assert.deepEqual(inventory.get("t3"), JSON.parse(eventLine("created")).params.data);
    assert.equal(inventory.has("t1"), true);
  });

  test("restarted replaces the record", async () => {
    const inventory = await applied({ address: "t3", argv: ["old"] }, "restarted");
    assert.deepEqual(inventory.get("t3"), JSON.parse(eventLine("restarted")).params.data);
  });

  test("removed takes the Terminal out", async () => {
    const inventory = await applied({ address: "t4" }, "removed");
    assert.equal(inventory.has("t4"), false);
  });

  test("an event for a Terminal the inventory lacks adds nothing", async () => {
    const inventory = await applied({ address: "t1" }, "title");
    assert.deepEqual([...inventory.keys()], ["t1"]);
  });

  test("an event for a federated Terminal, and a document's, leave it alone", async () => {
    const core = await fakeCore({ snapshot: { channel: 1, seq: 0, terminals: [{ address: "t1" }] } });
    const { connection, listener } = await connect();
    const federated = `${JSON.stringify({ method: "event", params: { seq: 1, type: "title", terminal: "lab/t1", data: { title: "x" } } })}\n`;
    const lines = federated + eventLine("doc");
    core.last.sendEvents(lines);
    await waitFor(() => core.last.creditFor(1) === Buffer.byteLength(lines), "credit");
    assert.deepEqual(connection.inventory.get("t1"), { address: "t1" });
    assert.equal(listener.seen.events.length, 0);
  });
});
