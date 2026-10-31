// A fake herdr-core socket fed by the shared frame vectors, for the Host Helper's
// tests. Its own small parser keeps a bug in the Helper's codec from hiding here.

import { mkdirSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { dirname } from "node:path";

export const vectors = JSON.parse(
  readFileSync(new URL("../../test-vectors/herdr-core-frames-v1.json", import.meta.url), "utf8"),
);

export const exchange = (name) => vectors.exchanges.find((vector) => vector.name === name);
export const eventLine = (name) => vectors.events.find((vector) => vector.name === name).line;

const DATA = 0;
const CREDIT = 1;
const CLOSE = 2;

export function frame(channel, kind, payload = Buffer.alloc(0)) {
  const header = Buffer.alloc(9);
  header.writeUInt32LE(channel, 0);
  header.writeUInt8(kind, 4);
  header.writeUInt32LE(payload.length, 5);
  return Buffer.concat([header, payload]);
}

const reply = (id, result) =>
  frame(0, DATA, Buffer.from(JSON.stringify({ id, jsonrpc: "2.0", result }), "utf8"));

/**
 * One connection as the fake saw it: `helloLine`, then each frame the client
 * sent as `requests` (channel 0, with `hex` holding its exact bytes) and
 * `credit` (bytes returned, per channel).
 */
class FakeConnection {
  helloLine = null;
  requests = [];
  credit = new Map();
  #socket;
  #core;
  #input = Buffer.alloc(0);

  constructor(socket, core) {
    this.#socket = socket;
    this.#core = core;
    socket.on("data", (bytes) => this.#read(bytes));
    socket.on("error", () => {});
  }

  /** The methods asked, hello first, in order. */
  get methods() {
    return [...(this.helloLine === null ? [] : ["hello"]), ...this.requests.map((request) => request.method)];
  }

  get closed() {
    return this.#socket.destroyed;
  }

  write(bytes) {
    this.#socket.write(bytes);
  }

  /** Sends bytes on the events channel as one DATA frame. */
  sendEvents(text, channel = this.#core.eventsChannel) {
    this.write(frame(channel, DATA, Buffer.from(text, "utf8")));
  }

  closeEvents(channel = this.#core.eventsChannel) {
    this.write(frame(channel, CLOSE));
  }

  destroy() {
    this.#socket.destroy();
  }

  creditFor(channel = this.#core.eventsChannel) {
    return this.credit.get(channel) ?? 0;
  }

  #read(bytes) {
    this.#input = Buffer.concat([this.#input, bytes]);
    if (this.helloLine === null) {
      const newline = this.#input.indexOf(0x0a);
      if (newline === -1) return;
      this.helloLine = this.#input.subarray(0, newline).toString("utf8");
      this.#input = this.#input.subarray(newline + 1);
      if (this.#core.answersHello) this.write(Buffer.from(`${this.#core.helloReply}\n`, "utf8"));
    }
    while (this.#input.length >= 9) {
      const length = this.#input.readUInt32LE(5);
      if (this.#input.length < 9 + length) return;
      const raw = this.#input.subarray(0, 9 + length);
      this.#input = this.#input.subarray(9 + length);
      this.#frame(raw);
    }
  }

  #frame(raw) {
    const channel = raw.readUInt32LE(0);
    const kind = raw.readUInt8(4);
    const payload = raw.subarray(9);
    if (kind === CREDIT) {
      this.credit.set(channel, this.creditFor(channel) + payload.readUInt32LE(0));
    } else if (kind === DATA && channel === 0) {
      const request = JSON.parse(payload);
      this.requests.push({ ...request, hex: raw.toString("hex") });
      this.#core.answer(this, request);
    }
  }
}

export class FakeCore {
  connections = [];
  eventsChannel = exchange("events-subscribe").result.channel;
  helloReply = vectors.hello.reply;
  answersHello = true;
  /** A result to answer with in place of the vector's captured reply. */
  status = null;
  snapshot = null;
  /** Lines to send on the events channel ahead of the subscribe reply. */
  earlyEvents = [];
  /** Per method, what to send in place of a reply: `(id) => bytes`. */
  answers = {};
  #server;
  #path;

  constructor(path, options = {}) {
    this.#path = path;
    Object.assign(this, options);
    this.#server = createServer((socket) => this.connections.push(new FakeConnection(socket, this)));
  }

  static async start(path, options) {
    mkdirSync(dirname(path), { recursive: true });
    const core = new FakeCore(path, options);
    await new Promise((done, fail) => {
      core.#server.once("error", fail);
      core.#server.listen(path, done);
    });
    return core;
  }

  answer(connection, { id, method }) {
    if (this.answers[method] !== undefined) {
      connection.write(this.answers[method](id));
      return;
    }
    if (method === "server.status") {
      connection.write(
        this.status === null ? Buffer.from(exchange("server-status").replyFrame, "hex") : reply(id, this.status),
      );
    } else if (method === "events.subscribe") {
      for (const line of this.earlyEvents) connection.sendEvents(line);
      connection.write(
        this.snapshot === null ? Buffer.from(exchange("events-subscribe").replyFrame, "hex") : reply(id, this.snapshot),
      );
    }
  }

  get last() {
    return this.connections.at(-1);
  }

  /** The core's end: every connection drops and the socket file goes. */
  async stop() {
    for (const connection of this.connections) connection.destroy();
    await new Promise((done) => this.#server.close(done));
    rmSync(this.#path, { force: true });
  }
}

/** Waits until `condition` holds, so a test never sleeps a fixed time. */
export async function waitFor(condition, what = "the condition", timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}.`);
    await new Promise((done) => setTimeout(done, 5));
  }
}
