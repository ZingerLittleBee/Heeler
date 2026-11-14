// The Helper's tmux follower reads `list-panes -a` every 5 seconds by default
// (1 second while a followed Agent Pane reads `blocked`) through the tmux
// executable and socket the app stored under `tmux/<socket>/paths.json`
// (ADRs 0044 and 0046). Every test runs a private `-S` server under a temporary
// directory and never touches the user's tmux.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, delimiter, join } from "node:path";

import {
  TMUX_BLOCKED_POLL_INTERVAL_MS,
  TMUX_POLL_INTERVAL_MS,
  combineTmuxListeners,
  followStoredTmuxServers,
  followTmuxServer,
} from "../helper/tmux/follower.js";
import { waitFor } from "./support/fake-core.js";
import { resolveTestTmux } from "./support/tmux.js";

const { skip, requireTmux } = resolveTestTmux();
const PATIENCE_MS = 5000;

let root;
let home;
let directory;
const cleanups = [];

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "heeler-tmux-follow-"));
  home = join(root, "home");
  directory = join(root, "helper");
  mkdirSync(home, { recursive: true });
  mkdirSync(directory, { recursive: true, mode: 0o700 });
});

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()();
  rmSync(root, { recursive: true, force: true });
});

function startPrivateServer(socketName = "work") {
  const executable = requireTmux();
  const socketDir = join(root, "sockets");
  mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  const socket = join(socketDir, socketName);
  execFileSync(
    executable,
    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/cat"],
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
    socket,
    stop,
    run(...args) {
      return execFileSync(executable, ["-N", "-S", socket, ...args], { encoding: "utf8" });
    },
  };
}

function storePaths(socketName, paths) {
  const folder = join(directory, "tmux", socketName);
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  writeFileSync(join(folder, "paths.json"), `${JSON.stringify(paths)}\n`, { mode: 0o600 });
}

suite("tmux test resolver", () => {
  test("prefers HEELER_TEST_TMUX, falls back to PATH, skips locally when absent, and fails under CI", () => {
    const emptyBin = join(root, "empty-bin");
    const customBin = join(root, "custom-bin");
    mkdirSync(emptyBin, { recursive: true });
    mkdirSync(customBin, { recursive: true });
    const fakeTmux = join(customBin, "tmux");
    writeFileSync(fakeTmux, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    chmodSync(fakeTmux, 0o755);

    const fromExplicit = resolveTestTmux({ HEELER_TEST_TMUX: fakeTmux, PATH: emptyBin });
    assert.equal(fromExplicit.tmux, fakeTmux);
    assert.equal(fromExplicit.skip, false);
    assert.equal(fromExplicit.pathWithTmux, `${customBin}${delimiter}${emptyBin}`);

    const fromPath = resolveTestTmux({ PATH: customBin });
    assert.equal(fromPath.tmux, fakeTmux);
    assert.equal(fromPath.skip, false);
    assert.equal(fromPath.pathWithTmux, customBin);

    const missingLocal = resolveTestTmux({ PATH: emptyBin });
    assert.equal(missingLocal.tmux, null);
    assert.equal(missingLocal.skip, "tmux is not installed");

    const missingCI = resolveTestTmux({ PATH: emptyBin, CI: "true" });
    assert.equal(missingCI.tmux, null);
    assert.equal(missingCI.skip, false);
    assert.throws(() => missingCI.requireTmux(), /tmux is not installed/);

    const badExplicit = resolveTestTmux({ HEELER_TEST_TMUX: join(emptyBin, "missing"), PATH: customBin });
    assert.equal(badExplicit.skip, false);
    assert.throws(() => badExplicit.requireTmux(), /HEELER_TEST_TMUX is not an executable file/);
  });
});

suite("tmux follower", () => {
  test("samples every 5 seconds by default and every 1 second while an Agent Pane reads blocked", () => {
    assert.equal(TMUX_POLL_INTERVAL_MS, 5000);
    assert.equal(TMUX_BLOCKED_POLL_INTERVAL_MS, 1000);
  });

  test("waits while no server runs without starting one, then follows it and starts over on a new instance", { skip }, async () => {
    const executable = requireTmux();
    // Even if ~/.tmux.conf tries to start a session, `-N` must never start a server.
    writeFileSync(join(home, ".tmux.conf"), "new-session -d -s autostart\n");
    const socketDir = join(root, "sockets");
    mkdirSync(socketDir, { recursive: true, mode: 0o700 });
    const socket = join(socketDir, "work");
    const events = [];
    const logs = [];

    const follower = followTmuxServer(
      "work",
      { executable, socket },
      {
        pollIntervalMs: 25,
        log: (line) => logs.push(line),
        listener: combineTmuxListeners({
          serverStarted: (report) => events.push({ type: "started", ...report }),
          serverEnded: (report) => events.push({ type: "ended", ...report }),
          panesUpdated: (report) => events.push({ type: "panes", ...report }),
        }),
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => logs.some((line) => line.includes("waiting for a tmux server")), "waiting log", PATIENCE_MS);
    assert.equal(existsSync(socket), false);
    assert.equal(events.length, 0);

    const first = startPrivateServer("work");
    await waitFor(() => events.some((event) => event.type === "panes" && event.panes.length === 1), "first server", PATIENCE_MS);

    const startedFirst = events.find((event) => event.type === "started");
    assert.ok(startedFirst);
    assert.match(startedFirst.instance, /^tmux-\d+-\d+$/);
    const firstPane = events.findLast((event) => event.type === "panes").panes[0];
    assert.equal(firstPane.sessionName, "main");
    assert.equal(firstPane.paneID, "%0");
    assert.equal(firstPane.isDead, false);

    // Stop the server and start a fresh one on the same socket path.
    first.stop();
    await waitFor(() => events.some((event) => event.type === "ended" && event.instance === startedFirst.instance), "first server ended", PATIENCE_MS);

    const second = startPrivateServer("work");
    await waitFor(
      () => events.some((event) => event.type === "started" && event.instance !== startedFirst.instance),
      "second server instance",
      PATIENCE_MS,
    );
    const startedSecond = events.findLast((event) => event.type === "started");
    assert.notEqual(startedSecond.instance, startedFirst.instance);
    second.stop();
  });

  test("omits Heeler's attach sessions, deduplicates linked windows, and resolves a pane's foreground agent", { skip }, async () => {
    const executable = requireTmux();
    const bin = join(root, "bin");
    mkdirSync(bin, { recursive: true });
    const fakeCodex = join(bin, "codex");
    writeFileSync(
      fakeCodex,
      `#!${process.execPath}\nsetInterval(() => {}, 1000);\n`,
      { mode: 0o755 },
    );
    chmodSync(fakeCodex, 0o755);

    const server = startPrivateServer("work");
    const created = server.run(
      "new-window", "-d", "-P", "-F", "#{window_id}\t#{pane_id}", "-t", "main:", fakeCodex, "--no-daemon",
    ).trim();
    const [windowID, paneID] = created.split("\t");

    // Link the window into an attach session marked `@heeler-attach`, as TmuxAttachScript does.
    server.run("new-session", "-d", "-s", "heeler-attach-1", "/bin/cat");
    server.run("set-option", "-t", "=heeler-attach-1:", "@heeler-attach", paneID);
    server.run("link-window", "-d", "-s", windowID, "-t", "=heeler-attach-1:");

    // Also link the window into a higher-numbered user session so `list-panes -a` lists it twice.
    server.run("new-session", "-d", "-s", "second", "/bin/cat");
    server.run("link-window", "-d", "-s", windowID, "-t", "=second:");

    let latest = [];
    const follower = followTmuxServer(
      "work",
      { executable, socket: server.socket },
      {
        pollIntervalMs: 25,
        listener: {
          panesUpdated: ({ panes }) => {
            latest = panes;
          },
        },
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(
      () => latest.some((pane) => pane.paneID === paneID && pane.agentKind === "codex"),
      "codex pane listed",
      PATIENCE_MS,
    );

    assert.equal(latest.some((pane) => pane.sessionName.startsWith("heeler-attach-")), false);
    const matching = latest.filter((pane) => pane.paneID === paneID);
    assert.equal(matching.length, 1);
    assert.equal(matching[0].sessionName, "main");
    assert.ok(matching[0].foregroundPid > 0);
  });

  test("follows stored tmux/<socket>/paths.json entries and stops when removed", { skip }, async () => {
    const executable = requireTmux();
    const server = startPrivateServer("work");
    storePaths("work", { executable, socket: server.socket });
    // Invalid or mismatched entries are ignored.
    storePaths("other", { executable, socket: join(root, "sockets", "wrong-name") });

    const seen = new Map();
    const ended = [];
    const manager = followStoredTmuxServers({
      directory,
      pollMs: 25,
      pollIntervalMs: 25,
      listener: {
        panesUpdated: ({ socket, panes }) => seen.set(socket, panes),
        followerStopped: ({ socket }) => ended.push(socket),
      },
    });
    cleanups.push(() => manager.stop());

    await waitFor(() => (seen.get("work")?.length ?? 0) === 1, "stored work server followed", PATIENCE_MS);
    assert.equal(seen.has("other"), false);
    assert.equal(basename(server.socket), "work");

    rmSync(join(directory, "tmux", "work"), { recursive: true, force: true });
    await waitFor(() => ended.includes("work"), "removed server stopped", PATIENCE_MS);
  });

  test("decodes panes when tmux 3.4 escapes $var and control bytes in list-panes output", async () => {
    const stubTmux = join(root, "tmux-34-stub");
    writeFileSync(
      stubTmux,
      `#!${process.execPath}
function quoteShell(text) {
  let out = "";
  for (const ch of text) {
    if ("|&;<>()$\`\\\\\\"'*?[# =%".includes(ch)) out += "\\\\";
    out += ch;
  }
  return out;
}
function strvis34(text) {
  const bytes = Buffer.from(text, "utf8");
  let out = "";
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i];
    if (b === 0x09 || b === 0x0a) { out += String.fromCharCode(b); i += 1; continue; }
    if (b === 0x07) { out += "\\\\a"; i += 1; continue; }
    if (b < 0x20 || b === 0x7f) { out += "\\\\" + b.toString(8).padStart(3, "0"); i += 1; continue; }
    if (b === 0x24 && i + 1 < bytes.length) {
      const next = bytes[i + 1];
      const ident = (next >= 0x41 && next <= 0x5a) || (next >= 0x61 && next <= 0x7a) || next === 0x5f || next === 0x7b;
      if (ident) { out += "\\\\$"; i += 1; continue; }
    }
    if (b < 0x80) { out += String.fromCharCode(b); i += 1; continue; }
    const w = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1;
    out += bytes.subarray(i, i + w).toString("utf8");
    i += w;
  }
  return out;
}
const rows = [
  {
    pid: "9001", start_time: "1700000000", session_id: "$0", window_id: "@0", window_index: "0",
    pane_id: "%0", pane_pid: String(process.ppid), pane_dead: "0", pane_pipe: "0",
    session_name: "my $work", window_name: "echo $HOME\\x1fsep\\x07", pane_current_command: "sh",
    pane_current_path: "/home/$USER/proj", pane_tty: "", "@heeler-status": "state=working:app=claude-code:turn=1:blocked=0",
    "@heeler-session": JSON.stringify({ session: "s1", file: "/home/$USER/.claude/projects/-w/s1.jsonl" }),
    "@heeler-pipe": "", "@heeler-piped": "", "@heeler-attach": "",
  },
  {
    pid: "9001", start_time: "1700000000", session_id: "$0", window_id: "@1", window_index: "1",
    pane_id: "%1", pane_pid: String(process.ppid), pane_dead: "0", pane_pipe: "0",
    session_name: "my $work", window_name: "fish", pane_current_command: "fish",
    pane_current_path: "/tmp", pane_tty: "", "@heeler-status": "",
    "@heeler-session": "", "@heeler-pipe": "", "@heeler-piped": "", "@heeler-attach": "",
  },
];
const args = process.argv.slice(2);
const fmt = args[args.length - 1];
for (const row of rows) {
  const expanded = fmt.replace(/#\\{(q:)?([^}]+)\\}/g, (_, q, name) => (q ? quoteShell(row[name] ?? "") : (row[name] ?? "")));
  process.stdout.write(strvis34(expanded) + "\\n");
}
`,
      { mode: 0o755 },
    );

    let latest = null;
    const follower = followTmuxServer(
      "work",
      { executable: stubTmux, socket: join(root, "stub.sock") },
      {
        pollIntervalMs: 25,
        listener: {
          panesUpdated: ({ panes }) => {
            latest = panes;
          },
        },
      },
    );
    cleanups.push(() => follower.stop());

    await waitFor(() => latest?.length === 2, "both panes decoded from tmux 3.4 output", PATIENCE_MS);
    assert.equal(latest[0].paneID, "%0");
    assert.equal(latest[0].sessionName, "my $work");
    assert.equal(latest[0].windowName, "echo $HOME\x1fsep\x07");
    assert.equal(latest[0].path, "/home/$USER/proj");
    assert.equal(
      JSON.parse(latest[0].agentSession).file,
      "/home/$USER/.claude/projects/-w/s1.jsonl",
    );
    assert.equal(latest[1].paneID, "%1");
    assert.equal(latest[1].windowName, "fish");
  });

  test("polls every 1 second on a fake clock only while a live Agent Pane reads blocked or a listener requests a shorter follow-up", async () => {
    const stateFile = join(root, "stub-state.json");
    const stubTmux = join(root, "tmux-clock-stub");
    writeFileSync(
      stateFile,
      JSON.stringify({ command: "claude", dead: "0", status: "state=idle:app=claude-code:turn=1:blocked=0" }),
    );
    writeFileSync(
      stubTmux,
      `#!${process.execPath}
const { readFileSync } = require("node:fs");
function quoteShell(text) {
  let out = "";
  for (const ch of text) {
    if ("|&;<>()$\`\\\\\\"'*?[# =%".includes(ch)) out += "\\\\";
    out += ch;
  }
  return out;
}
const state = JSON.parse(readFileSync(${JSON.stringify(stateFile)}, "utf8"));
const row = {
  pid: "9100", start_time: "1700000100", session_id: "$0", window_id: "@0", window_index: "0",
  pane_id: "%0", pane_pid: "2147483640", pane_dead: state.dead, pane_pipe: "0",
  session_name: "main", window_name: "agent", pane_current_command: state.command,
  pane_current_path: "/tmp", pane_tty: "", "@heeler-status": state.status,
  "@heeler-session": "", "@heeler-pipe": "", "@heeler-piped": "", "@heeler-attach": "",
};
const args = process.argv.slice(2);
const fmt = args[args.length - 1];
const expanded = fmt.replace(/#\\{(q:)?([^}]+)\\}/g, (_, q, name) => (q ? quoteShell(row[name] ?? "") : (row[name] ?? "")));
process.stdout.write(expanded + "\\n");
`,
      { mode: 0o755 },
    );

    const sleeps = [];
    let pendingSleep = null;
    let nextFollowUp = undefined;
    const pushed = [];

    const follower = followTmuxServer(
      "work",
      { executable: stubTmux, socket: join(root, "clock.sock") },
      {
        sleep(ms) {
          sleeps.push(ms);
          return new Promise((resolve) => {
            pendingSleep = resolve;
          });
        },
        listener: combineTmuxListeners(
          // Array.prototype.push returns a number; combineTmuxListeners must ignore non-object returns.
          { panesUpdated: ({ panes }) => pushed.push(panes[0]?.status) },
          { panesUpdated: () => nextFollowUp },
        ),
      },
    );
    cleanups.push(() => follower.stop());

    const step = async (nextState, followUp = undefined) => {
      await waitFor(() => pendingSleep !== null, "follower entered sleep", PATIENCE_MS);
      const seen = sleeps.at(-1);
      writeFileSync(stateFile, JSON.stringify(nextState));
      nextFollowUp = followUp;
      const wake = pendingSleep;
      pendingSleep = null;
      wake();
      return seen;
    };

    // Idle Agent Pane: 5000 ms.
    assert.equal(
      await step({ command: "claude", dead: "0", status: "state=working:app=claude-code:turn=1:blocked=0" }),
      5000,
    );
    // Working Agent Pane: still 5000 ms.
    assert.equal(
      await step({ command: "claude", dead: "0", status: "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1" }),
      5000,
    );
    // Live Agent Pane reading blocked: 1000 ms.
    assert.equal(
      await step({ command: "codex", dead: "0", status: "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1" }),
      1000,
    );
    // Foreign `app` on another foreground Agent reads null, not blocked: back to 5000 ms.
    assert.equal(
      await step(
        { command: "claude", dead: "0", status: "state=working:app=claude-code:turn=1:blocked=1" },
        { nextPollMs: 750 },
      ),
      5000,
    );
    // Listener follow-up request caps the next sleep to 750 ms, then returns to 5000 ms once cleared.
    assert.equal(
      await step({ command: "claude", dead: "0", status: "state=done:app=claude-code:turn=2:blocked=1" }),
      750,
    );
    await waitFor(() => pendingSleep !== null, "final sleep", PATIENCE_MS);
    assert.equal(sleeps.at(-1), 5000);
    assert.equal(pushed.length, 6);
  });
});
