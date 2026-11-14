// Heeler's Claude Code hook script in a tmux Pane (ADR 0046): the
// `@heeler-status` counts from the shared vector through every shell here,
// then the script run by a stand-in Claude Code in a Pane of a private tmux
// server, with a home of its own, for each event Heeler's entries name.

import { after, before, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { resolveTestTmux } from "./support/tmux.js";

const SCRIPT = fileURLToPath(new URL("../claude-code/hook.sh", import.meta.url));
const status = JSON.parse(readFileSync(new URL("../test-vectors/tmux-heeler-status-v1.json", import.meta.url), "utf8"));
const hooks = JSON.parse(readFileSync(new URL("../test-vectors/claude-code-hooks-v1.json", import.meta.url), "utf8"));

/** Heeler's command for a script path, as the hooks vector writes it. */
function hookCommand(script, shell = "/bin/sh") {
  return `f='${script.replaceAll("'", "'\\''")}'; [ ! -r "$f" ] || exec ${shell} "$f"`;
}

/** Each POSIX shell here, as the hook's `/bin/sh` may be any of them. */
function shells() {
  const found = ["/bin/sh"];
  for (const name of ["dash", "bash", "ksh"]) {
    const which = spawnSync("/bin/sh", ["-c", `command -v ${name}`], { encoding: "utf8" });
    const path = which.stdout.trim();
    if (which.status === 0 && path.startsWith("/")) found.push(path);
  }
  return found;
}

suite("Heeler's hook command", () => {
  test("is the vector's for every script path", () => {
    for (const vector of hooks.commands) assert.equal(hookCommand(vector.script), vector.command, vector.name);
  });

  test("runs nothing and fails nothing once the script is gone", () => {
    const run = spawnSync("/bin/sh", ["-c", hookCommand("/nonexistent/heeler/claude-code/hook.sh")], {
      input: '{"hook_event_name":"Stop"}',
      encoding: "utf8",
    });
    assert.equal(run.status, 0);
    assert.equal(run.stderr, "");
    assert.equal(run.stdout, "");
  });
});

suite("the script's @heeler-status writes", () => {
  test("every write continues the counts as the vector says, in every shell", () => {
    assert.ok(status.writes.length > 0);
    for (const shell of shells()) {
      for (const vector of status.writes) {
        let value = vector.start ?? "";
        for (const [index, step] of vector.steps.entries()) {
          const { state, app, kind = "", msg = "" } = step.report;
          value = execFileSync(shell, [SCRIPT, "continue", value, state, app, kind, msg], { encoding: "utf8" }).replace(
            /\n$/,
            "",
          );
          assert.equal(value, step.value, `${shell}: ${vector.name}, step ${index + 1}`);
        }
      }
    }
  });

  test("the programs known to report done are the vector's", () => {
    const line = /^DONE_REPORTERS="([^"]*)"$/m.exec(readFileSync(SCRIPT, "utf8"));
    assert.ok(line, "the script names its done reporters");
    assert.deepEqual(line[1].split(" ").sort(), [...status.doneReporters].sort());
  });
});

const { tmux: TMUX, skip, pathWithTmux, requireTmux } = resolveTestTmux();

/**
 * A stand-in Claude Code: it waits for `go`, then runs each step's hook as
 * Claude Code does, the command through `sh -c` with the event on stdin, and
 * after each one notes the Pane's options. A step with `child` runs its hook
 * from a process of its own, as a `claude -p` a tool started would.
 */
const DRIVER = `
import { spawn, execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const [stepsFile, go, done, tmux, socket] = process.argv.slice(2);
// The Pane this stand-in runs in, whatever its environment says: its own, or its shell's.
const pane = execFileSync(tmux, ["-N", "-S", socket, "list-panes", "-a", "-F", "#{pane_pid} #{pane_id}"], { encoding: "utf8" })
  .split("\\n")
  .map((line) => line.split(" "))
  .find(([pid]) => pid === String(process.pid) || pid === String(process.ppid))?.[1];
function runHook(command, payload, child) {
  return new Promise((resolve) => {
    const argv = child
      ? [process.execPath, ["-e", "const r=require('node:child_process').spawnSync('/bin/sh',['-c',process.argv[1]],{input:process.argv[2],encoding:'utf8'});process.stderr.write(r.stderr??'');process.exit(r.status??1)", command, payload]]
      : ["/bin/sh", ["-c", command]];
    const hook = spawn(argv[0], argv[1], { stdio: ["pipe", "ignore", "pipe"] });
    let stderr = "";
    hook.stderr.on("data", (chunk) => (stderr += chunk));
    hook.on("close", (code) => resolve({ code, stderr }));
    // Fast-exiting hooks (for example a missing script) close stdin before the payload flushes.
    hook.stdin.on("error", () => {});
    hook.stdin.end(child ? "" : payload);
  });
}
const option = (name) =>
  pane ? execFileSync(tmux, ["-N", "-S", socket, "show-options", "-p", "-q", "-v", "-t", pane, name], { encoding: "utf8" }).replace(/\\n$/, "") : "";
while (!existsSync(go)) await new Promise((resolve) => setTimeout(resolve, 20));
const results = [];
for (const step of JSON.parse(readFileSync(stepsFile, "utf8"))) {
  const ran = await runHook(step.command, JSON.stringify(step.payload), step.child);
  results.push({ ...ran, status: option("@heeler-status"), ask: option("@heeler-ask") });
}
writeFileSync(done, JSON.stringify({ pid: process.pid, results }));
setInterval(() => {}, 60000);
`;

/** The word each report is, as an event of Claude Code's that reports it. */
function eventFor(report, index) {
  switch (report.state) {
    case "idle":
      return index === 0 ? { hook_event_name: "SessionStart", source: "startup" } : notification("idle_prompt");
    case "working":
      return { hook_event_name: "UserPromptSubmit", prompt: "go on" };
    case "blocked":
      return permission("Bash", { command: `touch file-${index}` });
    case "done":
      return { hook_event_name: "Stop", stop_hook_active: false };
    case "error":
      return {
        hook_event_name: "StopFailure",
        error: "rate_limit",
        last_assistant_message: Buffer.from(report.msg ?? "", "base64").toString("utf8"),
      };
    case "clear":
      return { hook_event_name: "SessionEnd", reason: "prompt_input_exit" };
    default:
      throw new Error(`no event reports ${report.state}`);
  }
}

const notification = (type) => ({ hook_event_name: "Notification", message: "Claude", notification_type: type });
const permission = (tool, input, extra = {}) => ({
  hook_event_name: "PermissionRequest",
  tool_name: tool,
  tool_input: input,
  permission_suggestions: [],
  ...extra,
});
const toolEvent = (name, tool, input, extra = {}) => ({
  hook_event_name: name,
  tool_name: tool,
  tool_input: input,
  tool_use_id: `toolu_${tool}`,
  ...(name === "PreToolUse" ? {} : { tool_response: { stdout: "x".repeat(4096), stderr: "" } }),
  ...extra,
});

/**
 * The vector's cases a Claude Code can write: one program throughout, which
 * reports done, played as Claude Code. Claude Code asks only for permission.
 * A start value of Claude Code's own, beside another program's steps, becomes
 * that other program's, so the counts it continues stay another program's.
 */
function claudeCases() {
  const cases = [];
  for (const vector of status.writes) {
    const apps = new Set(vector.steps.map((step) => step.report.app));
    if (apps.size !== 1) continue;
    const [app] = apps;
    if (!status.doneReporters.includes(app)) continue;
    const swap = (value) =>
      value === null
        ? null
        : value
            .replaceAll("app=claude-code", "app=\u0000")
            .replaceAll(`app=${app}`, "app=claude-code")
            .replaceAll("app=\u0000", `app=${app}`)
            .replace(/kind=question/g, "kind=permission");
    const asClaude = (value) => swap(value).replace(/state=blocked:app=claude-code:kind=[a-z]+/g, "state=blocked:app=claude-code:kind=permission");
    cases.push({
      name: vector.name,
      start: swap(vector.start),
      steps: vector.steps.map((step) => ({ report: step.report, value: asClaude(step.value) })),
    });
  }
  return cases;
}

suite("the script in a tmux Pane", { skip }, () => {
  let root;
  let home;
  let script;
  let socket;
  let runs = 0;

  const tmux = (...args) =>
    execFileSync(TMUX, ["-N", "-S", socket, ...args], { encoding: "utf8", env: tmuxEnvironment() }).replace(/\n$/, "");

  /** The server's environment, which every Pane starts from: nothing of the test runner's own tmux. */
  function tmuxEnvironment() {
    return { HOME: home, PATH: pathWithTmux, SHELL: "/bin/sh", TERM: "xterm-256color", LC_ALL: "C" };
  }

  /** The paths the app stores for `name`'s server, as `TmuxPaths` encodes them. */
  function storePaths(name, paths) {
    const data =
      process.platform === "darwin" ? join(home, "Library", "Application Support") : join(home, ".local", "share");
    const folder = join(data, "heeler", "host-helper", "tmux", name);
    mkdirSync(folder, { recursive: true });
    writeFileSync(join(folder, "paths.json"), JSON.stringify(paths));
  }

  before(() => {
    const executable = requireTmux();
    root = mkdtempSync("/tmp/hkt-");
    home = join(root, "home");
    mkdirSync(home);
    socket = join(root, "s");
    // Where the app keeps the script, with a space as Application Support has one.
    const folder = join(root, "heeler data", "heeler", "claude-code");
    mkdirSync(folder, { recursive: true });
    script = join(folder, "hook.sh");
    writeFileSync(script, readFileSync(SCRIPT));
    writeFileSync(join(root, "driver.mjs"), DRIVER);
    // A placeholder keeps the server up between the windows the tests open.
    execFileSync(executable, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "hold", "sleep", "600"], {
      env: tmuxEnvironment(),
    });
    execFileSync(executable, ["-N", "-S", socket, "set-environment", "-g", "PATH", pathWithTmux], {
      env: tmuxEnvironment(),
    });
    storePaths("s", { executable, socket });
  });

  after(() => {
    if (TMUX && socket && existsSync(socket)) spawnSync(TMUX, ["-S", socket, "kill-server"]);
    if (root) rmSync(root, { recursive: true, force: true });
  });

  /**
   * Opens a window whose program is the stand-in, sets `seed` as its status,
   * lets it run each step's hook and waits for it to finish them. `shell`
   * runs it under a shell that stays its foreground.
   */
  async function run({ steps, seed, ask, shell = false, environment = {}, hookShell, command }) {
    const name = `run-${runs++}`;
    const go = join(root, `${name}.go`);
    const done = join(root, `${name}.done`);
    const prepared = steps.map((step) => ({
      child: step.child ?? false,
      command: command ?? hookCommand(script, hookShell),
      payload: {
        session_id: step.session ?? "9a7714b3-b2a6-4f8e-b30d-94b5df8fc6fc",
        transcript_path: step.transcript ?? "/h/.claude/projects/-w/9a7714b3-b2a6-4f8e-b30d-94b5df8fc6fc.jsonl",
        cwd: "/w",
        ...step.event,
      },
    }));
    const stepsFile = join(root, `${name}.json`);
    writeFileSync(stepsFile, JSON.stringify(prepared));
    const argv = [process.execPath, join(root, "driver.mjs"), stepsFile, go, done, TMUX, socket];
    const quoted = argv.map((word) => `'${word.replaceAll("'", "'\\''")}'`).join(" ");
    const exports = Object.entries(environment)
      .map(([key, value]) => `export ${key}='${value}';`)
      .join(" ");
    // With variables alone, the shell replaces itself with the stand-in, which so still leads the Pane.
    const program = shell
      ? ["/bin/sh", "-c", `${exports} ${quoted}; sleep 600`]
      : exports
        ? ["/bin/sh", "-c", `${exports} exec ${quoted}`]
        : argv;
    const pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-n", name, "--", ...program);
    if (seed) tmux("set-option", "-p", "-t", pane, "@heeler-status", seed);
    if (ask) tmux("set-option", "-p", "-t", pane, "@heeler-ask", ask.replace("<pid>", tmux("display-message", "-p", "-t", pane, "#{pane_pid}")));
    writeFileSync(go, "");
    const deadline = Date.now() + 20000;
    while (!existsSync(done)) {
      assert.ok(Date.now() < deadline, `the stand-in in ${pane} did not finish`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    const result = JSON.parse(readFileSync(done, "utf8"));
    for (const [index, step] of result.results.entries()) {
      assert.equal(step.code, 0, `step ${index + 1} exits 0`);
      assert.equal(step.stderr, "", `step ${index + 1} says nothing`);
    }
    return { pane, ...result, statuses: result.results.map((step) => step.status) };
  }

  const option = (pane, name) => tmux("show-options", "-p", "-q", "-v", "-t", pane, name);

  test("the vector's writes, as Claude Code's events", async () => {
    const cases = claudeCases();
    assert.ok(cases.length >= 8, "most of the vector's cases are Claude Code's to write");
    for (const vector of cases) {
      const { statuses } = await run({
        seed: vector.start ?? undefined,
        steps: vector.steps.map((step, index) => ({ event: eventFor(step.report, index) })),
      });
      assert.deepEqual(
        statuses,
        vector.steps.map((step) => step.value),
        vector.name,
      );
    }
  });

  test("every POSIX shell here writes the same", async () => {
    for (const hookShell of shells().slice(1)) {
      const { statuses } = await run({
        hookShell,
        steps: [
          { event: { hook_event_name: "SessionStart", source: "startup" } },
          { event: { hook_event_name: "UserPromptSubmit" } },
          { event: permission("Bash", { command: "ls" }) },
          { event: toolEvent("PostToolUse", "Bash", { command: "ls" }) },
          { event: { hook_event_name: "StopFailure", last_assistant_message: "API Error: Rate limit reached\nretry" } },
        ],
      });
      assert.deepEqual(
        statuses,
        [
          "state=idle:app=claude-code:turn=0:blocked=0",
          "state=working:app=claude-code:turn=0:blocked=0",
          "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1",
          "state=working:app=claude-code:turn=0:blocked=1",
          `state=error:app=claude-code:msg=${Buffer.from("API Error: Rate limit reached").toString("base64")}:turn=1:blocked=1`,
        ],
        hookShell,
      );
    }
  });

  test("tool events and a compaction's start move nothing they should not", async () => {
    const { statuses } = await run({
      steps: [
        { event: { hook_event_name: "SessionStart", source: "startup" } },
        { event: { hook_event_name: "SessionStart", source: "compact" } },
        { event: toolEvent("PreToolUse", "Read", { file_path: "/w/a" }) },
        { event: toolEvent("PostToolUseFailure", "Read", { file_path: "/w/a" }, { error: "missing" }) },
        { event: { hook_event_name: "Stop" } },
        { event: { hook_event_name: "SessionStart", source: "compact" } },
        { event: notification("idle_prompt") },
        { event: notification("auth_success") },
        { event: { hook_event_name: "SessionStart", source: "clear" } },
        { event: { hook_event_name: "SessionEnd", reason: "clear" } },
      ],
    });
    assert.deepEqual(statuses, [
      "state=idle:app=claude-code:turn=0:blocked=0",
      "state=idle:app=claude-code:turn=0:blocked=0",
      "state=working:app=claude-code:turn=0:blocked=0",
      "state=working:app=claude-code:turn=0:blocked=0",
      "state=done:app=claude-code:turn=1:blocked=0",
      "state=done:app=claude-code:turn=1:blocked=0",
      "state=idle:app=claude-code:turn=1:blocked=0",
      "state=idle:app=claude-code:turn=1:blocked=0",
      "state=idle:app=claude-code:turn=1:blocked=0",
      "turn=1:blocked=0",
    ]);
  });

  test("a question stays blocked through other tools and subagents until its own tool answers", async () => {
    const asked = { command: "rm -rf build", description: "Clean" };
    const { statuses } = await run({
      seed: "state=working:app=claude-code:turn=2:blocked=0",
      steps: [
        { event: toolEvent("PreToolUse", "Bash", asked) },
        { event: permission("Bash", asked) },
        { event: toolEvent("PreToolUse", "Read", { file_path: "/w/a" }, { agent_id: "a1", agent_type: "Explore" }) },
        { event: toolEvent("PostToolUse", "Read", { file_path: "/w/a" }, { agent_id: "a1", agent_type: "Explore" }) },
        { event: toolEvent("PostToolUse", "Bash", { ...asked, command: "rm -rf dist" }) },
        { event: notification("permission_prompt") },
        { event: notification("idle_prompt") },
        { event: { hook_event_name: "SessionStart", source: "resume" } },
        { event: toolEvent("PostToolUse", "Bash", asked) },
        { event: toolEvent("PostToolUse", "Read", { file_path: "/w/a" }) },
      ],
    });
    const blocked = "state=blocked:app=claude-code:kind=permission:turn=2:blocked=1";
    assert.deepEqual(statuses, [
      "state=working:app=claude-code:turn=2:blocked=0",
      blocked,
      blocked,
      blocked,
      blocked,
      blocked,
      blocked,
      blocked,
      "state=working:app=claude-code:turn=2:blocked=1",
      "state=working:app=claude-code:turn=2:blocked=1",
    ]);
  });

  test("two open questions, a subagent's among them, keep it blocked until both are answered", async () => {
    const first = { command: "make deploy" };
    const second = { file_path: "/w/b", content: "b" };
    const { statuses, results } = await run({
      seed: "state=working:app=claude-code:turn=0:blocked=0",
      steps: [
        { event: permission("Bash", first) },
        { event: permission("Write", second, { agent_id: "a2", agent_type: "general-purpose" }) },
        { event: toolEvent("PostToolUseFailure", "Bash", first, { error: "denied" }) },
        { event: toolEvent("PostToolUse", "Write", second, { agent_id: "a2", agent_type: "general-purpose" }) },
      ],
    });
    const blocked = "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1";
    assert.deepEqual(statuses, [blocked, blocked, blocked, "state=working:app=claude-code:turn=0:blocked=1"]);
    assert.equal(results[3].ask, "");
  });

  test("a prompt that names no tool is held until the turn moves", async () => {
    const { statuses } = await run({
      seed: "state=working:app=claude-code:turn=0:blocked=0",
      steps: [
        { event: notification("permission_prompt") },
        { event: toolEvent("PostToolUse", "Bash", { command: "curl example.com" }) },
        { event: { hook_event_name: "Stop" } },
        { event: { hook_event_name: "UserPromptSubmit" } },
        { event: notification("permission_prompt") },
        { event: { hook_event_name: "UserPromptSubmit" } },
      ],
    });
    assert.deepEqual(statuses, [
      "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1",
      "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1",
      "state=done:app=claude-code:turn=1:blocked=1",
      "state=working:app=claude-code:turn=1:blocked=1",
      "state=blocked:app=claude-code:kind=permission:turn=1:blocked=2",
      "state=working:app=claude-code:turn=1:blocked=2",
    ]);
  });

  test("a question another Claude Code left open holds nothing for this one", async () => {
    const { statuses } = await run({
      seed: "state=blocked:app=claude-code:kind=permission:turn=1:blocked=1",
      ask: "1 1-1",
      steps: [{ event: { hook_event_name: "SessionStart", source: "startup" } }],
    });
    assert.deepEqual(statuses, ["state=idle:app=claude-code:turn=1:blocked=1"]);
  });

  test("Heeler's own write ends the hold, and the next question starts afresh", async () => {
    const { statuses } = await run({
      seed: "state=working:app=claude-code:turn=0:blocked=1",
      ask: "<pid> 5-5",
      steps: [
        { event: toolEvent("PreToolUse", "Read", { file_path: "/w/a" }) },
        { event: permission("Bash", { command: "ls" }) },
        { event: toolEvent("PostToolUse", "Bash", { command: "ls" }) },
      ],
    });
    assert.deepEqual(statuses, [
      "state=working:app=claude-code:turn=0:blocked=1",
      "state=blocked:app=claude-code:kind=permission:turn=0:blocked=2",
      "state=working:app=claude-code:turn=0:blocked=2",
    ]);
  });

  test("the session, its Transcript and this Claude Code's process go into @heeler-session", async () => {
    const { pane, pid } = await run({
      steps: [
        { event: { hook_event_name: "SessionStart", source: "startup" } },
        { event: { hook_event_name: "UserPromptSubmit" } },
        {
          event: { hook_event_name: "SessionStart", source: "clear" },
          session: "2b4c",
          transcript: '/h/.claude/projects/-w "q"/2b4c.jsonl',
        },
      ],
    });
    const session = JSON.parse(option(pane, "@heeler-session"));
    assert.equal(session.session, "2b4c");
    assert.equal(session.file, '/h/.claude/projects/-w "q"/2b4c.jsonl');
    assert.equal(session.pid, pid);
    assert.equal(tmux("display-message", "-p", "-t", pane, "#{pane_pid}"), String(pid));
    assert.ok(session.start, "the process start is in the session");
  });

  test("a Claude Code that does not lead the Pane's foreground writes nothing", async () => {
    const { pane } = await run({
      shell: true,
      steps: [{ event: { hook_event_name: "SessionStart", source: "startup" } }, { event: { hook_event_name: "UserPromptSubmit" } }],
    });
    assert.equal(option(pane, "@heeler-status"), "");
    assert.equal(option(pane, "@heeler-session"), "");
  });

  test("a hook run by a process the Pane's Claude Code started writes nothing", async () => {
    const { statuses } = await run({
      seed: "state=idle:app=claude-code:turn=0:blocked=0",
      steps: [{ event: { hook_event_name: "UserPromptSubmit" }, child: true }],
    });
    assert.deepEqual(statuses, ["state=idle:app=claude-code:turn=0:blocked=0"]);
  });

  test("TMUX naming another server, no stored tmux, or no Pane writes nothing", async () => {
    const steps = [{ event: { hook_event_name: "UserPromptSubmit" } }];
    const otherServer = await run({ environment: { TMUX: `${socket},1,0` }, steps });
    assert.deepEqual(otherServer.statuses, [""]);

    const other = join(root, "other");
    storePaths("other", { executable: TMUX, socket });
    const unstored = await run({ environment: { TMUX: `${other},${tmux("display-message", "-p", "#{pid}")},0` }, steps });
    assert.deepEqual(unstored.statuses, [""]);

    const outside = await run({ environment: { TMUX_PANE: "" }, steps });
    assert.deepEqual(outside.statuses, [""]);
  });

  test("a hook still writes after Helper removal deletes everything in host-helper except tmux/", async () => {
    const data =
      process.platform === "darwin" ? join(home, "Library", "Application Support") : join(home, ".local", "share");
    const helperDir = join(data, "heeler", "host-helper");
    mkdirSync(join(helperDir, "app"), { recursive: true });
    writeFileSync(join(helperDir, "app", "main.js"), "// helper\n");
    writeFileSync(join(helperDir, "installed.json"), '{"version":1,"files":[],"folders":[]}\n');
    writeFileSync(join(helperDir, "notifications.json"), "{}\n");
    writeFileSync(join(helperDir, "usage-accounts.json"), "{}\n");

    for (const entry of ["app", "installed.json", "notifications.json", "usage-accounts.json"]) {
      rmSync(join(helperDir, entry), { recursive: true, force: true });
    }
    assert.equal(existsSync(join(helperDir, "app")), false);
    assert.equal(existsSync(join(helperDir, "tmux", "s", "paths.json")), true);

    const { statuses } = await run({
      steps: [
        { event: { hook_event_name: "SessionStart", source: "startup" } },
        { event: { hook_event_name: "UserPromptSubmit", prompt: "keep going" } },
        { event: { hook_event_name: "Stop", stop_hook_active: false } },
      ],
    });
    assert.deepEqual(statuses, [
      "state=idle:app=claude-code:turn=0:blocked=0",
      "state=working:app=claude-code:turn=0:blocked=0",
      "state=done:app=claude-code:turn=1:blocked=0",
    ]);
  });

  test("a hook whose script is gone does nothing and fails nothing", async () => {
    const { statuses } = await run({
      command: hookCommand(join(root, "gone", "hook.sh")),
      steps: [{ event: { hook_event_name: "UserPromptSubmit" } }],
    });
    assert.deepEqual(statuses, [""]);
  });

  test("hooks running alongside each other lose no question", async () => {
    const pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-n", "parallel", "--", "sleep", "600");
    tmux("set-option", "-p", "-t", pane, "@heeler-status", "state=idle:app=claude-code:turn=0:blocked=0");
    // The Pane's own process runs the hooks, many at once, as parallel subagents do.
    const go = join(root, "parallel.go");
    const done = join(root, "parallel.done");
    const payloads = [
      permission("Bash", { command: "deploy" }),
      ...Array.from({ length: 8 }, (_, index) => toolEvent("PostToolUse", "Read", { file_path: `/w/${index}` }, { agent_id: `a${index}` })),
    ].map((event) => JSON.stringify({ session_id: "s", transcript_path: "/t.jsonl", ...event }));
    const runner = `
      import { spawn } from "node:child_process";
      import { existsSync, readFileSync, writeFileSync } from "node:fs";
      const [command, payloadsFile, go, done] = process.argv.slice(2);
      while (!existsSync(go)) await new Promise((resolve) => setTimeout(resolve, 20));
      const codes = await Promise.all(JSON.parse(readFileSync(payloadsFile, "utf8")).map((payload, index) => new Promise((resolve) => {
        setTimeout(() => {
          const hook = spawn("/bin/sh", ["-c", command], { stdio: ["pipe", "ignore", "ignore"] });
          hook.on("close", resolve);
          hook.stdin.on("error", () => {});
          hook.stdin.end(payload);
        }, index === 0 ? 0 : 5);
      })));
      writeFileSync(done, JSON.stringify(codes));
      setInterval(() => {}, 60000);
    `;
    writeFileSync(join(root, "parallel.mjs"), runner);
    writeFileSync(join(root, "parallel.json"), JSON.stringify(payloads));
    tmux("respawn-pane", "-k", "-t", pane, "--", process.execPath, join(root, "parallel.mjs"), hookCommand(script), join(root, "parallel.json"), go, done);
    writeFileSync(go, "");
    const deadline = Date.now() + 20000;
    while (!existsSync(done)) {
      assert.ok(Date.now() < deadline, "the parallel hooks did not finish");
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.deepEqual(JSON.parse(readFileSync(done, "utf8")), Array(9).fill(0));
    assert.equal(option(pane, "@heeler-status"), "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1");
  });
});

/**
 * Stub `tmux` reproducing tmux 3.4's `cmdq_print` -> `utf8_stravisx(..., VIS_OCTAL|VIS_CSTYLE|VIS_NOSLASH)`:
 * control bytes other than TAB/LF become C escapes or 4-byte octal (`0x1f` -> `\037`), and `$` before
 * `[A-Za-z_{]` becomes `\$` even after `#{q:...}` (`format_quote_shell`) already added a backslash.
 */
const TMUX_34_STUB = `#!${process.execPath}
const { existsSync, readFileSync, writeFileSync } = require("node:fs");

const stateFile = process.env.HEELER_STUB_TMUX_STATE;
const state = existsSync(stateFile)
  ? JSON.parse(readFileSync(stateFile, "utf8"))
  : { pid: "4242", tty: "/dev/pts/7", options: {} };

function quoteShell(text) {
  let out = "";
  for (const ch of text) {
    if ("|&;<>()$\`\\\\\\"'*?[# =%".includes(ch)) out += "\\\\";
    out += ch;
  }
  return out;
}

function strvisTmux34(text) {
  const bytes = Buffer.from(text, "utf8");
  let out = "";
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i];
    if (b === 0x09 || b === 0x0a) { out += String.fromCharCode(b); i += 1; continue; }
    if (b === 0x07) { out += "\\\\a"; i += 1; continue; }
    if (b === 0x08) { out += "\\\\b"; i += 1; continue; }
    if (b === 0x0b) { out += "\\\\v"; i += 1; continue; }
    if (b === 0x0c) { out += "\\\\f"; i += 1; continue; }
    if (b === 0x0d) { out += "\\\\r"; i += 1; continue; }
    if (b < 0x20 || b === 0x7f) {
      out += "\\\\" + b.toString(8).padStart(3, "0");
      i += 1;
      continue;
    }
    if (b === 0x24 && i + 1 < bytes.length) {
      const next = bytes[i + 1];
      const isIdent = (next >= 0x41 && next <= 0x5a) || (next >= 0x61 && next <= 0x7a) || next === 0x5f || next === 0x7b;
      if (isIdent) { out += "\\\\$"; i += 1; continue; }
    }
    if (b < 0x80) { out += String.fromCharCode(b); i += 1; continue; }
    const width = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1;
    out += bytes.subarray(i, i + width).toString("utf8");
    i += width;
  }
  return out;
}

function fieldValue(name) {
  if (name === "pid") return state.pid;
  if (name === "pane_tty") return state.tty;
  return state.options[name] ?? "";
}

function expandFormat(fmt) {
  const andMatch = /^#\\{&&:#\\{==:#\\{(@[^}]+)\\},([^}]*)\\},#\\{==:#\\{(@[^}]+)\\},([^}]*)\\}\\}$/.exec(fmt);
  if (andMatch) {
    return fieldValue(andMatch[1]) === andMatch[2] && fieldValue(andMatch[3]) === andMatch[4] ? "1" : "0";
  }
  return fmt.replace(/#\\{(q:)?([^}]+)\\}/g, (_, quoted, name) => {
    const raw = fieldValue(name);
    return quoted ? quoteShell(raw) : raw;
  });
}

function parseCommandString(cmd) {
  return cmd.split(" ; ").map((part) => {
    const tokens = [];
    let cur = "", hasToken = false, inSingle = false;
    for (let i = 0; i < part.length; i += 1) {
      const ch = part[i];
      if (ch === "'") { inSingle = !inSingle; hasToken = true; continue; }
      if (!inSingle && ch === " ") {
        if (hasToken) { tokens.push(cur); cur = ""; hasToken = false; }
        continue;
      }
      cur += ch;
      hasToken = true;
    }
    if (hasToken) tokens.push(cur);
    return tokens;
  });
}

let args = process.argv.slice(2);
while (args.length > 0 && (args[0] === "-N" || args[0] === "-u" || args[0] === "-S")) {
  args = args[0] === "-S" ? args.slice(2) : args.slice(1);
}
const groups = [];
let current = [];
for (const word of args) {
  if (word === ";") { groups.push(current); current = []; }
  else current.push(word);
}
if (current.length > 0) groups.push(current);

function runGroup(words) {
  const sub = words[0];
  if (sub === "display-message") {
    const fmt = words[words.length - 1];
    process.stdout.write(strvisTmux34(expandFormat(fmt)) + "\\n");
  } else if (sub === "set-option") {
    const unset = words.includes("-u");
    const name = words[words.length - (unset ? 1 : 2)];
    if (unset) delete state.options[name];
    else state.options[name] = words[words.length - 1];
  } else if (sub === "if-shell") {
    const tIdx = words.indexOf("-t");
    const cond = words[tIdx + 2];
    const body = words[tIdx + 3];
    if (expandFormat(cond) === "1") {
      for (const inner of parseCommandString(body)) runGroup(inner);
    }
  }
}

for (const group of groups) runGroup(group);
writeFileSync(stateFile, JSON.stringify(state));
`;

suite("the script against tmux 3.4 output escaping", () => {
  test("writes Working, Blocked, Done, Error and @heeler-session when display-message escapes 0x1f and $var", () => {
    for (const hookShell of shells()) {
      const root = mkdtempSync("/tmp/hkt34-");
      try {
        const home = join(root, "home");
        const bin = join(root, "bin");
        mkdirSync(home, { recursive: true });
        mkdirSync(bin, { recursive: true });
        const socket = join(root, "s");
        writeFileSync(socket, "");
        const stubTmux = join(bin, "tmux");
        writeFileSync(stubTmux, TMUX_34_STUB, { mode: 0o755 });
        const stubPs = join(bin, "ps");
        writeFileSync(
          stubPs,
          '#!/bin/sh\nif [ "$1" = "-o" ] && [ "$2" = "pgid=" ]; then printf "%s %s pts/7\\n" "$8" "$8"; exit 0; fi\nexec /bin/ps "$@"\n',
          { mode: 0o755 },
        );
        const stateFile = join(root, "state.json");
        writeFileSync(stateFile, JSON.stringify({ pid: "4242", tty: "/dev/pts/7", options: {} }));

        const data =
          process.platform === "darwin" ? join(home, "Library", "Application Support") : join(home, ".local", "share");
        const pathsFolder = join(data, "heeler", "host-helper", "tmux", "s");
        mkdirSync(pathsFolder, { recursive: true });
        writeFileSync(join(pathsFolder, "paths.json"), JSON.stringify({ executable: stubTmux, socket }));

        const env = {
          HOME: home,
          PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          TMUX: `${socket},4242,0`,
          TMUX_PANE: "%0",
          HEELER_STUB_TMUX_STATE: stateFile,
        };
        const invoke = (payload) => {
          const ran = spawnSync(hookShell, [SCRIPT], {
            input: JSON.stringify({
              session_id: "9a7714b3-b2a6-4f8e-b30d-94b5df8fc6fc",
              transcript_path: "/home/$USER/.claude/projects/-w/9a7714b3.jsonl",
              cwd: "/w",
              ...payload,
            }),
            env,
            encoding: "utf8",
          });
          assert.equal(ran.status, 0, `${hookShell}: exit 0`);
          assert.equal(ran.stderr, "", `${hookShell}: no stderr`);
          return JSON.parse(readFileSync(stateFile, "utf8")).options;
        };

        let opts = invoke({ hook_event_name: "UserPromptSubmit", prompt: "hello" });
        assert.equal(opts["@heeler-status"], "state=working:app=claude-code:turn=0:blocked=0", hookShell);
        const saved = JSON.parse(opts["@heeler-session"]);
        assert.equal(saved.session, "9a7714b3-b2a6-4f8e-b30d-94b5df8fc6fc");
        assert.equal(saved.file, "/home/$USER/.claude/projects/-w/9a7714b3.jsonl");
        assert.equal(saved.pid, process.pid);

        opts = invoke(permission("Bash", { command: "ls" }));
        assert.equal(opts["@heeler-status"], "state=blocked:app=claude-code:kind=permission:turn=0:blocked=1", hookShell);
        assert.match(opts["@heeler-ask"], new RegExp(`^${process.pid} \\d+-\\d+$`));

        opts = invoke({ hook_event_name: "Stop", stop_hook_active: false });
        assert.equal(opts["@heeler-status"], "state=done:app=claude-code:turn=1:blocked=1", hookShell);
        assert.equal(opts["@heeler-ask"], "");

        opts = invoke({ hook_event_name: "UserPromptSubmit", prompt: "again" });
        assert.equal(opts["@heeler-status"], "state=working:app=claude-code:turn=1:blocked=1", hookShell);

        opts = invoke({ hook_event_name: "StopFailure", last_assistant_message: "Quota $LIMIT reached" });
        const expectedMsg = Buffer.from("Quota $LIMIT reached").toString("base64");
        assert.equal(opts["@heeler-status"], `state=error:app=claude-code:msg=${expectedMsg}:turn=2:blocked=1`, hookShell);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    }
  });
});
