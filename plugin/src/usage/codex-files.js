import { access, readdir, realpath, stat } from "node:fs/promises";
import { constants, createReadStream } from "node:fs";
import { spawn } from "node:child_process";
import { basename, delimiter, join, resolve } from "node:path";
import zlib from "node:zlib";
import { jsonLines } from "./json-lines.js";

export class ArchiveUnavailableError extends Error {
  constructor() { super("No zstd decoder is available."); this.name = "ArchiveUnavailableError"; }
}

/** One physical representation per rollout, with the live plain file preferred. */
export async function codexFiles(roots, cutoff) {
  const selected = new Map();
  const seenRoots = new Set();
  for (const root of roots) {
    let actual;
    try { actual = await realpath(root); }
    catch (error) { if (error.code === "ENOENT") continue; throw error; }
    if (seenRoots.has(actual)) continue;
    seenRoots.add(actual);
    async function visit(directory, archived) {
      let entries;
      try { entries = await readdir(directory, { withFileTypes: true }); }
      catch (error) { if (error.code === "ENOENT") return; throw error; }
      for (const entry of entries) {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) { await visit(path, archived); continue; }
        if (!entry.isFile() || !/^rollout-.+\.jsonl(?:\.zst)?$/.test(entry.name)) continue;
        const metadata = await stat(path);
        const compressed = path.endsWith(".zst");
        const logicalPath = compressed ? path.slice(0, -4) : path;
        const key = JSON.stringify([actual, basename(logicalPath)]);
        const priority = Number(!archived) * 2 + Number(!compressed);
        const previous = selected.get(key);
        if (!previous || priority > previous.priority) {
          selected.set(key, { path, logicalPath, compressed, dev: metadata.dev, ino: metadata.ino,
            size: metadata.size, mtimeMs: metadata.mtimeMs, priority });
        }
      }
    }
    await visit(join(actual, "sessions"), false);
    await visit(join(actual, "archived_sessions"), true);
  }
  return [...selected.values()].filter(file => file.mtimeMs >= cutoff)
    .sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path))
    .map(({ priority, ...file }) => file);
}

/** Offsets count complete decompressed bytes, including malformed lines. */
export async function* codexLines(file, runtime, onChunk = () => {}, start = 0) {
  let source;
  let input;
  let child;
  let childResult;
  if (file.compressed && typeof zlib.createZstdDecompress !== "function") {
    const executable = await externalZstd(runtime.env?.PATH);
    if (!executable) throw new ArchiveUnavailableError();
    const env = Object.fromEntries(Object.entries(runtime.env || {}).filter(([, value]) => typeof value === "string"));
    child = spawn(executable, ["-dc", "--", file.path], { env, stdio: ["ignore", "pipe", "ignore"] });
    childResult = new Promise(resolveResult => {
      child.once("error", error => resolveResult({ error }));
      child.once("close", (code, signal) => resolveResult({ code, signal }));
    });
    input = child.stdout;
  } else {
    source = createReadStream(file.path, { start: file.compressed ? 0 : start });
    input = file.compressed ? source.pipe(zlib.createZstdDecompress()) : source;
    if (input !== source) source.on("error", error => input.destroy(error));
  }
  try {
    yield* jsonLines(input, start, file.compressed ? start : 0, onChunk);
    if (childResult) {
      const result = await childResult;
      if (result.error || result.code !== 0) throw new Error("Could not decompress the Codex archive.");
    }
  } finally {
    input.destroy();
    source?.destroy();
    if (child) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await childResult;
    }
  }
}

async function externalZstd(path) {
  if (typeof path !== "string") return null;
  for (const directory of path.split(delimiter)) {
    const candidate = resolve(directory, "zstd");
    try {
      if (!(await stat(candidate)).isFile()) continue;
      await access(candidate, constants.X_OK);
      return candidate;
    } catch { /* Try the next executable on the recorded PATH. */ }
  }
  return null;
}
