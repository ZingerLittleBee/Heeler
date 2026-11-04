import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, utimesSync, symlinkSync, realpathSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import zlib from "node:zlib";
import { randomBytes } from "node:crypto";
import { ZstdFrames } from "../src/usage/codex-files.js";

const moduleURL = new URL("../src/usage/codex-files.js", import.meta.url).href;
function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "heeler-codex-files-")));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const write = (relative, contents = "{}\n", age = 0) => {
    const path = join(root, relative);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, contents);
    const modified = new Date(Date.now() - age);
    utimesSync(path, modified, modified);
    return path;
  };
  const run = source => spawnSync(process.execPath, ["--input-type=module", "-e", `import * as files from ${JSON.stringify(moduleURL)}; ${source}`], { encoding: "utf8", timeout: 5000 });
  return { root, write, run };
}

test("Codex discovery prefers live and plain rollouts and ignores old files", t => {
  const f = fixture(t);
  const live = f.write("one/sessions/2026/10/23/rollout-live.jsonl", "{}\n", 1000);
  f.write("one/sessions/2026/10/23/rollout-live.jsonl.zst");
  f.write("one/archived_sessions/rollout-live.jsonl");
  const archive = f.write("one/archived_sessions/rollout-archive.jsonl.zst");
  f.write("one/sessions/rollout-old.jsonl", "{}\n", 32 * 86400000);
  f.write("one/sessions/unrelated.jsonl");
  const other = f.write("two/sessions/rollout-other.jsonl", "{}\n", 500);
  symlinkSync(join(f.root, "one"), join(f.root, "alias"));
  const result = f.run(`console.log(JSON.stringify((await files.codexFiles(${JSON.stringify([join(f.root, "one"), join(f.root, "alias"), join(f.root, "two"), join(f.root, "missing")])}, Date.now() - 31 * 86400000))));`);
  assert.equal(result.status, 0, result.stderr);
  const { files: discovered, ...listing } = JSON.parse(result.stdout);
  assert.deepEqual(listing, { unreadable: [], rootFailed: false, older: true });
  assert.deepEqual(discovered.map(file => file.path), [archive, other, live]);
  assert.equal(discovered[0].compressed, true);
  assert.equal(discovered[0].logicalPath, archive.slice(0, -4));
  assert.equal(discovered[2].compressed, false);
  for (const file of discovered) {
    assert.ok(Number.isFinite(file.dev));
    assert.ok(Number.isFinite(file.ino));
    assert.ok(file.size > 0);
    assert.ok(Number.isFinite(file.mtimeMs));
  }
});

test("Codex lines preserve byte offsets and leave partial tails for a later read", t => {
  const f = fixture(t);
  const first = JSON.stringify({ text: "hello 😀" }) + "\n";
  const second = JSON.stringify({ number: 2 }) + "\n";
  const path = f.write("rollout-lines.jsonl", first + "torn\n" + second + '{"partial":');
  const result = f.run(`const result = []; for await (const item of files.codexLines({path:${JSON.stringify(path)}, compressed:false}, {env:{}}, () => {}, ${Buffer.byteLength(first)})) result.push(item); console.log(JSON.stringify(result));`);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), [
    { line: null, offset: Buffer.byteLength(first) + 5 },
    { line: { number: 2 }, offset: Buffer.byteLength(first) + 5 + Buffer.byteLength(second) },
  ]);
});

test("native zstd reads complete records from a decompressed byte offset", { skip: !zlib.createZstdDecompress }, t => {
  const f = fixture(t);
  const prefix = JSON.stringify({ message: "large " + "😀".repeat(20000) }) + "\n";
  const suffix = '{"number":2}\n{"incomplete":';
  const path = f.write("rollout-compressed.jsonl.zst", zlib.zstdCompressSync(prefix + suffix));
  const result = f.run(`const result=[]; for await (const item of files.codexLines({path:${JSON.stringify(path)},compressed:true},{env:{PATH:"/missing"}},()=>{},${Buffer.byteLength(prefix)})) result.push(item); console.log(JSON.stringify(result));`);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), [{ line: { number: 2 }, offset: Buffer.byteLength(prefix) + 13 }]);
});

test("zstd frame walking accepts whole archives and rejects every truncation", { skip: !zlib.zstdCompressSync }, () => {
  const lines = Buffer.from(Array.from({ length: 6000 }, (_, i) => JSON.stringify({ i, pad: "x".repeat(i % 40) })).join("\n") + "\n");
  const checksum = { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } };
  const skippable = Buffer.alloc(8 + 5); skippable.writeUInt32LE(0x184D2A53, 0); skippable.writeUInt32LE(5, 4);
  const first = zlib.zstdCompressSync(Buffer.from("{}\n"));
  // A cut exactly between frames leaves a valid archive and cannot be detected.
  const boundaries = new Set([first.length, first.length + skippable.length]);
  const archives = {
    lines: zlib.zstdCompressSync(lines),
    checksum: zlib.zstdCompressSync(lines, checksum),
    raw: zlib.zstdCompressSync(randomBytes(300_000)),
    rle: zlib.zstdCompressSync(Buffer.alloc(400_000, 97), checksum),
    frames: Buffer.concat([first, skippable, zlib.zstdCompressSync(lines)]),
  };
  const complete = (archive, size) => {
    const frames = new ZstdFrames();
    for (let at = 0; at < archive.length; at += size) frames.update(archive.subarray(at, at + size));
    return frames.complete;
  };
  for (const [name, archive] of Object.entries(archives)) {
    for (const size of [1, 7, 65536]) assert.equal(complete(archive, size), true, `${name} in ${size}-byte chunks`);
    const step = Math.max(1, Math.floor(archive.length / 400));
    for (let cut = 0; cut < archive.length; cut += cut < 64 || archive.length - cut < 64 ? 1 : step) {
      if (name !== "frames" || !boundaries.has(cut)) assert.equal(complete(archive.subarray(0, cut), 4096), false, `${name} cut at ${cut} of ${archive.length}`);
    }
  }
  assert.equal(complete(Buffer.from('{"plain":true}\n'), 4096), false);
});

test("a truncated archive read through native zstd is a read error", { skip: !zlib.createZstdDecompress }, t => {
  const f = fixture(t);
  const archive = zlib.zstdCompressSync(Buffer.from(Array.from({ length: 4000 }, (_, i) => JSON.stringify({ i })).join("\n") + "\n"));
  const path = f.write("rollout-truncated.jsonl.zst", archive.subarray(0, archive.length - 3));
  const result = f.run(`let count=0; try { for await (const item of files.codexLines({path:${JSON.stringify(path)},compressed:true},{env:{PATH:"/missing"}})) count++; console.log(JSON.stringify({count})); } catch(error) { console.log(JSON.stringify({error:true,unavailable:error instanceof files.ArchiveUnavailableError})); }`);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { error: true, unavailable: false });
});

test("zstd fallback uses only the recorded executable path and reports absence distinctly", t => {
  const f = fixture(t);
  const path = f.write("rollout-external.jsonl.zst", '{"first":1}\n{"second":2}\n');
  const executable = f.write("bin/zstd", `#!${process.execPath}\nconst fs=require('node:fs'); if(process.argv[2]!=="-dc" || process.argv[3]!=="--") process.exit(2); process.stdout.write(fs.readFileSync(process.argv[4]));\n`);
  chmodSync(executable, 0o700);
  const run = recordedPath => f.run(`import zlib from 'node:zlib'; Object.defineProperty(zlib,'createZstdDecompress',{value:undefined}); const result=[]; try { for await (const item of files.codexLines({path:${JSON.stringify(path)},compressed:true},{env:{PATH:${JSON.stringify(recordedPath)}}},()=>{},12)) result.push(item); console.log(JSON.stringify({result})); } catch(error) { console.log(JSON.stringify({unavailable:error instanceof files.ArchiveUnavailableError})); }`);
  const result = run(join(f.root, "bin"));
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { result: [{ line: { second: 2 }, offset: 25 }] });
  const missing = run(join(f.root, "missing"));
  assert.equal(missing.status, 0, missing.stderr);
  assert.deepEqual(JSON.parse(missing.stdout), { unavailable: true });
});

test("stopping after the archive header kills and reaps the external decoder", t => {
  const f = fixture(t);
  const path = f.write("rollout-header.jsonl.zst");
  const executable = f.write("bin/zstd", `#!${process.execPath}\nprocess.stdout.write(JSON.stringify({pid:process.pid})+'\\n'); setInterval(()=>{},1000);\n`);
  chmodSync(executable, 0o700);
  const result = f.run(`import zlib from 'node:zlib'; Object.defineProperty(zlib,'createZstdDecompress',{value:undefined}); let pid; for await (const item of files.codexLines({path:${JSON.stringify(path)},compressed:true},{env:{PATH:${JSON.stringify(join(f.root, "bin"))}}})) { pid=item.line.pid; break; } let alive=true; try { process.kill(pid,0); } catch(error) { if(error.code==='ESRCH') alive=false; else throw error; } console.log(JSON.stringify({alive}));`);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { alive: false });
});

test("archive decoder failure is an error rather than missing support", t => {
  const f = fixture(t);
  const path = f.write("rollout-corrupt.jsonl.zst", "not a zstd frame");
  const executable = f.write("bin/zstd", "#!/bin/sh\nexit 1\n");
  chmodSync(executable, 0o700);
  const result = f.run(`import zlib from 'node:zlib'; Object.defineProperty(zlib,'createZstdDecompress',{value:undefined}); try { for await (const item of files.codexLines({path:${JSON.stringify(path)},compressed:true},{env:{PATH:${JSON.stringify(join(f.root, "bin"))}}})) {} } catch(error) { console.log(JSON.stringify({error:true,unavailable:error instanceof files.ArchiveUnavailableError})); }`);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { error: true, unavailable: false });
});
