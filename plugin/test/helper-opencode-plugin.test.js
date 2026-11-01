// Heeler's OpenCode plugin, loaded the way each OpenCode release loads it: from
// its folder, with the TUI plugin API that release hands it, in a process whose
// environment names the Terminal (ADR 0033).

import { after, afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const FOLDER = fileURLToPath(new URL("../helper/extensions/opencode/", import.meta.url));

const root = mkdtempSync(join(tmpdir(), "heeler-oc-"));
after(() => rmSync(root, { recursive: true, force: true }));

let copies = 0;

/** A copy of the folder, as the edit puts it under OpenCode's config directory. */
function copyFolder() {
  const folder = join(root, `copy-${copies++}`, "heeler-opencode");
  cpSync(FOLDER, folder, { recursive: true });
  return folder;
}

async function loadPlugin(entry = "tui.js") {
  return (await import(pathToFileURL(join(copyFolder(), entry)).href)).default;
}

/** OpenCode 2.x's API, from `packages/tui/src/plugin/api.tsx` at v2.2.5. */
function fakeV2({ sessions = {} } = {}) {
  const screen = { route: { type: "home" }, sessions };
  return {
    screen,
    show(sessionID) {
      screen.route = { type: "session", sessionID };
    },
    home() {
      screen.route = { type: "home" };
    },
    api: {
      ui: { router: { current: () => screen.route } },
      data: { session: { get: (id) => screen.sessions[id] } },
    },
  };
}

/** OpenCode 1.x's API, as herdr's integration uses it (herdr compatibility). */
function fakeV1({ sessions = {} } = {}) {
  const screen = { route: { name: "home" }, sessions };
  const disposers = [];
  return {
    screen,
    dispose: () => disposers.forEach((dispose) => dispose()),
    show(sessionID) {
      screen.route = { name: "session", params: { sessionID } };
    },
    api: {
      route: {
        get current() {
          return screen.route;
        },
      },
      state: { session: { get: (id) => screen.sessions[id] } },
      lifecycle: { onDispose: (dispose) => disposers.push(dispose) },
    },
  };
}

/** A terminal socket that keeps what it is sent, and answers unless told not to. */
async function fakeSocket({ answers = true } = {}) {
  const path = join(root, `s${copies++}.sock`);
  const lines = [];
  const sockets = new Set();
  const closes = [];
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
      }
    });
    socket.on("close", () => closes.push(Date.now()));
    socket.on("error", () => {});
  });
  await new Promise((done) => server.listen(path, done));
  // A failed test must not hang the run on this.
  server.unref();
  return {
    path,
    lines,
    closes,
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise((done) => server.close(done));
    },
  };
}

async function until(condition, what, ms = 3000) {
  const deadline = Date.now() + ms;
  while (!condition()) {
    assert.ok(Date.now() < deadline, `never saw ${what}`);
    await new Promise((done) => setTimeout(done, 10));
  }
}

const settle = (ms = 600) => new Promise((done) => setTimeout(done, ms));

/** This process's start as the app's process reader sees it, without the plugin's code. */
function startOfThisProcess() {
  const command =
    process.platform === "linux"
      ? `sed 's/.*) //' /proc/${process.pid}/stat | cut -d' ' -f20`
      : `LC_ALL=C TZ=UTC /bin/ps -o lstart= -p ${process.pid}`;
  return spawnSync("/bin/sh", ["-c", command], { encoding: "utf8" }).stdout.trim();
}

const labelOf = (line) => JSON.parse(line.params.labels["heeler.session"]);

suite("Heeler's OpenCode plugin", () => {
  const savedEnvironment = { ...process.env };

  beforeEach(() => {
    delete process.env.HC_TERMINAL_ID;
    delete process.env.HC_TERMINAL_SOCKET;
  });

  afterEach(() => {
    process.env = { ...savedEnvironment };
  });

  suite("outside a herdr-core Terminal", () => {
    test("OpenCode 2.x: it starts nothing and writes nothing", async () => {
      const socket = await fakeSocket();
      process.env.HC_TERMINAL_SOCKET = socket.path;
      const plugin = await loadPlugin();
      const fake = fakeV2({ sessions: { ses_a: { id: "ses_a" } } });
      fake.show("ses_a");

      assert.equal(plugin.setup(fake.api), undefined);
      await settle();

      assert.deepEqual(socket.lines, []);
      await socket.close();
    });

    test("OpenCode 1.x: it starts nothing and writes nothing", async () => {
      const socket = await fakeSocket();
      process.env.HC_TERMINAL_SOCKET = socket.path;
      const plugin = await loadPlugin();
      const fake = fakeV1({ sessions: { ses_a: { id: "ses_a" } } });
      fake.show("ses_a");

      await plugin.tui(fake.api);
      await settle();

      assert.deepEqual(socket.lines, []);
      await socket.close();
    });
  });

  suite("inside a core Terminal", () => {
    async function running(version, options = {}) {
      const socket = await fakeSocket(options);
      process.env.HC_TERMINAL_ID = "t17";
      process.env.HC_TERMINAL_SOCKET = socket.path;
      const plugin = await loadPlugin();
      const fake = version === 2 ? fakeV2(options) : fakeV1(options);
      const cleanup = version === 2 ? plugin.setup(fake.api) : await plugin.tui(fake.api);
      return {
        socket,
        fake,
        async stop() {
          if (version === 2) cleanup();
          else fake.dispose();
          await socket.close();
        },
      };
    }

    for (const version of [2, 1]) {
      suite(`OpenCode ${version}.x`, () => {
        test("it writes one label line naming its session, its pid and its start", async () => {
          const { socket, fake, stop } = await running(version, { sessions: { ses_a: { id: "ses_a" } } });

          fake.show("ses_a");
          await until(() => socket.lines.length > 0, "the label");
          await settle();

          assert.equal(socket.lines.length, 1);
          assert.equal(socket.lines[0].method, "terminal.label");
          assert.equal(socket.lines[0].params.terminal, "t17");
          assert.deepEqual(Object.keys(socket.lines[0].params.labels), ["heeler.session"]);
          assert.deepEqual(labelOf(socket.lines[0]), {
            session: "ses_a",
            pid: process.pid,
            start: startOfThisProcess(),
          });
          await stop();
        });

        test("it writes a new line when the session changes", async () => {
          const { socket, fake, stop } = await running(version, {
            sessions: { ses_a: { id: "ses_a" }, ses_b: { id: "ses_b" } },
          });

          fake.show("ses_a");
          await until(() => socket.lines.length === 1, "the first label");
          fake.show("ses_b");
          await until(() => socket.lines.length === 2, "the second label");

          assert.deepEqual(socket.lines.map((line) => labelOf(line).session), ["ses_a", "ses_b"]);
          await stop();
        });

        test("a subagent's view keeps its root session", async () => {
          const { socket, fake, stop } = await running(version, {
            sessions: { ses_a: { id: "ses_a" }, ses_child: { id: "ses_child", parentID: "ses_a" } },
          });

          fake.show("ses_a");
          await until(() => socket.lines.length === 1, "the root's label");
          fake.show("ses_child");
          await settle();

          assert.deepEqual(socket.lines.map((line) => labelOf(line).session), ["ses_a"]);
          await stop();
        });

        test("a session it knows nothing of yet waits until it does", async () => {
          const { socket, fake, stop } = await running(version);

          fake.show("ses_new");
          await settle();
          assert.deepEqual(socket.lines, []);

          fake.screen.sessions.ses_new = { id: "ses_new" };
          await until(() => socket.lines.length === 1, "the label");
          assert.equal(labelOf(socket.lines[0]).session, "ses_new");
          await stop();
        });

        test("it gives up quietly after a short timeout when the socket does not answer", async () => {
          const { socket, fake, stop } = await running(version, {
            answers: false,
            sessions: { ses_a: { id: "ses_a" } },
          });

          const sent = Date.now();
          fake.show("ses_a");
          await until(() => socket.lines.length === 1, "the label");
          await until(() => socket.closes.length === 1, "the connection closing");

          assert.ok(socket.closes[0] - sent < 2000, "the plugin held the socket open");
          await settle();
          assert.equal(socket.lines.length, 1, "it asked again");
          await stop();
        });
      });
    }

    test("OpenCode 2.x: the home screen after /new says nothing, and the next session does", async () => {
      const { socket, fake, stop } = await running(2, {
        sessions: { ses_a: { id: "ses_a" }, ses_b: { id: "ses_b" } },
      });

      fake.show("ses_a");
      await until(() => socket.lines.length === 1, "the first label");
      fake.home();
      await settle();
      assert.equal(socket.lines.length, 1);

      fake.show("ses_b");
      await until(() => socket.lines.length === 2, "the second label");
      assert.equal(labelOf(socket.lines[1]).session, "ses_b");
      await stop();
    });

    test("nothing is written after OpenCode lets the plugin go", async () => {
      const { socket, fake, stop } = await running(2, { sessions: { ses_a: { id: "ses_a" } } });
      await stop();

      fake.show("ses_a");
      await settle();

      assert.deepEqual(socket.lines, []);
    });
  });

  suite("its folder", () => {
    test("OpenCode 1.x's entry point and OpenCode 2.x's are the same plugin", async () => {
      const folder = copyFolder();
      const index = (await import(pathToFileURL(join(folder, "index.js")).href)).default;
      const tui = (await import(pathToFileURL(join(folder, "tui.js")).href)).default;

      assert.equal(index, tui);
      assert.equal(typeof tui.id, "string");
      assert.equal(typeof tui.setup, "function");
      assert.equal(typeof tui.tui, "function");
      assert.equal(tui.server, undefined, "OpenCode 1.x refuses a plugin with both server() and tui()");
    });

    test("its package.json names no entry, so each release finds its own by file name", () => {
      const manifest = JSON.parse(readFileSync(join(FOLDER, "package.json"), "utf8"));
      assert.deepEqual(manifest, { type: "module" });
    });
  });
});
