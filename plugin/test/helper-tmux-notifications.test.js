// Agent Notifications and Live Activity updates on tmux Hosts (ADRs 0033 and
// 0046): a private real tmux server on one side and the fake Push Relay on the
// other, with the Helper's real tmux follower and listeners in between.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createDecipheriv } from "node:crypto";
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { followRegisteredSessions } from "../helper/core/follower.js";
import { liveActivityListener, tmuxLiveActivityListener } from "../helper/notifications/activity.js";
import { notificationListener, tmuxNotificationListener } from "../helper/notifications/notifier.js";
import { seenMarkFileName } from "../helper/notifications/seen-marks.js";
import { notificationKeyId } from "../helper/shared/notification-envelope.js";
import { combineTmuxListeners, followStoredTmuxServers, followTmuxServer } from "../helper/tmux/follower.js";
import { tmuxTranscriptListener } from "../helper/tmux/transcript-watcher.js";
import { TmuxTurnState } from "../helper/tmux/turn-state.js";
import { decryptActivityEnvelope } from "../src/activity-envelope.js";
import { FakeCore, exchange, waitFor } from "./support/fake-core.js";
import { resolveTestTmux } from "./support/tmux.js";

const { skip, requireTmux } = resolveTestTmux();
const statusVectors = JSON.parse(readFileSync(new URL("../test-vectors/tmux-heeler-status-v1.json", import.meta.url), "utf8"));

const STATUS = exchange("server-status").result;
const CHANNEL = exchange("events-subscribe").result.channel;
const HOST = "studio";
const PATIENCE_MS = 5000;

const KEY_A = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
const KEY_B = Buffer.from(Array.from({ length: 32 }, (_, i) => 250 - i));
const KEY_CORE = Buffer.alloc(32, 9);
const ALERT_A = "a".repeat(64);
const ALERT_B = "b".repeat(64);
const ALERT_CORE = "e".repeat(64);
const ACTIVITY_A = "c0".repeat(32);
const ACTIVITY_B = "d0".repeat(32);
const ACTIVITY_CORE = "f0".repeat(32);

let root;
let home;
let directory;
let relay;
let logs;
const cleanups = [];

async function startRelay(respond = () => ({ status: 200, body: {} })) {
  const requests = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", async () => {
      const request = { path: req.url, body: JSON.parse(raw) };
      const { status, body } = await respond(request, requests.length);
      requests.push(request);
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  cleanups.push(() => new Promise((done) => server.close(done)));
  return { url: `http://127.0.0.1:${server.address().port}`, requests };
}

function writeConfig(relayUrl, { debounceMs = 20, activityDebounceMs = 20 } = {}) {
  writeFileSync(
    join(directory, "notify.json"),
    JSON.stringify({
      relay_url: relayUrl,
      debounce_ms: debounceMs,
      activity_debounce_ms: activityDebounceMs,
      retry_delay_ms: 1,
    }),
  );
}

function entry(key, token, { session = "tmux/work", blocked = true, done = true, activity = null, live = {} } = {}) {
  return {
    token,
    key: key.toString("base64url"),
    env: "sandbox",
    session,
    notify: { blocked, done },
    ...(activity === null ? {} : { live_activity: { token: activity, started_at: "2026-11-10T00:00:00Z", ...live } }),
  };
}

function register(...devices) {
  writeFileSync(join(directory, "notifications.json"), JSON.stringify({ v: 1, devices }));
}

function writeMark(key, instance, marks) {
  const device = notificationKeyId(key);
  writeFileSync(join(directory, seenMarkFileName(device)), JSON.stringify({ core: instance, device, marks, v: 1 }));
}

function openAlert(envelope, key) {
  const wire = JSON.parse(envelope);
  const nonce = Buffer.from(wire.n, "base64url");
  const sealed = Buffer.from(wire.ct, "base64url");
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from("HERDR-NOTIFY:1", "utf8"));
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(sealed.subarray(0, sealed.length - 16)), decipher.final()]).toString("utf8"));
}

function openActivity(body, key) {
  return decryptActivityEnvelope(body.envelope, key);
}

function makeAgentBinary(name) {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const program = join(bin, name);
  writeFileSync(program, `#!${process.execPath}\nsetInterval(() => {}, 1000);\n`, { mode: 0o755 });
  chmodSync(program, 0o755);
  return program;
}

function storePaths(socketName, paths) {
  const folder = join(directory, "tmux", socketName);
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  writeFileSync(join(folder, "paths.json"), `${JSON.stringify(paths)}\n`, { mode: 0o600 });
}

function startPrivateServer(socketName, sessionName, programArgs) {
  const executable = requireTmux();
  const socketDir = join(root, "sockets");
  mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  const socket = join(socketDir, socketName);
  execFileSync(
    executable,
    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", sessionName, "-x", "80", "-y", "24", ...programArgs],
    {
      env: { PATH: "/usr/bin:/bin", HOME: home, USER: "fixture", TMUX_TMPDIR: socketDir },
      stdio: "ignore",
    },
  );
  const stop = () => {
    try {
      execFileSync(executable, ["-N", "-S", socket, "kill-server"], { stdio: "ignore" });
    } catch {
      // Already stopped.
    }
  };
  cleanups.push(async () => stop());
  const run = (...args) => execFileSync(executable, ["-N", "-S", socket, ...args], { encoding: "utf8" });
  const [pidText, startText] = run("display-message", "-p", "#{pid}\t#{start_time}").trim().split("\t");
  return {
    executable,
    socket,
    instance: `tmux-${pidText}-${startText}`,
    stop,
    run,
  };
}

const alertsTo = (token) => relay.requests.filter((req) => req.body.kind !== "liveactivity" && req.body.token === token);
const activitiesTo = (token) => relay.requests.map((req) => req.body).filter((body) => body.kind === "liveactivity" && body.token === token);

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), "heeler-tmux-notify-"));
  home = join(root, "home");
  directory = join(root, "helper");
  mkdirSync(home, { recursive: true });
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  logs = [];
  relay = await startRelay();
  writeConfig(relay.url);
});

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()();
  rmSync(root, { recursive: true, force: true });
});

suite("TmuxTurnState shared vector reads", () => {
  test("matches every reads case in tmux-heeler-status-v1.json", () => {
    assert.ok(statusVectors.reads.length > 0);
    for (const vector of statusVectors.reads) {
      const state = new TmuxTurnState();
      let kind = vector.kind;
      let seen = null;
      let isOpen = false;
      for (const [index, step] of vector.steps.entries()) {
        const label = `${vector.name}, step ${index + 1}`;
        if (step.event === "agent") {
          kind = step.kind;
          continue;
        }
        if (step.event === "open") {
          isOpen = true;
          if (state.last !== null) seen = { ...state.last };
          if (step.mark) assert.deepEqual(seen, step.mark, label);
        } else if (step.event === "close") {
          isOpen = false;
        } else if (step.event === "sample") {
          state.noteSample(step.value ?? "", kind);
          if (isOpen && state.last !== null && (seen === null || state.last.turn > seen.turn)) {
            seen = { ...state.last };
          }
          if (step.mark) assert.deepEqual(seen, step.mark, label);
        }
        const done = state.isDoneFor(seen);
        const shownStatus = kind === null ? null : done ? "done" : state.agentStatus;
        assert.equal(done, step.done, `${label} (done)`);
        assert.equal(shownStatus, step.status, `${label} (status)`);
      }
    }
  });
});

suite("tmux registration scoping and per-server Helper records", () => {
  test("keeps tmux/<socket>/ records apart from core session <socket> and does not refuse tmux/* in core follower", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer("work", "alpha", [fakeClaude, "--ide"]);
    storePaths("work", { executable: server.executable, socket: server.socket });
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=idle:app=claude-code:turn=0:blocked=0");

    // Start a fake herdr-core session ALSO named "work" on the same Host Helper directory.
    const coreSocket = join(root, "run", "herdr-core", "work.sock");
    const fakeCore = await FakeCore.start(coreSocket, {
      status: STATUS,
      snapshot: {
        seq: 1,
        channel: CHANNEL,
        terminals: [
          {
            address: "t1",
            state: "live",
            pid: 7,
            argv: ["/bin/zsh"],
            cwd: "/work/core-proj",
            title: "Core task",
            foreground: { pid: 4242, name: "claude", argv: ["claude"], cwd: "/work/core-proj" },
            status: { state: "working", app: "claude-code" },
            reported: true,
            turn: 0,
          },
        ],
      },
    });
    cleanups.push(() => fakeCore.stop().catch(() => {}));

    register(
      entry(KEY_A, ALERT_A, { session: "tmux/work", activity: ACTIVITY_A }),
      entry(KEY_B, ALERT_B, { session: "tmux/other", activity: ACTIVITY_B }),
      entry(KEY_CORE, ALERT_CORE, { session: "work", activity: ACTIVITY_CORE }),
    );

    const log = (line) => logs.push(line);
    const coreFollowers = followRegisteredSessions({
      directory,
      log,
      pollMs: 25,
      env: { HOME: home, XDG_RUNTIME_DIR: join(root, "run") },
      runUserDirectory: join(root, "none"),
      retryDelayMs: 10,
      listener: {
        connected: (report) => {
          notificationListener({ directory, log }).connected(report);
          liveActivityListener({ directory, log, hostName: HOST }).connected(report);
        },
      },
    });
    cleanups.push(() => coreFollowers.stop());

    const tmuxFollowers = followStoredTmuxServers({
      directory,
      log,
      pollMs: 25,
      pollIntervalMs: 25,
      listener: combineTmuxListeners(
        tmuxNotificationListener({ directory, log }),
        tmuxLiveActivityListener({ directory, log, hostName: HOST }),
      ),
    });
    cleanups.push(() => tmuxFollowers.stop());

    await waitFor(() => existsSync(join(directory, "tmux", "work", "notify.json")), "tmux notify.json created", PATIENCE_MS);
    await waitFor(() => activitiesTo(ACTIVITY_CORE).length >= 1, "core activity sent", PATIENCE_MS);

    // Move tmux pane to blocked -> alerts and Live Activity go ONLY to tmux/work (KEY_A / ACTIVITY_A), never core "work" or "tmux/other".
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1");
    await waitFor(() => alertsTo(ALERT_A).length === 1, "tmux blocked alert sent", PATIENCE_MS);
    await waitFor(() => activitiesTo(ACTIVITY_A).length >= 1, "tmux live activity sent", PATIENCE_MS);

    assert.equal(alertsTo(ALERT_CORE).length, 0);
    assert.equal(alertsTo(ALERT_B).length, 0);
    assert.equal(activitiesTo(ACTIVITY_B).length, 0);
    assert.equal(logs.some((line) => line.includes("refuses this name")), false);

    // Separate record files on disk.
    assert.equal(existsSync(join(directory, "tmux", "work", "notify.json")), true);
    assert.equal(existsSync(join(directory, "tmux", "work", "activity.json")), true);
    assert.equal(existsSync(join(directory, "state", "notify", "work.json")), true);
    assert.equal(existsSync(join(directory, "state", "activity", "work.json")), true);

    // Unregister tmux/work and stop the tmux server: notify.json and activity.json under tmux/work/ are removed while paths.json stays.
    register(entry(KEY_CORE, ALERT_CORE, { session: "work", activity: ACTIVITY_CORE }));
    server.stop();
    await waitFor(() => !existsSync(join(directory, "tmux", "work", "notify.json")), "tmux notify.json cleaned up", PATIENCE_MS);
    await waitFor(() => !existsSync(join(directory, "tmux", "work", "activity.json")), "tmux activity.json cleaned up", PATIENCE_MS);
    assert.equal(existsSync(join(directory, "tmux", "work", "paths.json")), true);
    assert.equal(existsSync(join(directory, "state", "notify", "work.json")), true);
  });
});

suite("tmux Agent Notifications", () => {
  test("settles on first sight, sends Blocked, Error, stepped blocked=<n>, and per-device Done without double-notifying on idle", { skip }, async () => {
    // Use a debounce longer than pollIntervalMs to verify steady polls do not starve pending debounce timers.
    writeConfig(relay.url, { debounceMs: 70, activityDebounceMs: 30 });
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer("work", "backend-api", [fakeClaude, "--ide"]);
    // Seed an already-blocked state at turn=1:blocked=1 before the Helper ever sees this server.
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1");

    register(
      entry(KEY_A, ALERT_A, { session: "tmux/work" }),
      entry(KEY_B, ALERT_B, { session: "tmux/work" }),
    );

    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: tmuxNotificationListener({ directory, log: (line) => logs.push(line) }),
      },
    );
    cleanups.push(() => follower.stop());

    // Wait past debounce: first sight of a new server instance sends nothing.
    await waitFor(() => existsSync(join(directory, "tmux", "work", "notify.json")), "initial notify memory saved", PATIENCE_MS);
    await new Promise((done) => setTimeout(done, 130));
    assert.equal(relay.requests.length, 0);

    // Stepping blocked=1 -> blocked=2 while still reading state=blocked sends a NEW Blocked alert!
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=1:blocked=2");
    await waitFor(() => alertsTo(ALERT_A).length === 1 && alertsTo(ALERT_B).length === 1, "stepped blocked alert", PATIENCE_MS);
    const firstAlert = openAlert(alertsTo(ALERT_A)[0].body.envelope, KEY_A);
    assert.deepEqual(firstAlert, {
      pane: "%0",
      kind: "claude",
      status: "blocked",
      project: "backend-api",
      title: "Claude",
      ts: firstAlert.ts,
    });

    // Device A marks turn 2 as seen before turn 2 finishes (e.g. had it open as turn ended); Device B has not seen turn 2.
    writeMark(KEY_A, server.instance, [{ terminal: "%0", turn: 2, word: "done" }]);
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=done:app=claude-code:turn=2:blocked=2");
    await waitFor(() => alertsTo(ALERT_B).length === 2, "unseen Done alert to B", PATIENCE_MS);
    await new Promise((done) => setTimeout(done, 110));
    assert.equal(alertsTo(ALERT_A).length, 1, "seen turn 2 does not notify A");
    assert.equal(openAlert(alertsTo(ALERT_B)[1].body.envelope, KEY_B).status, "done");

    // Claude Code's idle_prompt 60s later writes state=idle at the SAME turn=2 -> must NOT send a duplicate Done alert!
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=idle:app=claude-code:turn=2:blocked=2");
    await new Promise((done) => setTimeout(done, 120));
    assert.equal(alertsTo(ALERT_B).length, 2);

    // Error sends under the Blocked trigger with status "error".
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=error:app=claude-code:turn=3:blocked=2");
    await waitFor(() => alertsTo(ALERT_A).length === 2 && alertsTo(ALERT_B).length === 3, "error alert", PATIENCE_MS);
    assert.equal(openAlert(alertsTo(ALERT_A)[1].body.envelope, KEY_A).status, "error");
  });

  test("starts over when the tmux server on the socket is replaced by a new instance", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const first = startPrivateServer("work", "main", [fakeClaude, "--ide"]);
    first.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=done:app=claude-code:turn=3:blocked=0");
    register(entry(KEY_A, ALERT_A, { session: "tmux/work" }));

    const follower = followTmuxServer(
      "work",
      { executable: first.executable, socket: first.socket },
      {
        pollIntervalMs: 25,
        listener: tmuxNotificationListener({ directory, log: (line) => logs.push(line) }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => existsSync(join(directory, "tmux", "work", "notify.json")), "first instance saved", PATIENCE_MS);
    // Mark turn 3 seen on the OLD server instance.
    writeMark(KEY_A, first.instance, [{ terminal: "%0", turn: 3, word: "done" }]);

    // Replace the server on the same socket path.
    first.stop();
    const second = startPrivateServer("work", "main", [fakeClaude, "--ide"]);
    second.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=idle:app=claude-code:turn=0:blocked=0");
    await waitFor(
      () => JSON.parse(readFileSync(join(directory, "tmux", "work", "notify.json"), "utf8")).core === second.instance,
      "second instance adopted",
      PATIENCE_MS,
    );

    // Turn 1 on the new instance is NOT covered by turn 3's mark from the old instance!
    second.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=done:app=claude-code:turn=1:blocked=0");
    await waitFor(() => alertsTo(ALERT_A).length === 1, "turn 1 on new server instance notifies", PATIENCE_MS);
    assert.equal(openAlert(alertsTo(ALERT_A)[0].body.envelope, KEY_A).status, "done");
  });
});

suite("tmux Live Activity and desktop declines", () => {
  test("uses the tmux session name as workspace, wakes on stepped blocked=<n>, respects per-device marks, and ends when idle", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer("work", "payments-service", [fakeClaude, "--ide"]);
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=working:app=claude-code:turn=0:blocked=0");

    const layout = { rows: [[{ token: "workspace" }, { token: "agent" }, { token: "status" }]] };
    register(
      entry(KEY_A, ALERT_A, { session: "tmux/work", activity: ACTIVITY_A, live: { row_layout: layout } }),
      entry(KEY_B, ALERT_B, { session: "tmux/work", activity: ACTIVITY_B }),
    );

    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: tmuxLiveActivityListener({ directory, log: (line) => logs.push(line), hostName: HOST }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => activitiesTo(ACTIVITY_A).length === 1 && activitiesTo(ACTIVITY_B).length === 1, "initial working push", PATIENCE_MS);
    const firstA = activitiesTo(ACTIVITY_A)[0];
    assert.equal(firstA.event, "update");
    assert.equal(firstA.priority, 5);
    assert.deepEqual(firstA.counts, { working: 1, blocked: 0, done: 0 });
    const openedFirst = openActivity(firstA, KEY_A);
    assert.equal(openedFirst.host, HOST);
    assert.equal(openedFirst.agents[0].workspace, "payments-service");
    assert.equal(openedFirst.agents[0].pane, "%0");
    assert.equal(openedFirst.agents[0].kind, "claude");
    assert.equal(openedFirst.agents[0].status, "working");
    assert.deepEqual(openedFirst.agents[0].rows, [
      [{ text: "payments-service" }, { text: " · " }, { text: "claude" }, { text: " · " }, { text: "Working" }],
    ]);

    // Enter blocked=1 -> priority 10.
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1");
    await waitFor(() => activitiesTo(ACTIVITY_A).length === 2, "blocked=1 push", PATIENCE_MS);
    assert.equal(activitiesTo(ACTIVITY_A)[1].priority, 10);
    assert.deepEqual(activitiesTo(ACTIVITY_A)[1].counts, { working: 0, blocked: 1, done: 0 });

    // Step blocked=1 -> blocked=2 between looks -> sends a new priority-10 update!
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=0:blocked=2");
    await waitFor(() => activitiesTo(ACTIVITY_A).length === 3, "blocked=2 stepped push", PATIENCE_MS);
    assert.equal(activitiesTo(ACTIVITY_A)[2].priority, 10);
    assert.deepEqual(activitiesTo(ACTIVITY_A)[2].counts, { working: 0, blocked: 1, done: 0 });

    // Device A marks turn 1 as seen; Device B does not. When turn 1 finishes, A gets `end` while B gets Done `update`!
    writeMark(KEY_A, server.instance, [{ terminal: "%0", turn: 1, word: "done" }]);
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=done:app=claude-code:turn=1:blocked=2");
    await waitFor(() => activitiesTo(ACTIVITY_A).at(-1)?.event === "end", "seen device A ended", PATIENCE_MS);
    await waitFor(() => activitiesTo(ACTIVITY_B).at(-1)?.counts?.done === 1, "unseen device B shows done", PATIENCE_MS);

    // Once Device B also sees turn 1, Device B gets `end` at the next look too!
    writeMark(KEY_B, server.instance, [{ terminal: "%0", turn: 1, word: "done" }]);
    await waitFor(() => activitiesTo(ACTIVITY_B).at(-1)?.event === "end", "device B ended after mark", PATIENCE_MS);
  });

  test("a Claude Code desktop decline clears Blocked before notifications fire and ends the Live Activity", { skip }, async () => {
    // Production defaults are debounceMs=5000 > settleMs=1000; preserve that ordering under fast polling.
    writeConfig(relay.url, { debounceMs: 1600, activityDebounceMs: 20 });
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer("work", "cli-tools", [fakeClaude, "--ide"]);
    const pid = Number(server.run("display-message", "-p", "-t", "%0", "#{pane_pid}").trim());
    const transcript = join(home, "decline.jsonl");
    const sessionId = "s-decline";

    writeFileSync(transcript, "");
    server.run("set-option", "-p", "-t", "%0", "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=working:app=claude-code:turn=0:blocked=0");

    register(entry(KEY_A, ALERT_A, { session: "tmux/work", activity: ACTIVITY_A }));

    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: combineTmuxListeners(
          tmuxTranscriptListener(),
          tmuxNotificationListener({ directory, log: (line) => logs.push(line) }),
          tmuxLiveActivityListener({ directory, log: (line) => logs.push(line), hostName: HOST }),
        ),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => activitiesTo(ACTIVITY_A).length === 1, "working Live Activity push", PATIENCE_MS);

    // PermissionRequest opens the prompt (starting the Blocked alert debounce), then the user presses Esc at the desktop.
    appendFileSync(
      transcript,
      `${JSON.stringify({ type: "assistant", uuid: "a1", sessionId, message: { id: "m1", role: "assistant", content: [] } })}\n`,
    );
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1");
    await waitFor(() => activitiesTo(ACTIVITY_A).length === 2, "blocked Live Activity push", PATIENCE_MS);
    assert.equal(activitiesTo(ACTIVITY_A)[1].counts.blocked, 1);

    appendFileSync(
      transcript,
      `${JSON.stringify({ type: "system", subtype: "turn_duration", uuid: "t1", parentUuid: "a1", durationMs: 250, sessionId })}\n`,
    );

    await waitFor(() => activitiesTo(ACTIVITY_A).at(-1)?.event === "end", "Live Activity ended on desktop decline", PATIENCE_MS);
    await new Promise((done) => setTimeout(done, 750));
    assert.equal(alertsTo(ALERT_A).length, 0, "no Blocked or Done alert sent after desktop decline");
  });

  test("a normal Claude Code turn delivers Done even when the transcript watcher polls turn_duration before Stop", { skip }, async () => {
    writeConfig(relay.url, { debounceMs: 20, activityDebounceMs: 20 });
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer("work", "cli-tools", [fakeClaude, "--ide"]);
    const pid = Number(server.run("display-message", "-p", "-t", "%0", "#{pane_pid}").trim());
    const transcript = join(home, "normal.jsonl");
    const sessionId = "s-normal";

    writeFileSync(transcript, "");
    server.run("set-option", "-p", "-t", "%0", "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=working:app=claude-code:turn=0:blocked=0");

    register(entry(KEY_A, ALERT_A, { session: "tmux/work", activity: ACTIVITY_A }));

    let polls = 0;
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: combineTmuxListeners(
          tmuxTranscriptListener(),
          {
            panesUpdated: () => {
              polls += 1;
            },
          },
          tmuxNotificationListener({ directory, log: (line) => logs.push(line) }),
          tmuxLiveActivityListener({ directory, log: (line) => logs.push(line), hostName: HOST }),
        ),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => activitiesTo(ACTIVITY_A).length === 1, "working Live Activity push", PATIENCE_MS);

    // Claude Code appends turn_duration before Stop hook finishes; let watcher polls land in between.
    appendFileSync(
      transcript,
      `${JSON.stringify({ type: "assistant", uuid: "a1", sessionId, message: { id: "m1", role: "assistant", content: [] } })}\n` +
        `${JSON.stringify({ type: "system", subtype: "turn_duration", uuid: "t1", parentUuid: "a1", durationMs: 250, sessionId })}\n`,
    );
    const afterWrite = polls;
    await waitFor(() => polls >= afterWrite + 2, "watcher polled turn_duration before Stop hook", PATIENCE_MS);

    // Stop hook runs against the unchanged working status -> advances turn to 1 and sets done.
    const current = server.run("show-options", "-p", "-q", "-v", "-t", "%0", "@heeler-status").replace(/\n$/, "");
    assert.equal(current, "state=working:app=claude-code:turn=0:blocked=0");
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=done:app=claude-code:turn=1:blocked=0");

    await waitFor(() => alertsTo(ALERT_A).length === 1, "Done alert delivered", PATIENCE_MS);
    assert.equal(openAlert(alertsTo(ALERT_A)[0].body.envelope, KEY_A).status, "done");
    await waitFor(() => activitiesTo(ACTIVITY_A).at(-1)?.counts?.done === 1, "Live Activity shows Done", PATIENCE_MS);
  });
});
