const TYPES = {
  "Heeler.ipa": "application/octet-stream",
  "manifest.plist": "application/xml; charset=utf-8",
  "index.html": "text/html; charset=utf-8",
};
const MAX_IPA = 90 * 1024 * 1024;
const MAX_PAGE = 64 * 1024;

function reply(body, status, extra = {}) {
  return new Response(body, {
    status,
    headers: { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", ...extra },
  });
}

// One range is sufficient for iOS downloads. Reject malformed/unsatisfiable
// ranges; do not turn a suffix range into an incorrect full-body response.
export function byteRange(value, size) {
  if (value === null) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2]) || size === 0) return false;
  let start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
  let end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) return false;
  return { offset: start, length: end - start + 1 };
}

async function upload(request, env, key, file) {
  if (!env.UPLOAD_TOKEN || request.headers.get("Authorization") !== `Bearer ${env.UPLOAD_TOKEN}`) {
    return reply("Unauthorized", 401);
  }
  const length = request.headers.get("Content-Length");
  const size = Number(length);
  if (!length || !/^\d+$/.test(length) || !Number.isSafeInteger(size) || size <= 0) {
    return reply("Content-Length required", 411);
  }
  if (size > (file === "Heeler.ipa" ? MAX_IPA : MAX_PAGE)) return reply("File too large", 413);
  const sha256 = request.headers.get("X-File-SHA256");
  if (!/^[a-f0-9]{64}$/.test(sha256 || "")) return reply("SHA-256 required", 400);
  const previous = await env.BUILDS.head(key);
  if (previous) {
    // A retry after a lost response must not replace an existing build.
    return previous.size === size && previous.customMetadata?.sha256 === sha256
      ? reply(null, 204) : reply("Immutable build already exists", 409);
  }
  const object = await env.BUILDS.put(key, request.body, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: TYPES[file], cacheControl: "private, no-store" },
    customMetadata: { sha256 },
  });
  return object ? reply(null, 201) : reply("Immutable build already exists", 409);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // The random identifier grants read access. No bucket listing or public
    // latest-build pointer exposes IPAs containing registered-device IDs.
    const match = /^\/b\/([a-f0-9]{32})\/(Heeler\.ipa|manifest\.plist|index\.html)?$/.exec(url.pathname);
    if (!match || url.search) return reply("Not found", 404);
    const file = match[2] || "index.html";
    const key = `b/${match[1]}/${file}`;
    if (request.method === "PUT" && match[2]) return upload(request, env, key, file);
    if (!["GET", "HEAD"].includes(request.method)) return reply("Method not allowed", 405, { Allow: "GET, HEAD" });
    const metadata = await env.BUILDS.head(key);
    if (!metadata) return reply("Not found", 404);
    const ifRange = request.headers.get("If-Range");
    const range = request.method === "HEAD" || (ifRange && ifRange !== metadata.httpEtag)
      ? null : byteRange(request.headers.get("Range"), metadata.size);
    if (range === false) return reply("Range not satisfiable", 416, { "Content-Range": `bytes */${metadata.size}` });
    const headers = new Headers({
      "Content-Type": TYPES[file],
      "Content-Length": String(range ? range.length : metadata.size),
      "Accept-Ranges": "bytes",
      "Cache-Control": "private, no-store",
      "ETag": metadata.httpEtag,
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
    });
    if (range) headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`);
    if (file === "Heeler.ipa") headers.set("Content-Disposition", 'attachment; filename="Heeler.ipa"');
    if (request.method === "HEAD") return new Response(null, { headers });
    const object = await env.BUILDS.get(key, range ? { range } : undefined);
    if (!object) return reply("Not found", 404);
    return new Response(object.body, { status: range ? 206 : 200, headers });
  },
};
