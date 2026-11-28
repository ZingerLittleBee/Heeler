import { createHash, randomBytes } from "node:crypto";
import { createConnection } from "node:net";

const GUID = "256EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const HEADER_LIMIT = 64 * 1024;
const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
const HANDSHAKE_TIMEOUT_MS = 10_000;
const KEEPALIVE_MS = 30_000;
const IDLE_TIMEOUT_MS = 65_000;

const OPCODE_CONTINUATION = 0x0;
const OPCODE_TEXT = 0x1;
const OPCODE_BINARY = 0x2;
const OPCODE_CLOSE = 0x8;
const OPCODE_PING = 0x9;
const OPCODE_PONG = 0xa;

function acceptFor(key) {
  return createHash("sha1").update(key + GUID).digest("base64");
}

function encodeClientFrame(opcode, payload) {
  const length = payload.length;
  let headerLength = 2 + 4;
  if (length >= 126 && length < 65536) headerLength += 2;
  else if (length >= 65536) headerLength += 8;
  const frame = Buffer.allocUnsafe(headerLength + length);
  frame[0] = 0x80 | (opcode & 0x0f);
  let offset = 2;
  if (length < 126) {
    frame[1] = 0x80 | length;
  } else if (length < 65536) {
    frame[1] = 0x80 | 126;
    frame.writeUInt16BE(length, 2);
    offset = 4;
  } else {
    frame[1] = 0x80 | 127;
    frame.writeBigUInt64BE(BigInt(length), 2);
    offset = 10;
  }
  const mask = randomBytes(4);
  mask.copy(frame, offset);
  offset += 4;
  for (let i = 0; i < length; i += 1) {
    frame[offset + i] = payload[i] ^ mask[i & 3];
  }
  return frame;
}

function parseHttpHeaders(text) {
  const lines = text.split("\r\n");
  const statusLine = lines[0] ?? "";
  const match = /^HTTP\/1\.1\s+(\d{3})\b/.exec(statusLine);
  if (!match) return null;
  const status = Number(match[1]);
  const headers = new Map();
  for (let i = 1; i < lines.length; i += 1) {
    const colon = lines[i].indexOf(":");
    if (colon <= 0) continue;
    const name = lines[i].slice(0, colon).trim().toLowerCase();
    const value = lines[i].slice(colon + 1).trim();
    headers.set(name, headers.has(name) ? `${headers.get(name)}, ${value}` : value);
  }
  return { status, headers };
}

export function connectUnixWebSocket(
  socketPath,
  {
    path = "/api/control",
    subprotocol = "rex.control.v1",
    handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS,
    keepaliveMs = KEEPALIVE_MS,
    idleTimeoutMs = IDLE_TIMEOUT_MS,
    signal,
    onText = () => {},
  } = {},
) {
  return new Promise((resolveOpen, rejectOpen) => {
    let settledOpen = false;
    let ended = false;
    let upgraded = false;
    let closingSent = false;
    let buffer = Buffer.alloc(0);
    let fragmentOpcode = null;
    let fragments = [];
    let fragmentBytes = 0;

    let finishClosed;
    const closed = new Promise((resolve) => {
      finishClosed = resolve;
    });

    const key = randomBytes(16).toString("base64");
    const expectedAccept = acceptFor(key);

    let handshakeTimer = null;
    let keepaliveTimer = null;
    let idleTimer = null;

    const socket = createConnection(socketPath);

    const clearTimers = () => {
      clearTimeout(handshakeTimer);
      clearInterval(keepaliveTimer);
      clearTimeout(idleTimer);
      handshakeTimer = null;
      keepaliveTimer = null;
      idleTimer = null;
    };

    const fail = (error) => {
      if (ended) return;
      ended = true;
      clearTimers();
      signal?.removeEventListener("abort", onAbort);
      socket.destroy();
      if (!settledOpen) {
        settledOpen = true;
        rejectOpen(error);
      }
      finishClosed(error);
    };

    const onAbort = () => {
      close(1000);
      fail(new Error("closed"));
    };

    const sendFrame = (opcode, payload) => {
      if (ended || !upgraded) return;
      socket.write(encodeClientFrame(opcode, payload));
    };

    const sendText = (text) => {
      if (ended || !upgraded) throw new Error("The WebSocket is closed.");
      sendFrame(OPCODE_TEXT, Buffer.from(text, "utf8"));
    };

    const close = (code = 1000) => {
      if (ended) return;
      if (upgraded && !closingSent) {
        closingSent = true;
        const payload = Buffer.allocUnsafe(2);
        payload.writeUInt16BE(code, 0);
        try {
          sendFrame(OPCODE_CLOSE, payload);
        } catch {}
      }
      fail(new Error("closed"));
    };

    const touchIdle = () => {
      if (!upgraded || ended) return;
      clearTimeout(idleTimer);
      idleTimer = setTimeout(() => fail(new Error("The Rex server went silent.")), idleTimeoutMs);
      idleTimer.unref?.();
    };

    const handleControl = (opcode, payload) => {
      if (opcode === OPCODE_PING) {
        sendFrame(OPCODE_PONG, payload);
      } else if (opcode === OPCODE_PONG) {
        touchIdle();
      } else if (opcode === OPCODE_CLOSE) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        if (!closingSent) {
          closingSent = true;
          try {
            sendFrame(OPCODE_CLOSE, payload.subarray(0, 2));
          } catch {}
        }
        fail(new Error(`The Rex server closed the connection (${code}).`));
      }
    };

    const drainFrames = () => {
      while (!ended && buffer.length >= 2) {
        const first = buffer[0];
        const second = buffer[1];
        const fin = (first & 0x80) !== 0;
        const opcode = first & 0x0f;
        const masked = (second & 0x80) !== 0;
        let payloadLength = second & 0x7f;
        let offset = 2;

        if (payloadLength === 126) {
          if (buffer.length < offset + 2) return;
          payloadLength = buffer.readUInt16BE(offset);
          offset += 2;
        } else if (payloadLength === 127) {
          if (buffer.length < offset + 8) return;
          const bigLength = buffer.readBigUInt64BE(offset);
          if (bigLength > BigInt(MAX_MESSAGE_BYTES)) {
            fail(new Error("A WebSocket message exceeded the size limit."));
            return;
          }
          payloadLength = Number(bigLength);
          offset += 8;
        }

        if (payloadLength > MAX_MESSAGE_BYTES) {
          fail(new Error("A WebSocket message exceeded the size limit."));
          return;
        }

        const maskLength = masked ? 4 : 0;
        if (buffer.length < offset + maskLength + payloadLength) return;

        let payload = buffer.subarray(offset + maskLength, offset + maskLength + payloadLength);
        if (masked) {
          const mask = buffer.subarray(offset, offset + 4);
          const unmasked = Buffer.allocUnsafe(payloadLength);
          for (let i = 0; i < payloadLength; i += 1) {
            unmasked[i] = payload[i] ^ mask[i & 3];
          }
          payload = unmasked;
        } else {
          payload = Buffer.from(payload);
        }
        buffer = buffer.subarray(offset + maskLength + payloadLength);

        if (opcode >= 0x8) {
          handleControl(opcode, payload);
          continue;
        }

        if (opcode === OPCODE_CONTINUATION) {
          if (fragmentOpcode === null) {
            fail(new Error("Unexpected WebSocket continuation frame."));
            return;
          }
          fragmentBytes += payload.length;
          if (fragmentBytes > MAX_MESSAGE_BYTES) {
            fail(new Error("A WebSocket message exceeded the size limit."));
            return;
          }
          fragments.push(payload);
          if (fin) {
            const full = Buffer.concat(fragments, fragmentBytes);
            const messageOpcode = fragmentOpcode;
            fragmentOpcode = null;
            fragments = [];
            fragmentBytes = 0;
            if (messageOpcode === OPCODE_TEXT) onText(full.toString("utf8"));
          }
          continue;
        }

        if (opcode !== OPCODE_TEXT && opcode !== OPCODE_BINARY) {
          fail(new Error(`Unsupported WebSocket opcode ${opcode}.`));
          return;
        }

        if (!fin) {
          fragmentOpcode = opcode;
          fragments = [payload];
          fragmentBytes = payload.length;
          continue;
        }

        if (opcode === OPCODE_TEXT) onText(payload.toString("utf8"));
      }
    };

    const handleUpgrade = () => {
      const boundary = buffer.indexOf("\r\n\r\n");
      if (boundary === -1) {
        if (buffer.length > HEADER_LIMIT) fail(new Error("The WebSocket upgrade header is too large."));
        return;
      }
      const head = buffer.subarray(0, boundary).toString("latin1");
      buffer = buffer.subarray(boundary + 4);
      const parsed = parseHttpHeaders(head);
      if (parsed === null || parsed.status !== 101) {
        fail(new Error(`The Rex server refused the WebSocket upgrade (${parsed?.status ?? "invalid"}).`));
        return;
      }
      const upgradeHeader = (parsed.headers.get("upgrade") ?? "").toLowerCase();
      const connectionHeader = (parsed.headers.get("connection") ?? "").toLowerCase();
      const acceptHeader = parsed.headers.get("sec-websocket-accept") ?? "";
      const protocolHeader = parsed.headers.get("sec-websocket-protocol") ?? "";
      if (
        upgradeHeader !== "websocket" ||
        !connectionHeader.split(",").some((part) => part.trim() === "upgrade") ||
        acceptHeader !== expectedAccept ||
        (subprotocol && protocolHeader !== subprotocol)
      ) {
        fail(new Error("The Rex server answered with an invalid WebSocket upgrade."));
        return;
      }
      upgraded = true;
      clearTimeout(handshakeTimer);
      handshakeTimer = null;
      touchIdle();
      keepaliveTimer = setInterval(() => {
        if (!ended && upgraded) sendFrame(OPCODE_PING, Buffer.alloc(0));
      }, keepaliveMs);
      keepaliveTimer.unref?.();
      if (!settledOpen) {
        settledOpen = true;
        resolveOpen({ sendText, close, closed });
      }
      if (buffer.length > 0) drainFrames();
    };

    if (signal?.aborted) {
      fail(new Error("closed"));
      return;
    }
    signal?.addEventListener("abort", onAbort);

    handshakeTimer = setTimeout(() => fail(new Error("The Rex server did not finish the WebSocket upgrade in time.")), handshakeTimeoutMs);
    handshakeTimer.unref?.();

    socket.on("connect", () => {
      const request = [
        `GET ${path} HTTP/1.1`,
        "Host: localhost",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        ...(subprotocol ? [`Sec-WebSocket-Protocol: ${subprotocol}`] : []),
        "",
        "",
      ].join("\r\n");
      socket.write(request);
    });

    socket.on("data", (chunk) => {
      try {
        buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
        if (!upgraded) {
          handleUpgrade();
        } else {
          touchIdle();
          drainFrames();
        }
      } catch (error) {
        fail(error);
      }
    });

    socket.on("error", (error) => fail(error));
    socket.on("close", () => fail(new Error("The connection closed.")));
  });
}
