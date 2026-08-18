// Process-boundary tests for the Agent Notification notify hook (ADR 0008).
//
// notify-hook.js runs as a herdr [[events]] hook command, so these tests
// exercise it the same way: a real child process launched with the env herdr
// injects (HERDR_PLUGIN_EVENT_JSON, state dir, config dir, HERDR_BIN_PATH),
// against an in-test fake relay HTTP server and a stub HERDR_BIN_PATH binary
// controlling the debounce re-check. The fake relay and stub binary sit at
// true external boundaries; nothing internal is mocked.
//
// The event fixture reproduces the hook payload captured empirically against
// a live herdr 0.7.5 (see the shape comment in src/notify-hook.js).

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createDecipheriv } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const NOTIFY_SCRIPT = fileURLToPath(new URL("../src/notify-hook.js", import.meta.url));

const DEBOUNCE_MS = 120;
const RETRY_DELAY_MS = 10;

// Two Notification Keys from the shared-vector fixtures (raw bytes 0..31 and
// 255..224), so decryptability here lines up with the pinned vectors.
const KEY_A = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const KEY_B = Buffer.from(Array.from({ length: 32 }, (_, i) => 255 - i));
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);
const FCM_TOKEN_A = "fcm:opaque-registration/token-a";
const FCM_TOKEN_B = "fcm:opaque-registration/token-b";

const PANE_ID = "w1:p2";

let home;
let stateDir;
let configDir;
let stubDir;
let relay;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "notify-hook-"));
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

/** Start an in-test relay. `respond(request, index)` returns {status, body}. */
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

/**
 * Write the HERDR_BIN_PATH stub: logs every invocation and answers the two
 * subcommands the hook runs, like the real herdr CLI does — `agent get` with
 * a canned status (or an agent_not_found error when status is null) and
 * `workspace get` with a canned label (or a failure when it is null).
 */
function writeHerdrStub({
  status,
  agent = "claude",
  title = undefined,
  workspaceLabel = "Proj",
}) {
  const binPath = join(stubDir, "herdr");
  const agentInfo = { agent, agent_status: status, pane_id: PANE_ID, workspace_id: "w1" };
  if (title !== undefined) {
    agentInfo.terminal_title = `⠂ ${title}`;
    agentInfo.terminal_title_stripped = title;
  }
  const response = {
    agent:
      status === null
        ? {
            out: {
              error: { code: "agent_not_found", message: "agent target not found" },
              id: "cli:agent:get",
            },
            code: 1,
          }
        : {
            out: { id: "cli:agent:get", result: { agent: agentInfo, type: "agent_info" } },
            code: 0,
          },
    workspace:
      workspaceLabel === null
        ? {
            out: { error: { code: "workspace_not_found", message: "no such workspace" }, id: "x" },
            code: 1,
          }
        : {
            out: {
              id: "cli:workspace:get",
              result: {
                workspace: { workspace_id: "w1", label: workspaceLabel },
                type: "workspace_info",
              },
            },
            code: 0,
          },
  };
  writeFileSync(join(stubDir, "response.json"), JSON.stringify(response));
  // The stub is CommonJS on purpose: it lives outside the plugin package, so
  // no "type": "module" applies to it.
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
      "const answer = response[args[0]];",
      "if (answer === undefined) {",
      '  process.stderr.write(`stub: unexpected subcommand ${args.join(" ")}`);',
      "  process.exit(64);",
      "}",
      "process.stdout.write(JSON.stringify(answer.out));",
      "process.exit(answer.code);",
    ].join("\n"),
    { mode: 0o755 },
  );
  return binPath;
}

/** The invocations of one herdr subcommand, in order. */
function stubInvocationsOf(subcommand) {
  return stubInvocations().filter((entry) => entry.args[0] === subcommand);
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
      debounce_ms: DEBOUNCE_MS,
      retry_delay_ms: RETRY_DELAY_MS,
      ...overrides,
    }),
  );
}

function device({ token = TOKEN_A, key = KEY_A, env = "sandbox", notify, ...extra } = {}) {
  return {
    token,
    key: key.toString("base64url"),
    env,
    notify: notify === undefined ? { blocked: true, done: true } : notify,
    ...extra,
  };
}

function fcmDevice({ token = FCM_TOKEN_A, key = KEY_A, notify, ...extra } = {}) {
  return {
    provider: "fcm",
    token,
    key: key.toString("base64url"),
    notify: notify === undefined ? { blocked: true, done: true } : notify,
    ...extra,
  };
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
    const child = spawn(process.execPath, [NOTIFY_SCRIPT], {
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

/** Decrypt a POSTed envelope with the given Notification Key (test-side inverse). */
function decryptEnvelope(envelope, key) {
  const wire = JSON.parse(envelope);
  assert.equal(wire.v, 1);
  const nonce = Buffer.from(wire.n, "base64url");
  const ct = Buffer.from(wire.ct, "base64url");
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from("HERDR-NOTIFY:1", "utf8"));
  decipher.setAuthTag(ct.subarray(ct.length - 16));
  const plaintext = Buffer.concat([decipher.update(ct.subarray(0, ct.length - 16)), decipher.final()]);
  return { kid: wire.kid, payload: JSON.parse(plaintext.toString("utf8")) };
}

suite("notify-hook: sending", () => {
  test("a confirmed Blocked transition posts one decryptable push per device", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device(), device({ token: TOKEN_B, key: KEY_B, env: "production" })]);
    writeHerdrStub({ status: "blocked" });
    const before = Math.floor(Date.now() / 1000);

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    for (const request of relay.requests) {
      assert.equal(request.method, "POST");
      assert.equal(request.path, "/push");
    }
    const byToken = new Map(relay.requests.map((r) => [r.body.token, r.body]));
    const forA = byToken.get(TOKEN_A);
    const forB = byToken.get(TOKEN_B);
    assert.equal(forA.env, "sandbox");
    assert.equal(forB.env, "production");

    const a = decryptEnvelope(forA.envelope, KEY_A);
    const b = decryptEnvelope(forB.envelope, KEY_B);
    for (const { payload } of [a, b]) {
      assert.equal(payload.pane, PANE_ID);
      assert.equal(payload.kind, "claude");
      assert.equal(payload.status, "blocked");
      assert.ok(payload.ts >= before && payload.ts <= Math.floor(Date.now() / 1000) + 1);
    }
    assert.notEqual(a.kid, b.kid);
  });

  test("a confirmed Blocked transition posts an FCM device's opaque token without an APNs environment", async () => {
    await startFakeRelay(() => ({ status: 200, body: { fcmName: "projects/heeler/messages/x" } }));
    writeConfig();
    writeRegistration([device(), fcmDevice({ token: FCM_TOKEN_B, key: KEY_B })]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    const byToken = new Map(relay.requests.map((request) => [request.body.token, request.body]));
    const apns = byToken.get(TOKEN_A);
    const fcm = byToken.get(FCM_TOKEN_B);
    assert.equal("provider" in apns, false);
    assert.equal(apns.env, "sandbox");
    assert.equal(fcm.provider, "fcm");
    assert.equal("env" in fcm, false);
    assert.equal(fcm.collapse.length > 0, true);
    assert.equal(decryptEnvelope(fcm.envelope, KEY_B).payload.status, "blocked");
  });

  test("the collapse key is opaque, per pane, and stable across sends", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });
    await runHook(statusEvent("blocked"));

    writeHerdrStub({ status: "done" });
    await runHook(statusEvent("done"));

    assert.equal(relay.requests.length, 2);
    const [first, second] = relay.requests.map((r) => r.body.collapse);
    assert.equal(typeof first, "string");
    assert.ok(first.length > 0 && first.length <= 64);
    // Same pane -> same collapse key, so a newer status replaces the older
    // notification; and the key must not leak the pane id to the relay.
    assert.equal(first, second);
    assert.ok(!first.includes(PANE_ID));

    // A different pane collapses independently.
    writeHerdrStub({ status: "blocked" });
    await runHook(statusEvent("blocked", { paneId: "w9:p9" }));
    assert.equal(relay.requests.length, 3);
    assert.notEqual(relay.requests[2].body.collapse, first);
  });

  test("a Done transition with a missing event agent falls back to the re-checked agent kind", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "done", agent: "codex" });

    const result = await runHook(statusEvent("done", { agent: null }));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 1);
    const { payload } = decryptEnvelope(relay.requests[0].body.envelope, KEY_A);
    assert.equal(payload.kind, "codex");
    assert.equal(payload.status, "done");
  });

  test("the payload carries the project name and the agent's task title", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({
      status: "blocked",
      title: "排查修复 split 按钮 UI 结构问题",
      workspaceLabel: "Caterm",
    });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    const { payload } = decryptEnvelope(relay.requests[0].body.envelope, KEY_A);
    assert.equal(payload.project, "Caterm");
    assert.equal(payload.title, "排查修复 split 按钮 UI 结构问题");
    // The label is resolved for the workspace the re-check reports.
    assert.deepEqual(stubInvocationsOf("workspace")[0].args, ["workspace", "get", "w1"]);
  });

  test("a title longer than the display limit is trimmed with an ellipsis", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    const long = "重构传输层".repeat(40);
    writeHerdrStub({ status: "blocked", title: long });

    await runHook(statusEvent("blocked"));

    const { payload } = decryptEnvelope(relay.requests[0].body.envelope, KEY_A);
    assert.equal([...payload.title].length, 80);
    assert.ok(payload.title.endsWith("…"));
    assert.ok(long.startsWith([...payload.title].slice(0, 79).join("")));
  });

  test("an unresolvable workspace label just omits the project", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked", title: "Fix the flaky test", workspaceLabel: null });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    const { payload } = decryptEnvelope(relay.requests[0].body.envelope, KEY_A);
    assert.equal("project" in payload, false);
    assert.equal(payload.title, "Fix the flaky test");
  });

  test("an agent with no title at all still notifies", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "done" });

    const result = await runHook(statusEvent("done"));

    assert.equal(result.status, 0, result.stderr);
    const { payload } = decryptEnvelope(relay.requests[0].body.envelope, KEY_A);
    assert.equal("title" in payload, false);
    assert.equal(payload.status, "done");
  });

  test("unknown event fields are ignored (lenient parse)", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    const event = statusEvent("blocked", { future_field: "x", state_labels: { a: "b" } });
    event.top_level_future = true;
    const result = await runHook(event);

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 1);
  });
});

suite("notify-hook: debounce", () => {
  test("re-checks through HERDR_BIN_PATH only after the debounce sleep", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });
    const startedAt = Date.now();

    await runHook(statusEvent("blocked"));

    const invocations = stubInvocationsOf("agent");
    assert.equal(invocations.length, 1);
    assert.deepEqual(invocations[0].args, ["agent", "get", PANE_ID]);
    assert.ok(
      invocations[0].at - startedAt >= DEBOUNCE_MS,
      `re-check ran ${invocations[0].at - startedAt}ms after start, before the ${DEBOUNCE_MS}ms debounce`,
    );
  });

  test("aborts without posting when the status moved on during the debounce", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "working" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
    assert.equal(stubInvocations().length, 1);
  });

  test("aborts without posting when the agent is gone at re-check time", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: null });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
  });

  test("fails closed when the re-check itself cannot run", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);

    const result = await runHook(statusEvent("blocked"), {
      binPath: join(stubDir, "does-not-exist"),
    });

    assert.equal(result.status, 1);
    assert.equal(relay.requests.length, 0);
  });
});

suite("notify-hook: triggers and preferences", () => {
  test("working, idle, and unknown transitions never post", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    for (const status of ["working", "idle", "unknown"]) {
      writeHerdrStub({ status });
      const result = await runHook(statusEvent(status));
      assert.equal(result.status, 0, result.stderr);
    }
    assert.equal(relay.requests.length, 0);
  });

  test("per-device preference flags gate each status", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([
      device({ notify: { blocked: true, done: false } }),
      device({ token: TOKEN_B, key: KEY_B, notify: { blocked: false, done: true } }),
    ]);

    writeHerdrStub({ status: "blocked" });
    await runHook(statusEvent("blocked"));
    assert.deepEqual(
      relay.requests.map((r) => r.body.token),
      [TOKEN_A],
    );

    writeHerdrStub({ status: "done" });
    await runHook(statusEvent("done"));
    assert.deepEqual(
      relay.requests.map((r) => r.body.token),
      [TOKEN_A, TOKEN_B],
    );
  });

  test("a missing notify flag means do not send (fail closed)", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([
      device({ notify: null }),
      device({ token: TOKEN_B, key: KEY_B, notify: { blocked: true } }),
    ]);
    writeHerdrStub({ status: "done" });

    const result = await runHook(statusEvent("done"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
  });
});

suite("notify-hook: dedupe", () => {
  test("a same-status repeat does not post again", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    await runHook(statusEvent("blocked"));
    const repeat = await runHook(statusEvent("blocked"));

    assert.equal(repeat.status, 0, repeat.stderr);
    assert.equal(relay.requests.length, 1);
  });

  test("a confirmed different status re-arms the pane", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);

    writeHerdrStub({ status: "blocked" });
    await runHook(statusEvent("blocked"));

    writeHerdrStub({ status: "working" });
    await runHook(statusEvent("working"));

    writeHerdrStub({ status: "blocked" });
    await runHook(statusEvent("blocked"));

    assert.equal(relay.requests.length, 2);
  });

  test("a flapping intermediate status does not re-arm (re-check disagrees)", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    await runHook(statusEvent("blocked"));
    // Detection flaps to working, but by re-check time it is blocked again:
    // the clear must not happen, so the following blocked repeat stays deduped.
    await runHook(statusEvent("working"));
    const repeat = await runHook(statusEvent("blocked"));

    assert.equal(repeat.status, 0, repeat.stderr);
    assert.equal(relay.requests.length, 1);
  });

  test("dedupe is per pane", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    await runHook(statusEvent("blocked"));
    await runHook(statusEvent("blocked", { paneId: "w9:p9" }));

    assert.equal(relay.requests.length, 2);
  });
});

suite("notify-hook: relay failures", () => {
  test("a 410 Unregistered prunes the token, preserving everything else in the file", async () => {
    await startFakeRelay((request) =>
      request.body.token === TOKEN_A
        ? { status: 410, body: { reason: "Unregistered" } }
        : { status: 200, body: { apnsId: "x" } },
    );
    writeConfig();
    writeRegistration(
      [device({ future_entry_field: "kept" }), device({ token: TOKEN_B, key: KEY_B })],
      { future_top_field: "kept" },
    );
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    const file = readRegistration();
    assert.equal(file.v, 1);
    assert.equal(file.future_top_field, "kept");
    assert.deepEqual(
      file.devices.map((d) => d.token),
      [TOKEN_B],
    );
  });

  test("a 410 from FCM prunes only that FCM registration and preserves its provider metadata", async () => {
    await startFakeRelay((request) =>
      request.body.token === FCM_TOKEN_A
        ? { status: 410, body: { reason: "Unregistered" } }
        : { status: 200, body: { fcmName: "projects/heeler/messages/x" } },
    );
    writeConfig();
    writeRegistration(
      [
        fcmDevice({ future_entry_field: "remove-me" }),
        fcmDevice({ token: FCM_TOKEN_B, key: KEY_B, future_entry_field: "kept" }),
      ],
      { future_top_field: "kept" },
    );
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    const file = readRegistration();
    assert.equal(file.future_top_field, "kept");
    assert.deepEqual(file.devices, [
      fcmDevice({ token: FCM_TOKEN_B, key: KEY_B, future_entry_field: "kept" }),
    ]);
  });

  test("a transient 5xx is retried until it succeeds", async () => {
    await startFakeRelay((_request, index) =>
      index === 0
        ? { status: 500, body: { error: "boom" } }
        : { status: 200, body: { apnsId: "x" } },
    );
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 2);
    // The send succeeded, so the repeat is deduped as usual.
    await runHook(statusEvent("blocked"));
    assert.equal(relay.requests.length, 2);
  });

  test("a persistent failure gives up after the attempt cap and does not record a send", async () => {
    await startFakeRelay(() => ({ status: 500, body: { error: "boom" } }));
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 1);
    assert.equal(relay.requests.length, 3);
    assert.match(result.stderr, /500/);

    // Nothing was delivered, so a repeat event must try again, not dedupe.
    await startFakeRelay();
    writeConfig();
    const retry = await runHook(statusEvent("blocked"));
    assert.equal(retry.status, 0, retry.stderr);
    assert.equal(relay.requests.length, 1);
  });

  test("a partial delivery does not suppress a later same-status retry", async () => {
    await startFakeRelay((request) =>
      request.body.token === TOKEN_B
        ? { status: 400, body: { error: "bad_token" } }
        : { status: 200, body: { apnsId: "x" } },
    );
    writeConfig();
    writeRegistration([device(), device({ token: TOKEN_B, key: KEY_B })]);
    writeHerdrStub({ status: "blocked" });

    const initial = await runHook(statusEvent("blocked"));

    assert.equal(initial.status, 1);
    assert.equal(relay.requests.length, 2);

    await startFakeRelay();
    writeConfig();
    const retry = await runHook(statusEvent("blocked"));

    assert.equal(retry.status, 0, retry.stderr);
    assert.equal(relay.requests.length, 2);
  });

  test("a permanent 4xx is not retried", async () => {
    await startFakeRelay(() => ({ status: 400, body: { error: "bad_token" } }));
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 1);
    assert.equal(relay.requests.length, 1);
  });
});

suite("notify-hook: configuration and registration file", () => {
  test("an absent registration file sends nothing", async () => {
    await startFakeRelay();
    writeConfig();
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
  });

  test("a registration file with a foreign version is treated as absent", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    const file = readRegistration();
    file.v = 2;
    writeFileSync(join(configDir, "notifications.json"), JSON.stringify(file));
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
  });

  test("a corrupt registration file is treated as absent", async () => {
    await startFakeRelay();
    writeConfig();
    writeFileSync(join(configDir, "notifications.json"), "{not json");
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.equal(relay.requests.length, 0);
  });

  test("a device entry with a malformed key or env is skipped, not fatal", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([
      device({ key: Buffer.alloc(16) }),
      device({ token: TOKEN_B, key: KEY_B, env: "carrier-pigeon" }),
      device({ token: "c".repeat(64), key: KEY_A }),
    ]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(
      relay.requests.map((r) => r.body.token),
      ["c".repeat(64)],
    );
  });

  test("an opaque FCM token is accepted while FCM entries with env or malformed providers are skipped", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([
      fcmDevice(),
      fcmDevice({ token: FCM_TOKEN_B, env: "sandbox" }),
      { provider: "webpush", token: "opaque", key: KEY_A.toString("base64url"), notify: { blocked: true } },
      {
        provider: null,
        token: "d".repeat(64),
        key: KEY_A.toString("base64url"),
        env: "sandbox",
        notify: { blocked: true },
      },
    ]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook(statusEvent("blocked"));

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(
      relay.requests.map((request) => request.body.token),
      [FCM_TOKEN_A],
    );
  });

  test("an unparseable event JSON fails without contacting anything", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook("not json");

    assert.equal(result.status, 1);
    assert.equal(relay.requests.length, 0);
    assert.equal(stubInvocations().length, 0);
  });

  test("an event without a pane id or status fails leniently but loudly", async () => {
    await startFakeRelay();
    writeConfig();
    writeRegistration([device()]);
    writeHerdrStub({ status: "blocked" });

    const result = await runHook({ event: "pane_agent_status_changed", data: { type: "x" } });

    assert.equal(result.status, 1);
    assert.equal(relay.requests.length, 0);
  });
});
