// While a Claude Code Pane reads `working` or `blocked`, the Host Helper watches
// the end of the Transcript `@heeler-session` names, and a `system` /
// `turn_duration` entry written after the status changed sets `idle` (ADR 0046).

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { combineTmuxListeners, followTmuxServer } from "../helper/tmux/follower.js";
import { tmuxTranscriptListener } from "../helper/tmux/transcript-watcher.js";
import { waitFor } from "./support/fake-core.js";
import { resolveTestTmux } from "./support/tmux.js";

const HOOK_SCRIPT = fileURLToPath(new URL("../claude-code/hook.sh", import.meta.url));
const { skip, pathWithTmux, requireTmux } = resolveTestTmux();
const PATIENCE_MS = 6000;

let root;
let home;
const cleanups = [];

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "heeler-tmux-transcript-"));
  home = join(root, "home");
  mkdirSync(home, { recursive: true });
});

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()();
  rmSync(root, { recursive: true, force: true });
});

function makeAgentBinary(name) {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const program = join(bin, name);
  writeFileSync(program, `#!${process.execPath}\nsetInterval(() => {}, 1000);\n`, { mode: 0o755 });
  chmodSync(program, 0o755);
  return program;
}

function startPrivateServer(programArgs) {
  const executable = requireTmux();
  const socketDir = join(root, "sockets");
  mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  const socket = join(socketDir, "work");
  execFileSync(
    executable,
    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", ...programArgs],
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
  return {
    executable,
    socket,
    run(...args) {
      return execFileSync(executable, ["-N", "-S", socket, ...args], { encoding: "utf8" });
    },
    option(pane, name) {
      return execFileSync(executable, ["-N", "-S", socket, "show-options", "-p", "-q", "-v", "-t", pane, name], {
        encoding: "utf8",
      }).replace(/\n$/, "");
    },
  };
}

function jsonl(...records) {
  return `${records.map((record) => JSON.stringify(record)).join("\n")}\n`;
}

function storePaths(name, paths) {
  const data =
    process.platform === "darwin" ? join(home, "Library", "Application Support") : join(home, ".local", "share");
  const folder = join(data, "heeler", "host-helper", "tmux", name);
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "paths.json"), JSON.stringify(paths));
}

function makeHookDrivingClaude() {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const hookCopy = join(root, "hook.sh");
  writeFileSync(hookCopy, readFileSync(HOOK_SCRIPT));
  const queueDir = join(root, "hook-queue");
  mkdirSync(queueDir, { recursive: true });
  const program = join(bin, "claude");
  writeFileSync(
    program,
    `#!${process.execPath}
const { spawnSync } = require("node:child_process");
const { existsSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [queueDir, hookScript] = process.argv.slice(2);
let seq = 0;
setInterval(() => {
  const req = join(queueDir, \`req-\${seq}.json\`);
  if (!existsSync(req)) return;
  const payload = readFileSync(req, "utf8");
  rmSync(req, { force: true });
  const result = spawnSync("/bin/sh", [hookScript], { input: payload, encoding: "utf8" });
  writeFileSync(join(queueDir, \`ack-\${seq}.json\`), JSON.stringify({ status: result.status, stderr: result.stderr }));
  seq += 1;
}, 10);
`,
    { mode: 0o755 },
  );
  chmodSync(program, 0o755);
  let nextSeq = 0;
  return {
    executable: program,
    args: [queueDir, hookCopy],
    async fireHook(payload) {
      const id = nextSeq++;
      const ack = join(queueDir, `ack-${id}.json`);
      writeFileSync(join(queueDir, `req-${id}.json`), JSON.stringify(payload));
      await waitFor(() => existsSync(ack), `hook ${payload.hook_event_name} finished`, PATIENCE_MS);
      const out = JSON.parse(readFileSync(ack, "utf8"));
      assert.equal(out.status, 0, out.stderr);
    },
  };
}

suite("tmux Claude Code transcript watcher", () => {
  test("sets idle continuing counts when turn_duration is written while blocked or working, and updates downstream snapshots", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const pane = "%0";
    const pid = Number(server.run("display-message", "-p", "-t", pane, "#{pane_pid}").trim());
    const transcript = join(home, "session.jsonl");
    const sessionId = "9a7714b3-b2a6-4f8e-b30d-94b5df8fc6fc";

    // Pre-existing turn_duration from an earlier turn must not clear blocked on first sight.
    writeFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u1", parentUuid: null, sessionId, message: { role: "user", content: "hi" } },
        { type: "assistant", uuid: "a1", parentUuid: "u1", sessionId, message: { id: "m1", role: "assistant", content: [] } },
        { type: "system", subtype: "turn_duration", uuid: "t1", parentUuid: "a1", durationMs: 1200, sessionId },
      ),
    );
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=1:blocked=2");
    server.run("set-option", "-p", "-t", pane, "@heeler-ask", `${pid} u`);

    const downstream = [];
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 30,
        listener: combineTmuxListeners(tmuxTranscriptListener(), {
          panesUpdated: ({ panes }) => downstream.push(panes.map((entry) => ({ paneID: entry.paneID, status: entry.status }))),
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => downstream.length >= 3, "initial polls while blocked", PATIENCE_MS);
    assert.equal(server.option(pane, "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=1:blocked=2");

    // Desktop Esc writes the rejected tool result, interrupt marker, turn_duration, and trailing metadata.
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u2", parentUuid: "t1", sessionId, message: { role: "user", content: [{ type: "tool_result", is_error: true }] } },
        { type: "user", uuid: "u3", parentUuid: "u2", sessionId, message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user for tool use]" }] } },
        { type: "system", subtype: "turn_duration", uuid: "t2", parentUuid: "u3", durationMs: 950, sessionId },
        { type: "mode", mode: "normal", sessionId },
      ),
    );

    await waitFor(
      () => server.option(pane, "@heeler-status") === "state=idle:app=claude-code:turn=1:blocked=2",
      "blocked pane set to idle",
      PATIENCE_MS,
    );
    assert.equal(server.option(pane, "@heeler-ask"), "");
    await waitFor(
      () => downstream.some((panes) => panes[0]?.status === "state=idle:app=claude-code:turn=1:blocked=2"),
      "downstream listener sees idle",
      PATIENCE_MS,
    );

    // Works while reading `working` too, continuing counts without advancing turn (Claude Code is a done reporter).
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=working:app=claude-code:turn=1:blocked=2");
    const pollsBeforeWorking = downstream.length;
    await waitFor(() => downstream.length >= pollsBeforeWorking + 2, "watched while working", PATIENCE_MS);

    appendFileSync(
      transcript,
      jsonl({ type: "system", subtype: "turn_duration", uuid: "t3", parentUuid: "t2", durationMs: 410, sessionId }),
    );
    await waitFor(
      () => server.option(pane, "@heeler-status") === "state=idle:app=claude-code:turn=1:blocked=2",
      "working pane set to idle",
      PATIENCE_MS,
    );
  });

  test("ignores sidechains, earlier turn_duration written while idle, and turn_duration followed by a new prompt", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const pane = "%0";
    const pid = Number(server.run("display-message", "-p", "-t", pane, "#{pane_pid}").trim());
    const transcript = join(home, "session.jsonl");
    const sessionId = "s-main";

    writeFileSync(transcript, "");
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=idle:app=claude-code:turn=0:blocked=0");

    let polls = 0;
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 30,
        listener: combineTmuxListeners(tmuxTranscriptListener(), {
          panesUpdated: () => {
            polls += 1;
          },
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => polls >= 2, "polled while idle", PATIENCE_MS);

    // A lone turn_duration flushed right before UserPromptSubmit sets working must not clear the new turn's working.
    appendFileSync(transcript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t0", durationMs: 100, sessionId }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=working:app=claude-code:turn=1:blocked=0");
    const afterWorking = polls;
    await waitFor(() => polls >= afterWorking + 3, "polls after working", PATIENCE_MS);
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=1:blocked=0");

    // Sidechain turn_duration, mismatched sessionId, and a turn_duration already followed by a new user prompt stay working.
    appendFileSync(
      transcript,
      jsonl(
        { type: "system", subtype: "turn_duration", uuid: "side", isSidechain: true, durationMs: 50, sessionId },
        { type: "system", subtype: "turn_duration", uuid: "other", durationMs: 50, sessionId: "s-other" },
        { type: "system", subtype: "turn_duration", uuid: "t1", durationMs: 50, sessionId },
        { type: "user", uuid: "u-next", parentUuid: "t1", sessionId, message: { role: "user", content: "next prompt" } },
      ),
    );
    const afterNoise = polls;
    await waitFor(() => polls >= afterNoise + 3, "polls after non-ending records", PATIENCE_MS);
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=1:blocked=0");
  });

  test("catches a permission prompt declined at the desktop between two polls", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const pane = "%0";
    const pid = Number(server.run("display-message", "-p", "-t", pane, "#{pane_pid}").trim());
    const transcript = join(home, "fast.jsonl");
    const sessionId = "s-fast";

    writeFileSync(transcript, "");
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=idle:app=claude-code:turn=1:blocked=0");

    let polls = 0;
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 120,
        listener: combineTmuxListeners(tmuxTranscriptListener(), {
          panesUpdated: () => {
            polls += 1;
          },
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => polls >= 1, "first idle poll", PATIENCE_MS);

    // Within a single poll interval: prompt -> tool_use + blocked -> Esc + turn_duration.
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1");
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u1", sessionId, message: { role: "user", content: "rm temp" } },
        { type: "assistant", uuid: "a1", parentUuid: "u1", sessionId, message: { id: "m1", role: "assistant", content: [{ type: "tool_use", id: "tu1", name: "Bash" }] } },
        { type: "user", uuid: "u2", parentUuid: "a1", sessionId, toolDenialKind: "user-rejected", message: { role: "user", content: [{ type: "tool_result", is_error: true }] } },
        { type: "system", subtype: "turn_duration", uuid: "t1", parentUuid: "u2", durationMs: 300, sessionId },
      ),
    );

    await waitFor(
      () => server.option(pane, "@heeler-status") === "state=idle:app=claude-code:turn=1:blocked=1",
      "fast desktop decline clears blocked at the next look",
      PATIENCE_MS,
    );
  });

  test("leaves non-Claude panes and mismatched @heeler-session pids untouched", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const fakeCodex = makeAgentBinary("codex");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const codexPane = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", fakeCodex, "--no-daemon").trim();

    const transcript = join(home, "shared.jsonl");
    writeFileSync(transcript, "");
    // Wrong PID on %0; non-Claude program on codexPane.
    server.run("set-option", "-p", "-t", "%0", "@heeler-session", JSON.stringify({ session: "s1", file: transcript, pid: 999999 }));
    server.run("set-option", "-p", "-t", "%0", "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1");

    const codexPid = Number(server.run("display-message", "-p", "-t", codexPane, "#{pane_pid}").trim());
    server.run("set-option", "-p", "-t", codexPane, "@heeler-session", JSON.stringify({ session: "s1", file: transcript, pid: codexPid }));
    server.run("set-option", "-p", "-t", codexPane, "@heeler-status", "state=blocked:app=codex:kind=permission:turn=0:blocked=1");

    let polls = 0;
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 30,
        listener: combineTmuxListeners(tmuxTranscriptListener(), {
          panesUpdated: () => {
            polls += 1;
          },
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => polls >= 2, "watched initial polls", PATIENCE_MS);
    appendFileSync(transcript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t1", durationMs: 200, sessionId: "s1" }));

    const before = polls;
    await waitFor(() => polls >= before + 3, "polls after turn_duration", PATIENCE_MS);
    assert.equal(server.option("%0", "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1");
    assert.equal(server.option(codexPane, "@heeler-status"), "state=blocked:app=codex:kind=permission:turn=0:blocked=1");
  });

  test("a turn-end entry followed by the Stop hook keeps done with turn advanced and never writes idle, while a decline without a hook sets idle after the wait", { skip }, async () => {
    const claude = makeHookDrivingClaude();
    const server = startPrivateServer([claude.executable, ...claude.args]);
    storePaths("work", { executable: server.executable, socket: server.socket });
    const pane = "%0";
    const transcript = join(home, "hook-race.jsonl");
    const sessionId = "s-hook-race";
    writeFileSync(transcript, "");

    const observedStatuses = [];
    let polls = 0;
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: combineTmuxListeners(tmuxTranscriptListener(), {
          panesUpdated: ({ panes }) => {
            polls += 1;
            if (panes[0]?.status) observedStatuses.push(panes[0].status);
          },
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await claude.fireHook({
      hook_event_name: "UserPromptSubmit",
      session_id: sessionId,
      transcript_path: transcript,
      prompt: "ship it",
    });
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=0:blocked=0");

    const afterStart = polls;
    await waitFor(() => polls >= afterStart + 2, "watcher observed working turn", PATIENCE_MS);

    // Claude Code appends turn_duration before its Stop hook finishes; let watcher polls land in between.
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u1", sessionId, message: { role: "user", content: "ship it" } },
        { type: "assistant", uuid: "a1", parentUuid: "u1", sessionId, message: { id: "m1", role: "assistant", content: [] } },
        { type: "system", subtype: "turn_duration", uuid: "t1", parentUuid: "a1", durationMs: 420, sessionId },
      ),
    );
    const afterTurnDuration = polls;
    await waitFor(() => polls >= afterTurnDuration + 2, "watcher polled between turn_duration and Stop hook", PATIENCE_MS);
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=0:blocked=0");

    await claude.fireHook({
      hook_event_name: "Stop",
      session_id: sessionId,
      transcript_path: transcript,
      stop_hook_active: false,
    });
    assert.equal(server.option(pane, "@heeler-status"), "state=done:app=claude-code:turn=1:blocked=0");

    // Wait past the full watcher settle window to ensure no delayed idle write clobbers done.
    await new Promise((resolve) => setTimeout(resolve, 1200));
    assert.equal(server.option(pane, "@heeler-status"), "state=done:app=claude-code:turn=1:blocked=0");
    assert.equal(
      observedStatuses.some((value) => value.startsWith("state=idle:")),
      false,
      `watcher must never write idle during a normal Stop-hook turn (saw ${JSON.stringify(observedStatuses)})`,
    );

    // Next turn: PermissionRequest sets blocked, then a desktop decline writes turn_duration with no hook.
    await claude.fireHook({
      hook_event_name: "UserPromptSubmit",
      session_id: sessionId,
      transcript_path: transcript,
      prompt: "rm -rf build",
    });
    await claude.fireHook({
      hook_event_name: "PermissionRequest",
      session_id: sessionId,
      transcript_path: transcript,
      tool_name: "Bash",
      tool_input: { command: "rm -rf build" },
    });
    assert.equal(server.option(pane, "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1");
    assert.notEqual(server.option(pane, "@heeler-ask"), "");

    const afterBlocked = polls;
    await waitFor(() => polls >= afterBlocked + 2, "watcher observed blocked turn", PATIENCE_MS);

    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u2", sessionId, message: { role: "user", content: [{ type: "tool_result", is_error: true }] } },
        { type: "system", subtype: "turn_duration", uuid: "t2", parentUuid: "u2", durationMs: 310, sessionId },
      ),
    );
    const afterDeclineWrite = polls;
    await waitFor(() => polls >= afterDeclineWrite + 1, "first poll after decline turn_duration", PATIENCE_MS);
    assert.equal(server.option(pane, "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1");

    await waitFor(
      () => server.option(pane, "@heeler-status") === "state=idle:app=claude-code:turn=1:blocked=1",
      "decline without hook sets idle after settle wait",
      PATIENCE_MS,
    );
    assert.equal(server.option(pane, "@heeler-ask"), "");
  });

  test("handles missing, truncated and rotated Transcripts without false idle writes or leaked state", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const pane = "%0";
    const pid = Number(server.run("display-message", "-p", "-t", pane, "#{pane_pid}").trim());
    const missingTranscript = join(home, "missing.jsonl");
    const transcript = join(home, "active.jsonl");
    const sessionId = "s-files";

    // 1. Missing Transcript file on initial sight and across polls while working.
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: sessionId, file: missingTranscript, pid }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=working:app=claude-code:turn=2:blocked=0");

    let polls = 0;
    const watcher = tmuxTranscriptListener({ settleMs: 120 });
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: combineTmuxListeners(watcher, {
          panesUpdated: () => {
            polls += 1;
          },
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => polls >= 3, "polled missing transcript", PATIENCE_MS);
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=2:blocked=0");
    assert.equal(watcher.trackedPaneCount("work"), 1);

    // Switch to an existing Transcript, append turn_duration, then delete the file before settleMs elapses.
    writeFileSync(
      transcript,
      jsonl({ type: "user", uuid: "u1", sessionId, message: { role: "user", content: "first" } }),
    );
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    const afterSwitch = polls;
    await waitFor(() => polls >= afterSwitch + 2, "polled existing transcript", PATIENCE_MS);

    appendFileSync(transcript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t-del", durationMs: 100, sessionId }));
    const afterDelAppend = polls;
    await waitFor(() => polls >= afterDelAppend + 1, "saw pending turn_duration before unlink", PATIENCE_MS);
    rmSync(transcript, { force: true });
    await new Promise((resolve) => setTimeout(resolve, 180));
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=2:blocked=0");
    assert.equal(watcher.trackedPaneCount("work"), 1);

    // Recreate at the same path already carrying a historical turn_duration (two-step unlink+create rotation); must not fire idle.
    writeFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u2", sessionId, message: { role: "user", content: "padding to exceed zero bytes" } },
        { type: "assistant", uuid: "a2", sessionId, message: { id: "m2", role: "assistant", content: [] } },
        { type: "system", subtype: "turn_duration", uuid: "t-recreated-old", durationMs: 90, sessionId },
      ),
    );
    await new Promise((resolve) => setTimeout(resolve, 180));
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=2:blocked=0");

    // 2. Truncated Transcript: append turn_duration, then truncate to 0 before settleMs elapses.
    appendFileSync(transcript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t-trunc", durationMs: 100, sessionId }));
    const afterTruncAppend = polls;
    await waitFor(() => polls >= afterTruncAppend + 1, "saw pending turn_duration before truncate", PATIENCE_MS);
    truncateSync(transcript, 0);
    await new Promise((resolve) => setTimeout(resolve, 180));
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=2:blocked=0");
    assert.equal(watcher.trackedPaneCount("work"), 1);

    // 3. Replaced (rotated) Transcript: replace with a LARGER file at the same path that already ends with an old turn_duration.
    writeFileSync(
      transcript,
      jsonl({ type: "user", uuid: "u3", sessionId, message: { role: "user", content: "short line" } }),
    );
    const afterShort = polls;
    await waitFor(() => polls >= afterShort + 2, "polled short transcript before rotation", PATIENCE_MS);

    const rotatedIn = join(home, "rotated-in.jsonl");
    writeFileSync(
      rotatedIn,
      jsonl(
        { type: "user", uuid: "u-old-1", sessionId, message: { role: "user", content: "much longer historical content before rotation 1" } },
        { type: "assistant", uuid: "a-old-1", sessionId, message: { id: "m-old", role: "assistant", content: [{ type: "text", text: "historical answer padding" }] } },
        { type: "system", subtype: "turn_duration", uuid: "t-old-rotated", durationMs: 880, sessionId },
      ),
    );
    renameSync(rotatedIn, transcript);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(
      server.option(pane, "@heeler-status"),
      "state=working:app=claude-code:turn=2:blocked=0",
      "historical turn_duration inside a rotated-in file must not clear working",
    );
    assert.equal(watcher.trackedPaneCount("work"), 1);

    // Subsequent live turn_duration appended to the rotated file still clears working after settleMs.
    appendFileSync(transcript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t-live", durationMs: 90, sessionId }));
    await waitFor(
      () => server.option(pane, "@heeler-status") === "state=idle:app=claude-code:turn=2:blocked=0",
      "live turn_duration on rotated file sets idle",
      PATIENCE_MS,
    );

    await follower.stop();
    assert.equal(watcher.trackedPaneCount(), 0);
  });

  test("switching @heeler-session to another session while working ignores old turn_duration entries and drops stale state", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const pane = "%0";
    const pid = Number(server.run("display-message", "-p", "-t", pane, "#{pane_pid}").trim());
    const firstTranscript = join(home, "session-one.jsonl");
    const secondTranscript = join(home, "session-two.jsonl");

    writeFileSync(firstTranscript, jsonl({ type: "user", uuid: "u1", sessionId: "s-one", message: { role: "user", content: "one" } }));
    // Second session already has a finished historical turn ending in turn_duration.
    writeFileSync(
      secondTranscript,
      jsonl(
        { type: "user", uuid: "u2", sessionId: "s-two", message: { role: "user", content: "previous turn" } },
        { type: "assistant", uuid: "a2", sessionId: "s-two", message: { id: "m2", role: "assistant", content: [] } },
        { type: "system", subtype: "turn_duration", uuid: "t-prev", durationMs: 500, sessionId: "s-two" },
      ),
    );

    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: "s-one", file: firstTranscript, pid }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=working:app=claude-code:turn=3:blocked=0");

    let polls = 0;
    const watcher = tmuxTranscriptListener({ settleMs: 120 });
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: combineTmuxListeners(watcher, {
          panesUpdated: () => {
            polls += 1;
          },
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => polls >= 2, "polled session one", PATIENCE_MS);

    // Queue a pending turn_duration on session one, then immediately switch @heeler-session to session two while still working.
    appendFileSync(firstTranscript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t-one", durationMs: 110, sessionId: "s-one" }));
    const afterAppend = polls;
    await waitFor(() => polls >= afterAppend + 1, "saw pending turn_duration on session one", PATIENCE_MS);

    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: "s-two", file: secondTranscript, pid }));
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=3:blocked=0");
    assert.equal(watcher.trackedPaneCount("work"), 1);

    // Switching session id on the same transcript path while a pending turn_duration exists also resets cleanly.
    appendFileSync(secondTranscript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t-two-stale", durationMs: 120, sessionId: "s-two" }));
    const afterSecondAppend = polls;
    await waitFor(() => polls >= afterSecondAppend + 1, "saw pending turn_duration on s-two", PATIENCE_MS);
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: "s-three", file: secondTranscript, pid }));
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=3:blocked=0");
    assert.equal(watcher.trackedPaneCount("work"), 1);

    // Clearing @heeler-session drops tracked state so a pending turn_duration never fires afterwards.
    appendFileSync(secondTranscript, jsonl({ type: "system", subtype: "turn_duration", uuid: "t-three-stale", durationMs: 120, sessionId: "s-three" }));
    const afterThirdAppend = polls;
    await waitFor(() => polls >= afterThirdAppend + 1, "saw pending turn_duration on s-three", PATIENCE_MS);
    server.run("set-option", "-p", "-t", pane, "@heeler-session", "");
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=3:blocked=0");
    assert.equal(watcher.trackedPaneCount("work"), 0);
  });

  test("recovers a desktop-declined Blocked turn within 5 seconds on a fake clock at production defaults while preserving the Stop-hook settle window", { skip }, async () => {
    const fakeClaude = makeAgentBinary("claude");
    const server = startPrivateServer([fakeClaude, "--ide"]);
    const pane = "%0";
    const pid = Number(server.run("display-message", "-p", "-t", pane, "#{pane_pid}").trim());
    const transcript = join(home, "fake-clock.jsonl");
    const sessionId = "s-fake-clock";

    writeFileSync(transcript, "");
    server.run("set-option", "-p", "-t", pane, "@heeler-session", JSON.stringify({ session: sessionId, file: transcript, pid }));
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=idle:app=claude-code:turn=1:blocked=0");

    let clockMs = 0;
    const sleeps = [];
    let pendingSleep = null;
    const waitForSleep = async () => {
      await waitFor(() => pendingSleep !== null, "follower entered sleep", PATIENCE_MS);
      return pendingSleep.ms;
    };
    const advanceWithinSleep = (ms) => {
      assert.notEqual(pendingSleep, null, "expected follower to be sleeping");
      assert.ok(clockMs + ms <= pendingSleep.wakeAt, "cannot advance past wakeAt");
      clockMs += ms;
    };
    const wakeNextPoll = () => {
      assert.notEqual(pendingSleep, null, "expected follower to be sleeping");
      const { wakeAt, resolve } = pendingSleep;
      pendingSleep = null;
      clockMs = wakeAt;
      resolve();
    };

    const downstream = [];
    const follower = followTmuxServer(
      "work",
      { executable: server.executable, socket: server.socket },
      {
        sleep(ms) {
          sleeps.push(ms);
          return new Promise((resolve) => {
            pendingSleep = { ms, wakeAt: clockMs + ms, resolve };
          });
        },
        listener: combineTmuxListeners(tmuxTranscriptListener({ now: () => clockMs }), {
          panesUpdated: ({ panes }) => downstream.push({ at: clockMs, status: panes[0]?.status }),
        }),
      },
    );
    cleanups.push(() => follower.stop());

    // Initial idle sample sleeps the full 5000 ms.
    assert.equal(await waitForSleep(), 5000);

    // PermissionRequest lands while idle; next sample sees Blocked and switches to 1000 ms polling.
    advanceWithinSleep(4400);
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u1", sessionId, message: { role: "user", content: "rm -rf scratch" } },
        { type: "assistant", uuid: "a1", parentUuid: "u1", sessionId, message: { id: "m1", role: "assistant", content: [{ type: "tool_use", id: "tu1", name: "Bash" }] } },
      ),
    );
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1");
    server.run("set-option", "-p", "-t", pane, "@heeler-ask", `${pid} u`);
    wakeNextPoll();
    assert.equal(await waitForSleep(), 1000);

    // Worst-case phase while Blocked: user declines at the desktop 1 ms after a sample.
    // Under the old 5000 ms fixed interval this took 9999 ms (> 5000 ms); here it takes 1999 ms.
    advanceWithinSleep(1);
    const declineAt = clockMs;
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u2", parentUuid: "a1", sessionId, message: { role: "user", content: [{ type: "tool_result", is_error: true }] } },
        { type: "user", uuid: "u3", parentUuid: "u2", sessionId, message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user for tool use]" }] } },
        { type: "system", subtype: "turn_duration", uuid: "t1", parentUuid: "u3", durationMs: 650, sessionId },
      ),
    );

    // First post-decline poll (999 ms later): holds pending turn-end so a racing Stop hook could still win.
    wakeNextPoll();
    assert.equal(await waitForSleep(), 1000);
    assert.equal(server.option(pane, "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1");

    // Confirmation poll (1999 ms after decline): sets idle, clears @heeler-ask, updates downstream, and resumes 5000 ms polling.
    wakeNextPoll();
    assert.equal(await waitForSleep(), 5000);
    const blockedRecoveryMs = clockMs - declineAt;
    assert.equal(blockedRecoveryMs, 1999);
    assert.ok(blockedRecoveryMs <= 5000, `expected Blocked decline recovery <= 5000 ms, got ${blockedRecoveryMs} ms`);
    assert.equal(server.option(pane, "@heeler-status"), "state=idle:app=claude-code:turn=1:blocked=1");
    assert.equal(server.option(pane, "@heeler-ask"), "");
    assert.equal(downstream.at(-1)?.status, "state=idle:app=claude-code:turn=1:blocked=1");

    // Fast PermissionRequest + decline inside one 5000 ms idle sleep (1000 ms after prompt): follow-up poll confirms in <= 5000 ms.
    advanceWithinSleep(1000);
    const fastDeclineAt = clockMs;
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=blocked:app=claude-code:kind=permission:turn=1:blocked=2");
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u4", sessionId, message: { role: "user", content: "rm temp2" } },
        { type: "assistant", uuid: "a2", parentUuid: "u4", sessionId, message: { id: "m2", role: "assistant", content: [{ type: "tool_use", id: "tu2", name: "Bash" }] } },
        { type: "user", uuid: "u5", parentUuid: "a2", sessionId, message: { role: "user", content: [{ type: "tool_result", is_error: true }] } },
        { type: "system", subtype: "turn_duration", uuid: "t2", parentUuid: "u5", durationMs: 300, sessionId },
      ),
    );
    wakeNextPoll();
    assert.equal(await waitForSleep(), 1000);
    assert.equal(server.option(pane, "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=1:blocked=2");

    wakeNextPoll();
    assert.equal(await waitForSleep(), 5000);
    const fastRecoveryMs = clockMs - fastDeclineAt;
    assert.equal(fastRecoveryMs, 5000);
    assert.ok(fastRecoveryMs <= 5000);
    assert.equal(server.option(pane, "@heeler-status"), "state=idle:app=claude-code:turn=1:blocked=2");

    // Normal working turn where turn_duration lands before Stop: watcher schedules a 1000 ms settle check, and Stop within 1000 ms wins.
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=working:app=claude-code:turn=1:blocked=2");
    wakeNextPoll();
    assert.equal(await waitForSleep(), 5000);

    advanceWithinSleep(4900);
    appendFileSync(
      transcript,
      jsonl(
        { type: "user", uuid: "u6", sessionId, message: { role: "user", content: "ship" } },
        { type: "assistant", uuid: "a3", parentUuid: "u6", sessionId, message: { id: "m3", role: "assistant", content: [] } },
        { type: "system", subtype: "turn_duration", uuid: "t3", parentUuid: "a3", durationMs: 400, sessionId },
      ),
    );
    wakeNextPoll();
    assert.equal(await waitForSleep(), 1000);
    assert.equal(server.option(pane, "@heeler-status"), "state=working:app=claude-code:turn=1:blocked=2");

    advanceWithinSleep(150);
    server.run("set-option", "-p", "-t", pane, "@heeler-status", "state=done:app=claude-code:turn=2:blocked=2");
    wakeNextPoll();
    assert.equal(await waitForSleep(), 5000);
    assert.equal(server.option(pane, "@heeler-status"), "state=done:app=claude-code:turn=2:blocked=2");
  });
});
