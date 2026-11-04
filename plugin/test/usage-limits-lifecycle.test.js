import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readCodexLimits } from "../src/usage/codex-limits.js";
import { readClaudeLimits } from "../src/usage/claude-limits.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const running = pid => {
  if (!alive(pid)) return false;
  // An orphan killed with its launcher can await the OS reaper on Linux.
  const status = spawnSync("/bin/ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" });
  return status.status === 0 && !status.stdout.trim().startsWith("Z");
};

function fixture(t, program, mode) {
  const root = mkdtempSync(join(tmpdir(), "heeler-limits-lifecycle-"));
  const executable = join(root, program);
  const descendant = join(root, "program.cjs");
  const pids = join(root, "pids.json");
  const sentinel = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  const sentinelClosed = new Promise(resolve => sentinel.once("close", resolve));
  writeFileSync(executable, `#!${process.execPath}
const { spawn } = require('node:child_process');
const child = spawn(process.execPath, [${JSON.stringify(descendant)}], { stdio: 'inherit' });
require('node:fs').writeFileSync(${JSON.stringify(pids)}, JSON.stringify({ launcher: process.pid, descendant: child.pid }));
if (${JSON.stringify(mode)} === 'launcher-exit') setTimeout(() => process.exit(1), 200);
`, { mode: 0o700 });
  writeFileSync(descendant, `
const program = ${JSON.stringify(program)};
const mode = ${JSON.stringify(mode)};
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
// Keep inherited stdout and stderr open even after stdin EOF or a killed launcher.
setInterval(() => {}, 1000);
require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
  const request = JSON.parse(line);
  if (mode === 'malformed') { process.stdout.write('not json\\n'); return; }
  if (mode === 'oversized') { process.stdout.write(' '.repeat(1024 * 1024 + 1)); return; }
  if (program === 'codex') {
    if (request.method === 'initialize') send({ id: request.id, result: {} });
    else if (request.method === 'account/read') send({ id: request.id, result: { account: { type: 'chatgpt' } } });
    else if (request.method === 'account/rateLimits/read' && mode === 'success')
      send({ id: request.id, result: { rateLimits: { primary: { usedPercent: 12 } } } });
  } else if (request.request.subtype === 'initialize')
    send({ type: 'control_response', response: { request_id: request.request_id, subtype: 'success', response: {} } });
  else if (mode === 'success')
    send({ type: 'control_response', response: { request_id: request.request_id, subtype: 'success',
      response: { rate_limits_available: true, rate_limits: { five_hour: { utilization: 12, resets_at: null } } } } });
});
`);
  let request;
  t.after(async () => {
    try {
      const ids = JSON.parse(readFileSync(pids));
      for (const pid of [ids.descendant, ids.launcher]) if (alive(pid)) process.kill(pid, "SIGKILL");
    } catch { /* The fixture may fail before launching. */ }
    sentinel.kill("SIGKILL");
    await sentinelClosed;
    if (request) await request;
    rmSync(root, { recursive: true, force: true });
  });
  return {
    pids: () => JSON.parse(readFileSync(pids)),
    sentinel: sentinel.pid,
    read: () => {
      const read = program === "codex" ? readCodexLimits : readClaudeLimits;
      request = read({ [program]: executable, env: { PATH: "/usr/bin:/bin", HOME: root } }, root);
      return request;
    },
  };
}

for (const program of ["codex", "claude"]) for (const mode of ["success", "timeout", "launcher-exit", "malformed", "oversized"]) {
test(`${program} ${mode} reaps its npm launcher and terminates the inherited-stdio program`, async t => {
  const f = fixture(t, program, mode);
  const start = performance.now();
  let deadline;
  const result = await Promise.race([f.read(), new Promise(resolve => {
    deadline = setTimeout(() => resolve(null), mode === "timeout" ? 17_000 : 5000);
  })]);
  clearTimeout(deadline);
  assert.notEqual(result, null, "reader exceeded its completion deadline");
  if (mode === "success") {
    assert.equal(result.state, "ok");
    assert.equal(result.windows[0].usedPercent, 12);
  } else {
    const reason = mode === "timeout" ? "timeout" : mode === "launcher-exit" ? "requestFailed" : "invalidResponse";
    assert.deepEqual(result, { state: "error", reason });
    if (mode === "timeout") assert.ok(performance.now() - start >= 14_500, "the real 15-second request deadline must be exercised");
  }
  const ids = f.pids();
  assert.equal(alive(ids.launcher), false, "direct child must already be reaped");
  for (let i = 0; i < 100 && running(ids.descendant); i++) await sleep(10);
  assert.equal(running(ids.descendant), false, "owned descendant must terminate");
  assert.equal(alive(f.sentinel), true, "another process outside the reader must survive");
});
}
