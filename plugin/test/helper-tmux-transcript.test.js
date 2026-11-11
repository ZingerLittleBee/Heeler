// While a Claude Code Pane reads `working` or `blocked`, the Host Helper watches
// the end of the Transcript `@heeler-session` names, and a `system` /
// `turn_duration` entry written after the status changed sets `idle` (ADR 0044).

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { appendFileSync, chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { combineTmuxListeners, followTmuxServer } from "../helper/tmux/follower.js";
import { tmuxTranscriptListener } from "../helper/tmux/transcript-watcher.js";
import { waitFor } from "./support/fake-core.js";
import { resolveTestTmux } from "./support/tmux.js";

const { skip, requireTmux } = resolveTestTmux();
const PATIENCE_MS = 5000;

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
});
