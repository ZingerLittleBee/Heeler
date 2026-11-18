// Heeler's extension for Pi and Oh My Pi inside a Rex terminal (ADR 0056): loaded
// from an agent directory's `extensions` folder, as those programs load it, in a
// process whose environment names the terminal, it keeps the session in a file of
// that process's own beside the folder, which is where Chat reads it.

import { after, afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const EXTENSION = fileURLToPath(new URL("../helper/extensions/heeler-session.js", import.meta.url));
const OSC_7501 = "\x1b]7501;";

const root = mkdtempSync(join(tmpdir(), "heeler-rex-"));
after(() => rmSync(root, { recursive: true, force: true }));

let copies = 0;

/**
 * An agent directory holding a copy of the extension in `folderName`. With
 * `piVersion`, Pi's own package resolves from it, as Pi's loader makes it do.
 */
async function loadExtension({ piVersion, folderName = "extensions" } = {}) {
  const agent = join(root, `agent-${copies++}`);
  const folder = join(agent, folderName);
  mkdirSync(folder, { recursive: true });
  cpSync(EXTENSION, join(folder, "heeler-session.js"));
  writeFileSync(join(folder, "package.json"), '{"type":"module"}\n');
  if (piVersion) {
    const home = join(folder, "node_modules", "@earendil-works", "pi-coding-agent");
    mkdirSync(home, { recursive: true });
    writeFileSync(join(home, "package.json"), '{"type":"module","main":"index.js"}\n');
    writeFileSync(join(home, "index.js"), `export const VERSION = ${JSON.stringify(piVersion)};\n`);
  }
  const module = await import(pathToFileURL(join(folder, "heeler-session.js")).href);
  return { agent, sessions: join(agent, "heeler-session"), heelerSession: module.default, settled: module.rexWritesSettled };
}

/** The part of a program's extension API the extension may touch. */
function fakeProgram({ mode = "tui", hasUI = true } = {}) {
  const handlers = new Map();
  const program = {
    sessionId: "session-1",
    sessionFile: "/s/session-1.jsonl",
    registered: () => [...handlers.keys()],
    api: {
      on(event, handler) {
        handlers.set(event, [...(handlers.get(event) ?? []), handler]);
      },
    },
    async emit(event, payload = {}) {
      const context = {
        mode,
        hasUI,
        sessionManager: { getSessionId: () => program.sessionId, getSessionFile: () => program.sessionFile },
      };
      for (const handler of handlers.get(event) ?? []) await handler({ type: event, ...payload }, context);
    },
  };
  return program;
}

/** This process's start as the app's process reader reads it, found without the extension's code. */
function startOfThisProcess() {
  const command =
    process.platform === "linux"
      ? `sed 's/.*) //' /proc/${process.pid}/stat | cut -d' ' -f20`
      : `LC_ALL=C TZ=UTC /bin/ps -o lstart= -p ${process.pid}`;
  return spawnSync("/bin/sh", ["-c", command], { encoding: "utf8" }).stdout.trim();
}

/** The id of a process that has ended. */
function endedProcess() {
  return spawnSync(process.execPath, ["-e", ""]).pid;
}

suite("the extension in a Rex terminal", () => {
  const savedEnvironment = { ...process.env };
  const realWrite = process.stdout.write;
  let reports;

  beforeEach(() => {
    for (const name of ["HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "PI_PROGRAM_STATUS", "TMUX", "TMUX_PANE"]) {
      delete process.env[name];
    }
    process.env.REX_SESSION = "s-1";
    process.env.REX_BLOCK = "b-1";
    reports = [];
    process.stdout.write = function (chunk, ...rest) {
      if (String(chunk).includes(OSC_7501)) {
        reports.push(String(chunk));
        return true;
      }
      return realWrite.call(process.stdout, chunk, ...rest);
    };
  });

  afterEach(() => {
    process.stdout.write = realWrite;
    for (const name of Object.keys(process.env)) delete process.env[name];
    Object.assign(process.env, savedEnvironment);
  });

  test("one private file of this process's own names the session, the pid and the process start", async () => {
    const { sessions, heelerSession, settled } = await loadExtension();
    const program = fakeProgram();
    await heelerSession(program.api);

    await program.emit("session_start");
    await settled();

    assert.deepEqual(readdirSync(sessions), [`${process.pid}.json`]);
    const file = join(sessions, `${process.pid}.json`);
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), {
      session: "session-1",
      file: "/s/session-1.jsonl",
      pid: process.pid,
      start: startOfThisProcess(),
    });
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.equal(statSync(sessions).mode & 0o777, 0o700);
  });

  test("a session that has no file yet is named by its id alone", async () => {
    const { sessions, heelerSession, settled } = await loadExtension();
    const program = fakeProgram();
    program.sessionFile = undefined;
    await heelerSession(program.api);

    await program.emit("session_start");
    await settled();

    const value = JSON.parse(readFileSync(join(sessions, `${process.pid}.json`), "utf8"));
    assert.equal(value.session, "session-1");
    assert.equal("file" in value, false);
  });

  for (const event of ["session_start", "session_switch", "session_branch"]) {
    test(`a new session at ${event} replaces what the file names, and the same one writes nothing`, async () => {
      const { sessions, heelerSession, settled } = await loadExtension();
      const program = fakeProgram();
      await heelerSession(program.api);
      await program.emit("session_start");
      await settled();
      const file = join(sessions, `${process.pid}.json`);
      const first = statSync(file).ino;

      await program.emit(event);
      await settled();
      assert.equal(statSync(file).ino, first);

      Object.assign(program, { sessionId: "session-2", sessionFile: "/s/session-2.jsonl" });
      await program.emit(event);
      await settled();

      assert.equal(JSON.parse(readFileSync(file, "utf8")).session, "session-2");
      assert.deepEqual(readdirSync(sessions), [`${process.pid}.json`]);
    });
  }

  test("a quit takes the file away, and a session change does not", async () => {
    const { sessions, heelerSession, settled } = await loadExtension();
    const program = fakeProgram();
    await heelerSession(program.api);
    await program.emit("session_start");
    await settled();
    const file = join(sessions, `${process.pid}.json`);

    await program.emit("session_shutdown", { reason: "new" });
    assert.equal(existsSync(file), true);

    await program.emit("session_shutdown", { reason: "quit" });
    assert.equal(existsSync(file), false);

    Object.assign(program, { sessionId: "session-2", sessionFile: "/s/session-2.jsonl" });
    await program.emit("session_start");
    await settled();
    assert.deepEqual(readdirSync(sessions), []);
  });

  test("the file goes with a process that ends without saying it quit", async () => {
    const agent = join(root, `agent-${copies++}`);
    const folder = join(agent, "extensions");
    mkdirSync(folder, { recursive: true });
    cpSync(EXTENSION, join(folder, "heeler-session.js"));
    writeFileSync(join(folder, "package.json"), '{"type":"module"}\n');
    // A program of its own, which loads the extension, starts a session and ends.
    const script = `
      import { readdirSync } from "node:fs";
      const extension = await import(${JSON.stringify(pathToFileURL(join(folder, "heeler-session.js")).href)});
      const handlers = [];
      await extension.default({ on: (event, handler) => handlers.push([event, handler]) });
      const context = {
        mode: "tui",
        hasUI: true,
        sessionManager: { getSessionId: () => "session-1", getSessionFile: () => "/s/session-1.jsonl" },
      };
      for (const [event, handler] of handlers) {
        if (event === "session_start") await handler({ type: event }, context);
      }
      await extension.rexWritesSettled();
      console.log(JSON.stringify({ pid: process.pid, kept: readdirSync(${JSON.stringify(join(agent, "heeler-session"))}) }));
    `;
    const run = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });

    assert.equal(run.status, 0, run.stderr);
    const { pid, kept } = JSON.parse(run.stdout);
    assert.deepEqual(kept, [`${pid}.json`]);
    assert.deepEqual(readdirSync(join(agent, "heeler-session")), []);
  });

  test("a file a process that has ended left is removed, and a running one's stays", async () => {
    const { sessions, heelerSession, settled } = await loadExtension();
    mkdirSync(sessions);
    const ended = endedProcess();
    writeFileSync(join(sessions, `${ended}.json`), "{}");
    writeFileSync(join(sessions, `${ended}.json.tmp`), "{}");
    writeFileSync(join(sessions, `${process.ppid}.json`), "{}");
    writeFileSync(join(sessions, "notes.txt"), "kept");
    const program = fakeProgram();
    await heelerSession(program.api);

    await program.emit("session_start");
    await settled();

    assert.deepEqual(readdirSync(sessions).sort(), [`${process.pid}.json`, `${process.ppid}.json`, "notes.txt"].sort());
  });

  for (const [name, options] of [
    ["a headless run", { hasUI: false }],
    ["a run outside the terminal interface", { mode: "print" }],
  ]) {
    test(`${name} writes nothing`, async () => {
      const { sessions, heelerSession, settled } = await loadExtension();
      const program = fakeProgram(options);
      await heelerSession(program.api);

      await program.emit("session_start");
      await settled();

      assert.equal(existsSync(sessions), false);
    });
  }

  for (const [name, change] of [
    ["without REX_SESSION", () => delete process.env.REX_SESSION],
    ["without REX_BLOCK", () => delete process.env.REX_BLOCK],
    ["in a tmux Pane inside the terminal", () => (process.env.TMUX = "/tmp/tmux-501/other,4242,0")],
  ]) {
    test(`${name} it does nothing at all`, async () => {
      change();
      const { sessions, heelerSession, settled } = await loadExtension({ piVersion: "1.0.4" });
      const program = fakeProgram();

      await heelerSession(program.api);
      await program.emit("session_start");
      await settled();

      assert.deepEqual(program.registered(), []);
      assert.equal(existsSync(sessions), false);
      assert.deepEqual(reports, []);
    });
  }

  test("loaded from a folder that is not an agent directory's extensions it does nothing at all", async () => {
    const { agent, heelerSession, settled } = await loadExtension({ folderName: "elsewhere" });
    const program = fakeProgram();

    await heelerSession(program.api);
    await program.emit("session_start");
    await settled();

    assert.deepEqual(program.registered(), []);
    assert.deepEqual(readdirSync(agent), ["elsewhere"]);
  });

  test("a Pi before 1.1.0 has its status reported, and a later one reports its own", async () => {
    const before = await loadExtension({ piVersion: "1.0.4" });
    const old = fakeProgram();
    await before.heelerSession(old.api);
    await old.emit("session_start");
    await old.emit("agent_start");
    await before.settled();
    assert.deepEqual(reports, [`${OSC_7501}state=idle:app=pi\x1b\\`, `${OSC_7501}state=working:app=pi\x1b\\`]);

    reports.length = 0;
    const after = await loadExtension({ piVersion: "1.4.0" });
    const current = fakeProgram();
    await after.heelerSession(current.api);
    await current.emit("session_start");
    await current.emit("agent_start");
    await after.settled();
    assert.deepEqual(reports, []);
    assert.equal(existsSync(join(after.sessions, `${process.pid}.json`)), true);
  });
});
