// Usage on a tmux Host reads the server's global environment by the names the
// core record already uses (ADR 0033). The server here is a private `-S`
// socket, started with `-f /dev/null`, and every ask passes `-N`.

import { afterEach, before, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ENVIRONMENT_NAMES, readUsageRuntime, writeUsageRuntime } from "../helper/shared/usage/runtime-record.js";
import { readTmuxGlobalEnvironment } from "../helper/usage/tmux-environment.js";
import { resolveTestTmux } from "./support/tmux.js";

const { skip, requireTmux } = resolveTestTmux();
const roots = [];

afterEach(() => {
  while (roots.length > 0) rmSync(roots.pop(), { recursive: true, force: true });
});

function server() {
  const executable = requireTmux();
  const root = mkdtempSync(join(tmpdir(), "heeler-tmux-env-"));
  roots.push(root);
  const socket = join(root, "sock");
  execFileSync(executable, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/cat"], {
    env: { PATH: "/usr/bin:/bin", HOME: "/tmp", USER: "fixture" },
    stdio: "ignore",
  });
  return {
    socket,
    stop() {
      execFileSync(executable, ["-N", "-S", socket, "kill-server"], { stdio: "ignore" });
    },
    set(name, value) {
      execFileSync(executable, ["-N", "-S", socket, "set-environment", "-g", name, value], { stdio: "ignore" });
    },
    remove(name) {
      execFileSync(executable, ["-N", "-S", socket, "set-environment", "-gr", name], { stdio: "ignore" });
    },
  };
}

suite("tmux global environment", { skip }, () => {
  before(() => {
    requireTmux();
  });

  test("the global environment's named values, and nothing else", async () => {
    const running = server();
    try {
      running.set("HOME", "/tmp/fixture-home");
      running.set("PATH", "/fixture/bin:/usr/bin");
      running.set("USER", "fixture");
      running.set("CLAUDE_CONFIG_DIR", "/fixture/cla=ude");
      running.set("CODEX_HOME", "/dir/café");
      running.set("XDG_CONFIG_HOME", "say \"hi\" and $PATH");
      running.set("HTTPS_PROXY", "http://example.test/a\nb=CLAUDECODE=planted\n-TMUX");
      running.set("SSL_CERT_FILE", "");
      running.remove("USER");
      running.set("NOT_A_USAGE_NAME", "secret-marker");

      const environment = await readTmuxGlobalEnvironment({ executable: requireTmux(), socket: running.socket });
      assert.deepEqual(Object.keys(environment).sort(), [...ENVIRONMENT_NAMES].sort());
      assert.equal(environment.HOME, "/tmp/fixture-home");
      assert.equal(environment.PATH, "/fixture/bin:/usr/bin");
      assert.equal(environment.USER, null);
      assert.equal(environment.CLAUDE_CONFIG_DIR, "/fixture/cla=ude");
      assert.equal(environment.CODEX_HOME, "/dir/café");
      assert.equal(environment.XDG_CONFIG_HOME, "say \"hi\" and $PATH");
      assert.equal(environment.HTTPS_PROXY, "http://example.test/a\nb=CLAUDECODE=planted\n-TMUX");
      assert.equal(environment.SSL_CERT_FILE, "");
      assert.equal(environment.HTTP_PROXY, null);
      assert.equal("NOT_A_USAGE_NAME" in environment, false);
      assert.equal(Object.values(environment).includes("secret-marker"), false);

      const configDir = join(roots[0], "session");
      writeUsageRuntime(environment, {
        configDir,
        stateDir: join(roots[0], "state"),
        node: process.execPath,
        herdr: null,
      });
      assert.equal(readUsageRuntime(configDir).env.CLAUDE_CONFIG_DIR, "/fixture/cla=ude");
      assert.equal(readUsageRuntime(configDir).env.USER, null);
      assert.equal(readUsageRuntime(configDir).env.HTTPS_PROXY, environment.HTTPS_PROXY);
    } finally {
      running.stop();
    }
  });

  test("a bash function and names with a dot or a dash leave the real values", async () => {
    const running = server();
    try {
      running.set(
        "BASH_FUNC_module%%",
        "() {\nCLAUDE_CONFIG_DIR=\"/planted\"; export CLAUDE_CONFIG_DIR;\nunset HOME;\n}\n",
      );
      running.set("WITH.DOT", "dot-marker");
      running.set("WITH-DASH", "dash-marker");
      running.set("CLAUDE_CONFIG_DIR", "/fixture/real-claude");
      running.set("HOME", "/tmp/fixture-home");

      const environment = await readTmuxGlobalEnvironment({ executable: requireTmux(), socket: running.socket });
      assert.ok(environment);
      assert.deepEqual(Object.keys(environment).sort(), [...ENVIRONMENT_NAMES].sort());
      assert.equal(environment.CLAUDE_CONFIG_DIR, "/fixture/real-claude");
      assert.equal(environment.HOME, "/tmp/fixture-home");
      assert.equal(Object.values(environment).includes("/planted"), false);
      assert.equal(Object.values(environment).includes("dot-marker"), false);
      assert.equal(Object.values(environment).includes("dash-marker"), false);
      assert.equal("BASH_FUNC_module%%" in environment, false);
      assert.equal("WITH.DOT" in environment, false);
      assert.equal("WITH-DASH" in environment, false);
    } finally {
      running.stop();
    }
  });

  test("a server that is not there is unreadable, and asking does not start one", async () => {
    const root = mkdtempSync(join(tmpdir(), "heeler-tmux-env-"));
    roots.push(root);
    const socket = join(root, "absent");
    assert.equal(await readTmuxGlobalEnvironment({ executable: requireTmux(), socket }), null);
    assert.equal(existsSync(socket), false);
    assert.equal(await readTmuxGlobalEnvironment({ executable: join(root, "no-such-tmux"), socket }), null);
    assert.equal(await readTmuxGlobalEnvironment(null), null);
  });
});
