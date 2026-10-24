import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, symlinkSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const reading = report => report.programs.find(program => program.program === "claude").usageLimits;
function fixture(t, initialMode = "success") {
  const root = mkdtempSync(join(tmpdir(), "heeler-claude-limits-"));
  const bin = join(root, "bin");
  const env = { PATH: `${bin}:/usr/bin:/bin`, HOME: join(root, "home"), USER: "herdr-account", CLAUDE_CONFIG_DIR: join(root, "claude-home"),
    CODEX_HOME: join(root, "codex-home"), HERDR_PLUGIN_CONFIG_DIR: join(root, "config"),
    HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  mkdirSync(bin, { recursive: true });
  symlinkSync(process.execPath, join(bin, "node"));
  writeFileSync(join(bin, "security"), `#!/bin/sh\ntouch "${root}/credential-access"\nexit 1\n`, { mode: 0o755 });
  const mode = value => writeFileSync(join(root, "mode"), value);
  mode(initialMode);
  const now = Date.now();
  const setClock = time => writeFileSync(join(root, "clock"), String(time));
  setClock(now);
  const executable = join(bin, "claude");
  if (initialMode !== "missing") writeFileSync(executable, `#!/usr/bin/env node
const assert=require('node:assert/strict');
const fs=require('node:fs');
const root=${JSON.stringify(root)};
assert.deepEqual(process.argv.slice(2), ['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--no-session-persistence','--strict-mcp-config','--settings','{"disableAllHooks":true}']);
assert.equal(process.env.CLAUDE_CONFIG_DIR,${JSON.stringify(env.CLAUDE_CONFIG_DIR)});
assert.equal(process.env.HOME,${JSON.stringify(env.HOME)});
assert.equal(process.env.USER,${JSON.stringify(env.USER)}, 'Claude must receive the recorded keychain account');
assert.ok(fs.realpathSync(process.cwd()).startsWith(fs.realpathSync(${JSON.stringify(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))})));
fs.appendFileSync(root+'/starts',String(process.pid)+'\\n');
const send=response=>process.stdout.write(JSON.stringify({type:'control_response',response})+'\\n');
let initialized=false;
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const request=JSON.parse(line); fs.appendFileSync(root+'/requests',line+'\\n');
 assert.equal(request.type,'control_request');
 if(request.request.subtype==='initialize') {assert.equal(initialized,false); initialized=true; send({request_id:request.request_id,subtype:'success',response:{}});return;}
 assert.equal(initialized,true);assert.deepEqual(request.request,{subtype:'get_usage',skip_behaviors:true});
 const mode=fs.readFileSync(root+'/mode','utf8');
 if(mode==='timeout')return;
 if(mode==='error'||mode==='old')return send({request_id:request.request_id,subtype:'error',error:mode==='old'?'Unsupported control request subtype: get_usage':'private failure'});
 const reset=new Date(Number(fs.readFileSync(root+'/clock'))+30000).toISOString();
 const response={subscription_type:'max',rate_limits_available:mode!=='no-plan',rate_limits:{
 five_hour:{utilization:12,resets_at:reset}, seven_day:{utilization:23,resets_at:null},
 seven_day_opus:{utilization:null,resets_at:reset},seven_day_sonnet:{utilization:34,resets_at:Math.floor(Date.parse(reset)/1000)},
 future_window:{utilization:45,resets_at:null},model_scoped:[{display_name:'model-x',utilization:56,resets_at:reset}],
 extra_usage:{utilization:99,resets_at:reset,used_credits:123},spend:123}};
 if(mode==='malformed')delete response.rate_limits;
 send({request_id:request.request_id,subtype:'success',response});
});
`, { mode: 0o755 });
  const hook = spawnSync(process.execPath, [join(plugin, "src/sidebar-hook.js")], { env, encoding: "utf8" });
  assert.equal(hook.status, 0, hook.stderr);
  // The fixture owns the process clock and scan barrier. Production receives no test switches.
  const preload = join(root, "preload.mjs");
  writeFileSync(preload, `import fs from 'node:fs';import {syncBuiltinESMExports} from 'node:module';import {Readable} from 'node:stream';
const root=${JSON.stringify(root)}; const time=Number(fs.readFileSync(root+'/clock')); const OriginalDate=Date;
globalThis.Date=class extends OriginalDate {constructor(...args){super(...(args.length?args:[time]));}static now(){return time;}};
const original=fs.createReadStream;
fs.createReadStream=function(path,...args){const stream=original.call(this,path,...args);if(String(path).endsWith('.jsonl')&&fs.existsSync(root+'/hold'))return Readable.from((async function*(){fs.writeFileSync(root+'/held','yes');while(fs.existsSync(root+'/hold'))await new Promise(r=>setTimeout(r,10));yield* stream;})());return stream;};
const read=fs.readFileSync;fs.readFileSync=function(path,...args){if(String(path).endsWith('.credentials.json')){fs.writeFileSync(root+'/credential-access','read');throw new Error('credential access forbidden');}return read.call(this,path,...args);};syncBuiltinESMExports();`);
  const node = join(root, "recorded-node");
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  writeFileSync(node, `#!/bin/sh\nexec ${quote(process.execPath)} --import ${quote(preload)} "$@"\n`, { mode: 0o755 });
  const runtimePath = join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  const runtime = JSON.parse(readFileSync(runtimePath)); runtime.node = node;
  writeFileSync(runtimePath, JSON.stringify(runtime));
  writeFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime-node"), node + "\n");
  const query = (enabled = true) => {
    const result = spawnSync(node, [join(plugin, "src/usage-query.js"), "--tz", "UTC", ...(enabled ? ["--claude-limits"] : [])], {
      env: { HERDR_PLUGIN_CONFIG_DIR: env.HERDR_PLUGIN_CONFIG_DIR, HOME: join(root, "wrong-home"), USER: "ssh-account", PATH: "/usr/bin:/bin" }, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const finish = async (enabled = true) => { for (let i = 0; i < 500; i++) { const report = query(enabled); if (!report.refreshing) return report; await sleep(25); } assert.fail("worker did not finish"); };
  const requests = () => existsSync(join(root, "requests")) ? readFileSync(join(root, "requests"), "utf8").trim().split("\n").map(JSON.parse) : [];
  t.after(() => { try { process.kill(JSON.parse(readFileSync(join(cache(), "worker.lock"))).pid, "SIGKILL"); } catch {} rmSync(root, { recursive: true, force: true }); });
  return { root, env, now, mode, setClock, query, finish, requests, cache, executable };
}

test("Claude limits use the recorded process with only initialize and get_usage", async t => {
  const f = fixture(t);
  const result = reading(await f.finish());
  assert.equal(result.state, "ok");
  assert.equal(result.plan, "max");
  assert.equal(result.source, "service");
  assert.deepEqual(result.windows.map(window => [window.id, window.usedPercent, window.durationMinutes]), [
    ["fiveHour",12,300],["sevenDay",23,10080],["sevenDaySonnet",34,10080],["claude:future_window",45,null],["claude:model:model-x",56,null],
  ]);
  assert.equal(result.windows[1].resetsAt, null);
  assert.equal(result.windows[4].label, "model-x");
  assert.equal(existsSync(join(f.root, "credential-access")), false);
  assert.deepEqual(f.requests().map(request => request.request.subtype), ["initialize", "get_usage"]);
});

test("disabled queries start no Claude process and hide another device's cached reading", async t => {
  const f = fixture(t);
  assert.deepEqual(reading(await f.finish(false)), { state: "disabled" });
  assert.equal(f.requests().length, 0);
  assert.equal(reading(await f.finish()).state, "ok");
  assert.deepEqual(reading(f.query(false)), { state: "disabled" });
  assert.equal(f.requests().length, 2);
});

for (const [mode, state, reason] of [["missing", "unavailable", "programMissing"], ["no-plan", "unavailable", "noPlanLimits"],
  ["old", "unavailable", "programTooOld"], ["error", "error", "requestFailed"], ["malformed", "error", "invalidResponse"], ["timeout", "error", "timeout"]]) {
  test(`${mode} produces a filtered Claude result and the required retry cadence`, async t => {
    const f = fixture(t, mode);
    const result = reading(await f.finish());
    assert.deepEqual(result, { state, reason });
    const cache = JSON.parse(readFileSync(join(f.cache(), "limits.json")));
    assert.equal(cache.claude.nextAllowedAt, f.now + (state === "error" ? 300_000 : 60_000));
    assert.equal(JSON.stringify(cache).includes("private failure"), false);
  });
}

test("successful reads are limited to one get_usage per sixty seconds", async t => {
  const f = fixture(t);
  await f.finish();
  f.setClock(f.now + 59_999);
  await f.finish();
  assert.equal(f.requests().length, 2);
  f.setClock(f.now + 60_000);
  await f.finish();
  assert.equal(f.requests().length, 4);
});

test("old Claude can be upgraded at the next normal cadence", async t => {
  const f = fixture(t, "old");
  await f.finish();
  f.mode("success");
  f.setClock(f.now + 60_000);
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.requests().length, 4);
});

test("failed reads retain the last good reading and back off for five minutes", async t => {
  const f = fixture(t);
  const good = reading(await f.finish());
  f.mode("error");
  f.setClock(f.now + 60_000);
  const failed = reading(await f.finish());
  assert.equal(failed.state, "throttled");
  assert.equal(failed.observedAt, good.observedAt);
  assert.equal(failed.windows[1].usedPercent, good.windows[1].usedPercent);
  assert.equal(failed.retryAt, new Date(f.now + 360_000).toISOString());
  assert.equal(failed.windows[0].expired, true);
  assert.equal(failed.windows[0].usedPercent, null);
  f.mode("success");
  f.setClock(f.now + 359_999);
  assert.equal(reading(await f.finish()).state, "throttled");
  assert.equal(f.requests().length, 4);
  f.setClock(f.now + 360_000);
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.requests().length, 6);
});

test("cached windows expire per query and null reset windows stay current", async t => {
  const f = fixture(t);
  await f.finish();
  f.setClock(f.now + 30_001);
  const limits = reading(f.query());
  assert.equal(limits.windows[0].expired, true);
  assert.equal(limits.windows[0].usedPercent, null);
  assert.equal(limits.windows[1].expired, false);
  assert.equal(limits.windows[1].usedPercent, 23);
  assert.equal(f.requests().length, 2);
});

test("opting in during a disabled worker schedules Claude after that worker finishes", async t => {
  const f = fixture(t);
  const directory = join(f.env.CLAUDE_CONFIG_DIR, "projects", "one");
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "session.jsonl"), JSON.stringify({ type: "system" }) + "\n");
  writeFileSync(join(f.root, "hold"), "hold");
  assert.equal(f.query(false).refreshing, true);
  for (let i = 0; i < 100 && !existsSync(join(f.root, "held")); i++) await sleep(10);
  assert.equal(existsSync(join(f.root, "held")), true);
  assert.equal(f.query().refreshing, true);
  assert.equal(f.requests().length, 0);
  rmSync(join(f.root, "hold"));
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.requests().length, 2);
});
