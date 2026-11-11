// Usage on a tmux Host: the follower records each server's global environment
// under `tmux/<socket>/runtime.json` (apart from core sessions' `sessions/`),
// re-reads it on a new server instance, notes running Claude Code and Codex
// Account directories, and serves `usage-query.js --tmux <socket>`.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { agentDirectories } from "../helper/shared/usage/agent-directories.js";
import { followStoredTmuxServers } from "../helper/tmux/follower.js";
import { helperStateDirectory } from "../helper/usage/layout.js";
import { tmuxUsageListener } from "../helper/usage/recorder.js";
import { waitFor } from "./support/fake-core.js";
import { resolveTestTmux } from "./support/tmux.js";

const { skip, requireTmux } = resolveTestTmux();
const HELPER = fileURLToPath(new URL("../helper", import.meta.url));
const PATIENCE_MS = 5000;

let root;
let home;
let directory;
const cleanups = [];

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "heeler-tmux-usage-"));
  home = join(root, "home");
  directory = join(root, "helper");
  mkdirSync(home, { recursive: true });
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  cpSync(HELPER, join(directory, "app"), { recursive: true });
});

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()();
  rmSync(root, { recursive: true, force: true });
});

function startPrivateServer(socketName, envVars = {}) {
  const executable = requireTmux();
  const socketDir = join(root, "sockets");
  mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  const socket = join(socketDir, socketName);
  execFileSync(
    executable,
    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/cat"],
    {
      env: { PATH: "/usr/bin:/bin", HOME: home, USER: "fixture", ...envVars },
      stdio: "ignore",
    },
  );
  for (const [name, value] of Object.entries(envVars)) {
    execFileSync(executable, ["-N", "-S", socket, "set-environment", "-g", name, value], { stdio: "ignore" });
  }
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

function storePaths(socketName, socket) {
  const executable = requireTmux();
  const folder = join(directory, "tmux", socketName);
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  writeFileSync(join(folder, "paths.json"), `${JSON.stringify({ executable, socket })}\n`, { mode: 0o600 });
}

function runQuery(...args) {
  return spawnSync(process.execPath, [join(directory, "app", "usage-query.js"), ...args], {
    env: { HOME: join(root, "ssh-home"), PATH: "/usr/bin:/bin" },
    encoding: "utf8",
    timeout: 10_000,
  });
}

suite("tmux Usage recorder and query", () => {
  test("records tmux/<socket>/runtime.json apart from core sessions, re-reads on restart, and serves usage-query.js --tmux", { skip }, async () => {
    const firstConfig = join(root, "claude-first");
    const projects = join(firstConfig, "projects", "proj");
    mkdirSync(projects, { recursive: true });
    const nowIso = new Date().toISOString();
    writeFileSync(
      join(projects, "s1.jsonl"),
      `${JSON.stringify({
        type: "assistant",
        timestamp: nowIso,
        sessionId: "s",
        requestId: "r",
        cwd: "/work",
        message: {
          id: "msg_1",
          model: "claude-opus-4-1",
          usage: { input_tokens: 7, output_tokens: 5 },
        },
      })}\n`,
    );

    const first = startPrivateServer("work", { HOME: home, CLAUDE_CONFIG_DIR: firstConfig });
    storePaths("work", first.socket);

    // A core session of the same name keeps its own separate folder.
    mkdirSync(join(directory, "sessions", "work"), { recursive: true, mode: 0o700 });

    const follower = followStoredTmuxServers({
      directory,
      pollMs: 25,
      pollIntervalMs: 25,
      listener: tmuxUsageListener({ directory }),
    });
    cleanups.push(() => follower.stop());

    const runtimePath = join(directory, "tmux", "work", "runtime.json");
    await waitFor(() => existsSync(runtimePath), "tmux runtime record", PATIENCE_MS);
    assert.equal(existsSync(join(directory, "sessions", "work", "runtime.json")), false);
    assert.equal(readFileSync(join(directory, "tmux", "work", "runtime-node"), "utf8"), `${process.execPath}\n`);

    // Query settles against the tmux server's runtime record.
    let report = null;
    await waitFor(() => {
      const res = runQuery("--tz", "UTC", "--tmux", "work");
      assert.equal(res.status, 0, res.stderr);
      const parsed = JSON.parse(res.stdout);
      if (parsed.runtime === "recorded" && parsed.refreshing === false) {
        report = parsed;
        return true;
      }
      return false;
    }, "settled tmux usage report", PATIENCE_MS);

    const claude = report.programs.find((item) => item.program === "claude");
    assert.equal(claude.tokenUsage.state, "ok");
    assert.equal(claude.tokenUsage.totals.last30Days.tokens.total, 12);
    assert.equal(claude.accounts.find((account) => account.isDefault).directory, firstConfig);

    // Restart the server with a new CLAUDE_CONFIG_DIR; the new instance updates runtime.json.
    first.stop();
    const secondConfig = join(root, "claude-second");
    mkdirSync(secondConfig, { recursive: true });
    const second = startPrivateServer("work", { HOME: home, CLAUDE_CONFIG_DIR: secondConfig });
    await waitFor(
      () => JSON.parse(readFileSync(runtimePath, "utf8")).env.CLAUDE_CONFIG_DIR === secondConfig,
      "updated tmux runtime record on new server instance",
      PATIENCE_MS,
    );
    second.stop();
  });

  test("notes running Claude Code and Codex directories in tmux Panes for Account suggestions", { skip }, async () => {
    const bin = join(root, "bin");
    const claudeDir = join(root, "acct-claude");
    const codexDir = join(root, "acct-codex");
    mkdirSync(bin, { recursive: true });
    mkdirSync(claudeDir, { recursive: true });
    mkdirSync(codexDir, { recursive: true });

    for (const name of ["claude", "codex"]) {
      const target = join(bin, name);
      writeFileSync(target, `#!${process.execPath}\nsetInterval(() => {}, 1000);\n`, { mode: 0o755 });
      chmodSync(target, 0o755);
    }

    const server = startPrivateServer("work", { HOME: home });
    storePaths("work", server.socket);
    server.run("new-window", "-d", "-t", "main:", "-e", `CLAUDE_CONFIG_DIR=${claudeDir}`, join(bin, "claude"), "--resume");
    server.run("new-window", "-d", "-t", "main:", "-e", `CODEX_HOME=${codexDir}`, join(bin, "codex"), "--no-daemon");

    const follower = followStoredTmuxServers({
      directory,
      pollMs: 25,
      pollIntervalMs: 25,
      listener: tmuxUsageListener({ directory }),
    });
    cleanups.push(() => follower.stop());

    const stateDir = helperStateDirectory(directory);
    await waitFor(
      () =>
        agentDirectories(stateDir, Date.now(), "claude").includes(claudeDir) &&
        agentDirectories(stateDir, Date.now(), "codex").includes(codexDir),
      "both running agent directories noted",
      PATIENCE_MS,
    );
  });

  test("usage-query.js --tmux reports missing before a server runs and refuses invalid flags", () => {
    const missing = runQuery("--tz", "UTC", "--tmux", "absent");
    assert.equal(missing.status, 0, missing.stderr);
    assert.deepEqual(JSON.parse(missing.stdout), { version: 1, runtime: "missing" });

    for (const bad of [
      ["--tz", "UTC", "--tmux", "../work"],
      ["--tz", "UTC", "--tmux", "-flag"],
      ["--tz", "UTC", "--tmux", "work", "--session", "work"],
    ]) {
      const res = runQuery(...bad);
      assert.equal(res.status, 1);
      assert.equal(res.stdout, "");
    }
  });
});
