// The Helper's tmux follower reads `list-panes -a` every 5 seconds through the
// tmux executable and socket the app stored under `tmux/<socket>/paths.json`
// (ADRs 0042 and 0044). Every test runs a private `-S` server under a temporary
// directory and never touches the user's tmux.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import {
  TMUX_POLL_INTERVAL_MS,
  combineTmuxListeners,
  followStoredTmuxServers,
  followTmuxServer,
} from "../helper/tmux/follower.js";
import { waitFor } from "./support/fake-core.js";

const tmux = process.env.HEELER_TEST_TMUX ?? "/opt/homebrew/bin/tmux";
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
  const socketDir = join(root, "sockets");
  mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  const socket = join(socketDir, socketName);
  execFileSync(
    tmux,
    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/cat"],
    {
      env: { PATH: "/usr/bin:/bin", HOME: home, USER: "fixture", TMUX_TMPDIR: socketDir },
      stdio: "ignore",
    },
  );
  const stop = () => {
    try {
      execFileSync(tmux, ["-N", "-S", socket, "kill-server"], { stdio: "ignore" });
    } catch {
      // Already stopped.
    }
  };
  cleanups.push(async () => stop());
  return {
    socket,
    stop,
    run(...args) {
      return execFileSync(tmux, ["-N", "-S", socket, ...args], { encoding: "utf8" });
    },
  };
}

function storePaths(socketName, paths) {
  const folder = join(directory, "tmux", socketName);
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  writeFileSync(join(folder, "paths.json"), `${JSON.stringify(paths)}\n`, { mode: 0o600 });
}

suite("tmux follower", () => {
  test("samples every 5 seconds by default", () => {
    assert.equal(TMUX_POLL_INTERVAL_MS, 5000);
  });

  test("waits while no server runs without starting one, then follows it and starts over on a new instance", async () => {
    // Even if ~/.tmux.conf tries to start a session, `-N` must never start a server.
    writeFileSync(join(home, ".tmux.conf"), "new-session -d -s autostart\n");
    const socketDir = join(root, "sockets");
    mkdirSync(socketDir, { recursive: true, mode: 0o700 });
    const socket = join(socketDir, "work");
    const events = [];
    const logs = [];

    const follower = followTmuxServer(
      "work",
      { executable: tmux, socket },
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

  test("omits Heeler's attach sessions, deduplicates linked windows, and resolves a pane's foreground agent", async () => {
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
      { executable: tmux, socket: server.socket },
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

  test("follows stored tmux/<socket>/paths.json entries and stops when removed", async () => {
    const server = startPrivateServer("work");
    storePaths("work", { executable: tmux, socket: server.socket });
    // Invalid or mismatched entries are ignored.
    storePaths("other", { executable: tmux, socket: join(root, "sockets", "wrong-name") });

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
});
