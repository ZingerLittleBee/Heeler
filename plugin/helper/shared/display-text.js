// Display-string helpers shared by the notify and Live Activity hooks.
//
// Agent terminal titles and host labels are whole phrases and run long. The
// app trims to the same length for display; trimming here keeps encrypted
// payloads small on the wire too.

export const DISPLAY_LIMIT = 80;

/** A non-empty string or null; the display fields are all best-effort. */
export function optionalText(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** Trim a display string to DISPLAY_LIMIT graphemes, ellipsis included. */
export function forDisplay(value) {
  const text = optionalText(value);
  if (text === null) return null;
  const graphemes = [...text];
  if (graphemes.length <= DISPLAY_LIMIT) return text;
  return `${graphemes.slice(0, DISPLAY_LIMIT - 1).join("").trimEnd()}…`;
}
