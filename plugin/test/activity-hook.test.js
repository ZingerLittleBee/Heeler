// Process-boundary tests for the Live Activity hook.
//
// activity-hook.js runs as a herdr [[events]] hook command, so these tests
// exercise it the same way: a real child process launched with the env herdr
// injects, against an in-test fake relay HTTP server and a stub HERDR_BIN_PATH
// that answers `herdr agent list` and, for Account suggestions,
// `herdr pane process-info`.

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createDecipheriv } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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

// `processInfo` answers `pane process-info`: an object, "fail" (exit 1),
// "invalid" (not JSON) or "hang" (never answers).
function writeHerdrStub(
  agents,
  workspaces = [{ workspace_id: "w1", label: "Heeler" }],
  tabs = [],
  panes = [],
  processInfo = undefined,
) {
  const binPath = join(stubDir, "herdr");
  writeFileSync(join(stubDir, "response.json"), JSON.stringify({ agents, workspaces, tabs, panes, processInfo }));
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
      '} else if (args[0] === "pane" && args[1] === "process-info" && response.processInfo !== undefined) {',
      '  if (response.processInfo === "fail") process.exit(1);',
      '  if (response.processInfo === "hang") Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 60_000);',
      '  process.stdout.write(response.processInfo === "invalid" ? "not json"',
      '    : JSON.stringify({ id: "cli:pane:process-info", result: { type: "pane_process_info", process_info: response.processInfo } }));',
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

suite("activity-hook: Claude Code Account suggestions", () => {
  // Suggestions serve Usage, so the hook looks only once it records a runtime.
  const usageEnv = { HOME: "/home/ada" };
  const environmentReadable = ["darwin", "linux"].includes(process.platform) ? false : "reads environments on macOS and Linux only";
  let processes = [];
  afterEach(() => {
    for (const child of processes) child.kill("SIGKILL");
    processes = [];
  });
  // A running Agent stand-in: a non-Apple program whose environment the test sets.
  function startProcess(env) {
    const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60_000)"], { env, stdio: "ignore" });
    processes.push(child);
    return child.pid;
  }
  const claudeProcess = (pid, argv0 = "claude") => ({ pid, name: "2.1.312", argv0, argv: [argv0], cmdline: argv0, cwd: "/" });
  const processInfo = (foreground, leader = null) => ({
    pane_id: PANE_ID, tty: "/dev/ttys001", shell_pid: 1, foreground_process_group_id: leader, foreground_processes: foreground,
  });
  const agentsPath = () => join(stateDir, "usage", "claude-agents.json");
  const agentsFile = () => JSON.parse(readFileSync(agentsPath(), "utf8"));
  const lookups = () => stubInvocations().filter((entry) => entry.args[0] === "pane" && entry.args[1] === "process-info");
  // Only a directory that exists is kept, so the Agents' directories are real.
  const agentDirectory = (...names) => {
    const path = join(home, "agents", ...names);
    mkdirSync(path, { recursive: true });
    return path;
  };

  test("keeps only CLAUDE_CONFIG_DIR of the pane's Claude Code process, preferring the group leader", { skip: environmentReadable }, async () => {
    const work = agentDirectory("work dir", ".claude-work");
    const leader = startProcess({ CLAUDE_CONFIG_DIR: work, SECRET_TOKEN: "must-not-be-kept" });
    const follower = startProcess({ CLAUDE_CONFIG_DIR: agentDirectory("follower") });
    const other = startProcess({ CLAUDE_CONFIG_DIR: agentDirectory("other") });
    writeHerdrStub([listedAgent()], undefined, [], [], processInfo([
      claudeProcess(follower, "/opt/claude/bin/claude"), claudeProcess(other, "node"), claudeProcess(leader),
    ], leader));

    const result = await runHook(statusEvent("working"), { env: usageEnv });

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(lookups().map((entry) => entry.args), [["pane", "process-info", "--pane", PANE_ID]]);
    const file = agentsFile();
    assert.deepEqual(Object.keys(file.directories), [work]);
    assert.equal(Object.keys(file.panes).length, 1);
    assert.equal(readFileSync(agentsPath(), "utf8").includes("must-not-be-kept"), false);
    assert.equal(statSync(agentsPath()).mode & 0o777, 0o600);

    // Without a group leader among them, the first Claude Code process counts.
    rmSync(agentsPath());
    writeHerdrStub([listedAgent()], undefined, [], [], processInfo([claudeProcess(other, "node"), claudeProcess(follower, "/opt/claude/bin/claude")]));
    assert.equal((await runHook(statusEvent("working"), { env: usageEnv })).status, 0);
    assert.deepEqual(Object.keys(agentsFile().directories), [join(home, "agents", "follower")]);
  });

  test("keeps only the existing directory the variable names, never the variables after it", { skip: environmentReadable }, async () => {
    const directory = agentDirectory(".claude-2");
    const decoy = agentDirectory("decoy");
    for (const [env, expected] of [
      // bash exports a function under a name with `%%`, and its body has no ` NAME=`.
      [{ CLAUDE_CONFIG_DIR: directory, "BASH_FUNC_tok%%": '() {  curl -H "Authorization: Bearer SECRET-XYZ" https://x\n}' }, [directory]],
      [{ CLAUDE_CONFIG_DIR: directory, "my.token": "SECRET-123" }, [directory]],
      [{ CLAUDE_CONFIG_DIR: join(home, "agents", "gone") }, []],
      // An earlier value that names the variable makes `ps -E` ambiguous; `/proc` is not.
      [{ NOTE: `x CLAUDE_CONFIG_DIR=${decoy} y`, CLAUDE_CONFIG_DIR: directory }, process.platform === "linux" ? [directory] : []],
    ]) {
      rmSync(agentsPath(), { force: true });
      const pid = startProcess(env);
      writeHerdrStub([listedAgent()], undefined, [], [], processInfo([claudeProcess(pid)], pid));
      const result = await runHook(statusEvent("working"), { env: usageEnv });
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(Object.keys(agentsFile().directories), expected);
      assert.equal(readFileSync(agentsPath(), "utf8").includes("SECRET"), false);
    }
  });

  test("a process without CLAUDE_CONFIG_DIR, or with a relative one, suggests nothing", { skip: environmentReadable }, async () => {
    for (const env of [{ OTHER: "1" }, { CLAUDE_CONFIG_DIR: "relative/claude" }]) {
      rmSync(agentsPath(), { force: true });
      const pid = startProcess(env);
      writeHerdrStub([listedAgent()], undefined, [], [], processInfo([claudeProcess(pid)], pid));
      const result = await runHook(statusEvent("working"), { env: usageEnv });
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(agentsFile().directories, {});
    }
  });

  test("a pane is looked up at most once every 10 minutes per herdr session, and old directories expire", async () => {
    const now = Date.now();
    mkdirSync(join(stateDir, "usage"), { recursive: true });
    writeFileSync(agentsPath(), JSON.stringify({ panes: {}, directories: {
      "/agents/old": now - 31 * 86_400_000, "/agents/recent": now - 86_400_000, "relative": now,
    } }));
    writeHerdrStub([listedAgent()], undefined, [], [], processInfo([]));
    const run = async (event, env = {}) => {
      const result = await runHook(event, { env: { ...usageEnv, ...env } });
      assert.equal(result.status, 0, result.stderr);
      return lookups().length;
    };

    assert.equal(await run(statusEvent("working")), 1);
    assert.deepEqual(Object.keys(agentsFile().directories), ["/agents/recent"]);
    assert.equal(await run(statusEvent("blocked")), 1);
    assert.equal(await run(statusEvent("working", { paneId: "w1:p3" })), 2);
    // Pane ids repeat across herdr sessions.
    assert.equal(await run(statusEvent("working"), { HERDR_SOCKET_PATH: "/home/ada/.config/herdr/sessions/work/herdr.sock" }), 3);
    const file = agentsFile();
    for (const pane of Object.keys(file.panes)) file.panes[pane] -= 11 * 60_000;
    writeFileSync(agentsPath(), JSON.stringify(file));
    assert.equal(await run(statusEvent("working")), 4);
    // Checks past their interval leave the file.
    assert.equal(Object.keys(agentsFile().panes).length, 1);
  });

  test("only Claude Code Agents are looked up", async () => {
    writeHerdrStub([listedAgent()], undefined, [], [], processInfo([]));
    for (const agent of ["codex", null]) {
      const result = await runHook(statusEvent("working", { agent }), { env: usageEnv });
      assert.equal(result.status, 0, result.stderr);
    }
    assert.equal(lookups().length, 0);
    assert.equal(existsSync(agentsPath()), false);
  });

  test("a process-info that fails, answers garbage or hangs never fails the hook or its Live Activity", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    for (const [index, answer] of ["fail", "invalid", "hang"].entries()) {
      writeHerdrStub([listedAgent()], undefined, [], [], answer);
      rmSync(join(stateDir, "activity"), { recursive: true, force: true });
      const started = Date.now();

      const result = await runHook(statusEvent("working", { paneId: `w1:p${index + 10}` }), { env: usageEnv });

      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stderr, "");
      assert.equal(relay.requests.length, index + 1);
      // A lookup that never answers is given up after 3 seconds.
      assert.ok(Date.now() - started < 8_000);
    }
    assert.equal(lookups().length, 3);
    const file = agentsFile();
    assert.deepEqual(file.directories, {});
    assert.equal(Object.keys(file.panes).length, 3);
  });
});
