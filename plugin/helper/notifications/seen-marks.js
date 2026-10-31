// What a device has already seen on this Host (ADR 0033): one file per device in the
// Helper's directory, named from its Notification Key id and never from a Terminal
// address. The app writes it over SFTP, and the format is pinned by
// plugin/test-vectors/herdr-core-seen-mark-v1.json. A file that cannot be read means
// no marks, which leaves its Agents counted as Done, as a mark that failed to write.

import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const VERSION = 1;

export const seenMarkFileName = (keyId) => `seen-${keyId}.json`;

/** `{core, marks: Map(terminal -> {turn, word})}`, or null for a file this cannot trust. */
export function parseSeenMarks(text, keyId) {
  let file;
  try {
    file = JSON.parse(text);
  } catch {
    return null;
  }
  if (file?.v !== VERSION || file.device !== keyId || typeof file.core !== "string" || !Array.isArray(file.marks)) {
    return null;
  }
  const marks = new Map();
  for (const mark of file.marks) {
    if (typeof mark?.terminal !== "string" || !Number.isSafeInteger(mark.turn)) continue;
    marks.set(mark.terminal, { turn: mark.turn, word: typeof mark.word === "string" ? mark.word : null });
  }
  return { core: file.core, marks };
}

/** This device's marks of `core`'s Terminals. Addresses belong to one core. */
export function readSeenMarks(directory, keyId, core) {
  let text;
  try {
    text = readFileSync(join(directory, seenMarkFileName(keyId)), "utf8");
  } catch {
    return new Map();
  }
  const file = parseSeenMarks(text, keyId);
  return file?.core === core ? file.marks : new Map();
}

/** This device's mark of one Terminal of `core`, or null. */
export function readSeenMark(directory, keyId, core, terminal) {
  return readSeenMarks(directory, keyId, core).get(terminal) ?? null;
}

/** A device's marks go with its registration. */
export function removeSeenMarks(directory, keyId) {
  rmSync(join(directory, seenMarkFileName(keyId)), { force: true });
}
