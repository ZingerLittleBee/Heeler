import { test, suite } from "node:test";
import assert from "node:assert/strict";
import QRCode from "qrcode";

import { encodePairingCode } from "../src/envelope.js";
import {
  measureTerminalQr,
  renderTerminalQr,
  OCTANT_TABLE,
} from "../src/terminal-qr.js";

const typicalCode = encodePairingCode({
  addresses: ["192.168.1.42", "100.101.102.103", "fd7a:115c:a1e0::1"],
  port: 22,
  username: "zingerbee",
  hostKeyFingerprint: "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg",
  bootstrapSeed: Buffer.alloc(32, 7),
  expiresAt: 1753305600,
});

const bitsByOctant = new Map(OCTANT_TABLE.map((ch, bits) => [ch, bits]));

suite("terminal QR", () => {
  test("a typical Pairing Code stays within a herdr popup", () => {
    const { rows, columns } = measureTerminalQr(typicalCode);
    assert.ok(columns <= 40, `expected <= 40 columns, got ${columns}`);
    assert.ok(rows <= 20, `expected <= 20 rows, got ${rows}`);
  });

  test("packs a 2×4 octant cell so the QR is square in a 1:2 terminal grid", () => {
    const qr = QRCode.create("HELLO", { errorCorrectionLevel: "L" });
    const { rows, columns } = measureTerminalQr("HELLO");
    const total = qr.modules.size + 4;
    assert.equal(columns, Math.ceil(total / 2));
    assert.equal(rows, Math.ceil(total / 4));
    assert.ok(
      Math.abs(columns - 2 * rows) <= 2,
      `expected columns ≈ 2×rows for a square QR, got ${columns}×${rows}`,
    );
  });

  test("the octant table matches Unicode 16 (spot checks)", () => {
    assert.equal(OCTANT_TABLE.length, 256);
    assert.equal(new Set(OCTANT_TABLE).size, 256);
    assert.equal(OCTANT_TABLE[0x00], " ");
    assert.equal(OCTANT_TABLE[0x04], String.fromCodePoint(0x1cd00));
    assert.equal(OCTANT_TABLE[0x0f], "▀");
    assert.equal(OCTANT_TABLE[0x55], "▌");
    assert.equal(OCTANT_TABLE[0xf0], "▄");
    assert.equal(OCTANT_TABLE[0xfe], String.fromCodePoint(0x1cde5));
    assert.equal(OCTANT_TABLE[0xff], "█");
  });

  test("emits solid inverted blocks a camera can read", () => {
    const rendered = renderTerminalQr("HELLO");
    assert.match(rendered, /\u001b\[47m\u001b\[30m/);
    assert.match(rendered, /[\u{1CD00}-\u{1CDE5}▀-▟]/u);
    assert.doesNotMatch(rendered, /[\u2800-\u28FF]/);
  });

  test("round-trips modules so finder patterns stay intact", () => {
    const qr = QRCode.create(typicalCode, { errorCorrectionLevel: "L" });
    const { modules } = qr;
    const quiet = 2;
    const lines = renderTerminalQr(typicalCode)
      .replace(/\u001b\[[0-9;]*m/g, "")
      .split("\n")
      .map((line) => [...line]);
    let mismatches = 0;
    for (let y = 0; y < modules.size; y++) {
      for (let x = 0; x < modules.size; x++) {
        const cell = lines[Math.floor((y + quiet) / 4)][Math.floor((x + quiet) / 2)];
        const bits = bitsByOctant.get(cell);
        const bit = 1 << (((y + quiet) % 4) * 2 + ((x + quiet) % 2));
        const dark = (bits & bit) !== 0;
        if (dark !== Boolean(modules.get(y, x))) mismatches++;
      }
    }
    assert.equal(mismatches, 0);
  });
});
