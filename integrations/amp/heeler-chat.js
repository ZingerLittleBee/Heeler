// Heeler Amp Chat, protocol 1. Installed on request by the iOS app.
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const version = 1;
const messageLimit = 20;
const maxRequest = 128 * 1024;

function privateDirectory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0) {
    throw new Error("Amp Chat needs a private directory");
  }
}

function processStart(pid) {
  if (process.platform === "linux") {
    const stat = readFileSync("/proc/" + pid + "/stat", "utf8");
    return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19];
  }
  return execFileSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], {
    encoding: "utf8", timeout: 1500, env: { LC_ALL: "C", TZ: "UTC" },
  }).trim();
}

function text(value, limit) {
  if (typeof value !== "string") return "";
  return value.length <= limit ? value : value.slice(0, limit) + "…";
}

function outputText(value) {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.filter(part => part.type === "text").map(part => text(part.text, 4096)).join("\n");
}

function messageID(id) {
  return (typeof id === "number" ? "n:" : "s:") + id;
}

function row(message) {
  let remaining = 14000;
  const blocks = [];
  for (const part of message.content ?? []) {
    if (remaining <= 0 || blocks.length >= 96) {
      blocks.push({ type: "text", text: "…" });
      break;
    }
    let block;
    switch (part.type) {
      case "text":
      case "thinking":
        block = { type: part.type, text: text(part.text ?? part.thinking, remaining) };
        break;
      case "tool_use":
        block = { type: part.type, call: text(part.id, 256), name: text(part.name, 160),
          text: text(JSON.stringify(part.input ?? {}), Math.min(remaining, 4096)) };
        break;
      case "tool_result":
        block = { type: part.type, call: text(part.toolUseID, 256), status: part.status,
          text: text(outputText(part.output), Math.min(remaining, 4096)) };
        break;
      default: continue;
    }
    remaining -= (block.text ?? "").length + 64;
    blocks.push(block);
  }
  return { id: messageID(message.id), role: message.role, createdAt: message.createdAt, end: message.stopReason, blocks };
}

export default function activate(amp) {
  if (!["darwin", "linux"].includes(process.platform)) return;
  const pid = process.ppid;
  const start = processStart(pid);
  const uid = process.getuid();
  const instance = randomUUID();
  const directory = join(homedir(), ".local/state/heeler/amp");
  const sockets = "/tmp/heeler-amp-" + uid;
  privateDirectory(directory);
  privateDirectory(sockets);
  const record = join(directory, pid + ".json");
  const socket = join(sockets, instance + ".sock");
  let focused = amp.activeThread.current?.id ?? null;
  let revision = 0;
  let knownCount = 0;
  const submissions = new Map();
  function isPublished() {
    if (process.ppid !== pid) return false;
    try { return JSON.parse(readFileSync(record, "utf8")).instance === instance; }
    catch { return false; }
  }

  function observeFocus(thread) {
    const id = thread?.id ?? null;
    if (id !== focused) {
      focused = id;
      revision++;
      knownCount = 0;
    }
  }
  amp.activeThread.subscribe(observeFocus);
  function binding() {
    observeFocus(amp.activeThread.current);
    return { version, instance, revision, thread: focused, pid, start };
  }
  function matches(q) {
    const b = binding();
    return b.thread !== null && q.instance === instance && q.revision === b.revision && q.thread === b.thread;
  }

  // Amp offsets from the start remain stable as other turns arrive. Find the
  // first empty offset without walking an entire resumed thread.
  async function count(thread, q) {
    const exists = async index => {
      if (!matches(q)) throw new Error("stale");
      return (await thread.messages({ full: true, from: "start", offset: index, limit: 1 })).length > 0;
    };
    let low = knownCount;
    if (low && !(await exists(low - 1))) low = 0;
    if (!(await exists(low))) return low;
    let high = low + messageLimit;
    while (await exists(high)) {
      low = high;
      high *= 2;
      if (!Number.isSafeInteger(high)) throw new Error("range");
    }
    while (low + 1 < high) {
      const mid = low + Math.floor((high - low) / 2);
      if (await exists(mid)) low = mid;
      else high = mid;
    }
    return high;
  }

  async function handle(q) {
    if (!isPublished()) return { error: "stale" };
    if (q.version !== version) return { error: "version" };
    if (q.op === "binding") return { binding: binding() };
    if (!matches(q)) return { error: "stale" };
    const thread = amp.threads.get(focused);
    if (q.op === "send") {
      if (typeof q.requestID !== "string" || !/^[0-9a-f-]{36}$/i.test(q.requestID) ||
          typeof q.text !== "string" || !q.text.trim() || Buffer.byteLength(q.text) > 96 * 1024) return { error: "invalid" };
      const previous = submissions.get(q.requestID);
      if (previous) return previous.thread === focused && previous.revision === revision
        ? previous.result : { error: "stale" };
      if (submissions.size >= 8192) return { error: "reload" };
      // No await between the last check of focus and dispatch to this exact ID.
      const receipt = { thread: focused, revision };
      submissions.set(q.requestID, receipt);
      receipt.result = (async () => {
        try {
          await thread.appendUserMessage({ type: "user-message", content: q.text });
          return { sent: true };
        } catch { return { error: "unknown" }; }
      })();
      return receipt.result;
    }
    if (q.op !== "page") return { error: "invalid" };
    if (q.offset != null && (!Number.isSafeInteger(q.offset) || q.offset < 0)) return { error: "invalid" };
    if (!Number.isSafeInteger(q.limit) || q.limit < 1 || q.limit > messageLimit) return { error: "invalid" };
    const total = await count(thread, q);
    if (!matches(q)) return { error: "stale" };
    knownCount = total;
    const offset = q.offset ?? Math.max(0, total - q.limit);
    const limit = Math.min(q.limit, Math.max(0, total - offset));
    const page = limit ? await thread.messages({ full: true, from: "start", offset, limit }) : [];
    if (!matches(q) || !isPublished()) return { error: "stale" };
    return { page: { offset, total, rows: page.map(row) } };
  }

  const server = createServer(client => {
    client.on("error", () => {});
    client.setTimeout(12000, () => client.destroy());
    let bytes = 0;
    const chunks = [];
    client.on("data", chunk => {
      bytes += chunk.length;
      if (bytes > maxRequest) { client.destroy(); return; }
      chunks.push(chunk);
      if (!chunk.includes(10)) return;
      client.removeAllListeners("data");
      client.pause();
      let request;
      try { request = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
      catch { client.end('{"error":"invalid"}\n'); return; }
      handle(request).then(
        response => client.end(JSON.stringify(response) + "\n"),
        err => client.end(JSON.stringify({ error: err?.message === "stale" ? "stale" : "unavailable" }) + "\n")
      );
    });
  });
  server.on("error", () => {});
  server.listen(socket, () => {
    chmodSync(socket, 0o600);
    const temporary = record + "." + instance;
    writeFileSync(temporary, JSON.stringify({ version, pid, start, uid, instance }), { flag: "wx", mode: 0o600 });
    renameSync(temporary, record);
  });
  server.unref();
  process.once("exit", () => {
    try { if (JSON.parse(readFileSync(record, "utf8")).instance === instance) unlinkSync(record); } catch {}
    try { unlinkSync(socket); } catch {}
  });
}
