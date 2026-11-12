import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import worker, { byteRange } from "../src/worker.mjs";

const base = `https://install.example/b/${"a".repeat(32)}/`;
const token = "test-only-upload-token";
function bucket() {
  const objects = new Map();
  return {
    objects,
    async head(key) { return objects.get(key) || null; },
    async put(key, body, options) {
      assert.deepEqual(options.onlyIf, { etagDoesNotMatch: "*" });
      if (objects.has(key)) return null;
      const bytes = new Uint8Array(await new Response(body).arrayBuffer());
      const item = { bytes, size: bytes.length, httpEtag: '"etag"', ...options };
      objects.set(key, item);
      return item;
    },
    async get(key, options) {
      const item = objects.get(key);
      if (!item) return null;
      const range = options?.range;
      return { ...item, body: range ? item.bytes.slice(range.offset, range.offset + range.length) : item.bytes };
    },
  };
}
function put(file, body, credential = token, extra = {}) {
  return new Request(base + file, { method: "PUT", body, headers: {
    Authorization: `Bearer ${credential}`, "Content-Length": String(Buffer.byteLength(body)),
    "X-File-SHA256": createHash("sha256").update(body).digest("hex"), ...extra,
  } });
}
function env() { return { BUILDS: bucket(), UPLOAD_TOKEN: token }; }

test("only authenticated uploads can write to the bucket", async () => {
  const e = env();
  assert.equal((await worker.fetch(put("Heeler.ipa", "bytes", "wrong"), e)).status, 401);
  assert.equal((await worker.fetch(put("Heeler.ipa", "bytes"), { ...e, UPLOAD_TOKEN: "" })).status, 401);
  assert.equal(e.BUILDS.objects.size, 0);
});
test("uploads retry safely and cannot replace an immutable file", async () => {
  const e = env();
  assert.equal((await worker.fetch(put("Heeler.ipa", "bytes"), e)).status, 201);
  assert.equal((await worker.fetch(put("Heeler.ipa", "bytes"), e)).status, 204);
  assert.equal((await worker.fetch(put("Heeler.ipa", "other"), e)).status, 409);
});
test("uploads reject excessive size and missing integrity metadata", async () => {
  const e = env();
  assert.equal((await worker.fetch(put("Heeler.ipa", "bytes", token, { "Content-Length": String(91 * 1024 * 1024) }), e)).status, 413);
  assert.equal((await worker.fetch(put("index.html", "bytes", token, { "Content-Length": "65537" }), e)).status, 413);
  assert.equal((await worker.fetch(put("Heeler.ipa", "bytes", token, { "X-File-SHA256": "invalid" }), e)).status, 400);
  assert.equal(e.BUILDS.objects.size, 0);
});
test("no listing, arbitrary file access, query strings or deletion", async () => {
  const e = env();
  for (const url of ["https://install.example/", base + "logs.zip", base + "Heeler.ipa?key=1", base.replace("a".repeat(32), "guess")]) {
    assert.equal((await worker.fetch(new Request(url), e)).status, 404);
  }
  assert.equal((await worker.fetch(new Request(base + "Heeler.ipa", { method: "DELETE" }), e)).status, 405);
});
test("downloads and HEAD preserve MIME, byte count and private-link headers", async () => {
  const e = env();
  await worker.fetch(put("Heeler.ipa", "0123456789"), e);
  const r = await worker.fetch(new Request(base + "Heeler.ipa"), e);
  assert.equal(await r.text(), "0123456789");
  assert.equal(r.headers.get("Content-Type"), "application/octet-stream");
  assert.equal(r.headers.get("Content-Length"), "10");
  assert.equal(r.headers.get("Referrer-Policy"), "no-referrer");
  assert.equal(r.headers.get("Cache-Control"), "private, no-store");
  const h = await worker.fetch(new Request(base + "Heeler.ipa", { method: "HEAD" }), e);
  assert.equal(await h.text(), "");
  assert.equal(h.headers.get("Content-Length"), "10");
});
test("the bare build directory opens its installation page", async () => {
  const e = env();
  await worker.fetch(put("index.html", "<h1>Install</h1>"), e);
  const r = await worker.fetch(new Request(base), e);
  assert.equal(await r.text(), "<h1>Install</h1>");
  assert.equal(r.headers.get("Content-Type"), "text/html; charset=utf-8");
});
test("partial downloads return accurate ranges and bytes", async () => {
  const e = env();
  await worker.fetch(put("Heeler.ipa", "0123456789"), e);
  for (const [range, body, contentRange] of [
    ["bytes=2-4", "234", "bytes 2-4/10"], ["bytes=-3", "789", "bytes 7-9/10"],
    ["bytes=8-", "89", "bytes 8-9/10"], ["bytes=8-99", "89", "bytes 8-9/10"],
  ]) {
    const r = await worker.fetch(new Request(base + "Heeler.ipa", { headers: { Range: range } }), e);
    assert.equal(r.status, 206);
    assert.equal(await r.text(), body);
    assert.equal(r.headers.get("Content-Range"), contentRange);
    assert.equal(r.headers.get("Content-Length"), String(body.length));
  }
});
test("unsatisfiable and malformed ranges return 416", async () => {
  const e = env();
  await worker.fetch(put("Heeler.ipa", "0123456789"), e);
  for (const value of ["bytes=10-", "bytes=-0", "bytes=3-2", "bytes=-", "bytes=0-1,3-4", "garbage"]) {
    const r = await worker.fetch(new Request(base + "Heeler.ipa", { headers: { Range: value } }), e);
    assert.equal(r.status, 416);
    assert.equal(r.headers.get("Content-Range"), "bytes */10");
  }
  assert.equal(byteRange("bytes=0-1", 0), false);
  assert.equal(byteRange(null, 10), null);
});
test("a stale If-Range validator receives the complete object", async () => {
  const e = env();
  await worker.fetch(put("Heeler.ipa", "0123456789"), e);
  const r = await worker.fetch(new Request(base + "Heeler.ipa", {
    headers: { Range: "bytes=2-4", "If-Range": '"old-etag"' },
  }), e);
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "0123456789");
  assert.equal(r.headers.get("Content-Range"), null);
});
