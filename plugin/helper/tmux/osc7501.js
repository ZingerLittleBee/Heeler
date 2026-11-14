// Streaming OSC 7501 parser for a tmux Pane's output stream (ADR 0046).
// Reads both bare sequences (`ESC ] 7501 ; ... BEL` / `ESC \`) and Grok Build's
// tmux DCS passthrough (`ESC P tmux; ESC ESC ] 7501 ; ... ESC ESC \ ESC \`),
// ignoring capability queries (`?`) and child-session records (`id=...`).

const OSC_PREFIX = Buffer.from("\x1b]7501;", "ascii");
const DCS_PREFIX = Buffer.from("\x1bPtmux;", "ascii");
const MAX_PAYLOAD_BYTES = 16 * 1024;
const MAX_DCS_BYTES = 64 * 1024;
const VALID_STATES = new Set(["idle", "working", "blocked", "done", "error", "clear"]);
const TOKEN_PATTERN = /^[\x21-\x7e]+$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/=_-]+$/;

function parseOsc7501Payload(bytes) {
  const text = bytes.toString("utf8");
  if (text === "" || text === "?") return null;
  let state = null;
  let app = null;
  let kind = null;
  let msg = null;
  for (const word of text.split(":")) {
    const equals = word.indexOf("=");
    if (equals < 0) continue;
    const key = word.slice(0, equals);
    const value = word.slice(equals + 1);
    if (key === "id") {
      if (value !== "") return null;
    } else if (key === "state") {
      state = VALID_STATES.has(value) ? value : null;
    } else if (key === "app") {
      app = value !== "" && TOKEN_PATTERN.test(value) ? value : null;
    } else if (key === "kind") {
      kind = value !== "" && TOKEN_PATTERN.test(value) ? value : null;
    } else if (key === "msg") {
      msg = value !== "" && value.length <= 4096 && BASE64_PATTERN.test(value) ? value : null;
    }
  }
  return state ? { state, app, kind, msg } : null;
}

/**
 * Returns `{ feed(chunk) }` calling `onReport({ state, app, kind, msg })` for
 * each complete root OSC 7501 report in the Pane's byte stream.
 */
export function createOsc7501Parser(onReport) {
  const payload = Buffer.allocUnsafe(MAX_PAYLOAD_BYTES);
  let oscPrefix = 0;
  let inPayload = false;
  let payloadLength = 0;
  let payloadEscape = false;

  let dcsPrefix = 0;
  let inDcs = false;
  let dcsEscape = false;
  let dcsBytes = 0;

  const resetInner = () => {
    oscPrefix = 0;
    inPayload = false;
    payloadLength = 0;
    payloadEscape = false;
  };

  const emitPayload = () => {
    const report = parseOsc7501Payload(payload.subarray(0, payloadLength));
    inPayload = false;
    payloadLength = 0;
    payloadEscape = false;
    if (report) onReport(report);
  };

  const feedInner = (byte) => {
    if (!inPayload) {
      if (byte === OSC_PREFIX[oscPrefix]) {
        oscPrefix += 1;
        if (oscPrefix === OSC_PREFIX.length) {
          oscPrefix = 0;
          inPayload = true;
          payloadLength = 0;
          payloadEscape = false;
        }
      } else {
        oscPrefix = byte === OSC_PREFIX[0] ? 1 : 0;
      }
      return;
    }

    if (payloadEscape) {
      payloadEscape = false;
      if (byte === 0x5c) {
        emitPayload();
        return;
      }
      // An ESC inside an unclosed OSC that was not `ESC \` aborts the broken
      // report and lets the `ESC <byte>` pair start a new sequence.
      inPayload = false;
      payloadLength = 0;
      if (byte === OSC_PREFIX[1]) oscPrefix = 2;
      else if (byte === OSC_PREFIX[0]) oscPrefix = 1;
      else oscPrefix = 0;
      return;
    }

    if (byte === 0x07) {
      emitPayload();
    } else if (byte === 0x1b) {
      payloadEscape = true;
    } else if (payloadLength < MAX_PAYLOAD_BYTES) {
      payload[payloadLength] = byte;
      payloadLength += 1;
    } else {
      resetInner();
    }
  };

  const feedNormalByte = (byte) => {
    if (byte === DCS_PREFIX[dcsPrefix]) {
      dcsPrefix += 1;
      if (dcsPrefix === DCS_PREFIX.length) {
        dcsPrefix = 0;
        inDcs = true;
        dcsEscape = false;
        dcsBytes = 0;
        resetInner();
        return;
      }
    } else {
      dcsPrefix = byte === DCS_PREFIX[0] ? 1 : 0;
    }
    feedInner(byte);
  };

  return {
    feed(chunk) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      for (let index = 0; index < bytes.length; index += 1) {
        const byte = bytes[index];
        if (!inDcs) {
          feedNormalByte(byte);
          continue;
        }
        if (dcsEscape) {
          dcsEscape = false;
          if (byte === 0x1b) {
            dcsBytes += 1;
            if (dcsBytes > MAX_DCS_BYTES) {
              inDcs = false;
              resetInner();
            } else {
              feedInner(0x1b);
            }
          } else if (byte === 0x5c) {
            inDcs = false;
            dcsBytes = 0;
            resetInner();
          } else {
            inDcs = false;
            dcsBytes = 0;
            resetInner();
            feedNormalByte(0x1b);
            feedNormalByte(byte);
          }
        } else if (byte === 0x1b) {
          dcsEscape = true;
        } else {
          dcsBytes += 1;
          if (dcsBytes > MAX_DCS_BYTES) {
            inDcs = false;
            resetInner();
          } else {
            feedInner(byte);
          }
        }
      }
    },
  };
}
