import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const agyLimits = report => report.programs.find(program => program.program === "agy").usageLimits;

function fixture(t, initialMode = "success", { herdr = false, inAntigravityBin = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), "heeler-agy-limits-"));
  const bin = join(root, "bin");
  const home = join(root, "home");
  const env = {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: home,
    USER: "herdr-account",
    CLAUDE_CONFIG_DIR: join(root, "claude-home"),
    CODEX_HOME: join(root, "codex-home"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"),
    HERDR_PLUGIN_STATE_DIR: join(root, "state"),
    HERDR_BIN_PATH: herdr ? join(bin, "herdr") : "/missing",
  };
  mkdirSync(bin, { recursive: true });
  mkdirSync(home, { recursive: true });
  symlinkSync(process.execPath, join(bin, "node"));
  writeFileSync(join(bin, "security"), `#!/bin/sh
if [ "$1" = show-keychain-info ]; then echo checked >> "${root}/keychain-checks"; [ -e "${root}/keychain-locked" ] && exit 36; exit 0; fi
touch "${root}/credential-access"\nexit 1\n`, { mode: 0o755 });
  if (herdr) {
    writeFileSync(join(bin, "herdr"), `#!/bin/sh
printf '%s %s\\n' "$*" "\${HERDR_SOCKET_PATH:-none}" >> "${root}/herdr-invocations"
[ -e "${root}/herdr-refuses" ] && exit 1
HERDR_PLUGIN_CONFIG_DIR="${env.HERDR_PLUGIN_CONFIG_DIR}" "${process.execPath}" "${join(plugin, "src/usage-agy-action.js")}" </dev/null >/dev/null 2>&1 &
exit 0
`, { mode: 0o755 });
  }
  const mode = value => writeFileSync(join(root, "mode"), value);
  mode(initialMode);
  const now = Date.now();
  const setClock = time => writeFileSync(join(root, "clock"), String(time));
  setClock(now);
  const agyDir = inAntigravityBin ? join(home, ".antigravity", "bin") : bin;
  mkdirSync(agyDir, { recursive: true });
  const executable = join(agyDir, "agy");
  if (initialMode !== "missing") {
    writeFileSync(executable, `#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const root = ${JSON.stringify(root)};
if (process.argv[2] === '--version') {
  fs.appendFileSync(root + '/versions', 'checked\\n');
  const v = fs.existsSync(root + '/version') ? fs.readFileSync(root + '/version', 'utf8') : '1.1.11';
  process.stdout.write('agy ' + v + '\\n');
  process.exit(0);
}
assert.deepEqual(process.argv.slice(2), ['-p', '/usage', '--output-format', 'json']);
fs.appendFileSync(root + '/requests', 'usage\\n');
const m = fs.readFileSync(root + '/mode', 'utf8');
if (m === 'signed-out') {
  process.stdout.write(JSON.stringify({ status: 'ERROR', error: 'Not logged in. Please sign in to continue.' }) + '\\n');
  process.exit(1);
}
if (m === 'error') {
  process.stdout.write(JSON.stringify({ status: 'ERROR', error: 'Upstream failure' }) + '\\n');
  process.exit(1);
}
if (m === 'malformed') {
  process.stdout.write('not json\\n');
  process.exit(0);
}
if (m === 'no-plan') {
  process.stdout.write(JSON.stringify({ status: 'SUCCESS', command: { name: 'usage', data: { groups: [] } } }) + '\\n');
  process.exit(0);
}
const reset = new Date(Number(fs.readFileSync(root + '/clock')) + 3600_000).toISOString();
process.stdout.write(JSON.stringify({
  status: 'SUCCESS',
  command: {
    name: 'usage',
    data: {
      groups: [
        {
          name: 'Gemini Models',
          buckets: [
            { id: 'gemini_weekly', name: 'Weekly Limit Remaining', window: 'weekly', remaining_fraction: 0.65, reset_time: null },
            { id: 'gemini_5h', name: '5h Limit Remaining', window: '5h', remaining_fraction: 0.82, reset_time: reset },
          ],
        },
        {
          name: 'Claude and GPT Models',
          buckets: [
            { id: 'claude_5h', name: '5h Limit Remaining', window: '5h', remaining_fraction: 0.9, reset_time: reset },
          ],
        },
      ],
    },
  },
}) + '\\n');
`, { mode: 0o755 });
  }
  const hook = spawnSync(process.execPath, [join(plugin, "src/sidebar-hook.js")], { env, encoding: "utf8" });
  assert.equal(hook.status, 0, hook.stderr);
  const preload = join(root, "preload.mjs");
  writeFileSync(preload, `import fs from 'node:fs'; import { syncBuiltinESMExports } from 'node:module';
const root = ${JSON.stringify(root)}; const time = Number(fs.readFileSync(root + '/clock')); const OriginalDate = Date;
if (fs.existsSync(root + '/darwin')) Object.defineProperty(process, 'platform', { value: 'darwin' });
globalThis.Date = class extends OriginalDate { constructor(...args) { super(...(args.length ? args : [time])); } static now() { return time; } };
syncBuiltinESMExports();`);
  const node = join(root, "recorded-node");
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  writeFileSync(node, `#!/bin/sh\nexec ${quote(process.execPath)} --import ${quote(preload)} "$@"\n`, { mode: 0o755 });
  const runtimePath = join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  const runtime = JSON.parse(readFileSync(runtimePath, "utf8"));
  runtime.node = node;
  writeFileSync(runtimePath, JSON.stringify(runtime));
  writeFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime-node"), node + "\n");

  const query = (enabled = true) => {
    const result = spawnSync(node, [join(plugin, "src/usage-query.js"), "--tz", "UTC", ...(enabled ? [] : ["--no-agy-limits"])], {
      env, encoding: "utf8", timeout: 10_000,
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const finish = async (enabled = true) => {
    for (let i = 0; i < 300; i++) {
      const report = query(enabled);
      if (!report.refreshing) return report;
      await sleep(80);
    }
    assert.fail("worker did not finish");
  };
  const requests = () => existsSync(join(root, "requests")) ? readFileSync(join(root, "requests"), "utf8").trim().split("\n").filter(Boolean).length : 0;
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return { root, env, now, mode, setClock, query, finish, requests };
}

test("Antigravity limits are enabled by default, find ~/.antigravity/bin/agy, and sort 5-hour ahead of Weekly", async t => {
  const f = fixture(t, "success", { inAntigravityBin: true });
  const limits = agyLimits(await f.finish());
  assert.equal(limits.state, "ok");
  assert.equal(limits.source, "service");
  assert.deepEqual(limits.windows.map(w => [w.id, w.label, w.durationMinutes, w.usedPercent]), [
    ["agy:gemini_5h", "Gemini · 5-hour", 300, 18],
    ["agy:gemini_weekly", "Gemini · Weekly", 10080, 35],
    ["agy:claude_5h", "Claude & GPT · 5-hour", 300, 10],
  ]);
  assert.equal(f.requests(), 1);
  assert.equal(existsSync(join(f.root, "credential-access")), false);
});

test("--no-agy-limits starts no agy process and hides cached readings", async t => {
  const f = fixture(t);
  assert.equal(agyLimits(await f.finish(true)).state, "ok");
  assert.equal(f.requests(), 1);

  f.setClock(f.now + 61_000);
  const disabled = await f.finish(false);
  assert.deepEqual(agyLimits(disabled), { state: "disabled" });
  assert.equal(f.requests(), 1);
});

test("agy 1.1.10 and earlier report programTooOld without invoking -p /usage", async t => {
  const f = fixture(t);
  writeFileSync(join(f.root, "version"), "1.1.10");
  const limits = agyLimits(await f.finish());
  assert.deepEqual(limits, { state: "unavailable", reason: "programTooOld" });
  assert.equal(f.requests(), 0, "unsafe agy <= 1.1.10 must never run -p /usage");

  // Upgrading to 1.1.11 succeeds at the next 60-second cadence.
  writeFileSync(join(f.root, "version"), "1.1.11");
  f.setClock(f.now + 60_000);
  assert.equal(agyLimits(await f.finish()).state, "ok");
  assert.equal(f.requests(), 1);
});

test("missing, signed-out, and empty-bucket readings map to unavailable reasons", async t => {
  const missing = fixture(t, "missing");
  assert.deepEqual(agyLimits(await missing.finish()), { state: "unavailable", reason: "programMissing" });

  const signedOut = fixture(t, "signed-out");
  assert.deepEqual(agyLimits(await signedOut.finish()), { state: "unavailable", reason: "notSignedIn" });

  const noPlan = fixture(t, "no-plan");
  assert.deepEqual(agyLimits(await noPlan.finish()), { state: "unavailable", reason: "noPlanLimits" });
});

test("successful reads throttle for 60s and failed reads retain lastGood as throttled for 5 minutes", async t => {
  const f = fixture(t);
  assert.equal(agyLimits(await f.finish()).state, "ok");
  assert.equal(f.requests(), 1);

  f.setClock(f.now + 30_000);
  assert.equal(agyLimits(await f.finish()).state, "ok");
  assert.equal(f.requests(), 1);

  f.mode("error");
  f.setClock(f.now + 60_000);
  const throttled = agyLimits(await f.finish());
  assert.equal(throttled.state, "throttled");
  assert.equal(throttled.windows.length, 3);
  assert.equal(f.requests(), 2);

  f.setClock(f.now + 180_000);
  assert.equal(agyLimits(await f.finish()).state, "throttled");
  assert.equal(f.requests(), 2);

  f.mode("success");
  f.setClock(f.now + 360_000);
  assert.equal(agyLimits(await f.finish()).state, "ok");
  assert.equal(f.requests(), 3);
});

test("on macOS the read runs through usage-agy-limits and reports locked keychains", async t => {
  const server = fixture(t, "success", { herdr: true });
  writeFileSync(join(server.root, "darwin"), "yes");
  assert.equal(agyLimits(await server.finish()).state, "ok");
  assert.match(readFileSync(join(server.root, "herdr-invocations"), "utf8"), /plugin action invoke usage-agy-limits --plugin heeler/);

  const locked = fixture(t, "signed-out");
  writeFileSync(join(locked.root, "darwin"), "yes");
  writeFileSync(join(locked.root, "keychain-locked"), "yes");
  assert.deepEqual(agyLimits(await locked.finish()), { state: "unavailable", reason: "keychainUnavailable" });
});
