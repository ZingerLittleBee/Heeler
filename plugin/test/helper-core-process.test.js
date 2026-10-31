// The Helper's real process, from a bare copy of its files as a Host holds them,
// with `hc` and `herdr-core` on its PATH as tripwires: it never runs them, so it
// never brings back a core the user stopped (ADR 0033).

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { fileURLToPath } from "node:url";

import { FakeCore, exchange, waitFor } from "./support/fake-core.js";

const HELPER = fileURLToPath(new URL("../helper", import.meta.url));
const STATUS = exchange("server-status").result;
// Node's own start can take a moment on a busy machine.
const PATIENCE_MS = 15_000;

let root;
let home;
let tripwire;
let child;
let stdout;
const cores = [];

beforeEach(() => {
  root = mkdtempSync("/tmp/hh-");
  home = join(root, "home");
  tripwire = join(root, "tripwire");
  stdout = "";
  const bin = join(root, "bin");
  mkdirSync(bin);
  mkdirSync(home);
  for (const name of ["hc", "herdr-core", "herdr"]) {
    const path = join(bin, name);
    writeFileSync(path, `#!/bin/sh\necho "${name} $*" >> "${tripwire}"\n`);
    chmodSync(path, 0o755);
  }
});

afterEach(async () => {
  child?.kill("SIGKILL");
  while (cores.length > 0) await cores.pop().stop().catch(() => {});
  rmSync(root, { recursive: true, force: true });
});

function startHelper(sessions) {
  const directory = join(root, "helper");
  cpSync(HELPER, join(directory, "app"), { recursive: true });
  writeFileSync(
    join(directory, "notifications.json"),
    JSON.stringify({ v: 1, devices: sessions.map((session) => ({ session })) }),
  );
  child = spawn(process.execPath, [join(directory, "app", "main.js")], {
    env: { HOME: home, XDG_RUNTIME_DIR: join(root, "r"), PATH: join(root, "bin") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stdout += chunk;
  });
}

const socketFor = (session) => join(root, "r", "herdr-core", `${session}.sock`);

async function core(session, options) {
  const fake = await FakeCore.start(socketFor(session), options);
  cores.push(fake);
  return fake;
}

function filesUnder(path) {
  return existsSync(path)
    ? readdirSync(path, { recursive: true }).map((entry) => join(path, entry).split(sep).join("/"))
    : [];
}

suite("the Helper's process", () => {
  test("waits with no core, then connects and follows a restart, running no program", async () => {
    startHelper(["work"]);
    await waitFor(() => stdout.includes("waiting for a core"), "the waiting line", PATIENCE_MS);
    assert.match(stdout, /^Heeler Host Helper \S+ started\n/);
    assert.match(stdout, new RegExp(`core session "work": waiting for a core at ${socketFor("work")}`));
    // Nothing started a core: no socket, no core state, in its environment's places.
    assert.equal(existsSync(socketFor("work")), false);
    assert.deepEqual(filesUnder(home), []);

    const first = await core("work");
    await waitFor(() => stdout.includes(`connected to core pid ${STATUS.pid}`), "the connection", PATIENCE_MS);
    assert.deepEqual(first.last.methods, ["hello", "server.status", "events.subscribe"]);
    assert.equal(first.connections.length, 1);

    await first.stop();
    cores.pop();
    const second = await core("work", { status: { ...STATUS, pid: 4242 } });
    await waitFor(() => stdout.includes("connected to core pid 4242"), "the reconnection", PATIENCE_MS);
    assert.deepEqual(second.last.methods, ["hello", "server.status", "events.subscribe"]);

    assert.equal(existsSync(tripwire), false, existsSync(tripwire) ? readFileSync(tripwire, "utf8") : "");
    assert.equal(child.exitCode, null);

    const exit = new Promise((done) => child.on("exit", (code, signal) => done({ code, signal })));
    child.kill("SIGTERM");
    assert.deepEqual(await exit, { code: 0, signal: null });
  });

  test("records the core's named variables for Usage, at the pid server.status reported", async () => {
    const process_ = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
      env: { HOME: home, CLAUDE_CONFIG_DIR: "/core/claude", ANTHROPIC_API_KEY: "outside-the-list" },
      stdio: "ignore",
    });
    try {
      await core("work", { status: { ...STATUS, pid: process_.pid } });
      startHelper(["work"]);
      const path = join(root, "helper", "sessions", "work", "runtime.json");
      await waitFor(() => existsSync(path), "the record", PATIENCE_MS);
      const text = readFileSync(path, "utf8");
      assert.equal(JSON.parse(text).env.CLAUDE_CONFIG_DIR, "/core/claude");
      assert.equal(text.includes("outside-the-list"), false);
      assert.equal(existsSync(tripwire), false, existsSync(tripwire) ? readFileSync(tripwire, "utf8") : "");
    } finally {
      process_.kill("SIGKILL");
    }
  });

  test("connects only to the sessions its registrations name", async () => {
    const work = await core("work");
    const other = await core("other");
    startHelper(["work"]);
    await waitFor(() => stdout.includes("connected to core pid"), "the connection", PATIENCE_MS);
    assert.equal(work.connections.length, 1);
    assert.equal(other.connections.length, 0);
  });
});
