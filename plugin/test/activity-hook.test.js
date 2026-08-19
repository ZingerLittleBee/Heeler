// Process-boundary tests for the Live Activity hook.
//
// activity-hook.js runs as a herdr [[events]] hook command, so these tests
// exercise it the same way: a real child process launched with the env herdr
// injects, against an in-test fake relay HTTP server and a stub HERDR_BIN_PATH
// that answers `herdr agent list`.

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createDecipheriv } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os, { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { shortHostName } from "../src/activity-state.js";

const ACTIVITY_SCRIPT = fileURLToPath(new URL("../src/activity-hook.js", import.meta.url));

const DEBOUNCE_MS = 120;
const RETRY_DELAY_MS = 10;

const KEY_A = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const KEY_B = Buffer.from(Array.from({ length: 32 }, (_, i) => 255 - i));
const ALERT_TOKEN = "a".repeat(64);
const ACTIVITY_TOKEN_A = "c".repeat(64);
const ACTIVITY_TOKEN_B = "d".repeat(64);
const PANE_ID = "w1:p2";

let home;
let stateDir;
let configDir;
let stubDir;
let relay;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "activity-hook-"));
  stateDir = join(home, "state");
  configDir = join(home, "config");
  stubDir = join(home, "stub");
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(configDir, { recursive: true });
  mkdirSync(stubDir, { recursive: true });
  relay = null;
});

afterEach(async () => {
  if (relay) await relay.close();
  rmSync(home, { recursive: true, force: true });
});

async function startFakeRelay(respond = () => ({ status: 200, body: { apnsId: "x" } })) {
  if (relay) await relay.close();
  const requests = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const request = {
        method: req.method,
        path: req.url,
        body: JSON.parse(raw),
      };
      const { status, body } = respond(request, requests.length);
      requests.push(request);
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      relay = {
        url: `http://127.0.0.1:${server.address().port}`,
        requests,
        close: () => new Promise((done) => server.close(done)),
      };
      resolve(relay);
    });
  });
}

function writeHerdrStub(agents) {
  const binPath = join(stubDir, "herdr");
  writeFileSync(join(stubDir, "response.json"), JSON.stringify({ agents }));
  writeFileSync(
    binPath,
    [
      "#!/usr/bin/env node",
      'const fs = require("node:fs");',
      'const path = require("node:path");',
      "const dir = __dirname;",
      "const args = process.argv.slice(2);",
      "fs.appendFileSync(",
      '  path.join(dir, "invocations.log"),',
      '  JSON.stringify({ args, at: Date.now() }) + "\\n",',
      ");",
      'if (args[0] !== "agent" || args[1] !== "list") {',
      '  process.stderr.write(`stub: unexpected subcommand ${args.join(" ")}`);',
      "  process.exit(64);",
      "}",
      'const response = JSON.parse(fs.readFileSync(path.join(dir, "response.json"), "utf8"));',
      "process.stdout.write(JSON.stringify({",
      '  id: "cli:agent:list",',
      "  result: { agents: response.agents, type: \"agent_list\" },",
      "}));",
      "process.exit(0);",
    ].join("\n"),
    { mode: 0o755 },
  );
  return binPath;
}

function stubInvocations() {
  const log = join(stubDir, "invocations.log");
  if (!existsSync(log)) return [];
  return readFileSync(log, "utf8")
    .trimEnd()
    .split("\n")
    .map((line) => JSON.parse(line));
}

function writeConfig(overrides = {}) {
  writeFileSync(
    join(configDir, "notify.json"),
    JSON.stringify({
      relay_url: relay?.url,
      activity_debounce_ms: DEBOUNCE_MS,
      retry_delay_ms: RETRY_DELAY_MS,
      ...overrides,
    }),
  );
}

function device({
  token = ALERT_TOKEN,
  key = KEY_A,
  env = "sandbox",
  activityToken = ACTIVITY_TOKEN_A,
  liveActivity = undefined,
  ...extra
} = {}) {
  const entry = {
    token,
    key: key.toString("base64url"),
    env,
    notify: { blocked: true, done: true },
    ...extra,
  };
  if (liveActivity === null) return entry;
  entry.live_activity =
    liveActivity === undefined
      ? { token: activityToken, started_at: "2026-01-01T00:00:00Z" }
      : liveActivity;
  return entry;
}

function writeRegistration(devices, extra = {}) {
  writeFileSync(
    join(configDir, "notifications.json"),
    JSON.stringify({ v: 1, devices, ...extra }),
  );
}

function readRegistration() {
  return JSON.parse(readFileSync(join(configDir, "notifications.json"), "utf8"));
}

function writeLastState(state) {
  const dir = join(stateDir, "activity");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "last-state.json"), JSON.stringify(state));
}

function listedAgent({
  pane = PANE_ID,
  status = "working",
  agent = "claude",
  title = "implement live activity",
} = {}) {
  const info = { agent, agent_status: status, pane_id: pane, workspace_id: "w1" };
  if (title !== null) {
    info.terminal_title = `⠂ ${title}`;
    info.terminal_title_stripped = title;
  }
  return info;
}

function statusEvent(status, { agent = "claude", paneId = PANE_ID, ...dataExtra } = {}) {
  const data = {
    type: "pane_agent_status_changed",
    pane_id: paneId,
    workspace_id: "w1",
    agent_status: status,
    ...dataExtra,
  };
  if (agent !== null) data.agent = agent;
  return { event: "pane_agent_status_changed", data };
}

function runHook(event, { binPath, env = {} } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [ACTIVITY_SCRIPT], {
      env: {
        PATH: process.env.PATH,
        HERDR_PLUGIN_EVENT_JSON: typeof event === "string" ? event : JSON.stringify(event),
        HERDR_PLUGIN_STATE_DIR: stateDir,
        HERDR_PLUGIN_CONFIG_DIR: configDir,
        HERDR_BIN_PATH: binPath ?? join(stubDir, "herdr"),
        ...env,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

function decryptEnvelope(envelope, key) {
  const wire = JSON.parse(envelope);
  assert.equal(wire.v, 1);
  const nonce = Buffer.from(wire.n, "base64url");
  const ct = Buffer.from(wire.ct, "base64url");
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from("HERDR-ACTIVITY:1", "utf8"));
  decipher.setAuthTag(ct.subarray(ct.length - 16));
  const plaintext = Buffer.concat([
    decipher.update(ct.subarray(0, ct.length - 16)),
    decipher.final(),
  ]);
  return { kid: wire.kid, payload: JSON.parse(plaintext.toString("utf8")) };
}

suite("activity-hook: cheap exits", () => {
  test("no live_activity entries send zero requests", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device({ liveActivity: null })]);
    writeHerdrStub([listedAgent()]);

    const result = await runHook(statusEvent("working"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
    assert.equal(stubInvocations().length, 0);
  });

  test("ended last-state short-circuits non-eligible incoming statuses", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeLastState({ sent_at_ms: 1, statuses: {}, ended: true });
    writeHerdrStub([listedAgent({ status: "idle", title: null })]);

    const result = await runHook(statusEvent("idle"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
    assert.equal(stubInvocations().length, 0);
  });
});

suite("activity-hook: update and end", () => {
  test("posts an update with an envelope decryptable under HERDR-ACTIVITY:1", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device(), device({ token: "b".repeat(64), key: KEY_B, activityToken: ACTIVITY_TOKEN_B, env: "production" })]);
    writeHerdrStub([listedAgent({ title: "实现锁屏显示 agent 工作状态" })]);
    const before = Math.floor(Date.now() / 1000);

    const result = await runHook(statusEvent("working"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    for (const request of relay.requests) {
      assert.equal(request.method, "POST");
      assert.equal(request.path, "/push");
      assert.equal(request.body.kind, "liveactivity");
      assert.equal(request.body.event, "update");
      assert.equal(request.body.priority, 5);
      assert.equal(request.body.stale_date, request.body.timestamp + 900);
      assert.equal("dismissal_date" in request.body, false);
      assert.equal("collapse" in request.body, false);
      assert.deepEqual(request.body.counts, { working: 1, blocked: 0, done: 0 });
      assert.ok(request.body.timestamp >= before);
    }
    const byToken = new Map(relay.requests.map((request) => [request.body.token, request.body]));
    assert.equal(byToken.get(ACTIVITY_TOKEN_A).env, "sandbox");
    assert.equal(byToken.get(ACTIVITY_TOKEN_B).env, "production");
    const opened = decryptEnvelope(byToken.get(ACTIVITY_TOKEN_A).envelope, KEY_A);
    assert.equal(opened.payload.host, shortHostName(os.hostname()));
    assert.equal(opened.payload.v, 1);
    assert.equal(opened.payload.agents.length, 1);
    assert.equal(opened.payload.agents[0].kind, "claude");
    assert.equal(opened.payload.agents[0].pane, PANE_ID);
    assert.equal(opened.payload.agents[0].status, "working");
    assert.equal(opened.payload.agents[0].title, "实现锁屏显示 agent 工作状态");
    decryptEnvelope(byToken.get(ACTIVITY_TOKEN_B).envelope, KEY_B);
    assert.deepEqual(stubInvocations()[0].args, ["agent", "list"]);
  });

  test("pinned_pane_ids from each device reorder that device's envelope only", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([
      device({
        liveActivity: {
          token: ACTIVITY_TOKEN_A,
          started_at: "2026-01-01T00:00:00Z",
          pinned_pane_ids: ["w1:p2"],
        },
      }),
      device({
        token: "b".repeat(64),
        key: KEY_B,
        activityToken: ACTIVITY_TOKEN_B,
        env: "production",
      }),
    ]);
    writeHerdrStub([
      listedAgent({ pane: "w1:p1", status: "blocked", title: "need input" }),
      listedAgent({ pane: "w1:p2", status: "working", title: "coding" }),
    ]);

    const result = await runHook(statusEvent("working", { paneId: "w1:p2" }));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    const byToken = new Map(relay.requests.map((request) => [request.body.token, request.body]));
    assert.deepEqual(byToken.get(ACTIVITY_TOKEN_A).counts, { working: 1, blocked: 1, done: 0 });
    assert.deepEqual(byToken.get(ACTIVITY_TOKEN_B).counts, { working: 1, blocked: 1, done: 0 });
    const pinned = decryptEnvelope(byToken.get(ACTIVITY_TOKEN_A).envelope, KEY_A);
    const unpinned = decryptEnvelope(byToken.get(ACTIVITY_TOKEN_B).envelope, KEY_B);
    assert.deepEqual(
      pinned.payload.agents.map((entry) => entry.pane),
      ["w1:p2", "w1:p1"],
    );
    assert.deepEqual(
      unpinned.payload.agents.map((entry) => entry.pane),
      ["w1:p1", "w1:p2"],
    );
  });

  test("empty inventory sends end with dismissal_date and empty agents", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub([listedAgent({ status: "idle", title: null })]);

    const result = await runHook(statusEvent("idle"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 1);
    const body = relay.requests[0].body;
    assert.equal(body.event, "end");
    assert.equal(body.priority, 5);
    assert.equal(body.dismissal_date, body.timestamp);
    assert.equal("stale_date" in body, false);
    assert.deepEqual(body.counts, { working: 0, blocked: 0, done: 0 });
    const { payload } = decryptEnvelope(body.envelope, KEY_A);
    assert.deepEqual(payload.agents, []);
    assert.equal(payload.host, shortHostName(os.hostname()));
  });
});

suite("activity-hook: priority and suppression", () => {
  test("new blocked is priority 10, a repeat state sends nothing, a change without new blocked is 5", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);

    writeHerdrStub([listedAgent({ status: "blocked", title: "need input" })]);
    const first = await runHook(statusEvent("blocked"));
    assert.equal(first.status, 0, first.stderr);
    assert.equal(relay.requests.length, 1);
    assert.equal(relay.requests[0].body.priority, 10);
    assert.equal(relay.requests[0].body.event, "update");

    const repeat = await runHook(statusEvent("blocked"));
    assert.equal(repeat.status, 0, repeat.stderr);
    assert.equal(relay.requests.length, 1);

    writeHerdrStub([
      listedAgent({ status: "blocked", title: "need input" }),
      listedAgent({ pane: "w1:p3", status: "done", title: "landed" }),
    ]);
    const changed = await runHook(statusEvent("done", { paneId: "w1:p3" }));
    assert.equal(changed.status, 0, changed.stderr);
    assert.equal(relay.requests.length, 2);
    assert.equal(relay.requests[1].body.priority, 5);
    assert.deepEqual(relay.requests[1].body.counts, { working: 0, blocked: 1, done: 1 });
  });
});

suite("activity-hook: debounce", () => {
  test("overlapping invocations produce one send", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub([listedAgent()]);

    const [first, second] = await Promise.all([
      runHook(statusEvent("working")),
      runHook(statusEvent("working")),
    ]);

    assert.equal(first.status, 0, first.stderr);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(relay.requests.length, 1);
  });
});

suite("activity-hook: relay failures", () => {
  test("a 410 Unregistered prunes only live_activity, preserving the rest of the entry", async () => {
    await startFakeRelay(() => ({ status: 410, body: { reason: "Unregistered" } }));
    writeConfig();
    writeRegistration(
      [
        device({ future_entry_field: "kept" }),
        device({ token: "b".repeat(64), key: KEY_B, activityToken: ACTIVITY_TOKEN_B }),
      ],
      { future_top_field: "kept" },
    );
    writeHerdrStub([listedAgent()]);

    const result = await runHook(statusEvent("working"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    const file = readRegistration();
    assert.equal(file.v, 1);
    assert.equal(file.future_top_field, "kept");
    assert.equal(file.devices.length, 2);
    assert.equal(file.devices[0].token, ALERT_TOKEN);
    assert.equal(file.devices[0].key, KEY_A.toString("base64url"));
    assert.deepEqual(file.devices[0].notify, { blocked: true, done: true });
    assert.equal(file.devices[0].future_entry_field, "kept");
    assert.equal("live_activity" in file.devices[0], false);
    assert.equal("live_activity" in file.devices[1], false);
  });

  test("a relay-origin 413 resends without titles", async () => {
    await startFakeRelay((_request, index) =>
      index === 0
        ? { status: 413, body: { error: "payload_too_large" } }
        : { status: 200, body: { apnsId: "x" } },
    );
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub([listedAgent({ title: "a long enough title to drop" })]);

    const result = await runHook(statusEvent("working"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    const first = decryptEnvelope(relay.requests[0].body.envelope, KEY_A);
    const second = decryptEnvelope(relay.requests[1].body.envelope, KEY_A);
    assert.equal(first.payload.agents[0].title, "a long enough title to drop");
    assert.equal("title" in second.payload.agents[0], false);
    assert.equal(second.payload.agents[0].pane, PANE_ID);
    assert.equal(second.payload.agents[0].status, "working");
  });
});
