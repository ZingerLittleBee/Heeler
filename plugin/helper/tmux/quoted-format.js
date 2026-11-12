// Reads `#{q:...}` format fields printed by tmux 3.3 and later.
//
// `format_quote_shell` (`#{q:...}`) prefixes every ASCII byte in
// `|&;<>()$`\"'*?[# =%` with `\`. On tmux 3.4 and 3.5a, `cmdq_print` runs the
// formatted text through `utf8_stravisx(..., VIS_OCTAL|VIS_CSTYLE|VIS_NOSLASH)`,
// turning control bytes other than TAB and LF into `\a`, `\b`, `\f`, `\r`, `\v`
// or 4-byte octal `\ooo`, and on tmux 3.4 also turning `$` before `[A-Za-z_{]`
// into `\$` (so `\$HOME` from `#{q:...}` arrives as `\\$HOME`).
//
// Because `format_quote_shell` doubles every literal `\` (`2k` backslashes) and
// escapes every literal space and `$`, an unescaped space (`0` preceding `\`)
// unambiguously ends a `#{q:...}` field, `b >= 1` backslashes before `$` carry
// `Math.floor((b - 1) / 2)` literal backslashes plus `$`, and odd `b = 2k + 1`
// backslashes before any non-`$` byte carry `k` literal backslashes plus one
// `format_quote_shell` or `strvis` escape.

const SHELL_QUOTED_NON_SPACE = new Set(
  Buffer.from("|&;<>()$`\"'*?[#=%", "utf8"),
);
const SHELL_QUOTED_ESCAPED = new Set(
  Buffer.from("|&;<>()`\"'*?[# =%", "utf8"),
);

function cEscapeByte(code) {
  switch (code) {
    case 0x61:
      return 0x07; // \a
    case 0x62:
      return 0x08; // \b
    case 0x66:
      return 0x0c; // \f
    case 0x72:
      return 0x0d; // \r
    case 0x76:
      return 0x0b; // \v
    default:
      return -1;
  }
}

function isOctalDigit(code) {
  return code >= 0x30 && code <= 0x37;
}

/**
 * Reads `count` space-terminated `#{q:...}` fields followed by `.\n` from
 * `buffer` starting at `startOffset`. Returns `{ values, nextOffset }` or `null`.
 */
export function readQuotedTmuxRecord(buffer, startOffset, count) {
  const end = buffer.length;
  let cursor = startOffset;
  const values = [];

  for (let field = 0; field < count; field += 1) {
    const bytes = [];
    let closed = false;

    while (cursor < end) {
      let slashes = 0;
      while (cursor < end && buffer[cursor] === 0x5c) {
        slashes += 1;
        cursor += 1;
      }
      if (cursor >= end) return null;
      const b = buffer[cursor];

      if (slashes === 0) {
        if (b === 0x20) {
          cursor += 1;
          closed = true;
          break;
        }
        if (SHELL_QUOTED_NON_SPACE.has(b)) return null;
        bytes.push(b);
        cursor += 1;
        continue;
      }

      if (b === 0x24) {
        const rawSlashes = Math.floor((slashes - 1) / 2);
        for (let k = 0; k < rawSlashes; k += 1) bytes.push(0x5c);
        bytes.push(0x24);
        cursor += 1;
        continue;
      }

      const half = Math.floor(slashes / 2);
      for (let k = 0; k < half; k += 1) bytes.push(0x5c);
      if (slashes % 2 === 0) continue;

      if (SHELL_QUOTED_ESCAPED.has(b)) {
        bytes.push(b);
        cursor += 1;
        continue;
      }

      const cEsc = cEscapeByte(b);
      if (cEsc >= 0) {
        bytes.push(cEsc);
        cursor += 1;
        continue;
      }

      if (
        cursor + 2 < end &&
        isOctalDigit(b) &&
        isOctalDigit(buffer[cursor + 1]) &&
        isOctalDigit(buffer[cursor + 2])
      ) {
        const value = ((b - 0x30) << 6) | ((buffer[cursor + 1] - 0x30) << 3) | (buffer[cursor + 2] - 0x30);
        if (value > 0xff) return null;
        bytes.push(value);
        cursor += 3;
        continue;
      }

      return null;
    }

    if (!closed) return null;
    values.push(Buffer.from(bytes).toString("utf8"));
  }

  if (cursor + 1 >= end || buffer[cursor] !== 0x2e || buffer[cursor + 1] !== 0x0a) return null;
  return { values, nextOffset: cursor + 2 };
}

/**
 * Decodes the entire output of a `display-message -p` ending with `#{q:...} .`
 * into `count` string values, or `null` when malformed.
 */
export function decodeQuotedTmuxLine(stdout, count) {
  const buffer = Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout, "utf8");
  const record = readQuotedTmuxRecord(buffer, 0, count);
  if (!record || record.nextOffset !== buffer.length) return null;
  return record.values;
}
