// Compact terminal QR via sextants (2x3 modules per cell, Unicode 13).
// Sextants render on Ghostty/kitty/WezTerm/foot plus iTerm2, VS Code, and
// Alacritty; octants (Unicode 16) miss those last three. The trade-off is a
// ~1.33-1.47 vertical stretch (2H/3W at typical 1:2-1:2.2 cells): inside
// Apple's detector tolerance, at the edge of ZXing's ±40% finder-pattern
// budget. See docs/research/terminal-qr-rendering.md (§Glyph availability,
// §Aspect ratio). Unlike braille (same 2x3 geometry), sextant blocks fill
// the cell, so dark regions are solid ink and finder patterns stay
// camera-readable. Keep the white-background wrapper: unwrapped block
// glyphs inherit the terminal theme and become a photographic negative
// on light-on-dark (research note §Polarity).

import QRCode from "qrcode";

const RESET = "\u001b[0m";
const WHITE_BG_BLACK_FG = "\u001b[47m\u001b[30m";

const CELL_WIDTH = 2;
const CELL_HEIGHT = 3;
const QUIET_ZONE_MODULES = 4;
const ERROR_CORRECTION_LEVEL = "M";

// The sextant block U+1FB00..U+1FB3B encodes 60 of the 64 2x3 patterns.
// Bit n (0..5) is the dot at column n%2, row n/2 (row-major, top-left).
// Four patterns reuse older block characters. Verified against
// UnicodeData.txt 16.0.
function sextantChar(value) {
  if (value === 0) return " ";
  if (value === 21) return "\u258C";
  if (value === 42) return "\u2590";
  if (value === 63) return "\u2588";
  return String.fromCodePoint(
    0x1fb00 + (value - 1 - (value > 21 ? 1 : 0) - (value > 42 ? 1 : 0)),
  );
}

export const SEXTANT_TABLE = Array.from({ length: 64 }, (_, value) =>
  sextantChar(value),
);

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
  return SEXTANT_TABLE[bits];
}

function createQr(payload) {
  const options = { errorCorrectionLevel: ERROR_CORRECTION_LEVEL };
  if (payload instanceof Uint8Array) {
    return QRCode.create([{ data: payload, mode: "byte" }], options);
  }
  return QRCode.create(payload, options);
}

/**
 * Render `payload` as a compact inverted terminal QR (black modules on white).
 *
 * @param {string | Uint8Array} payload
 * @returns {string}
 */
export function renderTerminalQr(payload) {
  const qr = createQr(payload);
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

export function measureTerminalQr(payload) {
  const rendered = renderTerminalQr(payload);
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
