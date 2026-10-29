import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import { promisify } from "node:util";
import { cpSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, appendFileSync, chmodSync, realpathSync, renameSync, utimesSync, statSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";
import { createHash } from "node:crypto";

import { matchFiles } from "../src/usage/checkpoint.js";
import { processStart } from "../src/usage/cache.js";

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
import zlib from 'node:zlib';
const root=${JSON.stringify(root)};
// A Node without a zstd decoder, as before 22.15.0.
if(fs.existsSync(root+'/no-zstd'))delete zlib.createZstdDecompress;
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
const open=fs.openSync;
const write=fs.writeSync;
const truncate=fs.truncateSync;
const fsync=fs.fsyncSync;
const worker=process.argv[1]?.endsWith('usage-worker.js');
// With a tick every snapshot check is due, so progress commits at every line boundary.
if(worker&&fs.existsSync(root+'/tick')){let elapsed=0;performance.now=()=>(elapsed+=1000);}
const fault=()=>{try{return JSON.parse(fs.readFileSync(root+'/fault.json'))}catch{return undefined}};
function kill() {
  fs.writeFileSync(root+'/fault-reached',String(process.pid));
  process.kill(process.pid,'SIGKILL');
}
function crash(point) { if(fault()===point)kill(); }
// Numbered cache writes: {at:k} kills the worker at the k-th one.
let events=0;
const event=()=>{events++;return fault()?.at===events;};
if(worker)process.on('exit',()=>fs.writeFileSync(root+'/events',String(events)));
const logs=new Set();
fs.openSync=function(path,...args) {
  const fd=open.call(this,path,...args);
  if(/[/]keys[.]log([.].+[.]tmp)?$/.test(String(path)))logs.add(fd);
  return fd;
};
fs.writeSync=function(fd,data,...args) {
  if(!logs.has(fd))return write.call(this,fd,data,...args);
  if(event()){
    // Tear the write: only its first half reaches the log.
    const [offset=0,length=data.length-offset]=args;
    write.call(this,fd,data,offset,Math.max(1,Math.floor(length/2)));
    kill();
  }
  const result=write.call(this,fd,data,...args);
  if(String(data).includes('"tokens"'))crash('keys');
  return result;
};
fs.truncateSync=function(...args){const result=truncate.apply(this,args);if(event())kill();return result;};
fs.fsyncSync=function(fd){const result=fsync.call(this,fd);if(logs.has(fd)&&event())kill();return result;};
fs.renameSync=function(from,to) {
  const result=rename.call(this,from,to);
  if(String(to).endsWith('/files.json'))crash('files');
  if(String(to).endsWith('/buckets.json'))crash('buckets');
  if(/[/](keys[.]log|files[.]json|buckets[.]json|limits[.]json)$/.test(String(to))&&event())kill();
  return result;
};
const original=fs.createReadStream;
// A hold holding a number lets that many Transcript reads through first.
let opened=0;
const holdAfter=()=>{try{const n=Number(fs.readFileSync(root+'/hold','utf8'));return Number.isInteger(n)?n:0}catch{return null}};
fs.createReadStream=function(path,options) {
  const transcript=String(path).endsWith('.jsonl')||String(path).endsWith('.zst');
  if(transcript)append(${JSON.stringify(trace)},JSON.stringify({path:String(path),start:options?.start||0})+'\\n');
  const stream=original.call(this,path,options);
  const after=transcript?holdAfter():null;
  if(after!==null&&opened++>=after)return Readable.from((async function*(){
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
  const queryAsync = async () => { const r = await promisify(execFile)(node, [join(plugin, "src", "usage-query.js"), "--tz", "UTC"], { env, encoding: "utf8", timeout: 10_000 }); cache(); return JSON.parse(r.stdout); };
  const finish = async () => { for (let i=0;i<400;i++) { const r=query(); if(!r.refreshing)return r; await sleep(15); } assert.fail("worker did not finish"); };
  const stale = () => { const path=join(cache(), "buckets.json"); const value=JSON.parse(readFileSync(path)); value.generatedAt=new Date(Date.now()-61_000).toISOString(); writeFileSync(path,JSON.stringify(value)); };
  const transcript = (name, lines) => { const path=join(env.CLAUDE_CONFIG_DIR,"projects","-work-é",name); mkdirSync(join(path,".."),{recursive:true}); writeFileSync(path,records(lines)); return realpathSync(path); };
  const reads = () => { try{return readFileSync(trace,"utf8").trim().split("\n").filter(Boolean).map(JSON.parse)}catch{return []} };
  const clearReads = () => writeFileSync(trace, "");
  t.after(() => { try { const lock=JSON.parse(readFileSync(join(cache(),"worker.lock"))); if(lock.pid!==process.pid)process.kill(lock.pid,"SIGKILL"); }catch{} rmSync(root,{recursive:true,force:true}); });
  return { root,env,cache,query,queryAsync,finish,stale,transcript,reads,clearReads, setClock: time => writeFileSync(join(root,"clock.json"),JSON.stringify(time)) };
}

test("Claude appends seek from the last complete byte and match a full scan", async t => {
  const f=fixture(t);
  const first=records([assistant("first", 11)]);
  const path=f.transcript("append.jsonl", [JSON.parse(first)]);
  assert.equal(tokens(await f.finish()),11);
  const log=readFileSync(join(f.cache(),"keys.log"),"utf8");
  // A counted record is its own alias; only a losing copy writes an alias line.
  assert.equal(log.includes('"alias"'),false);
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
// The worker renames files.json before buckets.json; wait until a committed
// checkpoint binds the file state the test is looking for.
async function checkpointed(f,thread){
  for(let i=0;i<200;i++){
    try{
      const text=readFileSync(join(f.cache(),"files.json"),"utf8");
      const saved=Object.values(JSON.parse(text)).find(file=>file.carry.threadId===thread);
      const committed=JSON.parse(readFileSync(join(f.cache(),"buckets.json"))).checkpoint?.filesHash===createHash("sha256").update(text).digest("hex");
      if(committed&&saved?.carry.pending.length)return saved;
    }catch{/* The worker has not written both files yet. */}
    await sleep(15);
  }
  assert.fail(`no committed checkpoint holds the pending burst of ${thread}`);
}

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

test("a rollout tail appended before compression is read from the saved offset",{skip:!zlib.zstdCompressSync},async t=>{
  const f=fixture(t);const path=rollout(f,"cold",[meta("cold"),count(9,9)]);
  assert.equal(tokens(await f.finish(),"codex"),9);const initial=generation(f);
  appendFileSync(path,records([count(15,6),count(40,25)]));const appended=new Date(Date.now()+1000);
  // Codex compresses a cold rollout and copies the mtime of its last append.
  writeFileSync(path+".zst",zlib.zstdCompressSync(readFileSync(path)));utimesSync(path+".zst",appended,appended);rmSync(path);
  f.clearReads();f.stale();assert.equal(tokens(await f.finish(),"codex"),40);assert.equal(generation(f),initial);
  assert.deepEqual(f.reads().filter(r=>r.path===path+".zst").length,1);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,incremental.programs);
});

test("a reused inode claims an unlisted old state only under the same file name",()=>{
  const now=Date.now();const old={program:"claude",dev:1,ino:7,size:100,mtimeMs:now-30.5*86400000,offset:100,finished:true,compressed:false,carry:{}};
  const file=(path,extra={})=>({path,program:"claude",dev:1,ino:7,size:400,mtimeMs:now,...extra});
  // A Transcript deleted by cleanup frees its inode for an unrelated new file.
  const reused=matchFiles([file("/p/new.jsonl")],{"/p/old.jsonl":old},now);
  assert.deepEqual(reused,{states:{},rebuild:false});
  const archived={...old,program:"codex"};
  const moved=matchFiles([file("/c/archived_sessions/rollout-a.jsonl",{program:"codex",size:100,mtimeMs:old.mtimeMs})],{"/c/sessions/2026/10/01/rollout-a.jsonl":archived},now);
  assert.equal(moved.rebuild,false);assert.equal(moved.states["/c/archived_sessions/rollout-a.jsonl"].offset,100);
});

test("an unreadable directory keeps its known Transcripts without a rebuild",async t=>{
  const f=fixture(t);const path=f.transcript("live.jsonl",[assistant("live",5)]);
  const other=join(f.env.CLAUDE_CONFIG_DIR,"projects","-work-other");mkdirSync(other);writeFileSync(join(other,"kept.jsonl"),records([assistant("kept",7)]));
  assert.equal(tokens(await f.finish()),12);const initial=generation(f);
  chmodSync(other,0);let hidden;
  try{appendFileSync(path,records([assistant("more",3)]));f.stale();hidden=await f.finish();}finally{chmodSync(other,0o700);}
  assert.equal(tokens(hidden),15);assert.equal(hidden.scan.unreadableFiles,1);assert.equal(generation(f),initial);
  assert.equal(JSON.stringify(hidden.programs.map(({accounts,...program})=>program)).includes(f.root),false);
  f.stale();const restored=await f.finish();assert.equal(tokens(restored),15);assert.equal(restored.scan.unreadableFiles,0);assert.equal(generation(f),initial);
  rmSync(f.cache(),{recursive:true});assert.deepEqual((await f.finish()).programs,restored.programs);
});

test("an unreadable Claude root is counted while another root can be listed",{skip:process.getuid?.()===0&&"root ignores directory modes"},async t=>{
  const f=fixture(t);f.transcript("main.jsonl",[assistant("main",5)]);
  // The legacy XDG directory is the second root beside CLAUDE_CONFIG_DIR.
  const second=join(f.env.HOME,".config","claude","projects");mkdirSync(join(second,"-work-two"),{recursive:true});
  writeFileSync(join(second,"-work-two","two.jsonl"),records([assistant("two",7)]));
  assert.equal(tokens(await f.finish()),12);const initial=generation(f);
  const main=join(f.env.CLAUDE_CONFIG_DIR,"projects");
  let hidden;let failed;
  try{
    chmodSync(second,0);f.stale();hidden=await f.finish();
    chmodSync(main,0);f.stale();failed=await f.finish();
  }finally{chmodSync(second,0o700);chmodSync(main,0o700);}
  assert.equal(hidden.programs[0].tokenUsage.state,"ok");assert.equal(tokens(hidden),12);
  assert.equal(hidden.scan.unreadableFiles,1);assert.equal(generation(f),initial);
  // With no Claude root listed, the program reports the error.
  assert.equal(failed.programs[0].tokenUsage.state,"error");
  f.stale();const restored=await f.finish();assert.equal(tokens(restored),12);assert.equal(restored.scan.unreadableFiles,0);
});

test("a truncated rollout archive is skipped and counted without hiding Codex",{skip:!zlib.zstdCompressSync},async t=>{
  const f=fixture(t);rollout(f,"whole",[meta("whole"),count(9,9)]);
  const cut=rollout(f,"cut",[meta("cut"),count(50,50)]);const archive=zlib.zstdCompressSync(readFileSync(cut));
  writeFileSync(cut+".zst",archive.subarray(0,archive.length-2));rmSync(cut);
  const report=await f.finish();assert.equal(report.programs[1].tokenUsage.state,"ok");
  assert.equal(tokens(report,"codex"),9);assert.equal(report.scan.unreadableFiles,1);
});

test("an archive skipped for want of a decoder and later found truncated counts only as its latest failure",{skip:!zlib.zstdCompressSync},async t=>{
  const f=fixture(t);
  // No external zstd either: the recorded PATH names an empty directory.
  const runtimePath=join(f.env.HERDR_PLUGIN_CONFIG_DIR,"runtime.json");const runtime=JSON.parse(readFileSync(runtimePath));
  runtime.env.PATH=join(f.root,"no-programs");writeFileSync(runtimePath,JSON.stringify(runtime));
  const cut=rollout(f,"cut",[meta("cut"),count(50,50)]);const archive=zlib.zstdCompressSync(readFileSync(cut));
  writeFileSync(cut+".zst",archive.subarray(0,archive.length-2));rmSync(cut);
  const coverage=report=>[report.scan.skippedArchives,report.scan.unreadableFiles];
  writeFileSync(join(f.root,"no-zstd"),"");assert.deepEqual(coverage(await f.finish()),[1,0]);
  rmSync(join(f.root,"no-zstd"));f.stale();assert.deepEqual(coverage(await f.finish()),[0,1]);
  writeFileSync(join(f.root,"no-zstd"),"");f.stale();assert.deepEqual(coverage(await f.finish()),[1,0]);
});

test("coverage starts at the first recorded day, not the first day with usage",async t=>{
  const f=fixture(t);const now=Date.parse("2026-10-20T12:00:00Z");f.setClock(now);const day=86400000;
  const iso=time=>new Date(time).toISOString();
  // Ten days ago the Transcript only has a user message; usage starts later.
  const path=f.transcript("quiet.jsonl",[{type:"user",sessionId:"one",timestamp:iso(now-10*day),cwd:"/work/é",message:{content:"hi"}},assistant("late",4,{timestamp:iso(now-2*day)})]);
  utimesSync(path,new Date(now),new Date(now));
  const quiet=await f.finish();assert.equal(tokens(quiet),4);assert.equal(quiet.scan.coveredFrom,"2026-10-10");
  const codex=rollout(f,"quiet",[meta("quiet",{},iso(now-15*day)),count(6,6,iso(now-day))]);utimesSync(codex,new Date(now),new Date(now));
  const snapshotPath=join(f.cache(),"buckets.json");writeFileSync(snapshotPath,JSON.stringify({...JSON.parse(readFileSync(snapshotPath)),generatedAt:iso(now-61_000)}));
  const both=await f.finish();assert.equal(tokens(both,"codex"),6);assert.equal(both.scan.coveredFrom,"2026-10-05");
  // A Transcript older than the window means the Host kept records before it.
  const old=f.transcript("old.jsonl",[assistant("old",9,{timestamp:iso(now-40*day)})]);utimesSync(old,new Date(now-40*day),new Date(now-40*day));
  rmSync(f.cache(),{recursive:true});const kept=await f.finish();assert.equal(tokens(kept),4);assert.equal(kept.scan.coveredFrom,"2026-09-21");
});

test("expired keys leave the totals at once and the log only when a whole UTC day expires",async t=>{
  const f=fixture(t);const day=86400000;const now=Date.parse("2026-10-20T12:00:00Z");f.setClock(now);
  const log=()=>readFileSync(join(f.cache(),"keys.log"),"utf8");
  // The worker keeps 31 days; the report shows 30 calendar days, so read its buckets.
  const kept=()=>JSON.parse(readFileSync(join(f.cache(),"buckets.json"))).buckets.filter(b=>"model" in b).reduce((sum,b)=>sum+b.tokens.total,0);
  // 2026-09-19T18:00Z stays within 31 days until 2026-10-20T18:00Z.
  const path=f.transcript("prune.jsonl",[assistant("aging",100,{timestamp:new Date(now-30.75*day).toISOString()}),assistant("recent",7,{timestamp:new Date(now-day).toISOString()})]);
  await f.finish();assert.equal(kept(),107);const initial=generation(f);
  // Expired at once, but part of 2026-09-19 is still within 31 days: no rewrite.
  f.clearReads();f.setClock(now+0.3*day);await f.finish();assert.equal(kept(),7);
  assert.equal(generation(f),initial);assert.ok(log().includes('aging'));
  // Once all of 2026-09-19 is older than 31 days, the log drops it.
  f.setClock(now+0.6*day);await f.finish();assert.equal(kept(),7);
  assert.notEqual(generation(f),initial);assert.equal(log().includes('aging'),false);
  assert.deepEqual(f.reads().filter(r=>r.path===path),[]);
  const pruned=generation(f);f.setClock(now+0.9*day);await f.finish();assert.equal(kept(),7);assert.equal(generation(f),pruned);
  const incremental=await f.finish();rmSync(f.cache(),{recursive:true});
  assert.deepEqual((await f.finish()).programs,incremental.programs);assert.equal(kept(),7);
});

test("an unfinished Codex leading burst resumes from its saved bytes and metadata",async t=>{
  const f=fixture(t);const now=Date.now();f.setClock(now);
  const path=rollout(f,"pending",[meta("pending",{forked_from_id:"missing"},new Date(now).toISOString()),count(100,100,new Date(now+100).toISOString())]);
  f.query();const saved=await checkpointed(f,"pending");
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
  const start=processStart(process.pid);
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

test("a routine incremental run keeps the finished scan state until it finishes",async t=>{
  const f=fixture(t);const newer=f.transcript("newer.jsonl",[assistant("newer",5)]);const older=f.transcript("older.jsonl",[assistant("older",7)]);
  const first=await f.finish();assert.equal(tokens(first),12);assert.equal(first.scan.state,"complete");
  appendFileSync(older,records([assistant("older-more",100)]));appendFileSync(newer,records([assistant("newer-more",3)]));
  const later=new Date(Date.now()+2000);utimesSync(newer,later,later);
  // Commit after every line and hold the second Transcript's read, then end the worker there.
  f.stale();writeFileSync(join(f.root,"tick"),"");writeFileSync(join(f.root,"hold"),"1");
  assert.equal(f.query().refreshing,true);await waitFor(join(f.root,"read-started"));
  process.kill(JSON.parse(readFileSync(join(f.cache(),"worker.lock"))).pid,"SIGKILL");rmSync(join(f.root,"hold"));
  // The worker died after committing only the newest file's append.
  const during=f.query();assert.equal(tokens(during),15);
  assert.equal(during.scan.state,"complete");assert.equal(during.scan.coveredThrough,first.scan.coveredThrough);
  const finished=await f.finish();assert.equal(tokens(finished),115);assert.equal(finished.scan.state,"complete");
  assert.ok(finished.scan.coveredThrough>first.scan.coveredThrough);
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
  f.stale();f.query();const saved=await checkpointed(f,"rebuild-pending");
  assert.equal(saved.carry.pending.length,1);
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

test("queries observe a partial scan without starting another worker",async t=>{
  const f=fixture(t);
  f.transcript("first.jsonl",Array.from({length:30},(_,i)=>assistant(`first-${i}`,1)));
  f.transcript("second.jsonl",Array.from({length:30},(_,i)=>assistant(`second-${i}`,2)));
  writeFileSync(join(f.root,"tick"),"");writeFileSync(join(f.root,"hold"),"1");
  assert.equal(f.query().refreshing,true);await waitFor(join(f.root,"read-started"));
  const pid=JSON.parse(readFileSync(join(f.cache(),"worker.lock"))).pid;
  const partial=f.query();assert.equal(partial.refreshing,true);assert.equal(partial.scan.state,"partial");
  assert.ok([30,60].includes(tokens(partial)));
  assert.equal(JSON.parse(readFileSync(join(f.cache(),"worker.lock"))).pid,pid);
  rmSync(join(f.root,"hold"));assert.equal(tokens(await f.finish()),90);
});

async function killScenario(t,change){
  const day=86400000;const now=Date.parse("2026-10-20T12:00:00Z");const iso=time=>new Date(time).toISOString();
  const f=fixture(t);f.setClock(now);
  const main=f.transcript("main.jsonl",[assistant("aging",100,{timestamp:iso(now-30.75*day)})]);
  const shared=assistant("shared",11,{timestamp:iso(now-2*day)});const parent=f.transcript("parent.jsonl",[shared]);
  const copy=f.transcript("copy.jsonl",[{...shared,sessionId:"copy"}]);
  await f.finish();const initial=generation(f);
  // Later: a streamed snapshot grows, a sidechain replay loses to its parent
  // and a Codex line releases a burst. At 0.6 days 2026-09-19 expires whole
  // and the log is rewritten; at 0.3 days a key expires but the run keeps the
  // generation and appends to the log it has.
  const later=now+(change==="incremental"?0.3:0.6)*day;f.setClock(later);
  const streamed=assistant("streamed",3,{timestamp:iso(now)});
  appendFileSync(main,records([streamed,{...streamed,message:{...streamed.message,usage:{input_tokens:9}}}]));
  appendFileSync(copy,records([{...shared,sessionId:"copy",isSidechain:true,requestId:"replayed",message:{...shared.message,usage:{input_tokens:1000}}}]));
  const at=offset=>iso(now-60_000+offset);
  rollout(f,"burst",[meta("burst",{session_id:"parent"},at(0)),codexLine("token_usage_record",{thread_id:"burst",response_id:"r0",usage:{input_tokens:1}},at(0)),
    codexLine("inter_agent_communication",{trigger_turn:true},at(0)),count(10,10,at(0)),count(30,20,at(0)),count(60,30,at(0)),codexLine("turn_context",{model:"gpt-test"},at(5000))]);
  if(change==="rebuild"){const later=new Date(now+day);utimesSync(parent,later,later);}
  const template=join(f.root,"template");cpSync(f.cache(),template,{recursive:true});
  rmSync(f.cache(),{recursive:true});const expected=(await f.finish()).programs;
  // A recovered cache must also take a further run: one more record and a
  // larger streamed snapshot that replaces a counted one.
  const further=()=>f.transcript("further.jsonl",[{...streamed,message:{...streamed.message,usage:{input_tokens:40}}},assistant("further",4,{timestamp:iso(now)})]);
  const furtherPath=further();rmSync(f.cache(),{recursive:true});const expectedFurther=(await f.finish()).programs;rmSync(furtherPath);
  // Each snapshot's age follows the fixture clock, not the test's.
  const age=()=>{const path=join(f.cache(),"buckets.json");writeFileSync(path,JSON.stringify({...JSON.parse(readFileSync(path)),generatedAt:iso(later-61_000)}));};
  // Every line boundary commits, so the run passes through every kind of write.
  writeFileSync(join(f.root,"tick"),"");
  const restore=()=>{rmSync(f.cache(),{recursive:true});cpSync(template,f.cache(),{recursive:true});rmSync(join(f.root,"fault-reached"),{force:true});};
  restore();assert.deepEqual((await f.finish()).programs,expected);
  const pruned=!readFileSync(join(f.cache(),"keys.log"),"utf8").includes("aging");
  assert.equal(generation(f)!==initial,change!=="incremental");assert.equal(pruned,change!=="incremental");
  const writes=Number(readFileSync(join(f.root,"events"),"utf8"));
  // Poll the lock file rather than spawning a query every few milliseconds,
  // but query again periodically: only a query reclaims the lock of a killed
  // worker, and one that ran while the worker was still dying reported it live.
  const settle=async()=>{
    const deadline=Date.now()+60_000;
    while(Date.now()<deadline){
      const report=await f.queryAsync();if(!report.refreshing)return report;
      for(let i=0;i<50&&existsSync(join(f.cache(),"worker.lock"));i++)await sleep(5);
    }
    assert.fail(`${change}: the worker did not settle`);
  };
  const killAt=async k=>{
    restore();writeFileSync(join(f.root,"fault.json"),JSON.stringify({at:k}));
    assert.equal((await f.queryAsync()).refreshing,true);
    for(let i=0;i<2000&&!existsSync(join(f.root,"fault-reached"))&&existsSync(join(f.cache(),"worker.lock"));i++)await sleep(5);
    assert.ok(existsSync(join(f.root,"fault-reached")),`${change}: write ${k} of ${writes} was not reached`);
    rmSync(join(f.root,"fault.json"));
    assert.deepEqual((await settle()).programs,expected,`${change}: killed at write ${k} of ${writes}`);
    assert.deepEqual(readdirSync(f.cache()).filter(name=>name.endsWith(".tmp")),[]);
    // No latent corruption: the next run's appends still match a fresh full scan.
    const path=further();age();
    try{assert.deepEqual((await settle()).programs,expectedFurther,`${change}: further run after a kill at write ${k} of ${writes}`);}
    finally{rmSync(path);}
  };
  return { change, writes, expected, killAt };
}

test("a worker killed at any cache write recovers the totals of a fresh full scan",async t=>{
  // Two lanes per change share its write points; all lanes run at once.
  const lanes=[];
  for(const change of ["incremental","prune","rebuild"])for(let lane=0;lane<2;lane++)lanes.push(await killScenario(t,change));
  for(const lane of lanes){
    const twin=lanes.find(other=>other.change===lane.change);
    // Twins run in their own fixtures, so their Account directories differ.
    const portable=programs=>programs.map(({accounts,...program})=>({...program,accounts:accounts?.map(({directory,...account})=>account)}));
    assert.equal(lane.writes,twin.writes);assert.deepEqual(portable(lane.expected),portable(twin.expected));assert.ok(lane.writes>=15,`${lane.writes} writes`);
  }
  t.diagnostic(lanes.filter((_,i)=>i%2===0).map(lane=>`${lane.change}: ${lane.writes} writes`).join(", "));
  await Promise.all(lanes.map(async (lane,index)=>{for(let k=1+index%2;k<=lane.writes;k+=2)await lane.killAt(k);}));
});

test("a checkpoint from another scanner version rebuilds even when fresh",async t=>{
  const f=fixture(t);const path=f.transcript("scanner.jsonl",[assistant("one",5)]);
  assert.equal(tokens(await f.finish()),5);const initial=generation(f);
  // A counting fix bumps the scanner version without touching the price table.
  const snapshotPath=join(f.cache(),"buckets.json");const snapshot=JSON.parse(readFileSync(snapshotPath));
  snapshot.checkpoint.scannerVersion-=1;writeFileSync(snapshotPath,JSON.stringify(snapshot));
  f.clearReads();assert.equal(f.query().refreshing,true);
  assert.equal(tokens(await f.finish()),5);assert.notEqual(generation(f),initial);
  assert.deepEqual(f.reads().filter(r=>r.path===path).map(r=>r.start),[0]);
});
