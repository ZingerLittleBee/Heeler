// Square terminal QR via octants (2x4 modules per cell, Unicode 16).
// A cell is about twice as tall as it is wide, so two modules per column and
// four per row keep the module square -- the same aspect as half-blocks at a
// quarter of the area, which is what lets a version-11 Pairing Code fit a
// popup. Unlike braille (same geometry), octant blocks fill the cell, so dark
// regions are solid ink and finder patterns stay camera-readable. Requires a
// terminal that renders Symbols for Legacy Computing Supplement (Ghostty,
// Kitty, and other terminals with built-in block glyph synthesis do).

import QRCode from "qrcode";

const RESET = "\u001b[0m";
const WHITE_BG_BLACK_FG = "\u001b[47m\u001b[30m";

const CELL_WIDTH = 2;
const CELL_HEIGHT = 4;
const QUIET_ZONE_MODULES = 2;

// The octant block U+1CD00..U+1CDE5 encodes every 2x4 pattern in increasing
// bit order (bit n = octant position n+1, positions row-major top-left to
// bottom-right), skipping the 26 patterns that reuse older characters:
// space, full/half/quarter blocks, quadrants, and the Unicode 16 single-cell
// and middle-column fills. Verified against UnicodeData.txt 16.0.
const OCTANT_EXCEPTIONS = new Map([
  [0x00, 0x20], [0x01, 0x1cea8], [0x02, 0x1ceab], [0x03, 0x1fb82],
  [0x05, 0x2598], [0x0a, 0x259d], [0x0f, 0x2580], [0x14, 0x1fbe6],
  [0x28, 0x1fbe7], [0x3f, 0x1fb85], [0x40, 0x1cea3], [0x50, 0x2596],
  [0x55, 0x258c], [0x5a, 0x259e], [0x5f, 0x259b], [0x80, 0x1cea0],
  [0xa0, 0x2597], [0xa5, 0x259a], [0xaa, 0x2590], [0xaf, 0x259c],
  [0xc0, 0x2582], [0xf0, 0x2584], [0xf5, 0x2599], [0xfa, 0x259f],
  [0xfc, 0x2586], [0xff, 0x2588],
]);

export const OCTANT_TABLE = (() => {
  const table = [];
  let next = 0x1cd00;
  for (let bits = 0; bits < 256; bits++) {
    const codePoint = OCTANT_EXCEPTIONS.get(bits) ?? next++;
    table.push(String.fromCodePoint(codePoint));
  }
  return table;
})();

function isDark(modules, x, y) {
  if (x < 0 || y < 0 || x >= modules.size || y >= modules.size) {
    return false;
  }
  return Boolean(modules.get(y, x));
}

function packCell(modules, originX, originY) {
  let bits = 0;
  for (let row = 0; row < CELL_HEIGHT; row++) {
    for (let column = 0; column < CELL_WIDTH; column++) {
      if (isDark(modules, originX + column, originY + row)) {
        bits |= 1 << (row * CELL_WIDTH + column);
      }
    }
  }
  return OCTANT_TABLE[bits];
}

/**
 * Render `text` as a compact inverted terminal QR (black modules on white).
 *
 * @param {string} text
 * @returns {string}
 */
export function renderTerminalQr(text) {
  const qr = QRCode.create(text, { errorCorrectionLevel: "L" });
  const { modules } = qr;
  const total = modules.size + QUIET_ZONE_MODULES * 2;
  const columns = Math.ceil(total / CELL_WIDTH);
  const rows = Math.ceil(total / CELL_HEIGHT);
  const lines = [];

  for (let row = 0; row < rows; row++) {
    let line = WHITE_BG_BLACK_FG;
    for (let col = 0; col < columns; col++) {
      const x = col * CELL_WIDTH - QUIET_ZONE_MODULES;
      const y = row * CELL_HEIGHT - QUIET_ZONE_MODULES;
      line += packCell(modules, x, y);
    }
    line += RESET;
    lines.push(line);
  }

  return lines.join("\n");
}

export function measureTerminalQr(text) {
  const rendered = renderTerminalQr(text);
  const stripped = rendered.replace(/\u001b\[[0-9;]*m/g, "");
  const rows = stripped.split("\n");
  return {
    rendered,
    rows: rows.length,
    columns: rows.reduce(
      (max, line) => Math.max(max, [...line].length),
      0,
    ),
  };
}
