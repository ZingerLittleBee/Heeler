// The Helper's `pipe-pane` status reader for Codex, Grok Build and OpenCode
// 2.1+ on tmux Hosts (ADR 0046). Runs against a private `-S` tmux server with
// temporary HOME and fake agent programs writing bare and `ESC P tmux;`
// wrapped OSC 7501 reports.

import { afterEach, before, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { combineTmuxListeners, followTmuxServer } from "../helper/tmux/follower.js";
import { runStoredTmux } from "../helper/tmux/client.js";
import { createOsc7501Parser } from "../helper/tmux/osc7501.js";
import { tmuxPipeReaderListener } from "../helper/tmux/pipe-reader.js";
import { continueHeelerStatus, readHeelerStatus } from "../helper/tmux/status.js";
import { waitFor } from "./support/fake-core.js";
import { resolveTestTmux } from "./support/tmux.js";

const { skip, requireTmux } = resolveTestTmux();
const PATIENCE_MS = 5000;
const STATUS_VECTOR = JSON.parse(
  readFileSync(new URL("../test-vectors/tmux-heeler-status-v1.json", import.meta.url), "utf8"),
);

let root;
let home;
const cleanups = [];

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "heeler-tmux-pipe-"));
  home = join(root, "home");
  mkdirSync(home, { recursive: true });
});

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()();
  rmSync(root, { recursive: true, force: true });
});

function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code !== "ESRCH";
  }
}

function startPrivateServer(socketName = "work") {
  const executable = requireTmux();
  const socketDir = join(root, "sockets");
  mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  const socket = join(socketDir, socketName);
  execFileSync(
    executable,
    ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/cat"],
    {
      env: {
        PATH: "/usr/bin:/bin",
        HOME: home,
        USER: "fixture",
        TMUX_TMPDIR: socketDir,
        HISTFILE: "/dev/null",
        HISTSIZE: "0",
        SAVEHIST: "0",
      },
      stdio: "ignore",
    },
  );
  const stop = async () => {
    const pids = new Set();
    try {
      const listed = execFileSync(executable, ["-N", "-S", socket, "list-panes", "-a", "-F", "#{pid} #{pane_pid}"], {
        encoding: "utf8",
      });
      for (const word of listed.trim().split(/\s+/)) {
        if (/^\d+$/.test(word)) pids.add(Number(word));
      }
    } catch {
      // Already stopped.
    }
    try {
      execFileSync(executable, ["-N", "-S", socket, "kill-server"], { stdio: "ignore" });
    } catch {
      // Already stopped.
    }
    if (pids.size > 0) {
      await waitFor(() => [...pids].every((pid) => !processAlive(pid)), "server and pane processes exited", PATIENCE_MS);
    }
  };
  cleanups.push(() => stop());
  return {
    socket,
    paths: { executable, socket },
    stop,
    run(...args) {
      return execFileSync(executable, ["-N", "-S", socket, ...args], { encoding: "utf8" });
    },
    openShellPane() {
      return execFileSync(
        executable,
        [
          "-N",
          "-S",
          socket,
          "new-window",
          "-d",
          "-P",
          "-F",
          "#{pane_id}",
          "-t",
          "main:",
          "/usr/bin/env",
          "HISTFILE=/dev/null",
          "HISTSIZE=0",
          "SAVEHIST=0",
          "ENV=/dev/null",
          "PS1=$ ",
          "/bin/sh",
          "-i",
        ],
        { encoding: "utf8" },
      ).trim();
    },
    paneState(paneID) {
      const out = execFileSync(
        executable,
        [
          "-N",
          "-S",
          socket,
          "display-message",
          "-p",
          "-t",
          paneID,
          "#{pane_pipe}\t#{@heeler-pipe}\t#{@heeler-piped}\t#{@heeler-status}",
        ],
        { encoding: "utf8" },
      ).replace(/\n$/, "");
      const [pipe = "0", pipeMark = "", pipedProgram = "", status = ""] = out.split("\t");
      return { hasPipe: pipe !== "0", pipeMark, pipedProgram, status };
    },
  };
}

/**
 * Makes a fake interactive program named `name` that watches `commandFile` for
 * newline-delimited commands (`raw:<hex>` or `exit`) so tests can emit reports
 * after the pipe attaches and exit on cue.
 */
function makeControlledAgent(name) {
  const bin = join(root, "bin", `${name}-${Math.random().toString(16).slice(2, 8)}`);
  mkdirSync(bin, { recursive: true });
  const scriptPath = join(bin, name);
  const commandFile = join(bin, "commands.txt");
  writeFileSync(commandFile, "");
  writeFileSync(
    scriptPath,
    `#!${process.execPath}
const { readFileSync } = require("node:fs");
const file = ${JSON.stringify(commandFile)};
let lineCount = 0;
setInterval(() => {
  const lines = readFileSync(file, "utf8").split("\\n").filter(Boolean);
  while (lineCount < lines.length) {
    const line = lines[lineCount++];
    if (line === "exit") process.exit(0);
    if (line.startsWith("hex:")) process.stdout.write(Buffer.from(line.slice(4), "hex"));
  }
}, 15);
`,
    { mode: 0o755 },
  );
  chmodSync(scriptPath, 0o755);
  return {
    executable: scriptPath,
    emit(bytes) {
      const buf = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes, "utf8");
      writeFileSync(commandFile, `hex:${buf.toString("hex")}\n`, { flag: "a" });
    },
    exit() {
      writeFileSync(commandFile, "exit\n", { flag: "a" });
    },
  };
}

suite("tmux status vector and OSC 7501 parser", () => {
  test("matches every value and write step of tmux-heeler-status-v1.json", () => {
    for (const item of STATUS_VECTOR.values) {
      const actual = readHeelerStatus(item.value);
      assert.deepEqual(
        actual,
        {
          state: item.state,
          app: item.app,
          kind: item.kind,
          msg: item.msg,
          turn: item.turn,
          blocked: item.blocked,
        },
        item.name,
      );
    }
    for (const scenario of STATUS_VECTOR.writes) {
      let current = scenario.start;
      for (const step of scenario.steps) {
        current = continueHeelerStatus(current, step.report);
        assert.equal(current, step.value, scenario.name);
      }
    }
  });

  test("parses bare and ESC P tmux; wrapped OSC 7501 reports byte by byte while ignoring queries and child records", () => {
    const msg = Buffer.from("Need approval", "utf8").toString("base64");
    const stream = Buffer.concat([
      Buffer.from("hello \x1b[32mworld\x1b[0m\r\n"),
      // Capability query: ignored.
      Buffer.from("\x1b]7501;?\x1b\\"),
      // Truncated sequence before a valid BEL-terminated bare report.
      Buffer.from("\x1b]7501;state=working\x1b]7501;state=working:app=codex\x07"),
      // OpenCode child session record (`id=ses_1`): ignored so root status decides.
      Buffer.from("\x1b]7501;state=working:id=ses_1:app=opencode\x1b\\"),
      Buffer.from("\x1b]7501;state=clear:id=ses_1:app=opencode\x1b\\"),
      // Bare ST-terminated report with kind and base64 msg.
      Buffer.from(`\x1b]7501;state=blocked:app=codex:kind=permission:msg=${msg}\x1b\\`),
      // Grok Build tmux DCS passthrough report and exit clear (no app on clear).
      Buffer.from("\x1bPtmux;\x1b\x1b]7501;state=done:app=grok-build\x1b\x1b\\\x1b\\"),
      Buffer.from("\x1bPtmux;\x1b\x1b]7501;state=clear\x1b\x1b\\\x1b\\"),
    ]);

    const reports = [];
    const parser = createOsc7501Parser((report) => reports.push(report));
    for (let i = 0; i < stream.length; i += 1) {
      parser.feed(stream.subarray(i, i + 1));
    }

    assert.deepEqual(reports, [
      { state: "working", app: "codex", kind: null, msg: null },
      { state: "blocked", app: "codex", kind: "permission", msg },
      { state: "done", app: "grok-build", kind: null, msg: null },
      { state: "clear", app: null, kind: null, msg: null },
    ]);
  });
});

suite("tmux pipe-pane status reader", { skip }, () => {
  before(() => {
    requireTmux();
  });

  test("attaches to Codex, Grok Build and OpenCode, writes @heeler-status continuing counts, and ignores non-pipe programs", async () => {
    const server = startPrivateServer("work");
    const codex = makeControlledAgent("codex");
    const grok = makeControlledAgent("grok");
    const opencode = makeControlledAgent("opencode");
    const claude = makeControlledAgent("claude");

    const codexPane = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", codex.executable, "--no-daemon").trim();
    // Seed existing counts on Codex's pane to verify continuation.
    server.run("set-option", "-p", "-t", codexPane, "@heeler-status", "state=idle:app=claude-code:turn=3:blocked=1");

    const grokPane = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", grok.executable, "-s", "1").trim();
    const opencodePane = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", opencode.executable, "-s", "ses_1").trim();
    const claudePane = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", claude.executable, "--resume").trim();

    const follower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: tmuxPipeReaderListener(),
    });
    cleanups.push(() => follower.stop());

    await waitFor(
      () =>
        server.paneState(codexPane).hasPipe &&
        server.paneState(codexPane).pipeMark !== "" &&
        server.paneState(grokPane).hasPipe &&
        server.paneState(opencodePane).hasPipe,
      "pipes attached to codex, grok and opencode",
      PATIENCE_MS,
    );
    // Shell (%0) and Claude Code get no pipe-pane.
    assert.equal(server.paneState("%0").hasPipe, false);
    assert.equal(server.paneState(claudePane).hasPipe, false);

    // Codex bare reports continue turn=3:blocked=1 -> blocked=2 -> turn=4:blocked=2.
    codex.emit("\x1b]7501;state=working:app=codex\x07");
    codex.emit("\x1b]7501;state=blocked:app=codex:kind=permission\x07");
    codex.emit("\x1b]7501;state=done:app=codex\x07");
    await waitFor(
      () => server.paneState(codexPane).status === "state=done:app=codex:turn=4:blocked=2",
      "codex @heeler-status updated",
      PATIENCE_MS,
    );

    // Grok Build wrapped reports update @heeler-status.
    grok.emit("\x1bPtmux;\x1b\x1b]7501;state=working:app=grok-build\x1b\x1b\\\x1b\\");
    grok.emit("\x1bPtmux;\x1b\x1b]7501;state=done:app=grok-build\x1b\x1b\\\x1b\\");
    await waitFor(
      () => server.paneState(grokPane).status === "state=done:app=grok-build:turn=1:blocked=0",
      "grok @heeler-status updated",
      PATIENCE_MS,
    );

    // OpenCode 2.1+ reports working, child clear, then idle -> turn=1 (not in DONE_REPORTERS).
    opencode.emit("\x1b]7501;state=working:app=opencode\x1b\\");
    opencode.emit("\x1b]7501;state=working:id=ses_1:app=opencode\x1b\\");
    opencode.emit("\x1b]7501;state=clear:id=ses_1:app=opencode\x1b\\");
    opencode.emit("\x1b]7501;state=idle:app=opencode\x1b\\");
    await waitFor(
      () => server.paneState(opencodePane).status === "state=idle:app=opencode:turn=1:blocked=0",
      "opencode @heeler-status updated",
      PATIENCE_MS,
    );
  });

  test("recognizes its own @heeler-pipe across a Helper restart and closes it when the foreground leaves", async () => {
    const server = startPrivateServer("work");
    const codex = makeControlledAgent("codex");
    const paneID = server.openShellPane();
    server.run("send-keys", "-t", paneID, "-l", `'${codex.executable}'`);
    server.run("send-keys", "-t", paneID, "Enter");

    const first = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: tmuxPipeReaderListener(),
    });
    cleanups.push(() => first.stop());

    await waitFor(() => server.paneState(paneID).pipeMark !== "", "initial pipe mark", PATIENCE_MS);
    const originalMark = server.paneState(paneID).pipeMark;

    // Simulate a Helper restart while the pipe-pane worker stays attached.
    await first.stop();
    assert.equal(server.paneState(paneID).hasPipe, true);
    assert.equal(server.paneState(paneID).pipeMark, originalMark);

    let ticks = 0;
    const second = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: combineTmuxListeners(
        tmuxPipeReaderListener(),
        { panesUpdated: () => { ticks += 1; } },
      ),
    });
    cleanups.push(() => second.stop());

    await waitFor(() => ticks >= 3, "restarted follower sampled", PATIENCE_MS);
    assert.equal(server.paneState(paneID).hasPipe, true);
    assert.equal(server.paneState(paneID).pipeMark, originalMark);

    // Existing worker still writes status reports.
    codex.emit("\x1b]7501;state=working:app=codex\x07");
    await waitFor(
      () => server.paneState(paneID).status === "state=working:app=codex:turn=0:blocked=0",
      "existing pipe still writes after Helper restart",
      PATIENCE_MS,
    );

    // Once Codex exits back to the interactive shell, Heeler closes its marked pipe and clears the mark.
    codex.exit();
    await waitFor(
      () => !server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark === "",
      "pipe closed and @heeler-pipe cleared when foreground left",
      PATIENCE_MS,
    );
  });

  test("a pipe closed without Heeler leaves the Pane alone until its foreground program changes", async () => {
    const server = startPrivateServer("work");
    const firstCodex = makeControlledAgent("codex");
    const secondCodex = makeControlledAgent("codex");
    const paneID = server.openShellPane();
    server.run("send-keys", "-t", paneID, "-l", `'${firstCodex.executable}'; '${secondCodex.executable}'`);
    server.run("send-keys", "-t", paneID, "Enter");

    let ticks = 0;
    const follower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: combineTmuxListeners(
        tmuxPipeReaderListener(),
        { panesUpdated: () => { ticks += 1; } },
      ),
    });
    cleanups.push(() => follower.stop());

    await waitFor(() => server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark !== "", "first pipe attached", PATIENCE_MS);

    // Close the pipe externally (`pipe-pane -t <pane>` with no command) while firstCodex keeps running.
    server.run("pipe-pane", "-t", paneID);
    await waitFor(
      () => !server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark === "",
      "worker cleared @heeler-pipe on EOF",
      PATIENCE_MS,
    );

    const tickAtClose = ticks;
    await waitFor(() => ticks >= tickAtClose + 4, "several follower ticks after external close", PATIENCE_MS);
    // Still unpiped while firstCodex stays in the foreground.
    assert.equal(server.paneState(paneID).hasPipe, false);
    assert.equal(server.paneState(paneID).pipeMark, "");

    // Now firstCodex exits and secondCodex takes the foreground: Heeler attaches to the new program.
    firstCodex.exit();
    await waitFor(
      () => server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark !== "",
      "re-attached once foreground program changed",
      PATIENCE_MS,
    );
    secondCodex.emit("\x1b]7501;state=idle:app=codex\x07");
    await waitFor(
      () => server.paneState(paneID).status === "state=idle:app=codex:turn=0:blocked=0",
      "second codex status written",
      PATIENCE_MS,
    );
  });

  test("a pipe closed without Heeler stays unattached across a Helper restart until a new program starts", async () => {
    const server = startPrivateServer("work");
    const firstCodex = makeControlledAgent("codex");
    const secondCodex = makeControlledAgent("codex");
    const paneID = server.openShellPane();
    server.run("send-keys", "-t", paneID, "-l", `'${firstCodex.executable}'; '${secondCodex.executable}'`);
    server.run("send-keys", "-t", paneID, "Enter");

    const firstFollower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: tmuxPipeReaderListener(),
    });
    cleanups.push(() => firstFollower.stop());

    await waitFor(
      () => server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark !== "",
      "first pipe attached",
      PATIENCE_MS,
    );

    // Close the pipe externally while firstCodex stays in the foreground.
    server.run("pipe-pane", "-t", paneID);
    await waitFor(
      () => !server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark === "",
      "worker cleared @heeler-pipe on EOF",
      PATIENCE_MS,
    );

    // Restart the Helper (brand-new follower and pipe-reader listener).
    await firstFollower.stop();

    let ticks = 0;
    const secondFollower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: combineTmuxListeners(
        tmuxPipeReaderListener(),
        { panesUpdated: () => { ticks += 1; } },
      ),
    });
    cleanups.push(() => secondFollower.stop());

    await waitFor(() => ticks >= 4, "restarted follower sampled several times", PATIENCE_MS);
    assert.equal(server.paneState(paneID).hasPipe, false);
    assert.equal(server.paneState(paneID).pipeMark, "");

    // Once firstCodex exits and secondCodex takes the foreground, the restarted Helper attaches.
    firstCodex.exit();
    await waitFor(
      () => server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark !== "",
      "restarted Helper attached to new foreground program",
      PATIENCE_MS,
    );
    secondCodex.emit("\x1b]7501;state=working:app=codex\x07");
    await waitFor(
      () => server.paneState(paneID).status === "state=working:app=codex:turn=0:blocked=0",
      "second codex status written after Helper restart",
      PATIENCE_MS,
    );

    // Returning to the shell closes the pipe and clears both pipe options.
    secondCodex.exit();
    await waitFor(
      () =>
        !server.paneState(paneID).hasPipe &&
        server.paneState(paneID).pipeMark === "" &&
        server.paneState(paneID).pipedProgram === "",
      "both @heeler-pipe and @heeler-piped cleared on return to shell",
      PATIENCE_MS,
    );
  });

  test("leaves a Pane the user already pipes completely alone", async () => {
    const server = startPrivateServer("work");
    const codex = makeControlledAgent("codex");
    const userLog = join(root, "user-pipe.log");
    const paneID = server.openShellPane();
    server.run("send-keys", "-t", paneID, "-l", `'${codex.executable}'`);
    server.run("send-keys", "-t", paneID, "Enter");
    server.run("pipe-pane", "-O", "-t", paneID, `/bin/cat > '${userLog.replaceAll("'", "'\\''")}'`);
    assert.equal(server.paneState(paneID).hasPipe, true);
    assert.equal(server.paneState(paneID).pipeMark, "");

    let ticks = 0;
    const follower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 30,
      listener: combineTmuxListeners(
        tmuxPipeReaderListener(),
        { panesUpdated: () => { ticks += 1; } },
      ),
    });
    cleanups.push(() => follower.stop());

    await waitFor(() => ticks >= 3, "follower observed user-piped pane", PATIENCE_MS);
    codex.emit("hello-user-pipe\n\x1b]7501;state=working:app=codex\x07");
    await waitFor(() => {
      try {
        return readFileSync(userLog, "utf8").includes("hello-user-pipe");
      } catch {
        return false;
      }
    }, "user pipe still receiving bytes", PATIENCE_MS);

    assert.equal(server.paneState(paneID).hasPipe, true);
    assert.equal(server.paneState(paneID).pipeMark, "");
    assert.equal(server.paneState(paneID).status, "");

    // Even after Codex exits to the shell, the user's pipe stays open.
    codex.exit();
    const afterExitTick = ticks;
    await waitFor(() => ticks >= afterExitTick + 3, "follower observed exit on user-piped pane", PATIENCE_MS);
    assert.equal(server.paneState(paneID).hasPipe, true);
    assert.equal(server.paneState(paneID).pipeMark, "");
  });

  test("a failed pipe-pane attach leaves neither option behind and retries on a later sample", async () => {
    const server = startPrivateServer("work");
    const codex = makeControlledAgent("codex");
    const paneID = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", codex.executable, "--no-daemon").trim();

    // First failure mode: tmux's own `pipe-pane` command fails after the leading `set-option`s run.
    let failTmuxCommandOnce = true;
    let stateAfterFailedSample = null;
    const logs = [];
    const firstFollower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 40,
      listener: combineTmuxListeners(
        tmuxPipeReaderListener({
          log: (line) => logs.push(line),
          runTmux: async (target, args, options) => {
            if (failTmuxCommandOnce && args.includes("pipe-pane")) {
              failTmuxCommandOnce = false;
              const pipeIndex = args.indexOf("pipe-pane");
              const broken = [...args];
              const targetFlagIndex = broken.indexOf("-t", pipeIndex);
              broken[targetFlagIndex + 1] = "%999";
              return runStoredTmux(target, broken, options);
            }
            return runStoredTmux(target, args, options);
          },
        }),
        {
          panesUpdated: () => {
            if (!failTmuxCommandOnce && stateAfterFailedSample === null) {
              stateAfterFailedSample = server.paneState(paneID);
            }
          },
        },
      ),
    });
    cleanups.push(() => firstFollower.stop());

    await waitFor(() => stateAfterFailedSample !== null, "first attach attempt failed", PATIENCE_MS);
    assert.equal(stateAfterFailedSample.hasPipe, false);
    assert.equal(stateAfterFailedSample.pipeMark, "");
    assert.equal(stateAfterFailedSample.pipedProgram, "");
    assert.ok(logs.some((line) => line.includes("pipe-pane on") && line.includes("failed")));

    await waitFor(
      () => server.paneState(paneID).hasPipe && server.paneState(paneID).pipeMark !== "",
      "later sample retried and attached after tmux command failure",
      PATIENCE_MS,
    );
    codex.emit("\x1b]7501;state=working:app=codex\x07");
    await waitFor(
      () => server.paneState(paneID).status === "state=working:app=codex:turn=0:blocked=0",
      "status written after retry",
      PATIENCE_MS,
    );
    await firstFollower.stop();

    // Second failure mode: worker path is missing on the first attempt, then valid on the next sample.
    const secondCodex = makeControlledAgent("codex");
    const secondPane = server.run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "main:", secondCodex.executable, "--no-daemon").trim();
    let workerAttempts = 0;
    const secondFollower = followTmuxServer("work", server.paths, {
      pollIntervalMs: 40,
      listener: tmuxPipeReaderListener({
        resolveWorkerPath: (defaultPath) => {
          workerAttempts += 1;
          return workerAttempts === 1 ? join(root, "missing-worker.js") : defaultPath;
        },
      }),
    });
    cleanups.push(() => secondFollower.stop());

    await waitFor(() => workerAttempts >= 1, "first worker-path attempt issued", PATIENCE_MS);
    // tmux detects a dead pipe-pane child when the Pane next writes output (`EPIPE`);
    // under parallel suite load the missing-worker child may still be starting or exiting on the first write.
    await waitFor(
      () => {
        if (workerAttempts < 2) secondCodex.emit("prompt\r\n");
        return (
          workerAttempts >= 2 &&
          server.paneState(secondPane).hasPipe &&
          server.paneState(secondPane).pipedProgram !== ""
        );
      },
      "later sample retried and attached after missing worker path",
      PATIENCE_MS,
    );
    secondCodex.emit("\x1b]7501;state=done:app=codex\x07");
    await waitFor(
      () => server.paneState(secondPane).status === "state=done:app=codex:turn=0:blocked=0",
      "status written after worker-path retry",
      PATIENCE_MS,
    );
  });
});
