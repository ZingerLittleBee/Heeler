// One framed connection to a core's socket: `hello`, `server.status` for the
// pid, then `events.subscribe`, and the inventory from that snapshot and from
// any `missed` after it. Sequence numbers belong to one core process, so nothing
// here outlives its connection (ADR 0033).
//
// It opens a socket and starts nothing: a core that does not run stays stopped.

import { createConnection } from "node:net";

import { FRAME_KIND, FrameDecoder, INITIAL_CREDIT, LineBuffer, creditFrame, helloLine, requestFrame } from "./frames.js";
import { applyEvent, buildInventory, isLocalTerminal } from "./inventory.js";

const MAXIMUM_HELLO_LINE = 1024 * 1024;
const REQUIRED_FEATURES = ["framed", "events", "status"];
const HELLO_ID = "hello";
const HANDSHAKE_TIMEOUT_MS = 10_000;
// The core sends a heartbeat every 15 seconds unless it has other bytes queued.
const IDLE_TIMEOUT_MS = 45_000;

function checkHello(hello) {
  if (hello?.generation !== 1) throw new Error("The core is of another generation.");
  if (hello.framed !== true) throw new Error("The core did not switch to frames.");
  const features = Array.isArray(hello.features) ? hello.features : [];
  for (const feature of REQUIRED_FEATURES) {
    if (!features.includes(feature)) throw new Error(`The core lacks ${feature}.`);
  }
}

class CoreConnection {
  coreId = null;
  pid = null;
  inventory = new Map();
  /** Resolves with the Error saying why, once the connection has ended. */
  closed;

  #socket;
  #listener;
  #idleTimeoutMs;
  #signal;
  #finish;
  #ended = false;

  #plain = Buffer.alloc(0);
  #decoder = new FrameDecoder();
  #lines = new LineBuffer();
  #pending = new Map();
  #nextRequest = 0;

  #eventsChannel = null;
  #early = [];
  #earlyBytes = 0;
  #sequence = 0;
  #timer = null;

  constructor(socketPath, { listener = {}, handshakeTimeoutMs, idleTimeoutMs, signal }) {
    this.#listener = listener;
    this.#idleTimeoutMs = idleTimeoutMs;
    this.#signal = signal;
    this.closed = new Promise((done) => {
      this.#finish = done;
    });
    signal?.addEventListener("abort", this.#onAbort);
    this.#timer = setTimeout(() => this.#end(new Error("The core did not answer in time.")), handshakeTimeoutMs);
    this.#socket = createConnection(socketPath);
    this.#socket.on("data", (chunk) => this.#ingest(chunk));
    this.#socket.on("error", (error) => this.#end(error));
    this.#socket.on("close", () => this.#end(new Error("The connection closed.")));
  }

  #onAbort = () => this.#end(new Error("closed"));

  /** Ends the connection for good. Idempotent. */
  close() {
    this.#end(new Error("closed"));
    return this.closed;
  }

  async establish() {
    try {
      const hello = await this.#call(HELLO_ID, helloLine());
      checkHello(hello);
      const status = await this.#request("server.status");
      if (!Number.isInteger(status?.pid) || typeof status.core?.id !== "string") {
        throw new Error("The server status has no core or pid.");
      }
      this.coreId = status.core.id;
      this.pid = status.pid;
      this.#adopt(await this.#request("events.subscribe"));
    } catch (error) {
      this.#end(error);
      throw error;
    }
  }

  #request(method) {
    this.#nextRequest += 1;
    const id = String(this.#nextRequest);
    return this.#call(id, requestFrame(id, method));
  }

  #call(id, bytes) {
    if (this.#ended) return Promise.reject(new Error("The connection closed."));
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      this.#socket.write(bytes);
    });
  }

  /** Takes the subscribe snapshot, and what its stream sent ahead of the reply. */
  #adopt(snapshot) {
    if (!Number.isInteger(snapshot?.channel) || snapshot.channel <= 0) throw new Error("The snapshot names no channel.");
    if (!Number.isInteger(snapshot.seq) || snapshot.seq < 0) throw new Error("The snapshot has no sequence.");
    this.inventory = buildInventory(snapshot.terminals);
    this.#sequence = snapshot.seq;
    this.#eventsChannel = snapshot.channel;
    clearTimeout(this.#timer);
    this.#timer = setTimeout(() => this.#end(new Error("The core went silent.")), this.#idleTimeoutMs);
    this.#listener.connected?.({ coreId: this.coreId, pid: this.pid, inventory: this.inventory });
    const early = this.#early;
    this.#early = [];
    for (const frame of early) {
      if (this.#ended) break;
      this.#route(frame);
    }
  }

  #ingest(chunk) {
    try {
      if (this.#eventsChannel !== null) this.#timer.refresh();
      let frames = chunk;
      if (this.#plain !== null) {
        const plain = Buffer.concat([this.#plain, chunk]);
        const newline = plain.indexOf(0x0a);
        if (newline === -1) {
          if (plain.length > MAXIMUM_HELLO_LINE) throw new Error("The hello reply is too long.");
          this.#plain = plain;
          return;
        }
        this.#plain = null;
        this.#reply(plain.subarray(0, newline));
        frames = plain.subarray(newline + 1);
      }
      this.#decoder.append(frames);
      while (!this.#ended) {
        const frame = this.#decoder.next();
        if (frame === null) break;
        this.#route(frame);
      }
    } catch (error) {
      this.#end(error);
    }
  }

  #route(frame) {
    if (frame.channel === 0) {
      if (frame.kind === FRAME_KIND.data) this.#reply(frame.payload);
    } else if (this.#eventsChannel === null) {
      this.#keepEarly(frame);
    } else if (frame.channel === this.#eventsChannel) {
      if (frame.kind === FRAME_KIND.data) this.#consume(frame.payload);
      else if (frame.kind === FRAME_KIND.close) throw new Error("The core closed the events channel.");
    }
  }

  /**
   * A stream's first DATA can reach the wire before the reply naming its channel.
   * It has only its initial credit to send, and none goes back until it is read.
   */
  #keepEarly(frame) {
    this.#earlyBytes += frame.payload.length;
    if (this.#earlyBytes > INITIAL_CREDIT) throw new Error("A stream sent past its credit.");
    this.#early.push(frame);
  }

  #consume(payload) {
    for (const line of this.#lines.append(payload)) this.#line(line);
    if (!this.#ended && payload.length > 0) {
      this.#socket.write(creditFrame(this.#eventsChannel, payload.length));
    }
  }

  #line(line) {
    const { method, params } = JSON.parse(line);
    if (method !== "event" && method !== "missed" && method !== "heartbeat") return;
    const seq = params?.seq;
    if (!Number.isInteger(seq) || seq < 0) throw new Error("An event has no sequence.");
    if (method === "missed") {
      this.inventory = buildInventory(params.terminals);
      this.#sequence = seq;
      this.#listener.inventoryReplaced?.({ inventory: this.inventory });
    } else if (method === "event" && seq > this.#sequence) {
      // A heartbeat's sequence is the core's, and can precede events queued here.
      this.#sequence = seq;
      this.#event(params);
    }
  }

  #event({ seq, type, terminal, data }) {
    if (typeof type !== "string") throw new Error("An event has no type.");
    if (type === "doc") return;
    if (typeof terminal !== "string" || terminal === "") throw new Error("A Terminal's event has no address.");
    if (!isLocalTerminal(terminal)) return;
    const event = { seq, type, terminal, data };
    applyEvent(this.inventory, event);
    this.#listener.event?.({ event, inventory: this.inventory });
  }

  #reply(payload) {
    const message = JSON.parse(payload);
    const call = this.#pending.get(message?.id);
    if (call === undefined) return;
    this.#pending.delete(message.id);
    if (message.error !== undefined) {
      call.reject(new Error(`The core refused: ${message.error?.data?.kind ?? message.error?.code}.`));
    } else {
      call.resolve(message.result);
    }
  }

  #end(reason) {
    if (this.#ended) return;
    this.#ended = true;
    clearTimeout(this.#timer);
    this.#signal?.removeEventListener("abort", this.#onAbort);
    this.#socket?.destroy();
    for (const call of this.#pending.values()) call.reject(reason);
    this.#pending.clear();
    this.#finish(reason);
  }
}

/**
 * Connects to the socket at `socketPath` and resolves once the subscribe
 * snapshot has been taken. `listener` hears `connected({coreId, pid, inventory})`,
 * `inventoryReplaced({inventory})` after a `missed`, and `event({event, inventory})`
 * after each applied event. A listener that throws ends the connection.
 */
export async function connectCore(
  socketPath,
  { listener, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS, idleTimeoutMs = IDLE_TIMEOUT_MS, signal } = {},
) {
  const connection = new CoreConnection(socketPath, { listener, handshakeTimeoutMs, idleTimeoutMs, signal });
  await connection.establish();
  return connection;
}
