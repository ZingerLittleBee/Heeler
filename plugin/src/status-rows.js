// Conversational Live Activity rows (docs/agents/live-activity-contract.md,
// "Conversational rows").
//
// Pure: turns one herdr AgentInfo into at most three rows of plain-text spans,
// each row at most ROW_LIMIT graphemes. Every word on a row is either a herdr
// field (cleaned and clipped) or one of the fixed labels below; nothing is
// summarised, guessed or inferred.

import { strippedSidebarTitle } from "./activity-rows.js";

export const ROW_LIMIT = 80;

const GRAPHEMES = new Intl.Segmenter("en", { granularity: "grapheme" });
// Controls (Cc), format characters such as bidi overrides (Cf), line and
// paragraph separators (Zl, Zp), lone surrogates (Cs) and the Hangul filler
// characters that render as blanks. U+200C/U+200D stay: emoji sequences and
// some scripts need them.
const UNSAFE = /(?![‌‍])[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}ᅟᅠㅤﾠ]/gu;
const STATE_LABELS = new Map([["working", "Working"], ["blocked", "Blocked"], ["done", "Turn ended"]]);
const SEPARATOR = " · ";

const split = (text) => Array.from(GRAPHEMES.segment(text), ({ segment }) => segment);

/** Untrusted display text: line breaks become spaces, unsafe characters go, whitespace collapses. */
export function cleanText(value) {
  if (typeof value !== "string") return "";
  return value.replace(/[\t\n\r]+/g, " ").replace(UNSAFE, "").replace(/\s{2,}/g, " ").trim();
}

/**
 * Fit parts (`{text, bold?, dim?, sep?}`) into `limit` graphemes in total.
 * Overflow keeps the first `limit - 1` graphemes and ends in `…`; a cut
 * separator is dropped rather than left dangling, and a trailing joiner or
 * ellipsis is removed before the `…` goes on.
 */
export function clipRow(parts, limit = ROW_LIMIT) {
  const cells = parts.flatMap((part, index) => split(part.text).map((grapheme) => ({ grapheme, index })));
  const overflow = cells.length > limit;
  const out = [];
  for (const { grapheme, index } of overflow ? cells.slice(0, limit - 1) : cells) {
    if (out.at(-1)?.index === index) out.at(-1).text += grapheme;
    else out.push({ ...parts[index], text: grapheme, index });
  }
  while (overflow && out.at(-1)?.sep) out.pop();
  if (overflow) {
    const last = out.pop() ?? { text: "" };
    out.push({ ...last, text: `${last.text.replace(/[\s‌‍…]+$/u, "")}…` });
  }
  return out.map(({ sep, index, ...span }) => span);
}

function join(...parts) {
  return parts.filter(Boolean).flatMap((part, i) => (i === 0 ? [part] : [{ text: SEPARATOR, sep: true }, part]));
}

/** The terminal's own working title (spinner glyph removed), or null. */
export function workingTitle(agent) {
  const stripped = typeof agent?.terminal_title_stripped === "string" && agent.terminal_title_stripped.trim()
    ? agent.terminal_title_stripped
    : strippedSidebarTitle(agent?.terminal_title);
  return cleanText(stripped) || null;
}

/** The IANA zone to render in: a valid `activity_time_zone`, else the host's. */
export function displayTimeZone(configured) {
  if (typeof configured === "string" && configured.length > 0) {
    try {
      return new Intl.DateTimeFormat("en-US", { timeZone: configured }).resolvedOptions().timeZone;
    } catch {
      // An unknown zone name falls back to the host zone.
    }
  }
  return new Intl.DateTimeFormat("en-US").resolvedOptions().timeZone;
}

/** `{hhmm, zone, day, date}` of one instant in `timeZone` (24-hour, `en-US` labels). */
export function clockParts(ms, timeZone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone, hourCycle: "h23", hour: "2-digit", minute: "2-digit",
    year: "numeric", month: "short", day: "numeric", timeZoneName: "short",
  }).formatToParts(new Date(ms)).map(({ type, value }) => [type, value]));
  return {
    hhmm: `${parts.hour}:${parts.minute}`,
    zone: parts.timeZoneName,
    day: `${parts.year}-${parts.month}-${parts.day}`,
    date: `${parts.month} ${parts.day}`,
  };
}

/**
 * Row 3 times: the start `[Mon D ]HH:MM[ zone]` (null when unknown) and
 * `updated HH:MM zone`. The start names its date when that differs from the
 * date of the update, and its own zone label when that differs (a DST change
 * between the two instants).
 */
export function freshness(sinceMs, asOfMs, timeZone) {
  const asOf = clockParts(asOfMs, timeZone);
  let start = null;
  if (Number.isFinite(sinceMs)) {
    const began = clockParts(sinceMs, timeZone);
    const date = began.day === asOf.day ? "" : `${began.date} `;
    const zone = began.zone === asOf.zone ? "" : ` ${began.zone}`;
    start = `${date}${began.hhmm}${zone}`;
  }
  return { start, updated: `updated ${asOf.hhmm} ${asOf.zone}` };
}

/**
 * @param {{agent: object, status: string, workspace?: string|null,
 *   sinceMs?: number|null, asOfMs: number, timeZone?: string}} input
 *   `sinceMs`: when the plugin saw this status begin; null or absent means unknown.
 * @returns {object[][]} one to three nonempty rows of spans
 */
export function conversationalRows({ agent, status, workspace, sinceMs, asOfMs, timeZone }) {
  const title = workingTitle(agent);
  const identity = [agent.display_agent, agent.name, agent.agent].map(cleanText).find(Boolean) ?? "unknown";
  const workspaceText = cleanText(workspace);
  const { start, updated } = freshness(sinceMs, asOfMs, timeZone);
  return [
    join({ text: identity, bold: true }, workspaceText && { text: workspaceText }),
    title ? [{ text: title }] : [],
    // An unknown start is left out rather than shown as "unknown".
    [{ text: STATE_LABELS.get(status), bold: true }, start && { text: ` ${status === "done" ? "at" : "since"} ${start}`, dim: true },
      { text: SEPARATOR, sep: true }, { text: updated, dim: true }].filter(Boolean),
  ].map((row) => clipRow(row)).filter((row) => row.length > 0);
}
