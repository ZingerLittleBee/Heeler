// Usage on a tmux Host reads the server's global environment by the names the
// core record already uses (ADR 0033). The server here is a private `-S`
// socket, started with `-f /dev/null`, and every ask passes `-N`.

import { afterEach, before, suite, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

  test("queries only named variables so unrelated global values never leave tmux", async () => {
    const running = server();
    try {
      running.set("HOME", "/tmp/fixture-home");
      running.set("CLAUDE_CONFIG_DIR", "/fixture/claude-account");
      running.set("ANTHROPIC_API_KEY", "sk-ant-unrelated-secret");

      const root = roots[roots.length - 1];
      const logFile = join(root, "tmux-stdout.log");
      const argsFile = join(root, "tmux-args.jsonl");
      const wrapper = join(root, "tmux-spy");
      writeFileSync(
        wrapper,
        `#!${process.execPath}
const { appendFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const args = process.argv.slice(2);
appendFileSync(${JSON.stringify(argsFile)}, JSON.stringify(args) + String.fromCharCode(10));
const res = spawnSync(${JSON.stringify(requireTmux())}, args, { encoding: "buffer" });
if (res.stdout?.length) {
  appendFileSync(${JSON.stringify(logFile)}, res.stdout);
  process.stdout.write(res.stdout);
}
if (res.stderr?.length) process.stderr.write(res.stderr);
process.exit(res.status ?? 1);
`,
        { mode: 0o755 },
      );

      const environment = await readTmuxGlobalEnvironment({ executable: wrapper, socket: running.socket });
      assert.ok(environment);
      assert.equal(environment.HOME, "/tmp/fixture-home");
      assert.equal(environment.CLAUDE_CONFIG_DIR, "/fixture/claude-account");

      const invocations = readFileSync(argsFile, "utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      const askedNames = invocations.map((argv) => argv[argv.length - 1]);
      assert.deepEqual(askedNames, ENVIRONMENT_NAMES);
      for (const argv of invocations) {
        assert.deepEqual(argv.slice(0, -1), ["-N", "-S", running.socket, "-u", "show-environment", "-g", "-s"]);
      }
      const rawStdout = existsSync(logFile) ? readFileSync(logFile, "utf8") : "";
      assert.equal(rawStdout.includes("sk-ant-unrelated-secret"), false);
      assert.equal(rawStdout.includes("ANTHROPIC_API_KEY"), false);
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

suite("tmux 3.4 escaped global environment", () => {
  test("decodes double-escaped $var, literal backslashes, UTF-8 and strvis control bytes", async () => {
    const root = mkdtempSync(join(tmpdir(), "heeler-tmux-env34-"));
    roots.push(root);
    const stubTmux = join(root, "tmux-34");
    writeFileSync(
      stubTmux,
      `#!${process.execPath}
const args = process.argv.slice(2);
if (!args.includes("-N") || !args.includes("-u")) process.exit(2);
function showEnvEscape(v) {
  return v.replace(/[$\`"\\\\]/g, (m) => "\\\\" + m);
}
function strvis34(text) {
  const bytes = Buffer.from(text, "utf8");
  let out = "";
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i];
    if (b === 0x09 || b === 0x0a) { out += String.fromCharCode(b); i += 1; continue; }
    if (b === 0x07) { out += "\\\\a"; i += 1; continue; }
    if (b < 0x20 || b === 0x7f) { out += "\\\\" + b.toString(8).padStart(3, "0"); i += 1; continue; }
    if (b === 0x24 && i + 1 < bytes.length) {
      const next = bytes[i + 1];
      const ident = (next >= 0x41 && next <= 0x5a) || (next >= 0x61 && next <= 0x7a) || next === 0x5f || next === 0x7b;
      if (ident) { out += "\\\\$"; i += 1; continue; }
    }
    if (b < 0x80) { out += String.fromCharCode(b); i += 1; continue; }
    const w = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1;
    out += bytes.subarray(i, i + w).toString("utf8");
    i += w;
  }
  return out;
}
const entries = new Map([
  ["HOME", "/tmp/fixture-home"],
  ["XDG_CONFIG_HOME", 'say "hi" and $PATH and \\\\a and \\\\037 and \\x1f\\x07'],
  ["HTTPS_PROXY", "http://user:p$ss@proxy.example:8080"],
  ["CODEX_HOME", "/dir/café/$USER"],
]);
const flagIndex = args.indexOf("show-environment");
if (flagIndex < 0 || args[flagIndex + 1] !== "-g" || args[flagIndex + 2] !== "-s" || args.length !== flagIndex + 4) {
  process.exit(2);
}
const name = args[flagIndex + 3];
if (name === "USER") {
  process.stdout.write("unset USER;\\n");
  process.exit(0);
}
if (!entries.has(name)) {
  process.stderr.write(\`unknown variable: \${name}\\n\`);
  process.exit(1);
}
const v = entries.get(name);
process.stdout.write(strvis34(\`\${name}="\${showEnvEscape(v)}"; export \${name};\\n\`));
`,
      { mode: 0o755 },
    );

    const env = await readTmuxGlobalEnvironment({ executable: stubTmux, socket: join(root, "sock") });
    assert.ok(env);
    assert.equal(env.HOME, "/tmp/fixture-home");
    assert.equal(env.XDG_CONFIG_HOME, 'say "hi" and $PATH and \\a and \\037 and \x1f\x07');
    assert.equal(env.HTTPS_PROXY, "http://user:p$ss@proxy.example:8080");
    assert.equal(env.CODEX_HOME, "/dir/café/$USER");
    assert.equal(env.USER, null);
    assert.equal(env.HTTP_PROXY, null);
  });
});
