// Heeler's extension for Pi and Oh My Pi inside a tmux Pane (ADR 0044): the
// `@heeler-status` counts from the shared vector, then the extension loaded by a
// stand-in program running in a Pane of a private tmux server, with a home of
// its own, writing the status and its session through the tmux the Helper stored.

import { after, before, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const EXTENSION = fileURLToPath(new URL("../helper/extensions/heeler-session.js", import.meta.url));
const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/tmux-heeler-status-v1.json", import.meta.url), "utf8"),
);

suite("@heeler-status from the shared vector", () => {
  test("every value reads as the vector says", async () => {
    const { readHeelerStatus } = await import(pathToFileURL(EXTENSION).href);
    assert.ok(vectors.values.length > 0);
    for (const vector of vectors.values) {
      const { value, name, ...expected } = vector;
      assert.deepEqual(readHeelerStatus(value), expected, name);
    }
  });

  test("every write continues the counts as the vector says", async () => {
    const { continueHeelerStatus } = await import(pathToFileURL(EXTENSION).href);
    assert.ok(vectors.writes.length > 0);
    for (const vector of vectors.writes) {
      let value = vector.start;
      for (const [index, step] of vector.steps.entries()) {
        value = continueHeelerStatus(value, step.report);
        assert.equal(value, step.value, `${vector.name}, step ${index + 1}`);
      }
    }
  });
});

/** tmux as the user's shell finds it, or null. */
function findTmux() {
  const found = spawnSync("/bin/sh", ["-c", "command -v tmux"], { encoding: "utf8" });
  const path = found.stdout.trim();
  return found.status === 0 && path.startsWith("/") ? path : null;
}

const TMUX = findTmux();
// The CI runner has tmux; a machine without it says so instead of passing.
const skip = TMUX || process.env.CI ? false : "tmux is not installed";

/** A stand-in program: it loads the extension with Pi's API, waits for `go`, runs its steps, then stays. */
const DRIVER = `
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [extension, stepsJSON, go, done, overrides] = process.argv.slice(2);
Object.assign(process.env, JSON.parse(overrides));
for (const [name, value] of Object.entries(process.env)) if (value === "") delete process.env[name];
const { default: heelerSession, tmuxWritesSettled } = await import(pathToFileURL(extension).href);
const handlers = new Map();
const program = { sessionId: "session-1", sessionFile: "/s/session-1.jsonl" };
const context = {
  mode: "tui",
  hasUI: true,
  sessionManager: { getSessionId: () => program.sessionId, getSessionFile: () => program.sessionFile },
};
await heelerSession({ on: (event, handler) => handlers.set(event, [...(handlers.get(event) ?? []), handler]) });
while (!existsSync(go)) await new Promise((resolve) => setTimeout(resolve, 20));
for (const step of JSON.parse(stepsJSON)) {
  if (step.session) Object.assign(program, step.session);
  for (const handler of handlers.get(step.event) ?? []) await handler({ type: step.event, ...step.payload }, context);
  await tmuxWritesSettled();
}
writeFileSync(done, JSON.stringify({ registered: [...handlers.keys()], pid: process.pid }));
setInterval(() => {}, 60000);
`;

suite("the extension in a tmux Pane", { skip }, () => {
  let root;
  let home;
  let socket;
  let runs = 0;

  const tmux = (...args) =>
    execFileSync(TMUX, ["-N", "-S", socket, ...args], { encoding: "utf8", env: tmuxEnvironment() }).replace(/\n$/, "");

  /** The server's environment, which every Pane starts from: nothing of the test runner's own tmux. */
  function tmuxEnvironment() {
    return { HOME: home, PATH: process.env.PATH, SHELL: "/bin/sh", TERM: "xterm-256color", LC_ALL: "C" };
  }

  /** A copy of the extension as a folder holds it; Pi's package resolves from it for Pi. */
  function extensionCopy(program) {
    const folder = join(root, `extension-${program}`);
    if (existsSync(folder)) return join(folder, "heeler-session.js");
    mkdirSync(folder);
    cpSync(EXTENSION, join(folder, "heeler-session.js"));
    writeFileSync(join(folder, "package.json"), '{"type":"module"}\n');
    if (program === "pi") {
      const pi = join(folder, "node_modules", "@earendil-works", "pi-coding-agent");
      mkdirSync(pi, { recursive: true });
      writeFileSync(join(pi, "package.json"), '{"type":"module","main":"index.js"}\n');
      writeFileSync(join(pi, "index.js"), 'export const VERSION = "1.4.0";\n');
    }
    return join(folder, "heeler-session.js");
  }

  /** The paths the app gives the Helper for `name`'s server, as `TmuxPaths` encodes them. */
  function storePaths(name, paths) {
    const data =
      process.platform === "darwin" ? join(home, "Library", "Application Support") : join(home, ".local", "share");
    const folder = join(data, "heeler", "host-helper", "tmux", name);
    mkdirSync(folder, { recursive: true });
    writeFileSync(join(folder, "paths.json"), JSON.stringify(paths));
  }

  before(() => {
    root = mkdtempSync(join(tmpdir(), "htx-"));
    home = join(root, "home");
    mkdirSync(home);
    socket = join(root, "s");
    writeFileSync(join(root, "driver.mjs"), DRIVER);
    // A placeholder keeps the server up between the windows the tests open.
    execFileSync(TMUX, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "hold", "sleep", "600"], {
      env: tmuxEnvironment(),
    });
    storePaths("s", { executable: TMUX, socket });
  });

  after(() => {
    if (socket && existsSync(socket)) spawnSync(TMUX, ["-S", socket, "kill-server"]);
    if (root) rmSync(root, { recursive: true, force: true });
  });

  /**
   * Opens a window whose program is the stand-in, sets `seed` as its status,
   * lets it run `steps` and waits for it to finish them. `shell` runs it
   * under a shell that stays its foreground.
   */
  async function run({ program = "pi", steps, seed, overrides = {}, shell = false, beforeGo }) {
    const name = `run-${runs++}`;
    const go = join(root, `${name}.go`);
    const done = join(root, `${name}.done`);
    const argv = [process.execPath, join(root, "driver.mjs"), extensionCopy(program), JSON.stringify(steps), go, done,
      JSON.stringify(overrides)];
    const command = shell
      ? [argv.map((word) => `'${word.replaceAll("'", "'\\''")}'`).join(" ") + "; sleep 600"]
      : argv;
    const pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-n", name, "--", ...command);
    if (seed) tmux("set-option", "-p", "-t", pane, "@heeler-status", seed);
    await beforeGo?.(pane);
    writeFileSync(go, "");
    const deadline = Date.now() + 10000;
    while (!existsSync(done)) {
      assert.ok(Date.now() < deadline, `the stand-in in ${pane} did not finish`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return { pane, ...JSON.parse(readFileSync(done, "utf8")) };
  }

  const option = (pane, name) => tmux("show-options", "-p", "-q", "-v", "-t", pane, name);
  const ended = (stopReason, errorMessage) => ({
    event: "agent_end",
    payload: { messages: [{ role: "assistant", stopReason, ...(errorMessage ? { errorMessage } : {}) }] },
  });

  test("Pi writes its turn and session, continuing the counts it found", async () => {
    const { pane, pid } = await run({
      seed: "state=working:app=claude-code:turn=4:blocked=2",
      steps: [{ event: "session_start" }, { event: "agent_start" }, ended("stop")],
    });

    assert.equal(option(pane, "@heeler-status"), "state=done:app=pi:turn=5:blocked=2");
    const session = JSON.parse(option(pane, "@heeler-session"));
    assert.equal(session.session, "session-1");
    assert.equal(session.file, "/s/session-1.jsonl");
    assert.equal(session.pid, pid);
    // The Pane's own process: tmux started the stand-in itself.
    assert.equal(tmux("display-message", "-p", "-t", pane, "#{pane_pid}"), String(pid));
    if (process.platform !== "win32") assert.ok(session.start, "the process start is in the session");
  });

  test("Oh My Pi writes its error, then idle and its next session on a switch", async () => {
    const { pane } = await run({
      program: "omp",
      steps: [
        { event: "session_start" },
        { event: "agent_start" },
        ended("error", "rate limit\nretry later"),
      ],
    });
    assert.equal(
      option(pane, "@heeler-status"),
      `state=error:app=omp:msg=${Buffer.from("rate limit").toString("base64")}:turn=1:blocked=0`,
    );
    assert.equal(JSON.parse(option(pane, "@heeler-session")).session, "session-1");
  });

  test("a new session reads idle at the same count and names the new session", async () => {
    const { pane } = await run({
      program: "omp",
      steps: [
        { event: "session_start" },
        { event: "agent_start" },
        ended("stop"),
        { event: "session_switch", session: { sessionId: "session-2", sessionFile: "/s/session-2.jsonl" } },
      ],
    });
    assert.equal(option(pane, "@heeler-status"), "state=idle:app=omp:turn=1:blocked=0");
    assert.equal(JSON.parse(option(pane, "@heeler-session")).session, "session-2");
  });

  test("a quit clears the status and keeps the counts", async () => {
    const { pane } = await run({
      steps: [
        { event: "session_start" },
        { event: "agent_start" },
        ended("stop"),
        { event: "session_shutdown", payload: { reason: "quit" } },
      ],
    });
    assert.equal(option(pane, "@heeler-status"), "turn=1:blocked=0");
  });

  test("a program that does not lead the Pane's foreground writes nothing", async () => {
    const { pane, registered } = await run({
      shell: true,
      steps: [{ event: "session_start" }, { event: "agent_start" }],
    });
    assert.ok(registered.includes("agent_start"));
    assert.equal(option(pane, "@heeler-status"), "");
    assert.equal(option(pane, "@heeler-session"), "");
  });

  test("TMUX naming another server writes nothing", async () => {
    const { pane, registered } = await run({
      overrides: { TMUX: `${socket},1,0` },
      steps: [{ event: "session_start" }, { event: "agent_start" }],
    });
    assert.ok(registered.includes("agent_start"));
    assert.equal(option(pane, "@heeler-status"), "");
  });

  test("with no stored tmux for its server, or none of tmux, it stays inert", async () => {
    const other = join(root, "other");
    storePaths("other", { executable: TMUX, socket });
    const unstored = await run({
      overrides: { TMUX: `${other},1,0` },
      steps: [{ event: "session_start" }, { event: "agent_start" }],
    });
    assert.deepEqual(unstored.registered, []);

    const outside = await run({
      overrides: { TMUX: "", TMUX_PANE: "" },
      steps: [{ event: "session_start" }, { event: "agent_start" }],
    });
    assert.deepEqual(outside.registered, []);
    assert.equal(option(outside.pane, "@heeler-status"), "");
  });

  test("a process on another terminal, with the Pane's environment, writes nothing", async () => {
    const { pane } = await run({ steps: [] });
    const go = join(root, "detached.go");
    const done = join(root, "detached.done");
    writeFileSync(go, "");
    const child = spawn(
      process.execPath,
      [join(root, "driver.mjs"), extensionCopy("pi"), JSON.stringify([{ event: "session_start" }]), go, done, "{}"],
      {
        detached: true,
        stdio: "ignore",
        env: {
          ...tmuxEnvironment(),
          TMUX: `${socket},${tmux("display-message", "-p", "#{pid}")},0`,
          TMUX_PANE: pane,
        },
      },
    );
    const deadline = Date.now() + 10000;
    while (!existsSync(done)) {
      assert.ok(Date.now() < deadline, "the detached stand-in did not finish");
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    child.kill();
    assert.ok(JSON.parse(readFileSync(done, "utf8")).registered.includes("session_start"));
    assert.equal(option(pane, "@heeler-status"), "");
  });
});
