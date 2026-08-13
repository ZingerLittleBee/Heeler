import { test, suite } from "node:test";
import assert from "node:assert/strict";
import QRCode from "qrcode";

import { encodePairingCode } from "../src/envelope.js";
import {
  measureTerminalQr,
  renderTerminalQr,
  SEXTANT_TABLE,
} from "../src/terminal-qr.js";

const typicalCode = encodePairingCode({
  addresses: ["192.168.1.42", "100.101.102.103", "fd7a:115c:a1e0::1"],
  port: 22,
  username: "zingerbee",
  hostKeyFingerprint: "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg",
  bootstrapSeed: Buffer.alloc(32, 7),
  expiresAt: 1753305600,
});

const bitsBySextant = new Map(SEXTANT_TABLE.map((ch, bits) => [ch, bits]));

suite("terminal QR", () => {
  test("a typical Pairing Code stays within a herdr popup", () => {
    const { rows, columns } = measureTerminalQr(typicalCode);
    assert.ok(columns <= 40, `expected <= 40 columns, got ${columns}`);
    assert.ok(rows <= 26, `expected <= 26 rows, got ${rows}`);
  });

  test("packs a 2×3 sextant cell (modules + 4-module quiet zone)", () => {
    const qr = QRCode.create("HELLO", { errorCorrectionLevel: "M" });
    const { rows, columns } = measureTerminalQr("HELLO");
    const total = qr.modules.size + 8;
    assert.equal(columns, Math.ceil(total / 2));
    assert.equal(rows, Math.ceil(total / 3));
  });

  test("the sextant table matches Unicode 13 (spot checks)", () => {
    assert.equal(SEXTANT_TABLE.length, 64);
    assert.equal(new Set(SEXTANT_TABLE).size, 64);
    assert.equal(SEXTANT_TABLE[0], " ");
    assert.equal(SEXTANT_TABLE[1], String.fromCodePoint(0x1fb00));
    assert.equal(SEXTANT_TABLE[21], "▌");
    assert.equal(SEXTANT_TABLE[42], "▐");
    assert.equal(SEXTANT_TABLE[63], "█");
    const blockChars = SEXTANT_TABLE.filter((ch) => {
      const cp = ch.codePointAt(0);
      return cp >= 0x1fb00 && cp <= 0x1fb3b;
    });
    assert.equal(blockChars.length, 60);
    assert.equal(new Set(blockChars).size, 60);
  });

  test("emits solid inverted blocks a camera can read", () => {
    const rendered = renderTerminalQr("HELLO");
    assert.match(rendered, /\u001b\[47m\u001b\[30m/);
    assert.match(rendered, /[\u{1FB00}-\u{1FB3B}▌▐█]/u);
    assert.doesNotMatch(rendered, /[\u2800-\u28FF]/);
    assert.doesNotMatch(rendered, /[\u{1CD00}-\u{1CDE5}]/u);
  });

  test("renders a Uint8Array payload in byte mode", () => {
    const payload = Uint8Array.from([0x00, 0xff, 0x10, 0x80, 0x7f]);
    const rendered = renderTerminalQr(payload);
    assert.match(rendered, /\u001b\[47m\u001b\[30m/);
    assert.match(rendered, /[\u{1FB00}-\u{1FB3B}▌▐█]/u);
    const qr = QRCode.create([{ data: payload, mode: "byte" }], {
      errorCorrectionLevel: "M",
    });
    const { rows, columns } = measureTerminalQr(payload);
    const total = qr.modules.size + 8;
    assert.equal(columns, Math.ceil(total / 2));
    assert.equal(rows, Math.ceil(total / 3));
  });

  test("round-trips modules so finder patterns stay intact", () => {
    const qr = QRCode.create(typicalCode, { errorCorrectionLevel: "M" });
    const { modules } = qr;
    const quiet = 4;
    const lines = renderTerminalQr(typicalCode)
      .replace(/\u001b\[[0-9;]*m/g, "")
      .split("\n")
      .map((line) => [...line]);
    let mismatches = 0;
    for (let y = 0; y < modules.size; y++) {
      for (let x = 0; x < modules.size; x++) {
        const cell = lines[Math.floor((y + quiet) / 3)][Math.floor((x + quiet) / 2)];
        const bits = bitsBySextant.get(cell);
        const bit = 1 << (((y + quiet) % 3) * 2 + ((x + quiet) % 2));
        const dark = (bits & bit) !== 0;
        if (dark !== Boolean(modules.get(y, x))) mismatches++;
      }
    }
    assert.equal(mismatches, 0);
  });
});
