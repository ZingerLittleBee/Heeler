// Process-boundary tests for the Live Activity hook.
//
// activity-hook.js runs as a herdr [[events]] hook command, so these tests
// exercise it the same way: a real child process launched with the env herdr
// injects, against an in-test fake relay HTTP server and a stub HERDR_BIN_PATH
// that answers `herdr agent list`.

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createDecipheriv, createHash } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os, { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { parse as parseToml } from "smol-toml";

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

function writeHerdrStub(
  agents,
  workspaces = [{ workspace_id: "w1", label: "Heeler" }],
  tabs = [],
  panes = [],
) {
  const binPath = join(stubDir, "herdr");
  writeFileSync(join(stubDir, "response.json"), JSON.stringify({ agents, workspaces, tabs, panes }));
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
      'const response = JSON.parse(fs.readFileSync(path.join(dir, "response.json"), "utf8"));',
      'if (args[0] === "agent" && args[1] === "list") {',
      '  process.stdout.write(JSON.stringify({ id: "cli:agent:list", result: { agents: response.agents, type: "agent_list" } }));',
      '} else if (args[0] === "workspace" && args[1] === "list") {',
      '  process.stdout.write(JSON.stringify({ id: "cli:workspace:list", result: { workspaces: response.workspaces, type: "workspace_list" } }));',
      '} else if (["tab", "pane"].includes(args[0]) && args[1] === "list") {',
      '  const key = args[0] + "s";',
      '  process.stdout.write(JSON.stringify({ result: { [key]: response[key] } }));',
      '} else {',
      '  process.stderr.write(`stub: unexpected subcommand ${args.join(" ")}`);',
      "  process.exit(64);",
      "}",
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
    assert.equal(opened.payload.agents[0].workspace, "Heeler");
    decryptEnvelope(byToken.get(ACTIVITY_TOKEN_B).envelope, KEY_B);
    assert.deepEqual(stubInvocations().map((entry) => entry.args), [
      ["agent", "list"],
      ["workspace", "list"],
    ]);
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
    assert.equal(second.payload.agents[0].workspace, "Heeler");
    assert.equal(second.payload.agents[0].pane, PANE_ID);
    assert.equal(second.payload.agents[0].status, "working");
  });
});


suite("activity-hook: registered Agent List Fields", () => {
  test("devices render separate layouts and a preference change bypasses unchanged status suppression", async () => {
    await startFakeRelay();
    writeConfig();
    const live = { token: ACTIVITY_TOKEN_A, host_name: "My Mac", row_layout: { rows: [[{ token: "host" }], [{ token: "directory", dim: true }]] } };
    writeRegistration([device({ liveActivity: live }), device({ token: "b".repeat(64), key: KEY_B, activityToken: ACTIVITY_TOKEN_B })]);
    writeHerdrStub([{ ...listedAgent(), cwd: "/work/Heeler" }]);
    let result = await runHook(statusEvent("working"));
    assert.equal(result.status, 0, result.stderr);
    const first = decryptEnvelope(relay.requests[0].body.envelope, KEY_A).payload;
    assert.deepEqual(first.agents[0].rows, [[{ text: "My Mac" }], [{ dim: true, text: "/work/Heeler" }]]);
    assert.equal("rows" in decryptEnvelope(relay.requests[1].body.envelope, KEY_B).payload.agents[0], false);
    live.row_layout.rows = [[{ token: "agent" }]];
    writeRegistration([device({ liveActivity: live })]);
    result = await runHook(statusEvent("working"));
    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 3);
    assert.deepEqual(decryptEnvelope(relay.requests[2].body.envelope, KEY_A).payload.agents[0].rows,
      [[{ text: "claude" }]]);
  });

  test("fetches tab and pane context once per workspace for configured fields", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device({ liveActivity: { token: ACTIVITY_TOKEN_A, row_layout: { rows: [[{ token: "tab" }, { token: "pane" }]] } } })]);
    writeHerdrStub([{ ...listedAgent(), workspace_id: "w1", tab_id: "tab" }], undefined,
      [{ workspace_id: "w1", tab_id: "tab", label: "review" }],
      [{ workspace_id: "w1", tab_id: "tab", pane_id: PANE_ID, label: "pane label" }]);
    const result = await runHook(statusEvent("working"));
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(decryptEnvelope(relay.requests[0].body.envelope, KEY_A).payload.agents[0].rows,
      [[{ text: "review" }, { text: " · " }, { text: "pane label" }]]);
    assert.deepEqual(stubInvocations().filter((entry) => ["tab", "pane"].includes(entry.args[0])).map((entry) => entry.args),
      [["tab", "list", "--workspace", "w1"], ["pane", "list", "--workspace", "w1"]]);
  });

  test("payload degradation removes titles, then rows, then agents", async () => {
    await startFakeRelay((request, index) => index < 3 ? { status: 413, body: { error: "payload_too_large" } } : { status: 200, body: {} });
    writeConfig();
    writeRegistration([device({ liveActivity: { token: ACTIVITY_TOKEN_A, row_layout: { rows: [[{ token: "directory" }]] } } })]);
    writeHerdrStub([{ ...listedAgent(), workspace_id: "w1", cwd: "/work/Heeler" }]);
    const result = await runHook(statusEvent("working"));
    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 4);
    const contents = relay.requests.map((request) => decryptEnvelope(request.body.envelope, KEY_A).payload);
    assert.ok(contents[0].agents[0].title);
    assert.equal("title" in contents[1].agents[0], false);
    assert.ok(contents[1].agents[0].rows);
    assert.equal("rows" in contents[2].agents[0], false);
    assert.equal(contents[2].agents[0].workspace, "Heeler");
    assert.deepEqual(contents[3].agents, []);
  });
});

suite("activity-hook: herdr sessions", () => {
  const DEFAULT_SOCKET = "/home/ada/.config/herdr/herdr.sock";
  const socketFor = (session) => `/home/ada/.config/herdr/sessions/${session}/herdr.sock`;

  test("a hook delivers to legacy entries and entries of its own session only", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([
      device(),
      device({ token: "b".repeat(64), key: KEY_B, activityToken: ACTIVITY_TOKEN_B, session: "" }),
      device({ token: "e".repeat(64), activityToken: "f".repeat(64), session: "work" }),
    ]);
    writeHerdrStub([listedAgent()]);

    const result = await runHook(statusEvent("working"), {
      env: { HERDR_SOCKET_PATH: socketFor("work") },
    });

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(
      relay.requests.map((request) => request.body.token).sort(),
      [ACTIVITY_TOKEN_A, "f".repeat(64)],
    );
  });

  test("a session without its own entries makes no herdr calls", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device({ session: "work" })]);
    writeHerdrStub([listedAgent()]);

    const result = await runHook(statusEvent("working"), {
      env: { HERDR_SOCKET_PATH: DEFAULT_SOCKET },
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
    assert.equal(stubInvocations().length, 0);
    assert.equal(existsSync(join(stateDir, "activity", "claim.json")), false);
  });

  test("overlapping claims of two sessions do not supersede each other", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub([listedAgent()]);

    const [first, second] = await Promise.all([
      runHook(statusEvent("working"), { env: { HERDR_SOCKET_PATH: DEFAULT_SOCKET } }),
      runHook(statusEvent("working"), { env: { HERDR_SOCKET_PATH: socketFor("work") } }),
    ]);

    assert.equal(first.status, 0, first.stderr);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(relay.requests.length, 2);
    // The default session keeps the pre-session state path; named sessions nest.
    assert.ok(existsSync(join(stateDir, "activity", "last-state.json")));
    assert.ok(existsSync(join(stateDir, "sessions", "work", "activity", "last-state.json")));
  });

  test("one session's ended state does not cheap-exit another session", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeLastState({ sent_at_ms: 1, statuses: {}, ended: true });
    writeHerdrStub([listedAgent({ status: "idle", title: null })]);

    const ended = await runHook(statusEvent("idle"), {
      env: { HERDR_SOCKET_PATH: DEFAULT_SOCKET },
    });
    assert.equal(ended.status, 0, ended.stderr);
    assert.equal(stubInvocations().length, 0);

    const other = await runHook(statusEvent("idle"), {
      env: { HERDR_SOCKET_PATH: socketFor("work") },
    });
    assert.equal(other.status, 0, other.stderr);
    assert.deepEqual(stubInvocations().map((entry) => entry.args), [["agent", "list"]]);
    assert.equal(relay.requests.length, 1);
    assert.equal(relay.requests[0].body.event, "end");
  });
});

suite("activity-hook: conversational rows", () => {
  const socket = () => join(home, "herdr.sock");
  const env = () => ({ HERDR_SOCKET_PATH: socket() });
  const run = (status = "working", options = {}) => runHook(statusEvent(status), { env: env(), ...options });
  const rowsOf = (request, key = KEY_A) => decryptEnvelope(request.body.envelope, key).payload.agents;
  const text = (row) => row.map((span) => span.text).join("");
  const readState = () => JSON.parse(readFileSync(join(stateDir, "activity", "last-state.json"), "utf8"));

  function conversational(overrides = {}) {
    writeConfig({ activity_rows: "conversational", activity_time_zone: "UTC", activity_min_interval_ms: 0, ...overrides });
  }

  function convAgent({ pane = PANE_ID, status = "working", title = "Refactor parser", terminal = "t1", seq = 1, ...extra } = {}) {
    return {
      ...listedAgent({ pane, status, title }), name: "agent-a", terminal_id: terminal, state_change_seq: seq, ...extra,
    };
  }

  beforeEach(() => {
    writeFileSync(socket(), "");
  });

  test("the manifest subscribes only to pane.agent_status_changed (T-H8)", () => {
    const manifest = parseToml(readFileSync(new URL("../herdr-plugin.toml", import.meta.url), "utf8"));
    assert.ok(manifest.events.length > 0);
    for (const entry of manifest.events) assert.equal(entry.on, "pane.agent_status_changed");
  });

  test("an install in the default layout mode with state saved before this change sends no extra push (T-H6)", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub([listedAgent()]);
    // f98028b's preferences key: the device list alone, no rows mode.
    const preferences = createHash("sha256").update(JSON.stringify([
      { token: ACTIVITY_TOKEN_A, env: "sandbox", layout: null, host: null },
    ])).digest("hex");
    writeLastState({ sent_at_ms: 1, statuses: { [PANE_ID]: "working" }, preferences, ended: false });
    const result = await run();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
  });

  test("rows carry the zoned row 3, and identical rows send nothing even when only the raw spinner glyph moved (T-H4)", async () => {
    await startFakeRelay();
    conversational();
    writeRegistration([device()]);
    writeHerdrStub([convAgent()]);
    assert.equal((await run()).status, 0);
    assert.equal(relay.requests.length, 1);
    const [agent] = rowsOf(relay.requests[0]);
    assert.equal(text(agent.rows[1]), "Refactor parser");
    assert.match(text(agent.rows[2]), /^Working · updated \d\d:\d\d UTC$/);

    writeHerdrStub([{ ...convAgent(), terminal_title: "⠄ Refactor parser" }]);
    assert.equal((await run()).status, 0);
    assert.equal(relay.requests.length, 1);
  });

  test("a hidden sixth agent's title change sends nothing; a title change of a shown agent sends at priority 5 (T-H4)", async () => {
    await startFakeRelay();
    conversational();
    writeRegistration([device()]);
    const five = [1, 2, 3, 4, 5].map((n) => convAgent({ pane: `w1:p${n}`, terminal: `t${n}`, title: `Write tests ${n}` }));
    const sixth = (title) => convAgent({ pane: "w1:p9", terminal: "t9", title });
    writeHerdrStub([...five, sixth("Hidden one")]);
    await run();
    assert.equal(relay.requests.length, 1);
    writeHerdrStub([...five, sixth("Hidden two")]);
    await run();
    assert.equal(relay.requests.length, 1);
    writeHerdrStub([{ ...five[0], terminal_title_stripped: "Write docs" }, ...five.slice(1), sixth("Hidden two")]);
    await run();
    assert.equal(relay.requests.length, 2);
    assert.equal(relay.requests[1].body.priority, 5);
  });

  test("the minimum interval waits, then sends the newest state once (T-H4 trailing edge)", async () => {
    await startFakeRelay();
    conversational({ activity_min_interval_ms: 900 });
    writeRegistration([device()]);
    writeHerdrStub([convAgent({ title: "First title" })]);
    await run();
    const sentAt = Date.now();
    writeHerdrStub([convAgent({ title: "Second title" })]);
    const pending = run();
    await new Promise((resolve) => setTimeout(resolve, 400));
    writeHerdrStub([convAgent({ title: "Newest title" })]);
    assert.equal((await pending).status, 0);
    assert.equal(relay.requests.length, 2);
    assert.equal(text(rowsOf(relay.requests[1])[0].rows[1]), "Newest title");
    assert.ok(Date.now() - sentAt >= 750, "the second send waited for the interval");
  });

  test("a flap storm of 12 events inside the interval ends on the last state with at most two pushes", async () => {
    await startFakeRelay();
    conversational({ activity_min_interval_ms: 600 });
    writeRegistration([device()]);
    const runs = [];
    for (let i = 0; i < 12; i += 1) {
      writeHerdrStub([convAgent({ status: i % 2 ? "working" : "done", seq: i + 1, title: `Step ${i}` })]);
      runs.push(run());
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    await Promise.all(runs);
    assert.ok(relay.requests.length >= 1 && relay.requests.length <= 2, String(relay.requests.length));
    assert.equal(text(rowsOf(relay.requests.at(-1))[0].rows[1]), "Step 11");
  });

  test("newly blocked is priority 10 until activity_p10_per_hour, then 5 with a log line (T-H4 ledger)", async () => {
    await startFakeRelay();
    conversational({ activity_p10_per_hour: 1 });
    writeRegistration([device()]);
    writeHerdrStub([convAgent({ status: "blocked", seq: 1 })]);
    await run("blocked");
    writeHerdrStub([convAgent({ status: "working", seq: 2 })]);
    await run();
    writeHerdrStub([convAgent({ status: "blocked", seq: 3 })]);
    const capped = await run("blocked");
    assert.deepEqual(relay.requests.map((request) => request.body.priority), [10, 5, 5]);
    assert.match(capped.stderr, /activity_p10_per_hour reached/);
  });

  test("content-only sends stop at activity_content_per_hour while status changes keep sending", async () => {
    await startFakeRelay();
    conversational({ activity_content_per_hour: 1 });
    writeRegistration([device()]);
    writeHerdrStub([convAgent({ title: "Title 0" })]);
    await run();
    writeHerdrStub([convAgent({ title: "Title 1" })]);
    await run();
    writeHerdrStub([convAgent({ title: "Title 2" })]);
    const skipped = await run();
    assert.match(skipped.stderr, /activity_content_per_hour reached/);
    writeHerdrStub([convAgent({ status: "done", seq: 2, title: "Title 2" })]);
    await run("done");
    assert.equal(relay.requests.length, 3);
    assert.deepEqual(relay.requests.map((request) => request.body.priority), [5, 5, 5]);
  });

  test("a re-block between runs (new seq) shows since as the last block, not the first (T-H3 a)", async () => {
    await startFakeRelay();
    conversational();
    writeRegistration([device()]);
    writeHerdrStub([convAgent({ status: "blocked", seq: 2 })]);
    await run("blocked");
    const first = readState().terminals.t1.since_ms;
    assert.equal(first, null);
    writeHerdrStub([convAgent({ status: "blocked", seq: 4 })]);
    await run("blocked");
    assert.ok(Number.isFinite(readState().terminals.t1.since_ms));
  });

  test("a relay 500 then success leaves since unchanged (T-H3 b)", async () => {
    await startFakeRelay(() => ({ status: 500, body: { error: "down" } }));
    conversational();
    writeRegistration([device()]);
    writeHerdrStub([convAgent({ seq: 1 })]);
    await run();
    writeHerdrStub([convAgent({ status: "blocked", seq: 2 })]);
    const failed = await run("blocked");
    assert.equal(failed.status, 1);
    const since = readState().terminals.t1.since_ms;
    assert.ok(Number.isFinite(since));
    await new Promise((resolve) => setTimeout(resolve, 1100));
    await startFakeRelay();
    writeConfig({ activity_rows: "conversational", activity_time_zone: "UTC", activity_min_interval_ms: 0, relay_url: relay.url });
    assert.equal((await run("blocked")).status, 0);
    assert.equal(readState().terminals.t1.since_ms, since);
    const clock = new Date(since).toISOString().slice(11, 16);
    assert.match(text(rowsOf(relay.requests[0])[0].rows[2]), new RegExp(`^Blocked since ${clock} · updated`));
    assert.equal(relay.requests[0].body.priority, 10);
  });

  test("a new herdr server (socket recreated) with an equal seq resets since to unknown (T-H3 c)", async () => {
    await startFakeRelay();
    conversational();
    writeRegistration([device()]);
    writeHerdrStub([convAgent({ seq: 1 })]);
    await run();
    writeHerdrStub([convAgent({ status: "done", seq: 2 })]);
    await run("done");
    assert.ok(Number.isFinite(readState().terminals.t1.since_ms));
    rmSync(socket());
    await new Promise((resolve) => setTimeout(resolve, 20));
    writeFileSync(socket(), "");
    writeHerdrStub([convAgent({ status: "done", seq: 2, title: "Write docs" })]);
    await run("done");
    assert.equal(readState().terminals.t1.since_ms, null);
    assert.match(text(rowsOf(relay.requests.at(-1))[0].rows[2]), /^Turn ended · updated /);
  });

  test("32 parallel invocations leave a valid state file and one send (T-H10)", async () => {
    await startFakeRelay();
    conversational();
    writeRegistration([device()]);
    writeHerdrStub([convAgent()]);
    const results = await Promise.all(Array.from({ length: 32 }, () => run()));
    for (const result of results) assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 1);
    const state = readState();
    assert.equal(state.v, 2);
    assert.deepEqual(Object.keys(state.terminals), ["t1"]);
  });

  test("worst-case roster fits ct 2800, keeps the blocked agent's row 2 longest, and counts every agent (T-H1)", async () => {
    await startFakeRelay();
    conversational();
    writeRegistration([device()]);
    const wide = "锁".repeat(80);
    const roster = [
      convAgent({ pane: "w1:p1", terminal: "t1", status: "blocked", title: "鍵".repeat(80) }),
      ...[2, 3, 4, 5].map((n) => convAgent({ pane: `w1:p${n}`, terminal: `t${n}`, title: wide, display_agent: "名".repeat(80) })),
    ];
    for (const agents of [roster, [...roster, convAgent({ pane: "w1:p6", terminal: "t6", title: wide })]]) {
      relay.requests.length = 0;
      rmSync(join(stateDir, "activity"), { recursive: true, force: true });
      writeHerdrStub(agents);
      assert.equal((await run("blocked")).status, 0);
      const [request] = relay.requests;
      assert.ok(JSON.parse(request.body.envelope).ct.length <= 2800);
      assert.deepEqual(request.body.counts, { working: agents.length - 1, blocked: 1, done: 0 });
      const shown = rowsOf(request);
      const blocked = shown.find((entry) => entry.status === "blocked");
      assert.ok(blocked);
      for (const entry of shown.filter((other) => other !== blocked)) assert.ok(entry.rows.length <= blocked.rows.length);
    }
  });

  test("switching the mode sends again at the next event and switching back restores the layout rows", async () => {
    await startFakeRelay();
    writeConfig({ relay_url: relay.url });
    writeRegistration([device({ liveActivity: { token: ACTIVITY_TOKEN_A, row_layout: { rows: [[{ token: "agent" }]] } } })]);
    writeHerdrStub([convAgent()]);
    await run();
    conversational();
    await run();
    writeConfig();
    await run();
    assert.equal(relay.requests.length, 3);
    assert.deepEqual(relay.requests.map((request) => rowsOf(request)[0].rows.length), [1, 3, 1]);
  });
});
