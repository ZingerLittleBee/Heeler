import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createDecipheriv, createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { rexLiveActivityListener } from "../helper/notifications/activity.js";
import { rexNotificationListener } from "../helper/notifications/notifier.js";
import { seenMarkFileName } from "../helper/notifications/seen-marks.js";
import { connectRex } from "../helper/rex/client.js";
import { combineRexListeners, followRexServer, followRexSocket } from "../helper/rex/follower.js";
import { REX_SESSION, discoverRexSocket, readStoredRexSocket, resolveRexSocket, wantsRexFollower } from "../helper/rex/socket.js";
import {
  RexTurnState,
  foldRexPane,
  normalizeRexStatus,
  rexAgentKind,
  rexAgentReport,
  rexDecisionSignature,
  rexKindLabel,
  rexPaneID,
} from "../helper/rex/turn-state.js";
import { connectUnixWebSocket } from "../helper/rex/websocket.js";
import { notificationKeyId } from "../helper/shared/notification-envelope.js";
import { rexUsageListener } from "../helper/usage/recorder.js";
import { decryptActivityEnvelope } from "../src/activity-envelope.js";
import { waitFor } from "./support/fake-core.js";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const TERMINAL_CREATOR = "com.superlogical.terminal";
const HELPER = fileURLToPath(new URL("../helper", import.meta.url));
const PATIENCE_MS = 5000;

const KEY_A = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 11));
const ALERT_A = "a".repeat(64);
const ACTIVITY_A = "b1".repeat(32);

let root;
let directory;
const cleanups = [];

beforeEach(() => {
  root = mkdtempSync("/tmp/hh-rex-");
  directory = join(root, "helper");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
});

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()();
  rmSync(root, { recursive: true, force: true });
});

function acceptKey(key) {
  return createHash("sha1").update(key + WS_GUID).digest("base64");
}

function encodeServerFrame(opcode, payload, { fin = true } = {}) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8");
  const length = data.length;
  let headerLength = 2;
  if (length >= 126 && length < 65536) headerLength += 2;
  else if (length >= 65536) headerLength += 8;
  const frame = Buffer.allocUnsafe(headerLength + length);
  frame[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);
  let offset = 2;
  if (length < 126) {
    frame[1] = length;
  } else if (length < 65536) {
    frame[1] = 126;
    frame.writeUInt16BE(length, 2);
    offset = 4;
  } else {
    frame[1] = 127;
    frame.writeBigUInt64BE(BigInt(length), 2);
    offset = 10;
  }
  data.copy(frame, offset);
  return frame;
}

function parseClientFrames(state, onFrame) {
  while (state.buffer.length >= 2) {
    const first = state.buffer[0];
    const second = state.buffer[1];
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let payloadLength = second & 0x7f;
    let offset = 2;
    if (payloadLength === 126) {
      if (state.buffer.length < offset + 2) return;
      payloadLength = state.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (payloadLength === 127) {
      if (state.buffer.length < offset + 8) return;
      payloadLength = Number(state.buffer.readBigUInt64BE(offset));
      offset += 8;
    }
    const maskLength = masked ? 4 : 0;
    if (state.buffer.length < offset + maskLength + payloadLength) return;
    let payload = state.buffer.subarray(offset + maskLength, offset + maskLength + payloadLength);
    if (masked) {
      const mask = state.buffer.subarray(offset, offset + 4);
      const out = Buffer.allocUnsafe(payloadLength);
      for (let i = 0; i < payloadLength; i += 1) out[i] = payload[i] ^ mask[i & 3];
      payload = out;
    } else {
      payload = Buffer.from(payload);
    }
    state.buffer = state.buffer.subarray(offset + maskLength + payloadLength);
    onFrame({ fin, opcode, masked, payload });
  }
}

async function startRawWsServer(socketPath, onConnection) {
  const sockets = new Set();
  const server = createNetServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    const state = { upgraded: false, buffer: Buffer.alloc(0) };
    const ctx = {
      socket,
      headers: null,
      frames: [],
      sendFrame(opcode, payload, opts) {
        socket.write(encodeServerFrame(opcode, payload, opts));
      },
      sendText(text) {
        socket.write(encodeServerFrame(0x1, Buffer.from(text, "utf8")));
      },
      sendJson(obj) {
        this.sendText(JSON.stringify(obj));
      },
      onFrame: null,
      onUpgrade: null,
    };
    onConnection(ctx);
    socket.on("data", (chunk) => {
      state.buffer = state.buffer.length === 0 ? chunk : Buffer.concat([state.buffer, chunk]);
      if (!state.upgraded) {
        const boundary = state.buffer.indexOf("\r\n\r\n");
        if (boundary === -1) return;
        const head = state.buffer.subarray(0, boundary).toString("latin1");
        state.buffer = state.buffer.subarray(boundary + 4);
        const lines = head.split("\r\n");
        const headers = new Map();
        for (let i = 1; i < lines.length; i += 1) {
          const colon = lines[i].indexOf(":");
          if (colon > 0) headers.set(lines[i].slice(0, colon).trim().toLowerCase(), lines[i].slice(colon + 1).trim());
        }
        ctx.requestLine = lines[0];
        ctx.headers = headers;
        if (ctx.onUpgrade) {
          const accepted = ctx.onUpgrade(headers, lines[0]);
          if (accepted === false) return;
        } else {
          const accept = acceptKey(headers.get("sec-websocket-key") ?? "");
          const protocol = headers.get("sec-websocket-protocol");
          const response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            `Sec-WebSocket-Accept: ${accept}`,
            ...(protocol ? [`Sec-WebSocket-Protocol: ${protocol}`] : []),
            "",
            "",
          ].join("\r\n");
          socket.write(response);
        }
        state.upgraded = true;
      }
      if (state.upgraded && state.buffer.length > 0) {
        parseClientFrames(state, (frame) => {
          ctx.frames.push(frame);
          ctx.onFrame?.(frame);
        });
      }
    });
  });
  await new Promise((done) => server.listen(socketPath, done));
  const stop = async () => {
    for (const s of sockets) s.destroy();
    await new Promise((done) => server.close(done));
  };
  cleanups.push(stop);
  return { server, stop };
}

async function startMockRexServer(socketPath, options = {}) {
  const state = {
    instanceId: options.instanceId ?? "rex-inst-1",
    pid: options.pid === undefined ? 4242 : options.pid,
    apiRevision: options.apiRevision ?? 24,
    protocol: options.protocol ?? "rex.control.v1",
    sessions: options.sessions ?? [],
    views: new Map(Object.entries(options.views ?? {})),
    listings: new Map(Object.entries(options.listings ?? {})),
    titles: new Map(Object.entries(options.titles ?? {})),
    processes: new Map(Object.entries(options.processes ?? {})),
    statuses: new Map(Object.entries(options.statuses ?? {})),
    hellos: [],
    requests: [],
    seq: 0,
    clients: new Set(),
  };

  const server = await startRawWsServer(socketPath, (ctx) => {
    state.clients.add(ctx);
    ctx.socket.on("close", () => state.clients.delete(ctx));
    ctx.onFrame = (frame) => {
      if (frame.opcode === 0x9) {
        ctx.sendFrame(0xa, frame.payload);
        return;
      }
      if (frame.opcode === 0x8) {
        ctx.socket.end();
        return;
      }
      if (frame.opcode !== 0x1) return;
      const msg = JSON.parse(frame.payload.toString("utf8"));
      if (msg.type === "hello") {
        state.hellos.push(msg);
        ctx.sendJson({
          type: "welcome",
          protocol: state.protocol,
          api_revision: state.apiRevision,
        });
        return;
      }
      if (msg.type !== "request") return;
      state.requests.push(msg);
      const reply = (payload) => ctx.sendJson({ type: "response", id: msg.id, payload });
      const fail = (code, message) => ctx.sendJson({ type: "response", id: msg.id, error: { code, message } });

      if (msg.method === "server.status") {
        reply({ instance_id: state.instanceId, pid: state.pid });
      } else if (msg.method === "session.attach_all") {
        reply({ sessions: state.sessions });
      } else if (msg.method === "session.view") {
        const view = state.views.get(msg.payload?.session_id);
        if (view === undefined) fail("not_found", "missing view");
        else reply(view);
      } else if (msg.method === "session.list_blocks") {
        const listing = state.listings.get(msg.payload?.session_id);
        if (listing === undefined) fail("not_found", "missing listing");
        else reply(listing);
      } else if (msg.method === `${TERMINAL_CREATOR}.title`) {
        const key = `${msg.payload?.session_id}/${msg.payload?.block_id}`;
        reply(state.titles.get(key) ?? { title: "" });
      } else if (msg.method === `${TERMINAL_CREATOR}.process`) {
        const key = `${msg.payload?.session_id}/${msg.payload?.block_id}`;
        reply(state.processes.get(key) ?? {});
      } else if (msg.method === `${TERMINAL_CREATOR}.program_status`) {
        const key = `${msg.payload?.session_id}/${msg.payload?.block_id}`;
        reply(state.statuses.get(key) ?? { records: [] });
      } else {
        fail("unknown_method", `unknown ${msg.method}`);
      }
    };
  });

  return {
    state,
    stop: server.stop,
    emitEvent(payload, seqOverride) {
      state.seq = seqOverride ?? state.seq + 1;
      for (const client of state.clients) {
        client.sendJson({ type: "event", seq: state.seq, payload });
      }
    },
  };
}

async function startRelay(respond = () => ({ status: 200, body: {} })) {
  const requests = [];
  const server = createHttpServer((req, res) => {
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
  cleanups.push(() => new Promise((done) => server.close(done)));
  return { url: `http://127.0.0.1:${server.address().port}`, requests };
}

function openAlert(envelope, key) {
  const wire = JSON.parse(envelope);
  const nonce = Buffer.from(wire.n, "base64url");
  const sealed = Buffer.from(wire.ct, "base64url");
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from("HERDR-NOTIFY:1", "utf8"));
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(sealed.subarray(0, sealed.length - 16)), decipher.final()]).toString("utf8"));
}

function writeNotifyConfig(relayUrl) {
  writeFileSync(
    join(directory, "notify.json"),
    JSON.stringify({
      relay_url: relayUrl,
      debounce_ms: 15,
      activity_debounce_ms: 15,
      retry_delay_ms: 1,
    }),
  );
}

function registerRex({ blocked = true, done = true, activity = null } = {}) {
  writeFileSync(
    join(directory, "notifications.json"),
    JSON.stringify({
      v: 1,
      devices: [
        {
          token: ALERT_A,
          key: KEY_A.toString("base64url"),
          env: "sandbox",
          session: REX_SESSION,
          notify: { blocked, done },
          ...(activity ? { live_activity: { token: activity, started_at: "2026-11-28T00:00:00Z" } } : {}),
        },
      ],
    }),
  );
}

function writeSeenMark(key, instanceId, marks) {
  const device = notificationKeyId(key);
  writeFileSync(join(directory, seenMarkFileName(device)), JSON.stringify({ core: instanceId, device, marks, v: 1 }));
}

function storeRexSocket(socketPath) {
  mkdirSync(join(directory, "rex"), { recursive: true, mode: 0o700 });
  writeFileSync(join(directory, "rex", "socket.json"), JSON.stringify({ socket: socketPath }), { mode: 0o600 });
}

suite("Rex WebSocket transport", () => {
  test("verifies RFC 6455 Sec-WebSocket-Accept, masks short and extended client frames, and reassembles fragmented server messages across control frames", async () => {
    const socketPath = join(root, "ws.sock");
    let serverCtx;
    await startRawWsServer(socketPath, (ctx) => {
      serverCtx = ctx;
      ctx.onUpgrade = (headers, requestLine) => {
        assert.equal(requestLine, "GET /api/control HTTP/1.1");
        assert.equal(headers.get("sec-websocket-protocol"), "rex.control.v1");
        const accept = acceptKey(headers.get("sec-websocket-key"));
        ctx.socket.write(
          [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: keep-alive, Upgrade",
            `Sec-WebSocket-Accept: ${accept}`,
            "Sec-WebSocket-Protocol: rex.control.v1",
            "",
            "",
          ].join("\r\n"),
        );
      };
    });

    const received = [];
    const ws = await connectUnixWebSocket(socketPath, {
      path: "/api/control",
      subprotocol: "rex.control.v1",
      keepaliveMs: 60_000,
      onText: (text) => received.push(text),
    });
    cleanups.push(() => ws.close());

    const shortText = "hello-rex";
    const mediumText = "x".repeat(300);
    ws.sendText(shortText);
    ws.sendText(mediumText);

    await waitFor(() => serverCtx.frames.length >= 2, "client text frames", PATIENCE_MS);
    assert.equal(serverCtx.frames[0].masked, true);
    assert.equal(serverCtx.frames[0].opcode, 0x1);
    assert.equal(serverCtx.frames[0].payload.toString("utf8"), shortText);
    assert.equal(serverCtx.frames[1].masked, true);
    assert.equal(serverCtx.frames[1].payload.toString("utf8"), mediumText);

    serverCtx.sendFrame(0x1, "part-1:", { fin: false });
    serverCtx.sendFrame(0x9, "hb-ping");
    serverCtx.sendFrame(0x0, "part-2:", { fin: false });
    serverCtx.sendFrame(0x0, "part-3", { fin: true });

    await waitFor(() => received.length === 1 && serverCtx.frames.some((f) => f.opcode === 0xa), "fragmented text and pong", PATIENCE_MS);
    assert.equal(received[0], "part-1:part-2:part-3");
    const pong = serverCtx.frames.find((f) => f.opcode === 0xa);
    assert.equal(pong.masked, true);
    assert.equal(pong.payload.toString("utf8"), "hb-ping");

    const closePayload = Buffer.alloc(2);
    closePayload.writeUInt16BE(1001, 0);
    serverCtx.sendFrame(0x8, closePayload);
    const reason = await ws.closed;
    assert.match(reason.message, /1001/);
  });

  test("rejects bad Sec-WebSocket-Accept, wrong subprotocol, and non-101 upgrade", async () => {
    const cases = [
      {
        name: "bad-accept",
        respond: () =>
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong==\r\nSec-WebSocket-Protocol: rex.control.v1\r\n\r\n",
        pattern: /invalid WebSocket upgrade/,
      },
      {
        name: "wrong-subprotocol",
        respond: (headers) =>
          `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${acceptKey(headers.get("sec-websocket-key"))}\r\nSec-WebSocket-Protocol: other.v1\r\n\r\n`,
        pattern: /invalid WebSocket upgrade/,
      },
      {
        name: "non-101",
        respond: () => "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n",
        pattern: /403/,
      },
    ];

    for (const c of cases) {
      const sock = join(root, `${c.name}.sock`);
      await startRawWsServer(sock, (ctx) => {
        ctx.onUpgrade = (headers) => {
          ctx.socket.write(c.respond(headers));
          return false;
        };
      });
      await assert.rejects(connectUnixWebSocket(sock, { subprotocol: "rex.control.v1" }), c.pattern);
    }
  });
});

suite("Rex socket resolution and discovery", () => {
  test("reads valid stored socket.json and rejects invalid paths", () => {
    assert.equal(readStoredRexSocket(directory), null);
    assert.equal(wantsRexFollower(directory), false);

    mkdirSync(join(directory, "rex"), { recursive: true });
    assert.equal(wantsRexFollower(directory), true);

    const writeRaw = (obj) => writeFileSync(join(directory, "rex", "socket.json"), JSON.stringify(obj));
    writeRaw({ socket: "relative/server.sock" });
    assert.equal(readStoredRexSocket(directory), null);
    writeRaw({ socket: "npipe://./pipe/rex" });
    assert.equal(readStoredRexSocket(directory), null);
    writeRaw({ socket: "/tmp/trailing/" });
    assert.equal(readStoredRexSocket(directory), null);
    writeRaw({ socket: "/tmp/bad\nline.sock" });
    assert.equal(readStoredRexSocket(directory), null);
    writeRaw({ path: "/tmp/rex-alt.sock" });
    assert.equal(readStoredRexSocket(directory), "/tmp/rex-alt.sock");
    writeRaw({ socket: "/tmp/rex-primary.sock", path: "/tmp/rex-alt.sock" });
    assert.equal(readStoredRexSocket(directory), "/tmp/rex-primary.sock");
  });

  test("discovers real Unix sockets on darwin and linux, ignoring regular files, and prefers stored socket", async () => {
    const fakeHome = join(root, "home");
    const darwinDir = join(fakeHome, "Library", "Application Support", "rex");
    mkdirSync(darwinDir, { recursive: true });
    const darwinSock = join(darwinDir, "server.sock");
    writeFileSync(darwinSock, "not-a-socket");
    assert.equal(discoverRexSocket({ platform: "darwin", home: fakeHome }), null);
    rmSync(darwinSock);

    await startRawWsServer(darwinSock, () => {});
    assert.equal(discoverRexSocket({ platform: "darwin", home: fakeHome }), darwinSock);

    const rexRun = join(root, "rr");
    const xdgRun = join(root, "xr");
    mkdirSync(rexRun, { recursive: true });
    mkdirSync(join(xdgRun, "rex"), { recursive: true });
    const xdgSock = join(xdgRun, "rex", "server.sock");
    const rexSock = join(rexRun, "server.sock");
    await startRawWsServer(xdgSock, () => {});
    assert.equal(
      discoverRexSocket({ platform: "linux", home: fakeHome, env: { XDG_RUNTIME_DIR: xdgRun } }),
      xdgSock,
    );
    await startRawWsServer(rexSock, () => {});
    assert.equal(
      discoverRexSocket({ platform: "linux", home: fakeHome, env: { REX_RUNTIME_DIR: rexRun, XDG_RUNTIME_DIR: xdgRun } }),
      rexSock,
    );

    assert.equal(resolveRexSocket(directory, { platform: "darwin", home: fakeHome }), darwinSock);
    storeRexSocket("/tmp/override.sock");
    assert.equal(resolveRexSocket(directory, { platform: "darwin", home: fakeHome }), "/tmp/override.sock");
  });
});

suite("Rex turn state and seen marks", () => {
  test("escapes pane IDs, normalizes status records, and filters mismatched owners or apps", () => {
    assert.equal(rexPaneID("s/1%a", "b%2/c"), "s%2F1%25a/b%252%2Fc");
    assert.equal(rexKindLabel("claude"), "Claude");

    const normalized = normalizeRexStatus({
      state: "working",
      app: "claude-code",
      msg: "2 background tasks still running",
      owner: { pid: 500, name: "claude" },
      updated_at: "2026-11-28T10:00:00Z",
    });
    assert.equal(normalized.state, "done");
    assert.equal(normalized.ownerPid, 500);
    assert.equal(normalized.ownerName, "claude");
    assert.equal(normalized.updatedAt, "2026-11-28T10:00:00Z");

    const pane = { pid: 500, program: "claude", argv0: "claude", status: normalized };
    assert.equal(rexAgentKind(pane), "claude");
    assert.deepEqual(rexAgentReport(pane, "claude"), normalized);
    assert.equal(rexAgentReport({ ...pane, pid: 501 }, "claude"), null);
    assert.equal(rexAgentReport({ ...pane, program: "zsh" }, "claude"), null);
    assert.equal(rexAgentReport({ ...pane, status: { ...normalized, app: "codex" } }, "claude"), null);
  });

  test("tracks idle, working, blocked, done, error transitions and seen-mark matching", () => {
    const turns = new RexTurnState();
    const makePane = (state, updatedAt, { pid = 700, program = "claude", app = "claude-code" } = {}) => ({
      pid,
      program,
      argv0: program,
      sessionLabel: "proj",
      title: "Fix bug",
      status: { state, app, ownerPid: pid, ownerName: program, updatedAt },
    });

    foldRexPane(turns, makePane("idle", "2026-11-28T10:00:00Z"));
    assert.equal(turns.agentStatus, "idle");
    assert.equal(turns.ended, null);

    foldRexPane(turns, makePane("working", "2026-11-28T10:00:05Z"));
    assert.equal(turns.agentStatus, "working");
    assert.equal(turns.ended, null);

    foldRexPane(turns, makePane("blocked", "2026-11-28T10:00:08Z"));
    assert.equal(turns.agentStatus, "blocked");
    assert.equal(turns.ended, null);

    foldRexPane(turns, makePane("done", "2026-11-28T10:00:12Z"));
    assert.equal(turns.agentStatus, "idle");
    assert.deepEqual(turns.ended, { turn: 700, word: "2026-11-28T10:00:12Z" });
    assert.equal(turns.isDoneFor(null), true);
    assert.equal(turns.isDoneFor({ turn: 701, word: "2026-11-28T10:00:12Z" }), true);
    assert.equal(turns.isDoneFor({ turn: 700, word: "2026-11-28T10:00:11Z" }), true);
    assert.equal(turns.isDoneFor({ turn: 700, word: "2026-11-28T10:00:12Z" }), false);
    assert.equal(turns.isDoneFor({ turn: 700, word: "2026-11-28T10:00:15Z" }), false);

    foldRexPane(turns, makePane("idle", "2026-11-28T10:00:14Z"));
    assert.deepEqual(turns.ended, { turn: 700, word: "2026-11-28T10:00:12Z" });

    const restored = RexTurnState.restore(JSON.parse(JSON.stringify(turns.toJSON())));
    assert.deepEqual(restored.ended, turns.ended);
    assert.equal(rexDecisionSignature(makePane("idle", "2026-11-28T10:00:14Z"), restored).includes("2026-11-28T10:00:12Z"), true);

    foldRexPane(turns, makePane("working", "2026-11-28T10:01:00Z"));
    foldRexPane(turns, makePane("error", "2026-11-28T10:01:05Z"));
    assert.equal(turns.agentStatus, "error");
    assert.equal(turns.ended, null);

    const openCodeTurns = new RexTurnState();
    foldRexPane(openCodeTurns, makePane("idle", "2026-11-28T10:02:00Z", { pid: 800, program: "opencode", app: "opencode" }));
    foldRexPane(openCodeTurns, makePane("working", "2026-11-28T10:02:02Z", { pid: 800, program: "opencode", app: "opencode" }));
    foldRexPane(openCodeTurns, makePane("idle", "2026-11-28T10:02:05Z", { pid: 800, program: "opencode", app: "opencode" }));
    assert.deepEqual(openCodeTurns.ended, { turn: 800, word: "2026-11-28T10:02:05Z" });
  });
});

suite("Rex control client", () => {
  test("performs hello/welcome rev 24 handshake, syncs sessions/views/blocks, and applies live events", async () => {
    const socketPath = join(root, "rex-client.sock");
    const mock = await startMockRexServer(socketPath, {
      instanceId: "inst-client-1",
      pid: 7777,
      apiRevision: 24,
      sessions: [{ session_id: "s1", label: "Work" }],
      views: {
        s1: {
          label: "Work",
          windows: [
            {
              window_id: "win:12345678",
              label: "Window 12345678",
              layers: [
                {
                  kind: "floating",
                  blocks: [{ block_id: "blk:ff000001", creator_name: TERMINAL_CREATOR, label: "Float Term" }],
                },
                {
                  kind: "tiled",
                  layout: { split: { before: { block_id: "blk:aa000002" }, after: { block_id: "blk:aa000001" } } },
                  blocks: [
                    { block_id: "blk:aa000001", creator_name: TERMINAL_CREATOR, label: "Block aa000001" },
                    { block_id: "blk:aa000002", creator_name: TERMINAL_CREATOR, label: "Primary" },
                    { block_id: "blk:ignored1", creator_name: "com.other.widget", label: "Other" },
                  ],
                },
              ],
            },
          ],
        },
      },
      listings: {
        s1: {
          blocks: [
            { block_id: "blk:aa000002", creator_name: TERMINAL_CREATOR, placement: "placed", window_id: "win:12345678" },
            { block_id: "blk:aa000001", creator_name: TERMINAL_CREATOR, placement: "placed", window_id: "win:12345678" },
            { block_id: "blk:ff000001", creator_name: TERMINAL_CREATOR, placement: "placed", window_id: "win:12345678" },
            { block_id: "blk:dd000009", creator_name: TERMINAL_CREATOR, placement: "detached", label: "Detached Shell" },
          ],
        },
      },
      titles: {
        "s1/blk:aa000002": { title: "Claude Code" },
      },
      processes: {
        "s1/blk:aa000002": {
          home: "/Users/dev",
          foreground: { pid: 901, name: "claude", cwd: "/work/repo", argv0: "claude" },
        },
      },
      statuses: {
        "s1/blk:aa000002": {
          records: [
            { id: "child", state: "working", app: "claude-code" },
            { id: "", state: "idle", app: "claude-code", owner: { pid: 901, name: "claude" }, updated_at: "2026-11-28T11:00:00Z" },
          ],
        },
      },
    });

    const reports = { connected: [], updated: [] };
    const connection = await connectRex(socketPath, {
      listener: {
        connected: (r) => reports.connected.push(r),
        updated: (r) => reports.updated.push(r),
      },
    });
    cleanups.push(() => connection.close());

    assert.equal(mock.state.hellos.length, 1);
    assert.equal(mock.state.hellos[0].api_revision, 24);
    assert.equal(mock.state.hellos[0].api_min_revision, 12);
    assert.equal(reports.connected.length, 1);
    const inv = reports.connected[0].inventory;
    assert.deepEqual([...inv.keys()], [
      "s1/blk:aa000002",
      "s1/blk:aa000001",
      "s1/blk:ff000001",
      "s1/blk:dd000009",
    ]);
    const primary = inv.get("s1/blk:aa000002");
    assert.equal(primary.windowLabel, "");
    assert.equal(primary.blockLabel, "Primary");
    assert.equal(primary.agentKind, "claude");
    assert.equal(primary.status.state, "idle");
    assert.equal(inv.get("s1/blk:aa000001").blockLabel, null);
    assert.equal(inv.get("s1/blk:dd000009").windowID, "s1/detached");

    mock.emitEvent({
      type: "session_event",
      payload: {
        session_id: "s1",
        event: {
          type: "block_event",
          payload: {
            creator_name: TERMINAL_CREATOR,
            block_id: "blk:aa000002",
            name: "program_status_changed",
            payload: {
              id: "",
              record: { state: "working", app: "claude-code", owner: { pid: 901, name: "claude" }, updated_at: "2026-11-28T11:00:05Z" },
            },
          },
        },
      },
    });

    mock.emitEvent({
      type: "session_event",
      payload: {
        session_id: "s1",
        event: {
          type: "block_event",
          payload: {
            creator_name: TERMINAL_CREATOR,
            block_id: "blk:aa000002",
            name: "title_changed",
            payload: { title: "Review PR" },
          },
        },
      },
    });

    await waitFor(
      () => reports.updated.at(-1)?.inventory.get("s1/blk:aa000002")?.title === "Review PR",
      "live block events",
      PATIENCE_MS,
    );
    assert.equal(reports.updated.at(-1).inventory.get("s1/blk:aa000002").status.state, "working");

    mock.emitEvent({
      type: "session_event",
      payload: {
        session_id: "s1",
        event: { type: "session_label_changed", payload: { label: "Renamed Work" } },
      },
    });
    await waitFor(
      () => reports.updated.at(-1)?.inventory.get("s1/blk:aa000002")?.sessionLabel === "Renamed Work",
      "session label change",
      PATIENCE_MS,
    );

    mock.emitEvent({
      type: "session_destroyed",
      payload: { session_id: "s1" },
    });
    await waitFor(() => reports.updated.at(-1)?.inventory.size === 0, "session destroyed", PATIENCE_MS);
  });

  test("rejects unsupported API revision from welcome", async () => {
    const socketPath = join(root, "rex-badrev.sock");
    await startMockRexServer(socketPath, { apiRevision: 11 });
    await assert.rejects(connectRex(socketPath), /Unsupported Rex protocol or API revision/);
  });
});

suite("Rex follower, notifications, Live Activity, and Usage", () => {
  test("delivers encrypted alerts and Live Activity updates, honors seen marks, and serves usage-query --rex", async () => {
    const prevHome = process.env.HOME;
    const prevClaudeDir = process.env.CLAUDE_CONFIG_DIR;
    const fakeHome = join(root, "user-home");
    const claudeDir = join(root, "claude-config");
    const projects = join(claudeDir, "projects", "demo");
    mkdirSync(fakeHome, { recursive: true });
    mkdirSync(projects, { recursive: true });
    writeFileSync(
      join(projects, "s1.jsonl"),
      `${JSON.stringify({
        type: "assistant",
        timestamp: new Date().toISOString(),
        sessionId: "sess-rex",
        requestId: "req-rex",
        cwd: "/work/rex-app",
        message: {
          id: "msg_rex_1",
          model: "claude-opus-4-1",
          usage: { input_tokens: 13, output_tokens: 8 },
        },
      })}\n`,
    );
    process.env.HOME = fakeHome;
    process.env.CLAUDE_CONFIG_DIR = claudeDir;
    cleanups.push(() => {
      if (prevHome === undefined) delete process.env.HOME;
      else process.env.HOME = prevHome;
      if (prevClaudeDir === undefined) delete process.env.CLAUDE_CONFIG_DIR;
      else process.env.CLAUDE_CONFIG_DIR = prevClaudeDir;
    });

    cpSync(HELPER, join(directory, "app"), { recursive: true });
    const relay = await startRelay();
    writeNotifyConfig(relay.url);
    registerRex({ blocked: true, done: true, activity: ACTIVITY_A });

    const socketPath = join(root, "rex-live.sock");
    storeRexSocket(socketPath);
    const mock = await startMockRexServer(socketPath, {
      instanceId: "inst-live-1",
      pid: null,
      apiRevision: 24,
      sessions: [{ session_id: "s1", label: "Heeler" }],
      views: {
        s1: {
          label: "Heeler",
          windows: [
            {
              window_id: "w1",
              label: "Main",
              layers: [
                {
                  kind: "tiled",
                  blocks: [{ block_id: "b1", creator_name: TERMINAL_CREATOR, label: "Agent" }],
                },
              ],
            },
          ],
        },
      },
      listings: {
        s1: {
          blocks: [{ block_id: "b1", creator_name: TERMINAL_CREATOR, placement: "placed", window_id: "w1" }],
        },
      },
      titles: { "s1/b1": { title: "Ship Rex" } },
      processes: {
        "s1/b1": { foreground: { pid: 5151, name: "claude", cwd: "/work/rex-app", argv0: "claude" } },
      },
      statuses: {
        "s1/b1": {
          records: [
            { id: "", state: "idle", app: "claude-code", owner: { pid: 5151, name: "claude" }, updated_at: "2026-11-28T12:00:00Z" },
          ],
        },
      },
    });

    const follower = followRexServer({
      directory,
      pollMs: 25,
      retryDelayMs: 50,
      listener: combineRexListeners(
        rexUsageListener({ directory }),
        rexNotificationListener({ directory }),
        rexLiveActivityListener({ directory, hostName: "studio" }),
      ),
    });
    cleanups.push(() => follower.stop());

    const runtimePath = join(directory, "rex", "runtime.json");
    await waitFor(() => existsSync(runtimePath), "rex runtime.json", PATIENCE_MS);

    const emitStatus = (state, updatedAt) =>
      mock.emitEvent({
        type: "session_event",
        payload: {
          session_id: "s1",
          event: {
            type: "block_event",
            payload: {
              creator_name: TERMINAL_CREATOR,
              block_id: "b1",
              name: "program_status_changed",
              payload: {
                id: "",
                record: { state, app: "claude-code", owner: { pid: 5151, name: "claude" }, updated_at: updatedAt },
              },
            },
          },
        },
      });

    const alerts = () => relay.requests.filter((r) => r.body.kind !== "liveactivity" && r.body.token === ALERT_A);
    const activities = () =>
      relay.requests.map((r) => r.body).filter((b) => b.kind === "liveactivity" && b.token === ACTIVITY_A);

    emitStatus("working", "2026-11-28T12:00:05Z");
    await waitFor(() => activities().some((a) => a.counts?.working === 1), "working live activity", PATIENCE_MS);
    const workingActivity = decryptActivityEnvelope(activities().find((a) => a.counts?.working === 1).envelope, KEY_A);
    assert.equal(workingActivity.host, "studio");
    assert.equal(workingActivity.agents[0].status, "working");

    emitStatus("blocked", "2026-11-28T12:00:10Z");
    await waitFor(
      () => alerts().some((r) => openAlert(r.body.envelope, KEY_A).status === "blocked"),
      "blocked push alert",
      PATIENCE_MS,
    );
    const blockedAlert = openAlert(alerts().find((r) => openAlert(r.body.envelope, KEY_A).status === "blocked").body.envelope, KEY_A);
    assert.equal(blockedAlert.project, "Heeler");
    assert.equal(blockedAlert.title, "Ship Rex");

    emitStatus("working", "2026-11-28T12:00:15Z");
    emitStatus("done", "2026-11-28T12:00:20Z");
    await waitFor(
      () => alerts().some((r) => openAlert(r.body.envelope, KEY_A).status === "done"),
      "done push alert",
      PATIENCE_MS,
    );
    await waitFor(() => activities().some((a) => a.counts?.done === 1), "done live activity", PATIENCE_MS);

    const pushCountBeforeSeen = alerts().length;
    writeSeenMark(KEY_A, "inst-live-1", [{ terminal: "s1/b1", turn: 5151, word: "2026-11-28T12:00:30Z" }]);
    emitStatus("working", "2026-11-28T12:00:25Z");
    emitStatus("done", "2026-11-28T12:00:30Z");
    await waitFor(() => activities().at(-1)?.event === "end", "seen mark suppresses done and ends live activity", PATIENCE_MS);
    assert.equal(alerts().length, pushCountBeforeSeen);

    let report = null;
    await waitFor(() => {
      const res = spawnSync(
        process.execPath,
        [join(directory, "app", "usage-query.js"), "--tz", "UTC", "--rex", "--no-codex-limits", "--no-agy-limits"],
        {
          env: { HOME: join(root, "ssh-home"), PATH: "/usr/bin:/bin" },
          encoding: "utf8",
          timeout: 10_000,
        },
      );
      assert.equal(res.status, 0, res.stderr);
      const parsed = JSON.parse(res.stdout);
      if (parsed.runtime === "recorded" && parsed.refreshing === false) {
        report = parsed;
        return true;
      }
      return false;
    }, "settled rex usage report", PATIENCE_MS);

    const claude = report.programs.find((item) => item.program === "claude");
    assert.equal(claude.tokenUsage.state, "ok");
    assert.equal(claude.tokenUsage.totals.last30Days.tokens.total, 21);

    const badQuery = spawnSync(
      process.execPath,
      [join(directory, "app", "usage-query.js"), "--tz", "UTC", "--rex", "--session", "work"],
      { encoding: "utf8", timeout: 10_000 },
    );
    assert.equal(badQuery.status, 1);
  });

  test("followRexSocket retries until the socket appears and notifies on disconnect", async () => {
    const socketPath = join(root, "delayed.sock");
    const events = [];
    const follower = followRexSocket(socketPath, {
      retryDelayMs: 25,
      listener: {
        connected: (r) => events.push({ kind: "connected", id: r.instanceId }),
        ended: (r) => events.push({ kind: "ended", id: r.instanceId }),
      },
    });
    cleanups.push(() => follower.stop());

    const mock = await startMockRexServer(socketPath, { instanceId: "inst-retry-1" });
    await waitFor(() => events.some((e) => e.kind === "connected" && e.id === "inst-retry-1"), "delayed connect", PATIENCE_MS);
    await mock.stop();
    await waitFor(() => events.some((e) => e.kind === "ended" && e.id === "inst-retry-1"), "disconnect ended event", PATIENCE_MS);
  });
});
