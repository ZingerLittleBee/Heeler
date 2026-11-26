import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { setTimeout } from "node:timers/promises";
import activate from "../integrations/amp/heeler-chat.js";

test("Amp publishes the focused thread and scopes pages and sends to that selection", async t => {
  const home = await mkdtemp(join(tmpdir(), "heeler-amp-protocol-"));
  const originalHome = process.env.HOME;
  process.env.HOME = home;
  const sockets = [];
  t.after(async () => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    await Promise.all(sockets.map(path => rm(path, { force: true })));
    await rm(home, { recursive: true, force: true });
  });

  const observers = [];
  const activeThread = { current: null, subscribe(fn) { observers.push(fn); } };
  function select(id) {
    activeThread.current = id ? { id } : null;
    observers.forEach(fn => fn(activeThread.current));
  }
  const first = "T-" + randomUUID();
  const second = "T-" + randomUUID();
  const rows = Array.from({ length: 51 }, (_, i) => ({
    id: i === 2 ? String(1) : i, role: "user", content: [{ type: "text", text: "same" }],
  }));
  const submissions = [];
  let duringRead;
  const amp = { activeThread, threads: { get(id) {
    return {
      async messages({ full, from, offset, limit }) {
        assert.equal(full, true);
        assert.equal(from, "start");
        if (duringRead) { const change = duringRead; duringRead = undefined; change(); }
        return id === first ? rows.slice(offset, offset + limit) : [];
      },
      async appendUserMessage(message) { submissions.push([id, message.content]); },
    };
  } } };
  async function load() {
    activate(amp);
    for (let i = 0; i < 100; i++) {
      try {
        const path = join(home, ".local/state/heeler/amp", process.ppid + ".json");
        const { uid, instance, contentRevision } = JSON.parse(await readFile(path, "utf8"));
        assert.equal(contentRevision, 2);
        const socket = "/tmp/heeler-amp-" + uid + "/" + instance + ".sock";
        if (!sockets.includes(socket)) { sockets.push(socket); return socket; }
      } catch (error) { if (error.code !== "ENOENT") throw error; }
      await setTimeout(5);
    }
    assert.fail("Plugin did not publish a fresh instance");
  }
  function request(path, operation, args = {}) {
    return new Promise((resolve, reject) => {
      const client = connect(path, () => client.write(JSON.stringify({ version: 1, op: operation, ...args }) + "\n"));
      let reply = "";
      client.setEncoding("utf8").on("data", chunk => { reply += chunk; });
      client.on("error", reject);
      client.on("end", () => {
        try { resolve(JSON.parse(reply)); } catch (error) { reject(error); }
      });
    });
  }

  const socket = await load();
  assert.equal((await request(socket, "binding")).binding.thread, null);
  select(first);
  const { binding } = await request(socket, "binding");
  const tail = await request(socket, "page", { ...binding, limit: 20 });
  assert.deepEqual([tail.page.offset, tail.page.total, tail.page.rows.length], [31, 51, 20]);
  const earlier = await request(socket, "page", { ...binding, offset: 0, limit: 20 });
  assert.deepEqual(earlier.page.rows.slice(1, 3).map(row => row.id), ["n:1", "s:1"]);
  const send = { ...binding, requestID: randomUUID(), text: "same" };
  const acks = await Promise.all([request(socket, "send", send), request(socket, "send", send)]);
  assert.deepEqual(acks, [{ sent: true }, { sent: true }]);

  const prompt = "a".repeat(15000) + " 👩🏽‍💻";
  assert.deepEqual(await request(socket, "send", { ...send, requestID: randomUUID(), text: prompt }), { sent: true });
  rows.push({ id: "long", role: "user", content: [{ type: "text", text: submissions.at(-1)[1] }] });
  const assistantText = "x".repeat(13999) + "😀" + "x".repeat(90000);
  rows.push({ id: "unicode", role: "assistant", content: [{ type: "text", text: assistantText }] });
  const log = "x".repeat(8192) + " final error";
  rows.push({ id: "tools", role: "user", content: [
    { type: "tool_result", toolUseID: "build", status: "done", output: [
      { type: "text", text: log }, { type: "text", text: "exit 1" },
    ] },
    { type: "tool_result", toolUseID: "test", status: "done", output: "π".repeat(40000) },
  ] });
  const projected = await request(socket, "page", { ...binding, fullText: true, offset: 51, limit: 3 });
  const [user, assistant, tools] = projected.page.rows;
  assert.equal(user.blocks[0].text, prompt, "every accepted mobile prompt must reconcile with its complete record");
  assert.ok(assistant.blocks[0].text.isWellFormed(), "a truncated reply must decode as Unicode");
  assert.equal(tools.blocks[0].truncated, true, "the app must know when to fetch the rest");
  const legacy = await request(socket, "page", { ...binding, offset: 51, limit: 1 });
  assert.ok(legacy.page.rows[0].blocks[0].text.length < prompt.length);
  const expand = call => request(socket, "page", { ...binding, offset: 53, limit: 1, expandedCall: call });
  const full = await expand("build");
  assert.deepEqual(full.page.rows[0].blocks.map(block => [block.call, block.text]), [["build", log + "\nexit 1"]]);
  const capped = (await expand("test")).page.rows[0].blocks[0];
  assert.equal(capped.truncated, true);
  assert.ok(capped.text.isWellFormed() && Buffer.byteLength(capped.text) <= 64 * 1024);
  assert.deepEqual((await expand("missing")).page.rows[0].blocks, []);
  assert.deepEqual(await request(socket, "page", { ...binding, limit: 20, expandedCall: "build" }), { error: "invalid" });
  const escaped = '"'.repeat(30 * 1024) + "a".repeat(66 * 1024);
  assert.deepEqual(await request(socket, "send", { ...send, requestID: randomUUID(), text: escaped }), { sent: true });
  for (let i = 0; i < 20; i++) rows.push({ id: i + 54, role: "user", content: [{ type: "text", text: escaped }] });
  const maxPage = await request(socket, "page", { ...binding, fullText: true, offset: 54, limit: 20 });
  assert.equal(maxPage.page.rows.length, 20);
  assert.ok(maxPage.page.rows.every(row => row.blocks[0].text === escaped));
  assert.ok(Buffer.byteLength(JSON.stringify(maxPage)) < 3 * 1024 * 1024);

  duringRead = () => select(second);
  assert.deepEqual(await expand("build"), { error: "stale" });
  select(first);
  assert.deepEqual(await request(socket, "send", { ...send, requestID: randomUUID() }), { error: "stale" });
  const next = await load();
  assert.deepEqual(await request(socket, "binding"), { error: "stale" });
  assert.deepEqual(await request(next, "send", send), { error: "stale" });
  assert.deepEqual(submissions, [[first, "same"], [first, prompt], [first, escaped]]);
});
