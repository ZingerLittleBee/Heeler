import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, cpSync, symlinkSync, chmodSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const generator = fileURLToPath(new URL("../../scripts/generate-usage-pricing.mjs", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const base = { input: 0.000001, output: 0.000004, cacheRead: 0.0000001, cacheWrite: 0.00000125 };
function fixture(t, models = { "claude-fixture": { base } }) {
  const root = mkdtempSync(join(tmpdir(), "heeler-pricing-"));
  const install = join(root, "plugin");
  cpSync(join(plugin, "src"), join(install, "src"), { recursive: true });
  cpSync(join(plugin, "package.json"), join(install, "package.json"));
  symlinkSync(join(plugin, "node_modules"), join(install, "node_modules"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"), CODEX_HOME: join(root, "codex"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const table = join(install, "src/usage/pricing.json");
  const prices = (value = models, version = "2026-10-23") => writeFileSync(table, JSON.stringify({ pricingVersion: version, models: value }));
  prices();
  const run = (name, args = []) => spawnSync(process.execPath, [join(install, "src", name), ...args], { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  const query = () => { const result = run("usage-query.js", ["--tz", "UTC"]); assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout); };
  const finish = async () => { for (let i = 0; i < 400; i++) { const r = query(); if (!r.refreshing) return r; await sleep(15); } assert.fail("worker did not finish"); };
  const transcript = (program, lines, name = "one.jsonl") => {
    const path = program === "claude" ? join(env.CLAUDE_CONFIG_DIR, "projects/-work", name) : join(env.CODEX_HOME, "sessions/2026/10/23/rollout-one.jsonl");
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, lines.map(line => JSON.stringify(line)).join("\n") + "\n");
  };
  t.after(() => {
    try { for (const key of readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))) {
      const lock = JSON.parse(readFileSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage", key, "worker.lock")));
      if (lock.pid !== process.pid) process.kill(lock.pid, "SIGKILL");
    } } catch { /* Worker ended. */ }
    rmSync(root, { recursive: true, force: true });
  });
  return { root, install, env, prices, query, finish, transcript };
}
function claude(id, model, usage) {
  return { type: "assistant", timestamp: new Date().toISOString(), sessionId: "one", requestId: `req-${id}`, cwd: "/work",
    message: { id, model, usage } };
}
const usage = (report, program = "claude") => report.programs.find(p => p.program === program).tokenUsage;

test("query prices Claude requests including separate one-hour cache writes", async t => {
  const f = fixture(t);
  f.transcript("claude", [claude("one", "claude-fixture", { input_tokens: 100, cache_read_input_tokens: 200,
    cache_creation: { ephemeral_5m_input_tokens: 40, ephemeral_1h_input_tokens: 60 }, output_tokens: 10 })]);
  const report = await f.finish();
  assert.equal(report.pricingVersion, "2026-10-23");
  assert.ok(Math.abs(usage(report).totals.today.estimatedCostUSD - 0.00033) < 1e-12);
  assert.equal(usage(report).totals.today.unpricedTokens, 0);
});

test("a whole request switches long-context rates while a flat model stays flat", async t => {
  const f = fixture(t, { "claude-tiered": { base, longContext: { threshold: 1000, base: { input: 0.000002, output: 0.000006, cacheRead: 0.0000002, cacheWrite: 0.0000025 } } }, "claude-flat": { base } });
  f.transcript("claude", [
    claude("below", "claude-tiered", { input_tokens: 499, cache_read_input_tokens: 500, output_tokens: 10 }),
    claude("above", "claude-tiered", { input_tokens: 501, cache_read_input_tokens: 500, output_tokens: 10 }),
    claude("flat", "claude-flat", { input_tokens: 1001, output_tokens: 10 }),
  ]);
  // Below: .000589. Above: .001162. Flat: .001041.
  assert.ok(Math.abs(usage(await f.finish()).totals.today.estimatedCostUSD - 0.002792) < 1e-12);
});

function codex(model, tier, requests) {
  const timestamp = new Date().toISOString();
  return [
    { type: "session_meta", timestamp, payload: { id: "one", cwd: "/work" } },
    { type: "event_msg", timestamp, payload: { type: "thread_settings_applied", thread_id: "one", thread_settings: { model, service_tier: tier } } },
    ...requests.map((usage, i) => ({ type: "token_usage_record", timestamp, payload: { thread_id: "one", response_id: `response-${i}`, usage } })),
  ];
}

test("Claude Fast multiplies cache prices and Codex Fast and Flex use their full rates", async t => {
  const fast = { input: 0.000002, output: 0.000008, cacheRead: 0.0000002, cacheWrite: 0.0000025 };
  const flex = { input: 0.0000005, output: 0.000002, cacheRead: 0.00000005, cacheWrite: 0.000000625 };
  const f = fixture(t, { "claude-fixture": { base, fast }, "gpt-fixture": { base, fast, flex } });
  f.transcript("claude", [claude("fast", "claude-fixture", { input_tokens: 100, cache_read_input_tokens: 200,
    cache_creation: { ephemeral_5m_input_tokens: 40, ephemeral_1h_input_tokens: 60 }, output_tokens: 10, speed: "fast" })]);
  f.transcript("codex", codex("gpt-fixture", "priority", [{ input_tokens: 100, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 10, reasoning_output_tokens: 5 }]));
  const report = await f.finish();
  assert.ok(Math.abs(usage(report).totals.today.estimatedCostUSD - 0.00066) < 1e-12);
  assert.ok(Math.abs(usage(report, "codex").totals.today.estimatedCostUSD - 0.000238) < 1e-12);
  const g = fixture(t, { "gpt-fixture": { base, fast, flex } });
  g.transcript("codex", codex("gpt-fixture", "flex", [{ input_tokens: 100, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 10 }]));
  assert.ok(Math.abs(usage(await g.finish(), "codex").totals.today.estimatedCostUSD - 0.0000595) < 1e-12);
});

test("the generator deterministically trims source prices and preserves explicit tiers", t => {
  const root = mkdtempSync(join(tmpdir(), "heeler-price-generator-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const input = join(root, "source.json"), output = join(root, "prices.json");
  writeFileSync(input, JSON.stringify({
    "gpt-example": { mode: "responses", input_cost_per_token: 0.000001, output_cost_per_token: 0.000004,
      cache_read_input_token_cost: 0.0000001, input_cost_per_token_above_272k_tokens: 0.000002,
      output_cost_per_token_above_272k_tokens: 0.000006, cache_read_input_token_cost_above_272k_tokens: 0.0000002,
      input_cost_per_token_priority: 0.000002, output_cost_per_token_priority: 0.000008,
      cache_read_input_token_cost_priority: 0.0000002, input_cost_per_token_flex: 0.0000005,
      output_cost_per_token_flex: 0.000002, cache_read_input_token_cost_flex: 0.00000005,
      input_cost_per_token_above_272k_tokens_priority: 0.000004, output_cost_per_token_above_272k_tokens_priority: 0.000012 },
    "gpt-output-only-flex": { mode: "chat", input_cost_per_token: 0.000001, output_cost_per_token: 0.000004,
      output_cost_per_token_flex: 0.000002 },
    "claude-example": { mode: "chat", input_cost_per_token: 0.000001, output_cost_per_token: 0.000004,
      cache_creation_input_token_cost: 0.00000125, cache_read_input_token_cost: 0.0000001,
      provider_specific_entry: { us: 1.1, fast: 6 } },
    "gpt-image-example": { mode: "image_generation", input_cost_per_token: 9, output_cost_per_token: 9 },
    "other-model": { mode: "chat", input_cost_per_token: 9, output_cost_per_token: 9 },
  }));
  const run = () => spawnSync(process.execPath, [generator, "--input", input, "--output", output, "--date", "2026-10-23"], { encoding: "utf8" });
  let result = run(); assert.equal(result.status, 0, result.stderr);
  const first = readFileSync(output, "utf8");
  result = run(); assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(output, "utf8"), first);
  const table = JSON.parse(first);
  assert.deepEqual(Object.keys(table.models), ["claude-example", "gpt-example", "gpt-output-only-flex"]);
  assert.equal(table.models["claude-example"].fast.input, 0.000006);
  assert.equal(table.models["claude-example"].fast.cacheWrite, 0.0000075);
  // Priority maps to Fast and flex to Flex, each with only the categories the
  // source prices; the long-context tier carries its own service tiers.
  assert.deepEqual(table.models["gpt-example"], {
    base: { input: 0.000001, output: 0.000004, cacheRead: 0.0000001 },
    fast: { input: 0.000002, output: 0.000008, cacheRead: 0.0000002 },
    flex: { input: 0.0000005, output: 0.000002, cacheRead: 0.00000005 },
    longContext: { threshold: 272000, base: { input: 0.000002, output: 0.000006, cacheRead: 0.0000002 },
      fast: { input: 0.000004, output: 0.000012 } },
  });
  // A service tier without both an input and an output price is not invented.
  assert.deepEqual(table.models["gpt-output-only-flex"], { base: { input: 0.000001, output: 0.000004 } });
});

test("Codex cache writes use their own rate or the input rate and reasoning is not charged twice", async t => {
  const f = fixture(t, { "gpt-fixture": { base: { input: 0.000001, output: 0.000004, cacheRead: 0.0000001 } } });
  f.transcript("codex", codex("gpt-fixture", "standard", [{ input_tokens: 100, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 10, reasoning_output_tokens: 9 }]));
  const result = usage(await f.finish(), "codex").totals.today;
  assert.equal(result.tokens.total, 110);
  assert.ok(Math.abs(result.estimatedCostUSD - 0.000104) < 1e-12);
  const g = fixture(t, { "gpt-fixture": { base } });
  g.transcript("codex", codex("gpt-fixture", "standard", [{ input_tokens: 100, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 10 }]));
  assert.ok(Math.abs(usage(await g.finish(), "codex").totals.today.estimatedCostUSD - 0.000119) < 1e-12);
});

test("Codex cache reads without their own rate use the input rate", async t => {
  const f = fixture(t, { "gpt-fixture": { base: { input: 0.000001, output: 0.000004 } } });
  f.transcript("codex", codex("gpt-fixture", null, [{ input_tokens: 100, cached_input_tokens: 40, output_tokens: 10 }]));
  // 60 input + 40 cache read at the input rate + 10 output.
  assert.ok(Math.abs(usage(await f.finish(), "codex").totals.today.estimatedCostUSD - 0.00014) < 1e-12);
  const g = fixture(t, { "gpt-fixture": { base: { input: 0.000001, output: 0.000004, cacheRead: 0.0000001 } } });
  g.transcript("codex", codex("gpt-fixture", null, [{ input_tokens: 100, cached_input_tokens: 40, output_tokens: 10 }]));
  assert.ok(Math.abs(usage(await g.finish(), "codex").totals.today.estimatedCostUSD - 0.000104) < 1e-12);
});

test("unknown models and missing service-tier prices stay unpriced while mixed totals retain known estimates", async t => {
  const f = fixture(t);
  f.transcript("claude", [claude("unknown", "claude-unknown", { input_tokens: 100, output_tokens: 10 })]);
  let result = usage(await f.finish());
  assert.equal(result.totals.today.estimatedCostUSD, null);
  assert.equal(result.totals.today.unpricedTokens, 110);
  assert.equal(result.daily.at(-1).estimatedCostUSD, null);
  const g = fixture(t);
  g.transcript("claude", [claude("known", "claude-fixture", { input_tokens: 100, output_tokens: 10 }), claude("unknown", "claude-unknown", { input_tokens: 100, output_tokens: 10 })]);
  result = usage(await g.finish());
  assert.ok(Math.abs(result.totals.last30Days.estimatedCostUSD - 0.00014) < 1e-12);
  assert.equal(result.totals.last30Days.unpricedTokens, 110);
  const h = fixture(t, { "gpt-fixture": { base } });
  h.transcript("codex", codex("gpt-fixture", "priority", [{ input_tokens: 100, output_tokens: 10 }]));
  assert.equal(usage(await h.finish(), "codex").totals.today.estimatedCostUSD, null);
});

test("Codex service tiers without a known price stay unpriced while default routing is standard", async t => {
  const fast = { input: 0.000002, output: 0.000008, cacheRead: 0.0000002, cacheWrite: 0.0000025 };
  const flex = { input: 0.0000005, output: 0.000002, cacheRead: 0.00000005, cacheWrite: 0.000000625 };
  for (const [tier, expected] of [["ultrafast", null], ["default", 0.00014], [null, 0.00014]]) {
    const f = fixture(t, { "gpt-fixture": { base, fast, flex } });
    f.transcript("codex", codex("gpt-fixture", tier, [{ input_tokens: 100, output_tokens: 10 }]));
    const today = usage(await f.finish(), "codex").totals.today;
    if (expected === null) {
      assert.equal(today.estimatedCostUSD, null, tier);
      assert.equal(today.unpricedTokens, 110, tier);
    } else assert.ok(Math.abs(today.estimatedCostUSD - expected) < 1e-12, String(tier));
  }
});

test("a changed bundled price rebuilds unchanged transcripts even within the refresh interval", async t => {
  const f = fixture(t);
  f.transcript("claude", [claude("one", "claude-fixture", { input_tokens: 100, output_tokens: 10 })]);
  assert.ok(Math.abs(usage(await f.finish()).totals.today.estimatedCostUSD - 0.00014) < 1e-12);
  f.prices({ "claude-fixture": { base: { ...base, input: 0.000002 } } });
  assert.equal(f.query().refreshing, true);
  assert.ok(Math.abs(usage(await f.finish()).totals.today.estimatedCostUSD - 0.00024) < 1e-12);
  f.prices({ "claude-fixture": { base } }, "2026-10-24");
  const updated = await f.finish();
  assert.equal(updated.pricingVersion, "2026-10-24");
  assert.ok(Math.abs(usage(updated).totals.today.estimatedCostUSD - 0.00014) < 1e-12);
});

test("a price rebuild keeps old visible costs paired with their old table date until completion", async t => {
  const f = fixture(t);
  f.transcript("claude", [claude("held", "claude-fixture", { input_tokens: 100, output_tokens: 10 })], "held.jsonl");
  f.transcript("claude", [claude("newest", "claude-fixture", { input_tokens: 100, output_tokens: 10 })]);
  assert.ok(Math.abs(usage(await f.finish()).totals.today.estimatedCostUSD - 0.00028) < 1e-12);
  const hold = join(f.root, "hold"), reached = join(f.root, "held"), preload = join(f.root, "hold.mjs"), node = join(f.root, "node");
  writeFileSync(hold, "hold");
  writeFileSync(preload, `import fs from 'node:fs';import {Readable} from 'node:stream';import {syncBuiltinESMExports} from 'node:module';
const original=fs.createReadStream;
fs.createReadStream=function(path,options){const stream=original.call(this,path,options);if(String(path).endsWith('/held.jsonl')&&fs.existsSync(${JSON.stringify(hold)}))return Readable.from((async function*(){fs.writeFileSync(${JSON.stringify(reached)},'ready');while(fs.existsSync(${JSON.stringify(hold)}))await new Promise(r=>setTimeout(r,10));yield* stream;})());return stream;};syncBuiltinESMExports();`);
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  writeFileSync(node, `#!/bin/sh\nexec ${quote(process.execPath)} --import ${quote(preload)} "$@"\n`); chmodSync(node, 0o700);
  const runtimePath = join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  const runtime = JSON.parse(readFileSync(runtimePath)); runtime.node = node;
  writeFileSync(runtimePath, JSON.stringify(runtime)); writeFileSync(join(f.env.HERDR_PLUGIN_CONFIG_DIR, "runtime-node"), node + "\n");
  f.prices({ "claude-fixture": { base: { ...base, input: 0.000002 } } }, "2026-10-24");
  assert.equal(f.query().refreshing, true);
  for (let i = 0; i < 200 && !existsSync(reached); i++) await sleep(10);
  assert.ok(existsSync(reached));
  const midway = f.query();
  assert.equal(midway.refreshing, true);
  assert.equal(midway.pricingVersion, "2026-10-23");
  assert.ok(Math.abs(usage(midway).totals.today.estimatedCostUSD - 0.00028) < 1e-12);
  rmSync(hold);
  const final = await f.finish();
  assert.equal(final.pricingVersion, "2026-10-24");
  assert.ok(Math.abs(usage(final).totals.today.estimatedCostUSD - 0.00048) < 1e-12);
});

test("pre-pricing cached tokens are unpriced until their first priced rebuild completes", async t => {
  const f = fixture(t);
  f.transcript("claude", [claude("one", "claude-fixture", { input_tokens: 100, output_tokens: 10 })]);
  await f.finish();
  const parent = join(f.env.HERDR_PLUGIN_STATE_DIR, "usage");
  const path = join(parent, readdirSync(parent)[0], "buckets.json");
  const snapshot = JSON.parse(readFileSync(path));
  delete snapshot.pricingVersion; delete snapshot.checkpoint.pricingFingerprint;
  for (const bucket of snapshot.buckets) { delete bucket.estimatedCostUSD; delete bucket.unpricedTokens; }
  writeFileSync(path, JSON.stringify(snapshot));
  const first = f.query();
  assert.equal(first.refreshing, true);
  assert.equal(usage(first).totals.today.estimatedCostUSD, null);
  assert.equal(usage(first).totals.today.unpricedTokens, 110);
  assert.ok(Math.abs(usage(await f.finish()).totals.today.estimatedCostUSD - 0.00014) < 1e-12);
});

test("Codex long-context Fast and Flex select rates using all input categories", async t => {
  const model = { base, fast: { ...base, input: 0.000002 }, flex: { ...base, input: 0.0000005 }, longContext: { threshold: 100,
    base: { input: 0.000002, output: 0.000006, cacheRead: 0.0000002, cacheWrite: 0.0000025 },
    fast: { input: 0.000004, output: 0.000012, cacheRead: 0.0000004, cacheWrite: 0.000005 },
    flex: { input: 0.000001, output: 0.000003, cacheRead: 0.0000001, cacheWrite: 0.00000125 } } };
  for (const [tier, expected] of [["standard", 0.000226], ["fast", 0.000452], ["flex", 0.000113]]) {
    const f = fixture(t, { "gpt-fixture": model });
    f.transcript("codex", codex("gpt-fixture", tier, [{ input_tokens: 104, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 10 }]));
    assert.ok(Math.abs(usage(await f.finish(), "codex").totals.today.estimatedCostUSD - expected) < 1e-12, tier);
  }
  const f = fixture(t, { "gpt-fixture": model });
  f.transcript("codex", codex("gpt-fixture", "standard", [{ input_tokens: 100, cached_input_tokens: 40, cache_write_input_tokens: 60, output_tokens: 10 }]));
  assert.ok(Math.abs(usage(await f.finish(), "codex").totals.today.estimatedCostUSD - 0.000119) < 1e-12);
});

test("models.dev fallback converts per-million prices without inventing service tiers", t => {
  const root = mkdtempSync(join(tmpdir(), "heeler-price-fallback-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const input = join(root, "source.json"), output = join(root, "prices.json");
  writeFileSync(input, JSON.stringify({ anthropic: { models: { "claude-example": { cost: { input: 1, output: 4, cache_read: 0.1, cache_write: 1.25, context_over_200k: { input: 2, output: 6 } } } } } }));
  const result = spawnSync(process.execPath, [generator, "--source", "models-dev", "--input", input, "--output", output, "--date", "2026-10-23"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const model = JSON.parse(readFileSync(output)).models["claude-example"];
  assert.deepEqual(model.base, base);
  assert.equal(model.longContext.threshold, 200000);
  assert.equal(model.longContext.base.output, 0.000006);
  assert.equal(model.fast, undefined);
});
