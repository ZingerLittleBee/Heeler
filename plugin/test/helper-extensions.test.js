// Heeler's extension for Pi and Oh My Pi, loaded the way those programs load it:
// its default export called with their extension API, in a process whose
// environment names the Terminal (ADR 0033).

import { after, afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const EXTENSION = fileURLToPath(new URL("../helper/extensions/heeler-session.js", import.meta.url));
const OSC_7501 = "\x1b]7501;";

const root = mkdtempSync(join(tmpdir(), "heeler-ext-"));
after(() => rmSync(root, { recursive: true, force: true }));

let copies = 0;

/**
 * A copy of the extension, as a program's extension folder holds it. With
 * `piVersion`, Pi's own package resolves from it, as Pi's loader makes it do.
 */
async function loadExtension({ piVersion, piPackage = "@earendil-works/pi-coding-agent" } = {}) {
  const folder = join(root, `copy-${copies++}`);
  mkdirSync(folder);
  cpSync(EXTENSION, join(folder, "heeler-session.js"));
  writeFileSync(join(folder, "package.json"), '{"type":"module"}\n');
  if (piVersion) {
    const home = join(folder, "node_modules", piPackage);
    mkdirSync(home, { recursive: true });
    writeFileSync(join(home, "package.json"), '{"type":"module","main":"index.js"}\n');
    writeFileSync(join(home, "index.js"), `export const VERSION = ${JSON.stringify(piVersion)};\n`);
  }
  return (await import(pathToFileURL(join(folder, "heeler-session.js")).href)).default;
}

/** The part of a program's extension API the extension may touch. */
function fakeProgram({ mode = "tui", hasUI = true, sessionId = "session-1", sessionFile = "/s/session-1.jsonl" } = {}) {
  const handlers = new Map();
  const context = {
    mode,
    hasUI,
    sessionManager: { getSessionId: () => program.sessionId, getSessionFile: () => program.sessionFile },
  };
  const program = {
    sessionId,
    sessionFile,
    registered: () => [...handlers.keys()],
    api: {
      on(event, handler) {
        handlers.set(event, [...(handlers.get(event) ?? []), handler]);
      },
    },
    async emit(event, payload = {}) {
      for (const handler of handlers.get(event) ?? []) await handler({ type: event, ...payload }, context);
    },
  };
  return program;
}

/** A terminal socket that keeps what it is sent, and answers unless told not to. */
async function fakeSocket({ answers = true } = {}) {
  const path = join(root, `s${copies++}.sock`);
  const lines = [];
  const sockets = new Set();
  let closedAt = null;
  let waiting = [];
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.unref();
    let text = "";
    socket.on("data", (chunk) => {
      text += chunk;
      for (let at = text.indexOf("\n"); at >= 0; at = text.indexOf("\n")) {
        lines.push(JSON.parse(text.slice(0, at)));
        text = text.slice(at + 1);
        if (answers) socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: lines.at(-1).id, result: {} })}\n`);
        for (const wake of waiting) wake();
        waiting = [];
      }
    });
    socket.on("close", () => {
      closedAt = Date.now();
      for (const wake of waiting) wake();
      waiting = [];
    });
    socket.on("error", () => {});
  });
  await new Promise((done) => server.listen(path, done));
  // A failed test must not hang the run on this.
  server.unref();
  return {
    path,
    lines,
    closedAt: () => closedAt,
    async until(condition, ms = 3000) {
      const deadline = Date.now() + ms;
      while (!condition()) {
        const left = deadline - Date.now();
        assert.ok(left > 0, "the socket never saw what the test waited for");
        await new Promise((done) => {
          const timer = setTimeout(done, left);
          waiting.push(() => {
            clearTimeout(timer);
            done();
          });
        });
      }
    },
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise((done) => server.close(done));
    },
  };
}

/**
 * This process's start as the app's process reader sees it, found without the
 * extension's code: `/proc/<pid>/stat` field 22 on Linux, `ps -o lstart=` in UTC
 * on macOS.
 */
function startOfThisProcess() {
  const command =
    process.platform === "linux"
      ? `sed 's/.*) //' /proc/${process.pid}/stat | cut -d' ' -f20`
      : `LC_ALL=C TZ=UTC /bin/ps -o lstart= -p ${process.pid}`;
  return spawnSync("/bin/sh", ["-c", command], { encoding: "utf8" }).stdout.trim();
}

/** Lets anything the extension started without being awaited run to its end. */
const settle = (ms = 80) => new Promise((done) => setTimeout(done, ms));

suite("Heeler's Pi and Oh My Pi extension", () => {
  const savedEnvironment = { ...process.env };
  const realWrite = process.stdout.write;
  let reports;

  beforeEach(() => {
    delete process.env.HC_TERMINAL_ID;
    delete process.env.HC_TERMINAL_SOCKET;
    delete process.env.PI_PROGRAM_STATUS;
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
    // In place: a child finds its program through the real environment's PATH.
    for (const name of Object.keys(process.env)) delete process.env[name];
    Object.assign(process.env, savedEnvironment);
  });

  suite("outside a herdr-core Terminal", () => {
    for (const [name, options] of [
      ["Pi", { piVersion: "1.0.4" }],
      ["Oh My Pi", {}],
    ]) {
      test(`${name}: it returns at once, opens nothing and writes nothing`, async () => {
        const socket = await fakeSocket();
        process.env.HC_TERMINAL_SOCKET = socket.path;
        const heelerSession = await loadExtension(options);
        const program = fakeProgram();

        await heelerSession(program.api);
        await program.emit("session_start");
        await settle();

        assert.deepEqual(program.registered(), []);
        assert.deepEqual(socket.lines, []);
        assert.deepEqual(reports, []);
        await socket.close();
      });
    }
  });

  suite("inside a herdr-core Terminal", () => {
    let socket;

    beforeEach(async () => {
      socket = await fakeSocket();
      process.env.HC_TERMINAL_ID = "t7";
      process.env.HC_TERMINAL_SOCKET = socket.path;
    });

    afterEach(() => socket.close());

    test("one terminal.label request names the session, the pid and the process start", async () => {
      const heelerSession = await loadExtension();
      const program = fakeProgram();
      await heelerSession(program.api);

      await program.emit("session_start");
      await socket.until(() => socket.lines.length > 0);
      await settle();

      assert.equal(socket.lines.length, 1);
      const [request] = socket.lines;
      assert.equal(request.jsonrpc, "2.0");
      assert.equal(request.method, "terminal.label");
      assert.equal(request.params.terminal, "t7");
      assert.deepEqual(Object.keys(request.params.labels), ["heeler.session"]);
      const label = JSON.parse(request.params.labels["heeler.session"]);
      assert.equal(label.session, "session-1");
      assert.equal(label.file, "/s/session-1.jsonl");
      assert.equal(label.pid, process.pid);
      assert.equal(label.start, startOfThisProcess());
    });

    const labelsSent = () => socket.lines.map((line) => JSON.parse(line.params.labels["heeler.session"]).session);

    test("Pi: a session switch runs the extension again and sends the new session", async () => {
      const heelerSession = await loadExtension({ piVersion: "1.4.0" });
      const first = fakeProgram();
      await heelerSession(first.api);
      await first.emit("session_start", { reason: "startup" });
      await socket.until(() => socket.lines.length === 1);

      // `/new` replaces the extension's runtime: the factory runs again.
      await first.emit("session_shutdown", { reason: "new" });
      const second = fakeProgram({ sessionId: "session-2", sessionFile: "/s/session-2.jsonl" });
      await heelerSession(second.api);
      await second.emit("session_start", { reason: "new" });
      await socket.until(() => socket.lines.length === 2);

      assert.deepEqual(labelsSent(), ["session-1", "session-2"]);
    });

    for (const event of ["session_switch", "session_branch"]) {
      test(`Oh My Pi: ${event} sends the new session`, async () => {
        const heelerSession = await loadExtension();
        const program = fakeProgram();
        await heelerSession(program.api);
        await program.emit("session_start");
        await socket.until(() => socket.lines.length === 1);

        program.sessionId = "session-2";
        program.sessionFile = "/s/session-2.jsonl";
        await program.emit(event, { reason: "new" });
        await socket.until(() => socket.lines.length === 2);

        assert.deepEqual(labelsSent(), ["session-1", "session-2"]);
      });
    }

    test("an event that leaves the session as it was sends nothing", async () => {
      const heelerSession = await loadExtension();
      const program = fakeProgram();
      await heelerSession(program.api);
      await program.emit("session_start");
      await socket.until(() => socket.lines.length === 1);

      await program.emit("session_branch");
      await settle();

      assert.equal(socket.lines.length, 1);
    });

    test("two quick switches arrive in order", async () => {
      const heelerSession = await loadExtension();
      const program = fakeProgram();
      await heelerSession(program.api);
      await program.emit("session_start");
      program.sessionId = "session-2";
      await program.emit("session_switch");
      program.sessionId = "session-3";
      await program.emit("session_switch");
      await socket.until(() => socket.lines.length === 3);

      assert.deepEqual(labelsSent(), ["session-1", "session-2", "session-3"]);
    });

    test("a session with no file sends its id alone", async () => {
      const heelerSession = await loadExtension();
      const program = fakeProgram({ sessionFile: null });
      await heelerSession(program.api);
      await program.emit("session_start");
      await socket.until(() => socket.lines.length === 1);

      const label = JSON.parse(socket.lines[0].params.labels["heeler.session"]);
      assert.equal(label.session, "session-1");
      assert.equal("file" in label, false);
    });

    for (const [name, options] of [
      ["a subagent", { mode: "tui", hasUI: false }],
      ["print mode", { mode: "print", hasUI: false }],
      ["RPC mode", { mode: "rpc", hasUI: true }],
    ]) {
      test(`${name} leaves the Terminal's label to the program holding it`, async () => {
        const heelerSession = await loadExtension();
        const program = fakeProgram(options);
        await heelerSession(program.api);
        await program.emit("session_start");
        await settle();

        assert.deepEqual(socket.lines, []);
      });
    }
  });

  suite("a socket that does not help", () => {
    const load = async (path) => {
      process.env.HC_TERMINAL_ID = "t7";
      process.env.HC_TERMINAL_SOCKET = path;
      const heelerSession = await loadExtension();
      const program = fakeProgram();
      await heelerSession(program.api);
      return program;
    };

    test("one that never answers is given up on within the timeout, and the session goes on at once", async () => {
      const socket = await fakeSocket({ answers: false });
      const program = await load(socket.path);

      const before = Date.now();
      await program.emit("session_start");
      assert.ok(Date.now() - before < 100, "the program waited on the socket");

      await socket.until(() => socket.lines.length === 1);
      await socket.until(() => socket.closedAt() !== null, 2000);
      assert.ok(socket.closedAt() - before < 1500, "the extension held the socket too long");
      await socket.close();
    });

    test("a later switch still arrives after one that was never answered", async () => {
      const socket = await fakeSocket({ answers: false });
      const program = await load(socket.path);
      await program.emit("session_start");
      program.sessionId = "session-2";
      await program.emit("session_switch");
      await socket.until(() => socket.lines.length === 2, 3000);
      await socket.close();
    });

    for (const [name, path] of [
      ["missing", join(root, "nothing-here.sock")],
      ["unset", undefined],
    ]) {
      test(`one that is ${name} brings no error to the program`, async () => {
        const unhandled = [];
        const onUnhandled = (reason) => unhandled.push(reason);
        process.on("unhandledRejection", onUnhandled);
        process.env.HC_TERMINAL_ID = "t7";
        if (path) process.env.HC_TERMINAL_SOCKET = path;
        const heelerSession = await loadExtension();
        const program = fakeProgram();
        await heelerSession(program.api);

        await program.emit("session_start");
        await settle();

        process.off("unhandledRejection", onUnhandled);
        assert.deepEqual(unhandled, []);
      });
    }
  });

  suite("Program Status", () => {
    const status = (state, extra = "") => `\x1b]7501;state=${state}:app=pi${extra}\x1b\\`;

    /** A whole run: start, one prompt's run, and leaving. */
    async function runAPrompt(program) {
      await program.emit("session_start", { reason: "startup" });
      await program.emit("agent_start");
      await program.emit("agent_end", { messages: [{ role: "assistant", stopReason: "stop" }] });
      await program.emit("session_shutdown", { reason: "quit" });
    }

    async function reportsFrom(options, programOptions) {
      process.env.HC_TERMINAL_ID = "t7";
      const heelerSession = await loadExtension(options);
      const program = fakeProgram(programOptions);
      await heelerSession(program.api);
      await runAPrompt(program);
      return reports;
    }

    for (const version of ["1.0.4", "1.0.99", "0.85.1"]) {
      test(`Pi ${version}, below 1.1.0, reports through OSC 7501`, async () => {
        assert.deepEqual(await reportsFrom({ piVersion: version }), [
          status("idle"),
          status("working"),
          status("done"),
          `\x1b]7501;state=clear:app=pi\x1b\\`,
        ]);
      });
    }

    for (const version of ["1.1.0", "1.4.0", "2.0.0", "1.10.0"]) {
      test(`Pi ${version} reports for itself, so the extension stays silent`, async () => {
        assert.deepEqual(await reportsFrom({ piVersion: version }), []);
      });
    }

    test("Pi's former package name finds the version too", async () => {
      assert.equal(
        (await reportsFrom({ piVersion: "1.0.4", piPackage: "@mariozechner/pi-coding-agent" })).length,
        4,
      );
    });

    test("no version to go on means silence: Oh My Pi reports for itself", async () => {
      assert.deepEqual(await reportsFrom({}), []);
    });

    test("a version that cannot be read means silence", async () => {
      assert.deepEqual(await reportsFrom({ piVersion: "unknown" }), []);
    });

    test("PI_PROGRAM_STATUS=0 is Pi's own off switch", async () => {
      process.env.PI_PROGRAM_STATUS = "0";
      assert.deepEqual(await reportsFrom({ piVersion: "1.0.4" }), []);
    });

    test("outside the terminal interface it never writes to stdout", async () => {
      assert.deepEqual(await reportsFrom({ piVersion: "1.0.4" }, { mode: "rpc", hasUI: true }), []);
    });

    test("a failed run reports error with the first line of its message", async () => {
      process.env.HC_TERMINAL_ID = "t7";
      const heelerSession = await loadExtension({ piVersion: "1.0.4" });
      const program = fakeProgram();
      await heelerSession(program.api);
      await program.emit("agent_end", {
        messages: [
          { role: "user" },
          { role: "assistant", stopReason: "error", errorMessage: "Rate limited\x07\nretry later" },
        ],
      });
      const message = Buffer.from("Rate limited").toString("base64");
      assert.deepEqual(reports, [status("error", `:msg=${message}`)]);
    });

    test("a cancelled run goes back to idle", async () => {
      process.env.HC_TERMINAL_ID = "t7";
      const heelerSession = await loadExtension({ piVersion: "1.0.4" });
      const program = fakeProgram();
      await heelerSession(program.api);
      await program.emit("agent_end", { messages: [{ role: "assistant", stopReason: "aborted" }] });
      assert.deepEqual(reports, [status("idle")]);
    });

    test("a switch to another session is no goodbye", async () => {
      process.env.HC_TERMINAL_ID = "t7";
      const heelerSession = await loadExtension({ piVersion: "1.0.4" });
      const program = fakeProgram();
      await heelerSession(program.api);
      await program.emit("session_shutdown", { reason: "new" });
      assert.deepEqual(reports, []);
    });

    test("a stdout that throws does not reach the program", async () => {
      process.env.HC_TERMINAL_ID = "t7";
      const heelerSession = await loadExtension({ piVersion: "1.0.4" });
      const program = fakeProgram();
      await heelerSession(program.api);
      process.stdout.write = () => {
        throw new Error("EPIPE");
      };
      await program.emit("agent_start");
    });
  });

  suite("finding the extension folders", () => {
    const FOLDERS = fileURLToPath(new URL("../helper/extensions/extension-folders.js", import.meta.url));

    function makeHome(paths) {
      const home = mkdtempSync(join(root, "home-"));
      for (const path of paths) {
        if (path.endsWith("/")) mkdirSync(join(home, path), { recursive: true });
        else {
          mkdirSync(dirname(join(home, path)), { recursive: true });
          writeFileSync(join(home, path), "");
        }
      }
      return home;
    }

    /** Runs the script the way the app does on a Host, with its text as `-e`. */
    function foldersIn(home) {
      const source = readFileSync(FOLDERS, "utf8");
      const result = spawnSync(process.execPath, ["--input-type=module", "-e", source, home], {
        encoding: "utf8",
        env: {},
      });
      assert.equal(result.status, 0, result.stderr);
      return JSON.parse(result.stdout).folders;
    }

    const pathsIn = (home) => foldersIn(home).map(({ path }) => path.slice(home.length + 1));

    test("every Oh My Pi profile in a home that holds several", () => {
      const home = makeHome([".omp/agent/", ".omp/profiles/work/agent/", ".omp/profiles/side.2/", ".pi/agent/extensions/"]);
      assert.deepEqual(pathsIn(home), [
        ".pi/agent/extensions",
        ".omp/agent/extensions",
        ".omp/profiles/side.2/agent/extensions",
        ".omp/profiles/work/agent/extensions",
      ]);
    });

    test("a home with neither program still gets the folders they would load from", () => {
      assert.deepEqual(pathsIn(makeHome([])), [".pi/agent/extensions", ".omp/agent/extensions"]);
    });

    test("only what Oh My Pi could select counts as a profile", () => {
      const home = makeHome([
        ".omp/profiles/a-file",
        ".omp/profiles/default/",
        ".omp/profiles/Upper/",
        ".omp/profiles/.hidden/",
        ".omp/profiles/ends-with-dot./",
        ".omp/profiles/fine/",
      ]);
      assert.deepEqual(pathsIn(home), [
        ".pi/agent/extensions",
        ".omp/agent/extensions",
        ".omp/profiles/fine/agent/extensions",
      ]);
    });

    test("a profile linked from elsewhere counts, and a dead link does not", () => {
      const home = makeHome([".omp/profiles/", "elsewhere/"]);
      symlinkSync(join(home, "elsewhere"), join(home, ".omp/profiles/linked"));
      symlinkSync(join(home, "gone"), join(home, ".omp/profiles/dead"));
      assert.deepEqual(pathsIn(home), [
        ".pi/agent/extensions",
        ".omp/agent/extensions",
        ".omp/profiles/linked/agent/extensions",
      ]);
    });

    test("says which folders already hold the extension", () => {
      const home = makeHome([".pi/agent/extensions/heeler-session.js", ".omp/profiles/work/agent/"]);
      assert.deepEqual(
        foldersIn(home).map(({ path, installed }) => [path.slice(home.length + 1), installed]),
        [
          [".pi/agent/extensions", true],
          [".omp/agent/extensions", false],
          [".omp/profiles/work/agent/extensions", false],
        ],
      );
    });

    test("names the file the Helper's tree really holds", () => {
      assert.match(readFileSync(FOLDERS, "utf8"), new RegExp(`"${basename(EXTENSION).replace(".", "\\.")}"`));
    });
  });

  suite("on native Windows", () => {
    /** The form the core gives a Terminal there (herdr compatibility, #586). */
    const PIPE = "\\\\.\\pipe\\herdr-core-user-session.sock";
    /** A creation time as `ToFileTimeUtc` prints it, too long for a JavaScript number. */
    const FILETIME = "134065234567891237";
    const savedPlatform = Object.getOwnPropertyDescriptor(process, "platform");
    const savedDirectory = process.cwd();
    let folder;
    let asked;

    /**
     * Stands in for the system's `powershell.exe`, and keeps the arguments it was
     * given. Outside Windows the backslashes are one file's name beside this root.
     */
    function fakePowerShell(body) {
      process.env.SystemRoot = join(folder, "Windows");
      const path = `${process.env.SystemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
      writeFileSync(path, `#!/bin/sh\nprintf '%s\\n' "$@" > '${asked}'\n${body}\n`, { mode: 0o755 });
    }

    beforeEach(() => {
      folder = mkdtempSync(join(root, "win-"));
      asked = join(folder, "asked");
      // Outside Windows these backslashes are one file's name, under the working
      // folder, so the value reaches `net.connect` as the core gave it.
      process.chdir(folder);
      Object.defineProperty(process, "platform", { value: "win32" });
      process.env.HC_TERMINAL_ID = "t1t";
      process.env.HC_TERMINAL_SOCKET = PIPE;
    });

    afterEach(() => {
      Object.defineProperty(process, "platform", savedPlatform);
      process.chdir(savedDirectory);
      delete process.env.SystemRoot;
    });

    /** A terminal socket at the pipe's own name. */
    async function fakePipe({ answers = true } = {}) {
      const lines = [];
      const server = createServer((socket) => {
        socket.unref();
        let text = "";
        socket.on("data", (chunk) => {
          text += chunk;
          for (let at = text.indexOf("\n"); at >= 0; at = text.indexOf("\n")) {
            lines.push(JSON.parse(text.slice(0, at)));
            text = text.slice(at + 1);
            if (answers) socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: lines.at(-1).id, result: {} })}\n`);
          }
        });
        socket.on("close", () => {
          closedAt = Date.now();
        });
        socket.on("error", () => {});
      });
      let closedAt = null;
      await new Promise((done) => server.listen(PIPE, done));
      server.unref();
      return { lines, closedAt: () => closedAt, close: () => new Promise((done) => server.close(done)) };
    }

    async function started() {
      const heelerSession = await loadExtension();
      const program = fakeProgram({ sessionFile: "C:\\Users\\user\\.pi\\agent\\sessions\\s.jsonl" });
      await heelerSession(program.api);
      return program;
    }

    async function until(condition, ms = 3000) {
      const deadline = Date.now() + ms;
      while (!condition()) {
        assert.ok(Date.now() < deadline, "what the test waited for never happened");
        await settle(10);
      }
    }

    test("one label line goes to the pipe, naming the process by its creation time", async () => {
      fakePowerShell(`echo ${FILETIME}`);
      const pipe = await fakePipe();
      const program = await started();

      await program.emit("session_start");
      await until(() => pipe.lines.length > 0);
      await settle();

      assert.equal(pipe.lines.length, 1);
      const [request] = pipe.lines;
      assert.equal(request.method, "terminal.label");
      assert.equal(request.params.terminal, "t1t");
      const label = JSON.parse(request.params.labels["heeler.session"]);
      assert.equal(label.session, "session-1");
      assert.equal(label.file, "C:\\Users\\user\\.pi\\agent\\sessions\\s.jsonl");
      assert.equal(label.pid, process.pid);
      assert.equal(label.start, FILETIME);
      const arguments_ = readFileSync(asked, "utf8");
      assert.match(arguments_, new RegExp(`Get-Process -Id ${process.pid}\\b`));
      assert.match(arguments_, /-NoProfile/);
      await pipe.close();
    });

    test("a pipe that never answers is given up on quietly, and the session goes on at once", async () => {
      fakePowerShell(`echo ${FILETIME}`);
      const unhandled = [];
      const onUnhandled = (reason) => unhandled.push(reason);
      process.on("unhandledRejection", onUnhandled);
      const pipe = await fakePipe({ answers: false });
      const program = await started();

      const before = Date.now();
      await program.emit("session_start");
      assert.ok(Date.now() - before < 100, "the program waited on the label");
      await until(() => pipe.closedAt() !== null, 3000);
      assert.equal(pipe.lines.length, 1);
      assert.ok(pipe.closedAt() - before < 2500, "the extension held the pipe too long");

      process.off("unhandledRejection", onUnhandled);
      assert.deepEqual(unhandled, []);
      await pipe.close();
    });

    test("a slow PowerShell holds up nothing but the label", async () => {
      fakePowerShell(`sleep 1\necho ${FILETIME}`);
      const pipe = await fakePipe();
      const program = await started();

      const before = Date.now();
      await program.emit("session_start");
      assert.ok(Date.now() - before < 100, "the program waited on PowerShell");
      await until(() => pipe.lines.length === 1);
      await pipe.close();
    });

    for (const [name, body] of [
      ["fails", "exit 1"],
      ["prints something else", "echo 'not a number'"],
    ]) {
      test(`a PowerShell that ${name} leaves the label with no start, which Chat will not adopt`, async () => {
        fakePowerShell(body);
        const pipe = await fakePipe();
        const program = await started();

        await program.emit("session_start");
        await until(() => pipe.lines.length === 1);

        const label = JSON.parse(pipe.lines[0].params.labels["heeler.session"]);
        assert.equal(label.pid, process.pid);
        assert.equal("start" in label, false);
        await pipe.close();
      });
    }

    test("a powershell.exe in the project or on PATH is not what runs", async () => {
      fakePowerShell(`echo ${FILETIME}`);
      const ran = join(folder, "planted-ran");
      // The working folder is the Agent's project, which a bare name finds first.
      writeFileSync(join(folder, "powershell.exe"), `#!/bin/sh\ntouch '${ran}'\necho 1\n`, { mode: 0o755 });
      const savedPath = process.env.PATH;
      process.env.PATH = `${folder}:${savedPath}`;
      const pipe = await fakePipe();
      const program = await started();

      await program.emit("session_start");
      await until(() => pipe.lines.length === 1);
      process.env.PATH = savedPath;

      assert.equal(existsSync(ran), false);
      assert.equal(JSON.parse(pipe.lines[0].params.labels["heeler.session"]).start, FILETIME);
      await pipe.close();
    });

    test("with no SystemRoot to find PowerShell by, nothing starts", async () => {
      const ran = join(folder, "planted-ran");
      writeFileSync(join(folder, "powershell.exe"), `#!/bin/sh\ntouch '${ran}'\necho ${FILETIME}\n`, { mode: 0o755 });
      const savedPath = process.env.PATH;
      process.env.PATH = `${folder}:${savedPath}`;
      const pipe = await fakePipe();
      const program = await started();

      await program.emit("session_start");
      await until(() => pipe.lines.length === 1);
      process.env.PATH = savedPath;

      assert.equal(existsSync(ran), false);
      assert.equal("start" in JSON.parse(pipe.lines[0].params.labels["heeler.session"]), false);
      await pipe.close();
    });

    test("without HC_TERMINAL_ID it does nothing, and starts nothing", async () => {
      fakePowerShell(`echo ${FILETIME}`);
      delete process.env.HC_TERMINAL_ID;
      const pipe = await fakePipe();
      const program = await started();

      await program.emit("session_start");
      await settle();

      assert.deepEqual(program.registered(), []);
      assert.deepEqual(pipe.lines, []);
      assert.equal(existsSync(asked), false);
      await pipe.close();
    });
  });

  suite("the process start", () => {
    test("is field 22 of a Linux stat line, whatever the command is called", async () => {
      const { startTimeFromStat } = await import(pathToFileURL(EXTENSION).href);
      // Field 22 of a captured line, with a command name that looks like more fields.
      const stat = "4242 (node) S (x)) S 1 4242 4242 0 -1 4194304 7 0 0 0 1 2 0 0 20 0 11 0 987654 1234 56 18446744073709551615";
      assert.equal(startTimeFromStat(stat), "987654");
      assert.equal(startTimeFromStat("not a stat line"), null);
    });
  });
});
