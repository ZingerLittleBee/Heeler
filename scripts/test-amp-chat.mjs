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
        const { uid, instance } = JSON.parse(await readFile(path, "utf8"));
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

  duringRead = () => select(second);
  assert.deepEqual(await request(socket, "page", { ...binding, limit: 20 }), { error: "stale" });
  select(first);
  assert.deepEqual(await request(socket, "send", { ...send, requestID: randomUUID() }), { error: "stale" });
  const next = await load();
  assert.deepEqual(await request(socket, "binding"), { error: "stale" });
  assert.deepEqual(await request(next, "send", send), { error: "stale" });
  assert.deepEqual(submissions, [[first, "same"]]);
});
