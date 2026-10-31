// The Helper serves Usage as the plugin does. A user service does not start with
// the core's environment, so it records the named variables from the core process
// at the pid `server.status` reported (ADR 0033). The core process here is real,
// so its environment is read the way a Host's would be.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { followCoreSession } from "../helper/core/follower.js";
import { agentDirectories } from "../helper/shared/usage/agent-directories.js";
import { usageListener } from "../helper/usage/recorder.js";
import { FakeCore, exchange, waitFor } from "./support/fake-core.js";

const STATUS = exchange("server-status").result;
const FAST = { retryDelayMs: 10, pollMs: 10 };
const PATIENCE_MS = 5000;
// The plugin's named list, written out so the record cannot drift by importing it.
const HELPER = fileURLToPath(new URL("../helper", import.meta.url));
const NAMED = [
  "PATH", "HOME", "USER", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME",
  "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
  "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE",
];

let root;
let directory;
let env;
const running = [];

beforeEach(() => {
  root = mkdtempSync("/tmp/hh-");
  directory = join(root, "helper");
  mkdirSync(directory, { mode: 0o700 });
  env = { HOME: root, XDG_RUNTIME_DIR: join(root, "r") };
});

afterEach(async () => {
  while (running.length > 0) await running.pop()();
  rmSync(root, { recursive: true, force: true });
});

const socketFor = (session) => join(root, "r", "herdr-core", `${session}.sock`);
const recordPath = (session) => join(directory, "sessions", session, "runtime.json");
const readRecord = (session) => JSON.parse(readFileSync(recordPath(session), "utf8"));

/** A process standing in for the core, with exactly this environment. */
async function coreProcess(environment) {
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { env: environment, stdio: "ignore" });
  await new Promise((done, fail) => {
    child.once("spawn", done);
    child.once("error", fail);
  });
  running.push(async () => {
    child.kill("SIGKILL");
  });
  return child;
}

async function fakeCore(session, pid, options = {}) {
  const fake = await FakeCore.start(socketFor(session), { status: { ...STATUS, pid }, ...options });
  running.push(() => fake.stop().catch(() => {}));
  return fake;
}

function follow(session) {
  const logs = [];
  const log = (line) => logs.push(line);
  const handle = followCoreSession(session, {
    env,
    runUserDirectory: join(root, "none"),
    listener: usageListener({ directory, log }),
    log,
    ...FAST,
  });
  running.push(() => handle.stop());
  return logs;
}

suite("the Helper's runtime record", () => {
  test("holds exactly the named variables, from the core pid server.status reported", async () => {
    const coreEnvironment = {
      PATH: "/usr/bin:/bin",
      HOME: join(root, "core home"),
      USER: "core-account",
      CLAUDE_CONFIG_DIR: join(root, "claude config"),
      CODEX_HOME: join(root, "codex"),
      HTTPS_PROXY: "http://proxy.invalid:3128",
    };
    const child = await coreProcess(coreEnvironment);
    await fakeCore("work", child.pid);

    follow("work");
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);

    const record = readRecord("work");
    assert.deepEqual(Object.keys(record.env).sort(), [...NAMED].sort());
    assert.deepEqual(
      Object.fromEntries(Object.entries(record.env).filter(([, value]) => value !== null)),
      coreEnvironment,
    );
    assert.equal(record.version, 1);
    assert.equal(record.node, process.execPath);
    assert.equal(record.stateDir, join(directory, "state"));
    assert.equal(readFileSync(join(directory, "sessions", "work", "runtime-node"), "utf8"), `${process.execPath}\n`);
  });

  test("finds the programs on the core's PATH, not the Helper's", async () => {
    const bin = join(root, "core bin");
    mkdirSync(bin);
    for (const name of ["claude", "codex"]) {
      writeFileSync(join(bin, name), "#!/bin/sh\nexit 99\n");
      chmodSync(join(bin, name), 0o755);
    }
    const child = await coreProcess({ PATH: bin, HOME: root });
    await fakeCore("work", child.pid);

    follow("work");
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);

    assert.equal(readRecord("work").claude, join(bin, "claude"));
    assert.equal(readRecord("work").codex, join(bin, "codex"));
    assert.equal(readRecord("work").herdr, null);
  });

  test("a reconnect to a core with a new pid records the new values", async () => {
    const first = await coreProcess({ HOME: root, CLAUDE_CONFIG_DIR: "/first/claude" });
    const old = await fakeCore("work", first.pid);

    follow("work");
    await waitFor(() => readRecordIfAny("work")?.env.CLAUDE_CONFIG_DIR === "/first/claude", "the first record", PATIENCE_MS);

    await old.stop();
    const second = await coreProcess({ HOME: root, CLAUDE_CONFIG_DIR: "/second/claude" });
    await fakeCore("work", second.pid);

    await waitFor(() => readRecordIfAny("work")?.env.CLAUDE_CONFIG_DIR === "/second/claude", "the new record", PATIENCE_MS);
  });

  test("each session keeps a record of its own core", async () => {
    const work = await coreProcess({ HOME: root, CODEX_HOME: "/work/codex" });
    const other = await coreProcess({ HOME: root, CODEX_HOME: "/other/codex" });
    await fakeCore("work", work.pid);
    await fakeCore("other", other.pid);

    follow("work");
    follow("other");
    await waitFor(() => existsSync(recordPath("work")) && existsSync(recordPath("other")), "both records", PATIENCE_MS);

    assert.equal(readRecord("work").env.CODEX_HOME, "/work/codex");
    assert.equal(readRecord("other").env.CODEX_HOME, "/other/codex");
  });

  test("a variable outside the list never reaches the record", async () => {
    const child = await coreProcess({
      HOME: root,
      ANTHROPIC_API_KEY: "secret-outside-the-list",
      MY_CLAUDE_CONFIG_DIR: "secret-suffix-match",
      CLAUDE_CONFIG_DIRECTORY: "secret-prefix-match",
    });
    await fakeCore("work", child.pid);

    follow("work");
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);

    const text = readFileSync(recordPath("work"), "utf8");
    assert.equal(text.includes("secret-"), false, text);
    assert.equal(text.includes("ANTHROPIC_API_KEY"), false, text);
    assert.equal(readRecord("work").env.CLAUDE_CONFIG_DIR, null);
  });

  test("no value is logged", async () => {
    const child = await coreProcess({
      PATH: "/secret/path",
      HOME: join(root, "secret-home"),
      CLAUDE_CONFIG_DIR: "/secret/claude",
      HTTPS_PROXY: "http://user:secret@proxy.invalid",
    });
    await fakeCore("work", child.pid);

    const logs = follow("work");
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);
    await waitFor(() => logs.some((line) => line.includes("recorded")), "the log line", PATIENCE_MS);

    assert.deepEqual(logs.filter((line) => line.includes("secret")), []);
  });

  test("the record is private to the user", async () => {
    const child = await coreProcess({ HOME: root, HTTPS_PROXY: "http://user:secret@proxy.invalid" });
    await fakeCore("work", child.pid);

    follow("work");
    await waitFor(() => existsSync(join(directory, "sessions", "work", "runtime-node")), "the record", PATIENCE_MS);

    const mode = (path) => statSync(path).mode & 0o777;
    assert.equal(mode(recordPath("work")), 0o600);
    assert.equal(mode(join(directory, "sessions", "work", "runtime-node")), 0o600);
    assert.equal(mode(join(directory, "sessions", "work")), 0o700);
    assert.equal(mode(join(directory, "sessions")), 0o700);
  });

  test("a core whose environment cannot be read keeps the last record and says so", async () => {
    const child = await coreProcess({ HOME: root, CODEX_HOME: "/kept/codex" });
    const old = await fakeCore("work", child.pid);
    const logs = follow("work");
    await waitFor(() => existsSync(recordPath("work")), "the first record", PATIENCE_MS);

    await old.stop();
    const gone = await coreProcess({ HOME: root });
    gone.kill("SIGKILL");
    await new Promise((done) => gone.once("exit", done));
    await fakeCore("work", gone.pid);
    await waitFor(() => logs.some((line) => line.includes("cannot read")), "the log line", PATIENCE_MS);

    assert.equal(readRecord("work").env.CODEX_HOME, "/kept/codex");
  });
});

suite("Claude Code Account suggestions", () => {
  const stateDir = () => join(directory, "state");
  const live = (address, fields) => ({ address, state: "live", pid: 1, ...fields });
  const snapshot = (...terminals) => ({ channel: 1, seq: 1, terminals });

  async function agentDirectory(name) {
    const path = join(root, name);
    mkdirSync(path);
    return { path, process: await coreProcess({ HOME: root, CLAUDE_CONFIG_DIR: path }) };
  }

  async function startCore(options) {
    const self = await coreProcess({ HOME: root });
    const fake = await fakeCore("work", self.pid, options);
    return fake;
  }

  test("come from the configuration directories of the Claude Code Agents the inventory holds", async () => {
    const claude = await agentDirectory("claude-work");
    const npm = await agentDirectory("claude-npm");
    const ordinary = await agentDirectory("claude-ordinary");
    const shell = await agentDirectory("claude-shell");
    await startCore({
      snapshot: snapshot(
        live("t1", { foreground: { argv: ["/usr/local/bin/claude"], name: "claude", pid: claude.process.pid } }),
        live("t2", {
          foreground: {
            argv: ["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
            name: "node",
            pid: npm.process.pid,
          },
        }),
        // Named no Agent: its environment says nothing about an Account.
        live("t3", { foreground: { argv: ["vim", "claude"], name: "vim", pid: ordinary.process.pid } }),
        // Claude Code exited: its report stays behind a plain shell.
        live("t4", {
          foreground: { argv: ["/bin/zsh"], name: "zsh", pid: shell.process.pid },
          status: { app: "claude-code", state: "idle" },
        }),
      ),
    });

    follow("work");
    await waitFor(() => agentDirectories(stateDir()).length === 2, "the Agents' directories", PATIENCE_MS);

    assert.deepEqual(agentDirectories(stateDir()).sort(), [claude.path, npm.path].sort());
  });

  test("a Terminal reporting Claude Code counts when its foreground is no plain shell", async () => {
    const reporting = await agentDirectory("claude-reporting");
    await startCore({
      snapshot: snapshot(
        live("t1", {
          foreground: { argv: ["some-wrapper"], name: "some-wrapper", pid: reporting.process.pid },
          status: { app: "claude-code", state: "working" },
        }),
      ),
    });

    follow("work");
    await waitFor(() => agentDirectories(stateDir()).length === 1, "the Agent's directory", PATIENCE_MS);

    assert.deepEqual(agentDirectories(stateDir()), [reporting.path]);
  });

  test("an Agent started after the snapshot counts from its foreground event", async () => {
    const claude = await agentDirectory("claude-later");
    const fake = await startCore({ snapshot: snapshot(live("t1", {})) });

    follow("work");
    await waitFor(() => existsSync(recordPath("work")), "the connection", PATIENCE_MS);
    assert.deepEqual(agentDirectories(stateDir()), []);

    const line = JSON.stringify({
      jsonrpc: "2.0",
      method: "event",
      params: {
        seq: 9,
        terminal: "t1",
        type: "foreground",
        data: { argv: ["claude"], name: "claude", pid: claude.process.pid, cwd: root },
      },
    });
    fake.last.sendEvents(`${line}\n`);

    await waitFor(() => agentDirectories(stateDir()).length === 1, "the Agent's directory", PATIENCE_MS);
    assert.deepEqual(agentDirectories(stateDir()), [claude.path]);
  });

  test("a reconnect looks at the Agents again, each pid once", async () => {
    const claude = await agentDirectory("claude-again");
    const terminal = live("t1", { foreground: { argv: ["claude"], name: "claude", pid: claude.process.pid } });
    const fake = await startCore({ snapshot: snapshot(terminal) });
    follow("work");
    await waitFor(() => agentDirectories(stateDir()).length === 1, "the Agent's directory", PATIENCE_MS);
    const noted = () => JSON.parse(readFileSync(join(stateDir(), "usage", "claude-agents.json"), "utf8"));
    const first = noted();

    fake.last.destroy();
    await waitFor(() => fake.connections.length === 2, "the reconnection", PATIENCE_MS);
    await waitFor(() => fake.last.methods.includes("events.subscribe"), "the subscribe", PATIENCE_MS);

    assert.deepEqual(noted(), first);
  });

  test("an unset, relative or missing directory suggests nothing", async () => {
    const unset = await coreProcess({ HOME: root });
    const relative = await coreProcess({ HOME: root, CLAUDE_CONFIG_DIR: "relative/claude" });
    const missing = await coreProcess({ HOME: root, CLAUDE_CONFIG_DIR: join(root, "no-such-directory") });
    const last = await agentDirectory("claude-last");
    await startCore({
      snapshot: snapshot(
        ...[unset, relative, missing, last.process].map((child, index) =>
          live(`t${index}`, { foreground: { argv: ["claude"], name: "claude", pid: child.pid } }),
        ),
      ),
    });

    follow("work");
    await waitFor(() => agentDirectories(stateDir()).length > 0, "a directory", PATIENCE_MS);

    assert.deepEqual(agentDirectories(stateDir()), [last.path]);
  });
});

suite("the Helper's Usage query", () => {
  /**
   * A Host as an install leaves it: a bare copy of the Helper, its real service
   * following a core, and `hc`, `herdr-core` and `herdr` as tripwires. What the
   * query is run with stands for the SSH session, which lacks the core's variables.
   */
  async function host({ registered = ["work"], claude = false } = {}) {
    const coreHome = join(root, "core-home");
    const config = join(root, "core-claude");
    const bin = join(root, "bin");
    const tripwire = join(root, "tripwire");
    const claudeLog = join(root, "claude-log");
    mkdirSync(coreHome);
    mkdirSync(bin);
    for (const name of ["hc", "herdr-core", "herdr"]) {
      writeFileSync(join(bin, name), `#!/bin/sh\necho "${name} $*" >> "${tripwire}"\n`);
      chmodSync(join(bin, name), 0o755);
    }
    if (claude) {
      writeFileSync(join(bin, "claude"), `#!/bin/sh\necho "$*" >> "${claudeLog}"\n`);
      chmodSync(join(bin, "claude"), 0o755);
    }
    mkdirSync(join(config, "projects", "-work"), { recursive: true });
    writeFileSync(
      join(config, "projects", "-work", "a.jsonl"),
      `${JSON.stringify({
        type: "assistant",
        timestamp: new Date().toISOString(),
        sessionId: "s",
        requestId: "r",
        cwd: "/work",
        message: { id: "m", model: "claude-opus-4-1", usage: { input_tokens: 7, output_tokens: 5 } },
      })}\n`,
    );
    cpSync(HELPER, join(directory, "app"), { recursive: true });
    writeFileSync(
      join(directory, "notifications.json"),
      JSON.stringify({ v: 1, devices: registered.map((session) => ({ session })) }),
    );
    const core = await coreProcess({ PATH: bin, HOME: coreHome, CLAUDE_CONFIG_DIR: config });
    await fakeCore("work", core.pid);
    const service = spawn(process.execPath, [join(directory, "app", "main.js")], {
      env: { HOME: root, XDG_RUNTIME_DIR: join(root, "r"), PATH: bin },
      stdio: "ignore",
    });
    running.push(async () => {
      service.kill("SIGKILL");
    });

    const run = (name, ...args) =>
      spawnSync(process.execPath, [join(directory, "app", name), ...args], {
        env: { HOME: join(root, "ssh-home"), USER: "ssh-account", PATH: bin },
        encoding: "utf8",
        timeout: 10_000,
      });
    const query = (...args) => {
      const result = run("usage-query.js", "--tz", "UTC", "--session", "work", ...args);
      assert.equal(result.status, 0, result.stderr);
      return JSON.parse(result.stdout);
    };
    const settled = async (...args) => {
      for (let attempt = 0; attempt < 600; attempt += 1) {
        const report = query(...args);
        if (report.runtime === "recorded" && report.refreshing === false) return report;
        await new Promise((done) => setTimeout(done, 25));
      }
      assert.fail("the worker did not finish");
    };
    const tripped = () => (existsSync(tripwire) ? readFileSync(tripwire, "utf8") : "");
    const claudeCalls = () => (existsSync(claudeLog) ? readFileSync(claudeLog, "utf8") : "");
    return { config, query, run, settled, tripped, claudeCalls };
  }

  const claudeProgram = (report) => report.programs.find((program) => program.program === "claude");

  test("counts the Default Account the core's environment names, from a bare copy", async () => {
    const { config, settled, tripped } = await host();
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);

    const report = await settled();

    assert.equal(report.version, 1);
    const program = claudeProgram(report);
    assert.equal(program.tokenUsage.state, "ok");
    assert.equal(program.tokenUsage.totals.last30Days.tokens.total, 12);
    const fallback = program.accounts.find((account) => account.isDefault);
    assert.equal(fallback.directory, config);
    assert.equal(tripped(), "");
  });

  test("reads as missing while the Helper holds no record of the session", async () => {
    const { query } = await host({ registered: [] });
    assert.deepEqual(query(), { version: 1, runtime: "missing" });
  });

  test("refuses a session name the core refuses", async () => {
    const { run } = await host();
    const result = run("usage-query.js", "--tz", "UTC", "--session", "../work");
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr.includes("work"), false);
  });

  test("reads the Account file from the Helper's directory", async () => {
    const { settled } = await host();
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);
    const added = join(root, "added-claude");
    mkdirSync(join(added, "projects"), { recursive: true });
    writeFileSync(
      join(directory, "usage-accounts.json"),
      JSON.stringify({
        version: 1,
        claude: { defaultName: "Lab", accounts: [{ id: "added-one", directory: added, name: "Added" }], ignored: [] },
      }),
    );

    const report = await settled();

    const accounts = claudeProgram(report).accounts;
    assert.deepEqual(accounts.map((account) => account.name), ["Lab", "Added"]);
    assert.deepEqual(accounts.map((account) => account.state), ["ok", "ok"]);
  });

  test("runs Claude Code for its Usage Limits only when asked", async () => {
    const { settled, tripped, claudeCalls } = await host({ claude: true });
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);

    await settled();
    assert.equal(claudeCalls(), "");

    await settled("--claude-limits");
    assert.match(claudeCalls(), /--version/);
    assert.equal(tripped(), "");
  });

  test("suggests the directories of the Claude Code Agents the service saw", async () => {
    const agentHome = join(root, "agent-claude");
    mkdirSync(agentHome);
    const agent = await coreProcess({ HOME: root, CLAUDE_CONFIG_DIR: agentHome });
    const bin = join(root, "plain");
    mkdirSync(bin);
    cpSync(HELPER, join(directory, "app"), { recursive: true });
    writeFileSync(join(directory, "notifications.json"), JSON.stringify({ v: 1, devices: [{ session: "work" }] }));
    const self = await coreProcess({ HOME: join(root, "core-home"), PATH: bin });
    await fakeCore("work", self.pid, {
      snapshot: {
        channel: 1,
        seq: 1,
        terminals: [
          { address: "t1", state: "live", foreground: { argv: ["claude"], name: "claude", pid: agent.pid } },
        ],
      },
    });
    const service = spawn(process.execPath, [join(directory, "app", "main.js")], {
      env: { HOME: root, XDG_RUNTIME_DIR: join(root, "r"), PATH: bin },
      stdio: "ignore",
    });
    running.push(async () => {
      service.kill("SIGKILL");
    });
    await waitFor(() => existsSync(recordPath("work")), "the record", PATIENCE_MS);
    await waitFor(() => existsSync(join(directory, "state", "usage", "claude-agents.json")), "the note", PATIENCE_MS);

    let report;
    for (let attempt = 0; attempt < 600 && report?.refreshing !== false; attempt += 1) {
      const result = spawnSync(process.execPath, [join(directory, "app", "usage-query.js"), "--tz", "UTC", "--session", "work"], {
        env: { HOME: root, PATH: bin },
        encoding: "utf8",
      });
      report = JSON.parse(result.stdout);
      await new Promise((done) => setTimeout(done, 25));
    }

    assert.deepEqual(claudeProgram(report).accountSuggestions, [
      { directory: agentHome, name: "agent-claude", source: "agent" },
    ]);
  });
});

function readRecordIfAny(session) {
  try {
    return readRecord(session);
  } catch {
    return null;
  }
}
