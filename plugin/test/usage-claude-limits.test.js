import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, symlinkSync, existsSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { cacheClaudeLimits, claudeLimitsEntries } from "../src/usage/claude-limits.js";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const reading = report => report.programs.find(program => program.program === "claude").usageLimits;
function fixture(t, initialMode = "success", { herdr = false, configDir = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "heeler-claude-limits-"));
  const bin = join(root, "bin");
  const env = { PATH: `${bin}:/usr/bin:/bin`, HOME: join(root, "home"), USER: "herdr-account",
    ...(configDir ? { CLAUDE_CONFIG_DIR: join(root, "claude-home") } : {}),
    CODEX_HOME: join(root, "codex-home"), HERDR_PLUGIN_CONFIG_DIR: join(root, "config"),
    HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: herdr ? join(bin, "herdr") : "/missing",
    HTTPS_PROXY: "http://proxy.invalid:3128", NODE_EXTRA_CA_CERTS: join(root, "ca.pem") };
  mkdirSync(bin, { recursive: true });
  symlinkSync(process.execPath, join(bin, "node"));
  // Asking for the keychain's settings is allowed; reading any item is not.
  writeFileSync(join(bin, "security"), `#!/bin/sh
if [ "$1" = show-keychain-info ]; then echo checked >> "${root}/keychain-checks"; [ -e "${root}/keychain-locked" ] && exit 36; exit 0; fi
touch "${root}/credential-access"\nexit 1\n`, { mode: 0o755 });
  // Like herdr's server, run the action in the background with the plugin's config directory.
  if (herdr) writeFileSync(join(bin, "herdr"), `#!/bin/sh
printf '%s %s\\n' "$*" "\${HERDR_SOCKET_PATH:-none}" >> "${root}/herdr-invocations"
[ -e "${root}/herdr-refuses" ] && exit 1
HERDR_PLUGIN_CONFIG_DIR="${env.HERDR_PLUGIN_CONFIG_DIR}" "${process.execPath}" "${join(plugin, "src/usage-claude-action.js")}" </dev/null >/dev/null 2>&1 &
exit 0
`, { mode: 0o755 });
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
if(process.argv[2]==='--version'){fs.appendFileSync(root+'/versions','checked\\n');process.stdout.write((fs.existsSync(root+'/version')?fs.readFileSync(root+'/version','utf8'):'2.1.309')+' (Claude Code)\\n');process.exit(0);}
assert.deepEqual(process.argv.slice(2), ['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--no-session-persistence','--strict-mcp-config','--settings','{"disableAllHooks":true}']);
// Each request records the Account directory it ran with; an Account may override the mode.
const configDir=process.env.CLAUDE_CONFIG_DIR??null;
assert.equal(process.env.HOME,${JSON.stringify(env.HOME)});
assert.equal(process.env.USER,${JSON.stringify(env.USER)}, 'Claude must receive the recorded keychain account');
assert.equal(process.env.HTTPS_PROXY,${JSON.stringify(env.HTTPS_PROXY)});
assert.equal(process.env.NODE_EXTRA_CA_CERTS,${JSON.stringify(env.NODE_EXTRA_CA_CERTS)});
assert.ok(fs.realpathSync(process.cwd()).startsWith(fs.realpathSync(${JSON.stringify(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))})));
fs.appendFileSync(root+'/starts',String(process.pid)+'\\n');
const send=response=>process.stdout.write(JSON.stringify({type:'control_response',response})+'\\n');
let initialized=false;
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const request=JSON.parse(line); fs.appendFileSync(root+'/requests',JSON.stringify({...request,configDir})+'\\n');
 assert.equal(request.type,'control_request');
 if(request.request.subtype==='initialize') {assert.equal(initialized,false); initialized=true; send({request_id:request.request_id,subtype:'success',response:{}});return;}
 assert.equal(initialized,true);assert.deepEqual(request.request,{subtype:'get_usage',skip_behaviors:true});
 const mode=fs.readFileSync(configDir&&fs.existsSync(configDir+'/stub-mode')?configDir+'/stub-mode':root+'/mode','utf8');
 if(mode==='timeout'||mode==='silent')return;
 if(mode==='error'||mode==='old')return send({request_id:request.request_id,subtype:'error',error:mode==='old'?'Unsupported control request subtype: get_usage':'private failure'});
 const reset=new Date(Number(fs.readFileSync(root+'/clock'))+30000).toISOString();
 const response={subscription_type:'max',rate_limits_available:mode!=='no-plan',rate_limits:{
 five_hour:{utilization:12,resets_at:reset}, seven_day:{utilization:23,resets_at:null},
 seven_day_opus:{utilization:null,resets_at:reset},seven_day_sonnet:{utilization:34,resets_at:Math.floor(Date.parse(reset)/1000)},
 future_window:{utilization:45,resets_at:null,label:'Future window'},code_named:{utilization:60,resets_at:reset,limit_dollars:250},model_scoped:[{display_name:'model-x',utilization:56,resets_at:reset}],
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
if(fs.existsSync(root+'/darwin'))Object.defineProperty(process,'platform',{value:'darwin'});
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
  const query = (enabled = true, extra = {}) => {
    const result = spawnSync(node, [join(plugin, "src/usage-query.js"), "--tz", "UTC", ...(enabled ? ["--claude-limits"] : [])], {
      env: { HERDR_PLUGIN_CONFIG_DIR: env.HERDR_PLUGIN_CONFIG_DIR, HOME: join(root, "wrong-home"), USER: "ssh-account", PATH: "/usr/bin:/bin", ...extra }, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const finish = async (enabled = true, extra = {}) => { for (let i = 0; i < 500; i++) { const report = query(enabled, extra); if (!report.refreshing) return report; await sleep(25); } assert.fail("worker did not finish"); };
  const requests = () => existsSync(join(root, "requests")) ? readFileSync(join(root, "requests"), "utf8").trim().split("\n").map(JSON.parse) : [];
  t.after(() => { try { process.kill(JSON.parse(readFileSync(join(cache(), "worker.lock"))).pid, "SIGKILL"); } catch {} rmSync(root, { recursive: true, force: true }); });
  const versions = () => existsSync(join(root, "versions")) ? readFileSync(join(root, "versions"), "utf8").trim().split("\n").length : 0;
  const accounts = entries => writeFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "usage-accounts.json"),
    JSON.stringify({ version: 1, claude: { defaultName: null, accounts: entries } }));
  const limits = () => JSON.parse(readFileSync(join(cache(), "limits.json")));
  return { root, env, now, mode, setClock, query, finish, requests, cache, executable, versions, accounts, limits };
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
  assert.equal(result.windows[3].label, "Future window");
  assert.equal(result.windows[4].label, "model-x");
  assert.equal(existsSync(join(f.root, "credential-access")), false);
  assert.deepEqual(f.requests().map(request => request.request.subtype), ["initialize", "get_usage"]);
  // The Default Account keeps the recorded CLAUDE_CONFIG_DIR.
  assert.deepEqual(f.requests().map(request => request.configDir), [f.env.CLAUDE_CONFIG_DIR, f.env.CLAUDE_CONFIG_DIR]);
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
    const cache = f.limits();
    assert.equal(cache.claude.default.nextAllowedAt, f.now + (state === "error" ? 300_000 : 60_000));
    assert.equal(JSON.stringify(cache).includes("private failure"), false);
  });
}

test("on macOS the read runs in herdr's session through the plugin action", async t => {
  const f = fixture(t, "success", { herdr: true });
  writeFileSync(join(f.root, "darwin"), "");
  const result = reading(await f.finish(true, { HERDR_SOCKET_PATH: "/tmp/herdr-test.sock" }));
  assert.equal(result.state, "ok");
  assert.equal(result.plan, "max");
  assert.deepEqual(readFileSync(join(f.root, "herdr-invocations"), "utf8").trim().split("\n"),
    ["plugin action invoke usage-claude-limits --plugin heeler /tmp/herdr-test.sock"]);
  assert.deepEqual(f.requests().map(request => request.request.subtype), ["initialize", "get_usage"]);
  assert.equal(existsSync(join(f.cache(), "claude-request.json")), false);
});

test("on macOS a herdr that cannot invoke the action leaves the read in place", async t => {
  const f = fixture(t, "success", { herdr: true });
  writeFileSync(join(f.root, "darwin"), "");
  writeFileSync(join(f.root, "herdr-refuses"), "");
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(readFileSync(join(f.root, "herdr-invocations"), "utf8").trim().split("\n").length, 1);
  assert.equal(existsSync(join(f.cache(), "claude-request.json")), false);
});

test("on macOS a keychain this session cannot use is reported instead of missing plan limits", async t => {
  const f = fixture(t, "no-plan");
  writeFileSync(join(f.root, "darwin"), "");
  writeFileSync(join(f.root, "keychain-locked"), "");
  assert.deepEqual(reading(await f.finish()), { state: "unavailable", reason: "keychainUnavailable" });
  assert.equal(existsSync(join(f.root, "credential-access")), false);
});

test("on macOS a usable keychain keeps an answer without plan limits", async t => {
  const f = fixture(t, "no-plan");
  writeFileSync(join(f.root, "darwin"), "");
  assert.deepEqual(reading(await f.finish()), { state: "unavailable", reason: "noPlanLimits" });
  assert.equal(existsSync(join(f.root, "keychain-checks")), true);
  assert.equal(existsSync(join(f.root, "credential-access")), false);
});

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
  const midway = f.query();
  assert.equal(midway.refreshing, true);
  // Limits are read after the scan; until then neither program is reported missing.
  for (const program of midway.programs) assert.deepEqual(program.usageLimits, { state: "unavailable", reason: "notReadYet" });
  assert.deepEqual(reading(f.query(false)), { state: "disabled" });
  assert.equal(f.requests().length, 0);
  rmSync(join(f.root, "hold"));
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.requests().length, 2);
});

test("an answer without plan limits drops the last good reading before a later failure", () => {
  const good = { state: "ok", source: "service", observedAt: "2026-10-23T12:00:00.000Z", plan: "max", windows: [] };
  let cache = cacheClaudeLimits(undefined, good, 0);
  assert.equal(cacheClaudeLimits(cache, { state: "error", reason: "timeout" }, 1).report.state, "throttled");
  cache = cacheClaudeLimits(cache, { state: "unavailable", reason: "noPlanLimits" }, 1);
  assert.equal(Object.hasOwn(cache, "lastGood"), false);
  cache = cacheClaudeLimits(cache, { state: "error", reason: "timeout" }, 2);
  assert.deepEqual(cache.report, { state: "error", reason: "timeout" });
  assert.equal(Object.hasOwn(cache, "lastGood"), false);
});

test("a Claude Code that leaves unknown requests unanswered is too old without a timeout", async t => {
  const f = fixture(t, "silent");
  writeFileSync(join(f.root, "version"), "2.1.12");
  const started = Date.now();
  assert.deepEqual(reading(await f.finish()), { state: "unavailable", reason: "programTooOld" });
  assert.ok(Date.now() - started < 10_000);
  assert.deepEqual(f.requests(), []);
  assert.equal(f.versions(), 1);
  // A too-old version is asked again at each allowed request, still without a stream-json process.
  f.setClock(f.now + 60_000);
  assert.deepEqual(reading(await f.finish()), { state: "unavailable", reason: "programTooOld" });
  assert.equal(f.versions(), 2);
  assert.deepEqual(f.requests(), []);
  // The stub stands in for a shim or wrapper: an update behind it leaves the
  // recorded file unchanged and is still picked up at the next allowed request.
  writeFileSync(join(f.root, "version"), "2.1.309");
  f.mode("success");
  f.setClock(f.now + 120_000);
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.versions(), 3);
  // A version that supports get_usage is asked once per installed executable.
  f.setClock(f.now + 180_000);
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.versions(), 3);
  appendFileSync(f.executable, "// updated\n");
  f.setClock(f.now + 240_000);
  assert.equal(reading(await f.finish()).state, "ok");
  assert.equal(f.versions(), 4);
});

const claudeAccountsOf = report => report.programs.find(program => program.program === "claude").accounts;
const accountLimits = report => claudeAccountsOf(report).map(account => account.usageLimits);
function withAccount(f) {
  const directory = join(f.root, "claude-2");
  mkdirSync(directory);
  f.accounts([{ id: "second-id", directory, name: "claude-2" }, { id: "gone-id1", directory: join(f.root, "gone"), name: "gone" }]);
  return directory;
}

test("an added Account reads with its own CLAUDE_CONFIG_DIR and the Default Account with none, after one version check", async t => {
  const f = fixture(t, "success", { configDir: false });
  const second = withAccount(f);
  const report = await f.finish();
  assert.deepEqual(f.requests().map(request => [request.request.subtype, request.configDir]),
    [["initialize", null], ["get_usage", null], ["initialize", second], ["get_usage", second]]);
  assert.equal(f.versions(), 1);
  assert.deepEqual(accountLimits(report).map(limits => limits?.state), ["ok", "ok", undefined]);
  // The program's reading stays the Default Account's.
  assert.deepEqual(reading(report), accountLimits(report)[0]);
  assert.deepEqual(Object.keys(f.limits().claude), ["default", "second-id"]);
  // An Account that leaves takes its throttle and readings out of limits.json.
  f.accounts([]);
  assert.deepEqual(claudeAccountsOf(await f.finish()).map(account => account.id), ["default"]);
  assert.deepEqual(Object.keys(f.limits().claude), ["default"]);
  assert.equal(f.requests().length, 4);
});

test("an added ~/.claude is read without CLAUDE_CONFIG_DIR, as a plain claude signs in there", async t => {
  const f = fixture(t, "success", { herdr: true });
  writeFileSync(join(f.root, "darwin"), "");
  const home = join(f.env.HOME, ".claude");
  mkdirSync(home, { recursive: true });
  f.accounts([{ id: "home-dir", directory: home, name: "claude" }]);
  assert.deepEqual(accountLimits(await f.finish()).map(limits => limits.state), ["ok", "ok"]);
  // The Default Account keeps the recorded variable; the added ~/.claude runs without one.
  assert.deepEqual(f.requests().map(request => request.configDir), [f.env.CLAUDE_CONFIG_DIR, f.env.CLAUDE_CONFIG_DIR, null, null]);
});

test("each Account keeps its own throttle, back-off and last good reading", async t => {
  const f = fixture(t, "success", { configDir: false });
  const second = withAccount(f);
  writeFileSync(join(second, "stub-mode"), "error");
  const reads = () => f.requests().filter(request => request.request.subtype === "get_usage").map(request => request.configDir);
  const nextRead = () => JSON.parse(readFileSync(join(f.cache(), "buckets.json"))).nextClaudeLimitsAt;
  let [primary, added] = accountLimits(await f.finish());
  assert.equal(primary.state, "ok");
  // The Default Account's reading is not the failed Account's last good one.
  assert.deepEqual(added, { state: "error", reason: "requestFailed" });
  assert.deepEqual(reads(), [null, second]);
  assert.equal(nextRead(), f.now + 60_000);
  // The Default Account is read again after a minute while the other backs off for five.
  f.setClock(f.now + 60_000);
  await f.finish();
  assert.deepEqual(reads(), [null, second, null]);
  assert.equal(nextRead(), f.now + 120_000);
  writeFileSync(join(second, "stub-mode"), "success");
  f.setClock(f.now + 300_000);
  [primary, added] = accountLimits(await f.finish());
  assert.deepEqual(reads(), [null, second, null, null, second]);
  assert.equal(added.state, "ok");
  writeFileSync(join(second, "stub-mode"), "error");
  f.setClock(f.now + 360_000);
  [primary, added] = accountLimits(await f.finish());
  assert.deepEqual(reads(), [null, second, null, null, second, null, second]);
  assert.equal(primary.state, "ok");
  assert.equal(added.state, "throttled");
  assert.equal(added.observedAt, new Date(f.now + 300_000).toISOString());
  assert.equal(added.retryAt, new Date(f.now + 660_000).toISOString());
});

test("on macOS each Account is read through the action, which refuses a directory the Account file does not list", async t => {
  const f = fixture(t, "success", { herdr: true, configDir: false });
  writeFileSync(join(f.root, "darwin"), "");
  const second = withAccount(f);
  assert.deepEqual(accountLimits(await f.finish()).map(limits => limits?.state), ["ok", "ok", undefined]);
  assert.equal(readFileSync(join(f.root, "herdr-invocations"), "utf8").trim().split("\n").length, 2);
  assert.deepEqual(f.requests().map(request => request.configDir), [null, null, second, second]);
  const answer = directory => {
    writeFileSync(join(f.cache(), "claude-request.json"), JSON.stringify({ token: "refused", version: null, directory }));
    const result = spawnSync(process.execPath, [join(plugin, "src/usage-claude-action.js")], {
      env: { HERDR_PLUGIN_CONFIG_DIR: f.env.HERDR_PLUGIN_CONFIG_DIR, PATH: "/usr/bin:/bin" }, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(readFileSync(join(f.cache(), "claude-reading.json")));
  };
  mkdirSync(join(f.root, "unlisted"));
  // An unlisted directory, a listed one that is not ok, and the Default Account's own directory by name.
  for (const directory of [join(f.root, "unlisted"), join(f.root, "gone"), join(f.env.HOME, ".claude")]) {
    assert.deepEqual(answer(directory), { token: "refused", reading: { state: "error", reason: "requestFailed" } });
  }
  assert.equal(existsSync(join(f.cache(), "claude-request.json")), false);
  assert.equal(f.requests().length, 4);
});

test("a query without --claude-limits reports every Account's limits as disabled", async t => {
  const f = fixture(t, "success", { configDir: false });
  withAccount(f);
  const disabled = [{ state: "disabled" }, { state: "disabled" }, undefined];
  assert.deepEqual(accountLimits(await f.finish(false)), disabled);
  assert.equal(f.requests().length, 0);
  assert.deepEqual(accountLimits(await f.finish()).map(limits => limits?.state), ["ok", "ok", undefined]);
  // Readings another device's query cached stay hidden.
  assert.deepEqual(accountLimits(f.query(false)), disabled);
});

test("limits.json keeps entries for counted Accounts only and drops a 0.7.x entry for the Host", () => {
  const accounts = [{ id: "default" }, { id: "second-id" }];
  const entry = { report: { state: "ok" }, nextAllowedAt: 1 };
  assert.deepEqual(claudeLimitsEntries({ default: entry, "second-id": entry, "gone-id1": entry }, accounts), { default: entry, "second-id": entry });
  // "lastGood" is a valid Account id, so the old shape is told apart by its number.
  assert.deepEqual(claudeLimitsEntries({ ...entry, lastGood: { state: "ok" }, version: {} }, [...accounts, { id: "lastGood" }]), {});
  assert.deepEqual(claudeLimitsEntries(undefined, accounts), {});
});
