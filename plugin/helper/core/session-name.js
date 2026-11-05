// The folder-name contract from herdr-core 0.1.13 paths.rs, pinned with the
// app's by plugin/test-vectors/herdr-core-session-names-v1.json.

const AROUND = /^\p{White_Space}+|\p{White_Space}+$/gu;
const REFUSED_CHARACTERS = /[\p{Cc}/\\:*?"<>|]/u;

/** A session's folder name, or null for a name the core refuses. */
export function normalizeSessionName(raw) {
  const name = raw.replace(AROUND, "") || "default";
  if (name === "." || name === ".." || REFUSED_CHARACTERS.test(name)) return null;
  return name;
}
