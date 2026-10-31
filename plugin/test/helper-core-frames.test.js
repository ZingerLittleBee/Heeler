// The Helper and the app read the same vectors (ADR 0033), so the two never
// disagree about the framed protocol or a session's name.

import { suite, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  FRAME_KIND,
  FrameDecoder,
  LineBuffer,
  creditFrame,
  encodeFrame,
  helloLine,
  requestFrame,
} from "../helper/core/frames.js";
import { normalizeSessionName } from "../helper/core/session-name.js";

const readVector = (name) => JSON.parse(readFileSync(new URL(`../test-vectors/${name}`, import.meta.url), "utf8"));
const frames = readVector("herdr-core-frames-v1.json");
const sessionNames = readVector("herdr-core-session-names-v1.json");

const bytes = (hex) => Buffer.from(hex, "hex");

function decodeAll(input) {
  const decoder = new FrameDecoder();
  decoder.append(input);
  const decoded = [];
  for (let frame = decoder.next(); frame !== null; frame = decoder.next()) decoded.push(frame);
  return { decoded, decoder };
}

suite("frame vectors", () => {
  for (const vector of frames.frames) {
    test(`${vector.name} decodes and encodes back to its bytes`, () => {
      const { decoded, decoder } = decodeAll(bytes(vector.bytes));
      assert.equal(decoded.length, 1);
      assert.equal(decoder.bufferedByteCount, 0);
      assert.equal(encodeFrame(decoded[0]).toString("hex"), vector.bytes);
    });
  }

  test("a frame's fields are where the vector's header puts them", () => {
    const [close] = decodeAll(bytes(frames.frames.find((v) => v.name === "close-program-ended").bytes)).decoded;
    assert.equal(close.channel, 3);
    assert.equal(close.kind, FRAME_KIND.close);
    assert.equal(JSON.parse(close.payload).reason, "exited");
  });

  test("credit encodes as the captured 256 KiB grant", () => {
    const vector = frames.frames.find((v) => v.name === "credit-256-kib");
    assert.equal(creditFrame(2, 256 * 1024).toString("hex"), vector.bytes);
  });

  for (const vector of frames.exchanges) {
    test(`the ${vector.name} request encodes to its captured bytes`, () => {
      const { id } = JSON.parse(decodeAll(bytes(vector.requestFrame)).decoded[0].payload);
      assert.equal(requestFrame(id, vector.method, vector.params).toString("hex"), vector.requestFrame);
    });

    test(`the ${vector.name} reply decodes to its result and encodes back`, () => {
      const { decoded } = decodeAll(bytes(vector.replyFrame));
      assert.equal(decoded.length, 1);
      assert.equal(decoded[0].channel, 0);
      assert.equal(decoded[0].kind, FRAME_KIND.data);
      assert.deepEqual(JSON.parse(decoded[0].payload).result, vector.result);
      assert.equal(encodeFrame(decoded[0]).toString("hex"), vector.replyFrame);
    });
  }

  for (const vector of frames.eventFrames) {
    test(`${vector.name} splits into its ${vector.lines} lines and encodes back`, () => {
      const { decoded, decoder } = decodeAll(bytes(vector.bytes));
      assert.equal(decoder.bufferedByteCount, 0);
      assert.equal(Buffer.concat(decoded.map(encodeFrame)).toString("hex"), vector.bytes);
      const lines = new LineBuffer();
      const found = decoded.flatMap((frame) => lines.append(frame.payload));
      assert.equal(found.length, vector.lines);
      for (const line of found) assert.equal(JSON.parse(line).method, "event");
    });

    test(`${vector.name} decodes the same one byte at a time`, () => {
      const decoder = new FrameDecoder();
      const decoded = [];
      for (const byte of bytes(vector.bytes)) {
        decoder.append(Buffer.from([byte]));
        for (let frame = decoder.next(); frame !== null; frame = decoder.next()) decoded.push(frame);
      }
      assert.equal(Buffer.concat(decoded.map(encodeFrame)).toString("hex"), vector.bytes);
    });
  }

  for (const vector of [...frames.events]) {
    test(`the ${vector.name} event line survives a cut anywhere`, () => {
      const line = Buffer.from(vector.line, "utf8");
      const lines = new LineBuffer();
      const cut = Math.floor(line.length / 2);
      assert.deepEqual(lines.append(line.subarray(0, cut)), []);
      const [found, ...rest] = lines.append(line.subarray(cut));
      assert.deepEqual(rest, []);
      assert.deepEqual(JSON.parse(found), JSON.parse(vector.line));
    });
  }
});

suite("the frame codec's edges", () => {
  test("a multi-byte character cut across two frames is not damaged", () => {
    const line = Buffer.from('{"title":"東京"}\n', "utf8");
    const lines = new LineBuffer();
    const cut = line.indexOf(Buffer.from("東")) + 1;
    assert.deepEqual(lines.append(line.subarray(0, cut)), []);
    assert.equal(JSON.parse(lines.append(line.subarray(cut))[0]).title, "東京");
  });

  test("a header announcing more than 16 MiB is refused for good", () => {
    const decoder = new FrameDecoder();
    const header = Buffer.alloc(9);
    header.writeUInt32LE(16 * 1024 * 1024 + 1, 5);
    decoder.append(header);
    assert.throws(() => decoder.next(), /16 MiB/);
    decoder.append(bytes(frames.frames[0].bytes));
    assert.throws(() => decoder.next(), /16 MiB/);
  });

  test("a frame of an unknown kind is skipped", () => {
    const unknown = Buffer.from("00000000" + "63" + "01000000" + "aa", "hex");
    const { decoded } = decodeAll(Buffer.concat([unknown, bytes(frames.frames[0].bytes)]));
    assert.equal(decoded.length, 1);
    assert.equal(decoded[0].kind, FRAME_KIND.data);
  });

  test("hello asks for generation 1 in frames and names no core", () => {
    const line = helloLine();
    assert.equal(line.at(-1), 0x0a);
    assert.deepEqual(JSON.parse(line), {
      jsonrpc: "2.0",
      id: "hello",
      method: "hello",
      params: { generation: 1, framed: true },
    });
  });
});

suite("core session names", () => {
  for (const vector of sessionNames.cases) {
    test(vector.name, () => {
      assert.equal(normalizeSessionName(vector.raw), vector.normalized);
    });
  }

  test("spaces are what Rust's trim takes, not what JavaScript's does", () => {
    // herdr-core's str::trim keeps a byte order mark and takes a next line.
    assert.equal(normalizeSessionName("\u0085work\u0085"), "work");
    assert.equal(normalizeSessionName("\uFEFFwork"), "\uFEFFwork");
  });
});
