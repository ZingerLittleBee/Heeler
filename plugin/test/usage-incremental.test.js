import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, appendFileSync, chmodSync, realpathSync, renameSync, utimesSync, statSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const records = lines => lines.map(line => JSON.stringify(line)).join("\n") + "\n";
const assistant = (id, input, extra = {}) => ({ type: "assistant", sessionId: "one", requestId: `req-${id}`,
  timestamp: new Date().toISOString(), cwd: "/work/é", message: { id, model: "claude-test", usage: { input_tokens: input } }, ...extra });
const tokens = (report, program = "claude") => report.programs.find(p => p.program === program).tokenUsage.totals?.last30Days.tokens.total || 0;
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-incremental-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"), CODEX_HOME: join(root, "codex"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const run = (name, args = []) => spawnSync(process.execPath, [join(plugin, "src", name), ...args], { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  // Instrument only the child process's filesystem boundary. Production sees no test switch.
  const trace = join(root, "reads.jsonl");
  const preload = join(root, "trace.mjs");
  writeFileSync(preload, `
import fs from 'node:fs';
import {syncBuiltinESMExports} from 'node:module';
import {Readable} from 'node:stream';
const root=${JSON.stringify(root)};
const clockPath=root+'/clock.json';
if(fs.existsSync(clockPath)) {
  const time=JSON.parse(fs.readFileSync(clockPath));
  const OriginalDate=Date;
  globalThis.Date=class extends OriginalDate {
    constructor(...args){super(...(args.length?args:[time]));}
    static now(){return time;}
  };
}
const append=fs.appendFileSync;
const rename=fs.renameSync;
function crash(point) {
  if(!fs.existsSync(root+'/fault.json'))return;
  const wanted=JSON.parse(fs.readFileSync(root+'/fault.json'));
  if(wanted!==point)return;
  fs.writeFileSync(root+'/fault-reached',String(process.pid));
  process.kill(process.pid,'SIGKILL');
}
fs.appendFileSync=function(path,data,...args) {
  const result=append.call(this,path,data,...args);
  if(String(path).endsWith('/keys.log')&&String(data).includes('"tokens"'))crash('keys');
  return result;
};
fs.renameSync=function(from,to) {
  const result=rename.call(this,from,to);
  if(String(to).endsWith('/files.json'))crash('files');
  return result;
};
const original=fs.createReadStream;
fs.createReadStream=function(path,options) {
  const transcript=String(path).endsWith('.jsonl')||String(path).endsWith('.zst');
  if(transcript)append(${JSON.stringify(trace)},JSON.stringify({path:String(path),start:options?.start||0})+'\\n');
  const stream=original.call(this,path,options);
  if(transcript&&fs.existsSync(root+'/hold'))return Readable.from((async function*(){
    fs.writeFileSync(root+'/read-started','ready');
    while(fs.existsSync(root+'/hold'))await new Promise(resolve=>setTimeout(resolve,10));
    yield* stream;
  })());
  return stream;
};
syncBuiltinESMExports();
`);
  const node = join(root, "recorded-node");
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  writeFileSync(node, `#!/bin/sh\nexec ${quote(process.execPath)} --import ${quote(preload)} "$@"\n`);
  chmodSync(node, 0o700);
  const runtimePath = join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  const runtime = JSON.parse(readFileSync(runtimePath)); runtime.node = node;
  writeFileSync(runtimePath, JSON.stringify(runtime)); writeFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime-node"), node + "\n");
  let cachedDirectory;
  const cache = () => cachedDirectory ||= join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const query = () => { const r = spawnSync(node, [join(plugin, "src", "usage-query.js"), "--tz", "UTC"], { env, encoding: "utf8", timeout: 10_000 }); assert.equal(r.status, 0, r.stderr); cache(); return JSON.parse(r.stdout); };
  const finish = async () => { for (let i=0;i<400;i++) { const r=query(); if(!r.refreshing)return r; await sleep(15); } assert.fail("worker did not finish"); };
  const stale = () => { const path=join(cache(), "buckets.json"); const value=JSON.parse(readFileSync(path)); value.generatedAt=new Date(Date.now()-61_000).toISOString(); writeFileSync(path,JSON.stringify(value)); };
  const transcript = (name, lines) => { const path=join(env.CLAUDE_CONFIG_DIR,"projects","-work-é",name); mkdirSync(join(path,".."),{recursive:true}); writeFileSync(path,records(lines)); return realpathSync(path); };
  const reads = () => { try{return readFileSync(trace,"utf8").trim().split("\n").filter(Boolean).map(JSON.parse)}catch{return []} };
  const clearReads = () => writeFileSync(trace, "");
  t.after(() => { try { const lock=JSON.parse(readFileSync(join(cache(),"worker.lock"))); if(lock.pid!==process.pid)process.kill(lock.pid,"SIGKILL"); }catch{} rmSync(root,{recursive:true,force:true}); });
  return { root,env,cache,query,finish,stale,transcript,reads,clearReads, setClock: time => writeFileSync(join(root,"clock.json"),JSON.stringify(time)) };
}

test("Claude appends seek from the last complete byte and match a full scan", async t => {
  const f=fixture(t);
  const first=records([assistant("first", 11)]);
  const path=f.transcript("append.jsonl", [JSON.parse(first)]);
  assert.equal(tokens(await f.finish()),11);
  const log=readFileSync(join(f.cache(),"keys.log"),"utf8");
  f.clearReads();
  appendFileSync(path,records([assistant("second",7)])); f.stale();
  assert.equal(tokens(await f.finish()),18);
  assert.deepEqual(f.reads().filter(r=>r.path===path).map(r=>r.start),[Buffer.byteLength(first)]);
  assert.ok(readFileSync(join(f.cache(),"keys.log"),"utf8").startsWith(log));
  const incremented=await f.finish(); rmSync(f.cache(),{recursive:true});
  assert.deepEqual((await f.finish()).programs,incremented.programs);
});

test("unchanged Transcripts are not reopened and split UTF-8 tails resume once complete", async t => {
  const f=fixture(t); const path=f.transcript("partial.jsonl",[assistant("one",3)]);
  assert.equal(tokens(await f.finish()),3);
  f.clearReads(); f.stale(); assert.equal(tokens(await f.finish()),3); assert.deepEqual(f.reads().filter(r=>r.path===path),[]);
  const tail=Buffer.from(records([assistant("é",5)])); const split=tail.indexOf(Buffer.from("é"))+1;
  appendFileSync(path,tail.subarray(0,split)); f.stale(); assert.equal(tokens(await f.finish()),3);
  appendFileSync(path,tail.subarray(split)); f.stale(); assert.equal(tokens(await f.finish()),8);
  const incremental=await f.finish(); rmSync(f.cache(),{recursive:true}); assert.deepEqual((await f.finish()).programs,incremental.programs);
});

const codexLine=(type,payload,timestamp=new Date(Date.now()-60_000).toISOString())=>({type,payload,timestamp});
const meta=(id,extra={},timestamp)=>codexLine("session_meta",{id,cwd:"/work/codex",...extra},timestamp);
const count=(total,last,timestamp)=>codexLine("event_msg",{type:"token_count",info:{total_token_usage:{input_tokens:total},...(last===undefined?{}:{last_token_usage:{input_tokens:last}})}},timestamp);
const response=(id,key,input)=>codexLine("token_usage_record",{thread_id:id,response_id:key,usage:{input_tokens:input}});
const settings=(id,timestamp)=>codexLine("event_msg",{type:"thread_settings_applied",thread_id:id,thread_settings:{model:"gpt-test",service_tier:"priority"}},timestamp);
function rollout(f,id,lines,area="sessions/2026/10/24") {const path=join(f.env.CODEX_HOME,area,`rollout-${id}.jsonl`);mkdirSync(join(path,".."),{recursive:true});writeFileSync(path,records(lines));return realpathSync(path);}
const generation=f=>JSON.parse(readFileSync(join(f.cache(),"buckets.json"))).checkpoint.generation;

test("Codex appends preserve cumulative baselines and response suppression across runs", async t=>{
  const f=fixture(t);const path=rollout(f,"own",[meta("own"),settings("own"),count(10,10),response("own","next",7)]);
  assert.equal(tokens(await f.finish(),"codex"),17);
  const offset=Buffer.byteLength(readFileSync(path));f.clearReads();
  appendFileSync(path,records([count(10,10),count(17,7),count(20)]));f.stale();
  assert.equal(tokens(await f.finish(),"codex"),20);
  assert.deepEqual(f.reads().filter(r=>r.path===path).map(r=>r.start),[offset]);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});

test("a larger Claude snapshot appended later reverses the old contribution",async t=>{
  const f=fixture(t);const small=assistant("stream",3);const path=f.transcript("stream.jsonl",[small]);
  assert.equal(tokens(await f.finish()),3);const initial=generation(f);
  appendFileSync(path,records([{...small,message:{...small.message,usage:{input_tokens:9}}}]));f.stale();
  assert.equal(tokens(await f.finish()),9);assert.equal(generation(f),initial);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});

test("recent deletion preserves a globally duplicated response by rebuilding from survivors",async t=>{
  const f=fixture(t);const shared=assistant("copied",11);
  const older=f.transcript("older.jsonl",[shared]);const newer=f.transcript("newer.jsonl",[shared]);
  utimesSync(older,new Date(Date.now()-5000),new Date(Date.now()-5000));
  assert.equal(tokens(await f.finish()),11);const initial=generation(f);rmSync(newer);f.stale();
  assert.equal(tokens(await f.finish()),11);assert.notEqual(generation(f),initial);
  const rebuilt=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,rebuilt.programs);
});

test("truncation, inode replacement and same-size rewrites rebuild instead of reusing offsets",async t=>{
  for(const change of ["truncate","replace","mtime"]){
    const f=fixture(t);const first=assistant("first",11);const second={...first,message:{...first.message,usage:{input_tokens:17}}};
    const path=f.transcript(`${change}.jsonl`,change==="truncate"?[first,assistant("removed",99)]:[first]);
    assert.equal(tokens(await f.finish()),change==="truncate"?110:11);const initial=generation(f);
    if(change==="replace"){writeFileSync(path+".new",records([second]));renameSync(path+".new",path);}else writeFileSync(path,records([second]));
    const changed=new Date(Date.now()+100);utimesSync(path,changed,changed);f.stale();
    assert.equal(tokens(await f.finish()),17);assert.notEqual(generation(f),initial);
    const rebuilt=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,rebuilt.programs);
  }
});

test("old deletions, same-inode archival and compression transitions keep incremental state",{skip:!zlib.zstdCompressSync},async t=>{
  const f=fixture(t);const old=f.transcript("old.jsonl",[assistant("old",100,{timestamp:new Date(Date.now()-30.5*86400000).toISOString()})]);
  const oldTime=new Date(Date.now()-30.5*86400000);utimesSync(old,oldTime,oldTime);
  let path=rollout(f,"moving",[meta("moving"),count(9,9)]);assert.equal(tokens(await f.finish(),"codex"),9);const initial=generation(f);
  rmSync(old);f.stale();assert.equal(tokens(await f.finish(),"codex"),9);assert.equal(generation(f),initial);
  const archived=join(f.env.CODEX_HOME,"archived_sessions","rollout-moving.jsonl");mkdirSync(join(archived,".."),{recursive:true});renameSync(path,archived);path=realpathSync(archived);
  f.clearReads();f.stale();assert.equal(tokens(await f.finish(),"codex"),9);assert.equal(generation(f),initial);assert.deepEqual(f.reads().filter(r=>r.path===path),[]);
  const plain=readFileSync(path);const time=statSync(path).mtime;writeFileSync(path+".zst",zlib.zstdCompressSync(plain));utimesSync(path+".zst",time,time);rmSync(path);
  f.clearReads();f.stale();assert.equal(tokens(await f.finish(),"codex"),9);assert.equal(generation(f),initial);assert.deepEqual(f.reads().filter(r=>r.path===path+".zst"),[]);
  writeFileSync(path,Buffer.concat([plain,Buffer.from(records([count(15,6)]))]));utimesSync(path,time,time);rmSync(path+".zst");
  f.clearReads();f.stale();assert.equal(tokens(await f.finish(),"codex"),15);assert.equal(generation(f),initial);
  assert.deepEqual(f.reads().filter(r=>r.path===path).map(r=>r.start),[plain.length]);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});

test("expired keys and buckets are pruned without rereading unchanged Transcripts",async t=>{
  const f=fixture(t);const now=Date.now();f.setClock(now);
  const path=f.transcript("prune.jsonl",[assistant("aging",100,{timestamp:new Date(now-30.9*86400000).toISOString()}),assistant("recent",7)]);
  assert.equal(tokens(await f.finish()),7);assert.ok(readFileSync(join(f.cache(),"keys.log"),"utf8").includes('aging'));
  f.clearReads();f.setClock(now+86400000);assert.equal(tokens(await f.finish()),7);
  assert.deepEqual(f.reads().filter(r=>r.path===path),[]);
  assert.equal(readFileSync(join(f.cache(),"keys.log"),"utf8").includes('aging'),false);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});

test("an unfinished Codex leading burst resumes from its saved bytes and metadata",async t=>{
  const f=fixture(t);const now=Date.now();f.setClock(now);
  const path=rollout(f,"pending",[meta("pending",{forked_from_id:"missing"},new Date(now).toISOString()),count(100,100,new Date(now+100).toISOString())]);
  f.query();let saved;
  for(let i=0;i<100;i++){try{saved=Object.values(JSON.parse(readFileSync(join(f.cache(),"files.json")))).find(file=>file.carry.threadId==="pending");}catch{}if(saved?.carry.pending.length)break;await sleep(15);}
  assert.equal(saved.carry.pending.length,1);assert.equal(saved.carry.previousTotal.input_tokens,100);
  const initial=generation(f);const offset=readFileSync(path).length;
  appendFileSync(path,records([settings("pending",new Date(now+200).toISOString()),count(109,9,new Date(now+300).toISOString())]));f.clearReads();
  assert.equal(tokens(await f.finish(),"codex"),9);assert.equal(generation(f),initial);
  const reads=f.reads().filter(r=>r.path===path);assert.ok(reads.length>0);assert.ok(reads.every(r=>r.start===offset));
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});

test("a live sibling worker keeps its old snapshot cache during another roots refresh",async t=>{
  const f=fixture(t);await f.finish();
  const sibling=join(f.env.HERDR_PLUGIN_STATE_DIR,"usage","active-sibling");mkdirSync(sibling);writeFileSync(join(sibling,"buckets.json"),"{}");
  const old=new Date(Date.now()-32*86400000);utimesSync(join(sibling,"buckets.json"),old,old);
  const start=spawnSync("/bin/ps",["-p",String(process.pid),"-o","lstart="],{encoding:"utf8"}).stdout.trim();
  writeFileSync(join(sibling,"worker.lock"),JSON.stringify({pid:process.pid,processStart:start,heartbeat:Date.now(),token:"owned-fixture"}));
  f.stale();await f.finish();assert.equal(readFileSync(join(sibling,"buckets.json"),"utf8"),"{}");
});

async function waitFor(path) {
  for(let i=0;i<200;i++){if(existsSync(path))return;await sleep(15);}
  assert.fail(`fixture did not reach ${path}`);
}

test("a killed worker resumes or rebuilds without counting uncommitted contributions twice",async t=>{
  for(const point of ["keys","files"]){
    const f=fixture(t);const path=f.transcript("interrupt.jsonl",[assistant("before",10)]);
    assert.equal(tokens(await f.finish()),10);const before=generation(f);
    appendFileSync(path,records([assistant("after",7)]));f.stale();writeFileSync(join(f.root,"fault.json"),JSON.stringify(point));
    assert.equal(f.query().refreshing,true);await waitFor(join(f.root,"fault-reached"));
    rmSync(join(f.root,"fault.json"));
    assert.equal(tokens(await f.finish()),17);
    if(point==="keys")assert.equal(generation(f),before);else assert.notEqual(generation(f),before);
    const recovered=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,recovered.programs);
  }
});

test("a rebuild keeps the previous snapshot visible until its replacement is complete",async t=>{
  const f=fixture(t);const path=f.transcript("rebuild.jsonl",[assistant("old",10)]);
  assert.equal(tokens(await f.finish()),10);
  writeFileSync(path,records([assistant("new",77)]));const changed=new Date(Date.now()+100);utimesSync(path,changed,changed);
  writeFileSync(join(f.root,"hold"),"pause filesystem boundary");f.stale();f.query();await waitFor(join(f.root,"read-started"));
  const during=f.query();assert.equal(during.refreshing,true);assert.equal(tokens(during),10);
  rmSync(join(f.root,"hold"));assert.equal(tokens(await f.finish()),77);
});

test("a rebuild persists a pending Codex burst while still serving its previous totals",async t=>{
  const f=fixture(t);const now=Date.now();f.setClock(now);
  const old=f.transcript("old.jsonl",[assistant("old",10)]);assert.equal(tokens(await f.finish()),10);rmSync(old);
  const path=rollout(f,"rebuild-pending",[meta("rebuild-pending",{forked_from_id:"missing"},new Date(now).toISOString()),count(100,100,new Date(now+100).toISOString())]);
  f.stale();f.query();let saved;
  for(let i=0;i<100;i++){try{saved=Object.values(JSON.parse(readFileSync(join(f.cache(),"files.json")))).find(file=>file.carry.threadId==="rebuild-pending");}catch{}if(saved?.carry.pending.length)break;await sleep(15);}
  assert.equal(saved?.carry.pending.length,1);
  assert.equal(tokens(f.query()),10);const initial=generation(f);
  appendFileSync(path,records([settings("rebuild-pending",new Date(now+200).toISOString()),count(109,9,new Date(now+300).toISOString())]));
  const finished=await f.finish();assert.equal(tokens(finished),0);assert.equal(tokens(finished,"codex"),9);assert.equal(generation(f),initial);
});

test("persisted cross-session aliases suppress a sidechain replay appended on a later run",async t=>{
  const f=fixture(t);const parent=assistant("shared",10);f.transcript("parent.jsonl",[parent]);assert.equal(tokens(await f.finish()),10);
  const copy={...parent,sessionId:"copy"};const path=f.transcript("copy.jsonl",[copy]);f.stale();assert.equal(tokens(await f.finish()),10);
  appendFileSync(path,records([{...copy,isSidechain:true,requestId:"replayed",message:{...copy.message,usage:{input_tokens:1000}}}]));f.stale();
  assert.equal(tokens(await f.finish()),10);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});
