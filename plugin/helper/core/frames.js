// herdr-core's framed protocol: a plain `hello` line, then frames of channel
// (u32 LE), kind (u8), length (u32 LE) and payload. Pinned, with the app's codec,
// by plugin/test-vectors/herdr-core-frames-v1.json.

const HEADER_LENGTH = 9;
const MAXIMUM_PAYLOAD = 16 * 1024 * 1024;

/** The credit a stream starts with before the client returns any. */
export const INITIAL_CREDIT = 256 * 1024;

export const FRAME_KIND = Object.freeze({ data: 0, credit: 1, close: 2, resize: 3, focus: 4, facts: 5 });

const KNOWN_KINDS = new Set(Object.values(FRAME_KIND));

export function encodeFrame({ channel, kind, payload = Buffer.alloc(0) }) {
  if (payload.length > MAXIMUM_PAYLOAD) throw new Error("A frame's payload exceeds 16 MiB.");
  const header = Buffer.alloc(HEADER_LENGTH);
  header.writeUInt32LE(channel, 0);
  header.writeUInt8(kind, 4);
  header.writeUInt32LE(payload.length, 5);
  return Buffer.concat([header, payload]);
}

/** Grants a stream `bytes` more of DATA payload. */
export function creditFrame(channel, bytes) {
  const payload = Buffer.alloc(4);
  payload.writeUInt32LE(bytes, 0);
  return encodeFrame({ channel, kind: FRAME_KIND.credit, payload });
}

/** One channel-0 request. Frames delimit its message, so it has no newline. */
export function requestFrame(id, method, params = {}) {
  const payload = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, method, params }), "utf8");
  return encodeFrame({ channel: 0, kind: FRAME_KIND.data, payload });
}

/**
 * The plain line that switches a connection to frames. It never carries a
 * `core` field, which would register the connection as a peer core.
 */
export function helloLine() {
  const request = { jsonrpc: "2.0", id: "hello", method: "hello", params: { generation: 1, framed: true } };
  return Buffer.from(`${JSON.stringify(request)}\n`, "utf8");
}

/**
 * Splits a byte stream into frames. A header announcing more than the limit is
 * refused as soon as it is complete, and the refusal sticks: nothing after it
 * can be trusted to be a frame.
 */
export class FrameDecoder {
  #chunks = [];
  #length = 0;
  #needed = HEADER_LENGTH;
  #refusal = null;

  get bufferedByteCount() {
    return this.#length;
  }

  append(bytes) {
    if (this.#refusal !== null) return;
    this.#chunks.push(bytes);
    this.#length += bytes.length;
  }

  /** The next complete frame of a known kind, or null until more bytes arrive. */
  next() {
    if (this.#refusal !== null) throw this.#refusal;
    while (this.#length >= this.#needed) {
      const buffered = this.#chunks.length === 1 ? this.#chunks[0] : Buffer.concat(this.#chunks);
      const length = buffered.readUInt32LE(5);
      if (length > MAXIMUM_PAYLOAD) {
        this.#chunks = [];
        this.#length = 0;
        this.#refusal = new Error(`A frame announces ${length} bytes, over the 16 MiB limit.`);
        throw this.#refusal;
      }
      const frameLength = HEADER_LENGTH + length;
      if (buffered.length < frameLength) {
        this.#chunks = [buffered];
        this.#needed = frameLength;
        return null;
      }
      const rest = buffered.subarray(frameLength);
      this.#chunks = rest.length > 0 ? [rest] : [];
      this.#length = rest.length;
      this.#needed = HEADER_LENGTH;
      const kind = buffered.readUInt8(4);
      if (KNOWN_KINDS.has(kind)) {
        return {
          channel: buffered.readUInt32LE(0),
          kind,
          payload: buffered.subarray(HEADER_LENGTH, frameLength),
        };
      }
    }
    return null;
  }
}

/**
 * The events channel is a byte stream of newline-terminated JSON, cut at 16 KiB
 * and at the credit edge, so a frame can hold part of a line or several lines.
 * Bytes wait here undecoded, so a cut inside a character does no harm.
 */
export class LineBuffer {
  #pending = [];
  #pendingLength = 0;

  /** The lines these bytes complete, without their newlines. Blank lines are dropped. */
  append(bytes) {
    const lines = [];
    let start = 0;
    for (let newline = bytes.indexOf(0x0a); newline !== -1; newline = bytes.indexOf(0x0a, start)) {
      this.#keep(bytes.subarray(start, newline));
      const line = Buffer.concat(this.#pending);
      this.#pending = [];
      this.#pendingLength = 0;
      if (line.length > 0) lines.push(line);
      start = newline + 1;
    }
    this.#keep(bytes.subarray(start));
    return lines;
  }

  #keep(bytes) {
    this.#pendingLength += bytes.length;
    if (this.#pendingLength > MAXIMUM_PAYLOAD) throw new Error("An event line exceeds 16 MiB.");
    if (bytes.length > 0) this.#pending.push(bytes);
  }
}
