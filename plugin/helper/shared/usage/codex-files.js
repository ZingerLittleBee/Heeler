import { access, readdir, realpath, stat } from "node:fs/promises";
import { constants, createReadStream } from "node:fs";
import { spawn } from "node:child_process";
import { basename, delimiter, join, resolve } from "node:path";
import zlib from "node:zlib";
import { jsonLines } from "./json-lines.js";

export class ArchiveUnavailableError extends Error {
  constructor() { super("No zstd decoder is available."); this.name = "ArchiveUnavailableError"; }
}

/**
 * One physical representation per rollout, with the live plain file preferred.
 * An entry that cannot be listed is skipped and its logical path returned in
 * `unreadable`; only a Codex home, `sessions/` or `archived_sessions/` that
 * cannot be listed sets `rootFailed`. `older` tells whether a rollout older
 * than the window exists.
 */
export async function codexFiles(roots, cutoff) {
  const selected = new Map();
  const seenRoots = new Set();
  const unreadable = [];
  let rootFailed = false;
  const skip = (path, root) => { if (root) rootFailed = true; else unreadable.push(path); };
  for (const root of roots) {
    let actual;
    try { actual = await realpath(root); }
    catch (error) { if (error.code !== "ENOENT") rootFailed = true; continue; }
    if (seenRoots.has(actual)) continue;
    seenRoots.add(actual);
    async function visit(directory, archived, root) {
      let entries;
      try { entries = await readdir(directory, { withFileTypes: true }); }
      catch (error) { if (error.code !== "ENOENT") skip(directory, root); return; }
      for (const entry of entries) {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) { await visit(path, archived, false); continue; }
        if (!entry.isFile() || !/^rollout-.+\.jsonl(?:\.zst)?$/.test(entry.name)) continue;
        const compressed = path.endsWith(".zst");
        const logicalPath = compressed ? path.slice(0, -4) : path;
        let metadata;
        try { metadata = await stat(path); }
        catch (error) { if (error.code !== "ENOENT") skip(logicalPath, false); continue; }
        const key = JSON.stringify([actual, basename(logicalPath)]);
        const priority = Number(!archived) * 2 + Number(!compressed);
        const previous = selected.get(key);
        if (!previous || priority > previous.priority) {
          selected.set(key, { path, logicalPath, compressed, dev: metadata.dev, ino: metadata.ino,
            size: metadata.size, mtimeMs: metadata.mtimeMs, priority });
        }
      }
    }
    await visit(join(actual, "sessions"), false, true);
    await visit(join(actual, "archived_sessions"), true, true);
  }
  const files = [...selected.values()].filter(file => file.mtimeMs >= cutoff)
    .sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path))
    .map(({ priority, ...file }) => file);
  return { files, unreadable, rootFailed, older: [...selected.values()].some(file => file.mtimeMs < cutoff) };
}

/**
 * Walks zstd frame and block headers (RFC 8878) over the compressed bytes.
 * Node's decoder ends quietly on a truncated archive; an archive is complete
 * only when its last frame, block payloads and checksum are all present.
 */
export class ZstdFrames {
  #skip = 0;
  #want = 4;
  #bytes = [];
  #step = "magic";
  #checksum = false;
  #frames = 0;
  #invalid = false;

  update(chunk) {
    let index = 0;
    while (index < chunk.length && !this.#invalid) {
      if (this.#skip) {
        const skipped = Math.min(this.#skip, chunk.length - index);
        this.#skip -= skipped;
        index += skipped;
        continue;
      }
      const taken = Math.min(this.#want - this.#bytes.length, chunk.length - index);
      for (let i = 0; i < taken; i++) this.#bytes.push(chunk[index + i]);
      index += taken;
      if (this.#bytes.length === this.#want) {
        const header = Buffer.from(this.#bytes);
        this.#bytes = [];
        this.#header(header);
      }
    }
  }

  get complete() {
    return !this.#invalid && this.#frames > 0 && this.#step === "magic" && !this.#skip && !this.#bytes.length;
  }

  #header(header) {
    if (this.#step === "magic") {
      const magic = header.readUInt32LE(0);
      if (magic === 0xFD2FB528) { this.#step = "descriptor"; this.#want = 1; }
      else if ((magic & 0xFFFFFFF0) >>> 0 === 0x184D2A50) { this.#step = "skippable"; this.#want = 4; }
      else this.#invalid = true;
    } else if (this.#step === "skippable") {
      this.#skip = header.readUInt32LE(0);
      this.#step = "magic"; this.#want = 4;
    } else if (this.#step === "descriptor") {
      const descriptor = header[0];
      const single = (descriptor >> 5) & 1;
      if (descriptor & 0b1000) { this.#invalid = true; return; }
      this.#checksum = Boolean(descriptor & 0b100);
      // Window descriptor, dictionary id and frame content size precede the blocks.
      this.#skip = (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + [single, 2, 4, 8][descriptor >> 6];
      this.#step = "block"; this.#want = 3;
    } else {
      const block = header[0] | (header[1] << 8) | (header[2] << 16);
      const type = (block >> 1) & 3;
      if (type === 3) { this.#invalid = true; return; }
      // An RLE block stores one byte whatever its regenerated size.
      this.#skip = type === 1 ? 1 : block >>> 3;
      if (block & 1) {
        if (this.#checksum) this.#skip += 4;
        this.#frames++;
        this.#step = "magic"; this.#want = 4;
      }
    }
  }
}

/** Offsets count complete decompressed bytes, including malformed lines. */
export async function* codexLines(file, runtime, onChunk = () => {}, start = 0) {
  let source;
  let input;
  let child;
  let childResult;
  let frames;
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
    if (input !== source) {
      frames = new ZstdFrames();
      source.on("data", chunk => frames.update(chunk));
      source.on("error", error => input.destroy(error));
    }
  }
  try {
    yield* jsonLines(input, start, file.compressed ? start : 0, onChunk);
    if (childResult) {
      const result = await childResult;
      if (result.error || result.code !== 0) throw new Error("Could not decompress the Codex archive.");
    }
    if (frames && !frames.complete) throw new Error("The Codex archive is truncated.");
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
