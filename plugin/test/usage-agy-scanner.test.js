import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { agyDirectories, agyFiles, consumeAgyLine, normalizeAgyModelLabel } from "../src/usage/agy-scanner.js";
import { priceContribution } from "../src/usage/pricing.js";

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), "heeler-agy-scanner-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test("normalizeAgyModelLabel matches Antigravity CLI slugs and known orchestrator labels", () => {
  assert.equal(normalizeAgyModelLabel("Gemini 3.8 Flash (High)"), "gemini-3.8-flash-high");
  assert.equal(normalizeAgyModelLabel("Gemini 4 Carbon (High)"), "gemini-4-carbon-high");
  assert.equal(normalizeAgyModelLabel("Claude Opus 4.6 (Thinking)"), "claude-opus-4-6-thinking");
  assert.equal(normalizeAgyModelLabel("Orchestrator (Carbon)"), "gemini-pro-orchestrator");
  assert.equal(normalizeAgyModelLabel("Orchestrator (Argon)"), "gemini-pro-orchestrator-argon");
  assert.equal(normalizeAgyModelLabel("gemini-2.5-pro"), "gemini-2.5-pro");
  assert.equal(normalizeAgyModelLabel("None"), null);
  assert.equal(normalizeAgyModelLabel("   "), null);
});

test("consumeAgyLine tracks model outside USER_REQUEST, emits PLANNER_RESPONSE and CHECKPOINT, and prices base models", () => {
  const carry = {};
  const cutoff = Date.parse("2026-10-01T00:00:00Z");
  const at = "2026-10-23T10:15:00Z";
  const directories = new Map([["11111111-2222-3333-4444-555555555555", "/work/parent"]]);

  // Spoofed <USER_SETTINGS_CHANGE> inside <USER_REQUEST> must be ignored.
  assert.equal(consumeAgyLine(carry, {
    step_index: 1,
    type: "USER_INPUT",
    created_at: at,
    content: "<USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Claude Opus 4.6 (Thinking).\n</USER_SETTINGS_CHANGE>\n</USER_REQUEST>",
  }, "child-id", undefined, cutoff, directories), null);
  assert.equal(carry.model, undefined);

  // Real <USER_SETTINGS_CHANGE> after </USER_REQUEST> sets carry.model.
  consumeAgyLine(carry, {
    step_index: 2,
    type: "USER_INPUT",
    created_at: at,
    content: "<USER_REQUEST>\nhello\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.8 Flash (High). No need to comment on the setting change.\n</USER_SETTINGS_CHANGE>",
  }, "child-id", undefined, cutoff, directories);
  assert.equal(carry.model, "gemini-3.8-flash-high");

  // SYSTEM_MESSAGE sender=<uuid> resolves parent workspace when child has none of its own.
  consumeAgyLine(carry, {
    step_index: 3,
    type: "SYSTEM_MESSAGE",
    created_at: at,
    content: "[Message] timestamp=2026-10-23T10:15:00Z sender=11111111-2222-3333-4444-555555555555 priority=MESSAGE_PRIORITY_HIGH content=task",
  }, "child-id", undefined, cutoff, directories);

  const planner = consumeAgyLine(carry, {
    step_index: 4,
    type: "PLANNER_RESPONSE",
    created_at: at,
    input_tokens: 1_000_000,
    cache_read_tokens: 0,
    output_tokens: 100_000,
  }, "child-id", undefined, cutoff, directories);
  assert.equal(planner.key, '["agy","child-id",4]');
  assert.equal(planner.model, "gemini-3.8-flash-high");
  assert.equal(planner.directory, "/work/parent");
  assert.deepEqual(planner.tokens, { input: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 100_000, reasoning: 0, total: 1_100_000 });

  // Pricing strips `-high` to match `gemini-3.8-flash` in pricing.json.
  const priced = priceContribution(planner);
  assert.equal(typeof priced.estimatedCostUSD, "number");
  assert.ok(priced.estimatedCostUSD > 0);
  assert.equal(priced.unpricedTokens, 0);

  // Explicit `model` on PLANNER_RESPONSE overrides carry, and internal codenames stay unpriced.
  const checkpoint = consumeAgyLine(carry, {
    step_index: 5,
    type: "CHECKPOINT",
    created_at: at,
    input_tokens: 500,
    cache_read_tokens: 200,
    output_tokens: 100,
  }, "child-id", "alt00001", cutoff, directories);
  assert.equal(checkpoint.key, '["agy","alt00001","child-id",5]');
  assert.equal(checkpoint.tokens.total, 800);

  const carbon = consumeAgyLine(carry, {
    step_index: 6,
    type: "PLANNER_RESPONSE",
    created_at: at,
    model: "gemini-4-carbon-high",
    input_tokens: 300,
    output_tokens: 100,
  }, "child-id", undefined, cutoff, directories);
  const pricedCarbon = priceContribution(carbon);
  assert.ok(Math.abs(pricedCarbon.estimatedCostUSD - 0.0016) < 1e-12);
  assert.equal(pricedCarbon.unpricedTokens, 0);

  const orchestrator = consumeAgyLine(carry, {
    step_index: 7,
    type: "PLANNER_RESPONSE",
    created_at: at,
    model: "gemini-pro-orchestrator",
    input_tokens: 300,
    output_tokens: 100,
  }, "child-id", undefined, cutoff, directories);
  const unpriced = priceContribution(orchestrator);
  assert.equal(unpriced.estimatedCostUSD, null);
  assert.equal(unpriced.unpricedTokens, 400);
});

test("agyFiles lists in-window transcripts, marks older ones, and deduplicates symlinks", async t => {
  const root = tempDir(t);
  const home = join(root, "agy");
  const recent = join(home, "brain", "conv-recent", ".system_generated", "logs", "transcript_full.jsonl");
  const old = join(home, "brain", "conv-old", ".system_generated", "logs", "transcript_full.jsonl");
  mkdirSync(join(recent, ".."), { recursive: true });
  mkdirSync(join(old, ".."), { recursive: true });
  writeFileSync(recent, "{}\n");
  writeFileSync(old, "{}\n");
  const oldTime = new Date(Date.now() - 40 * 86_400_000);
  utimesSync(old, oldTime, oldTime);
  symlinkSync(join(home, "brain", "conv-recent"), join(home, "brain", "conv-alias"));

  const cutoff = Date.now() - 30 * 86_400_000;
  const listing = await agyFiles([home, join(root, "missing-agy")], cutoff);
  assert.equal(listing.rootFailed, false);
  assert.equal(listing.older, true);
  assert.equal(listing.files.length, 1);
  assert.equal(listing.files[0].conversationId, "conv-recent");
});

test("agyFiles reports rootFailed only when an existing brain directory cannot be listed", { skip: process.getuid?.() === 0 && "root ignores directory modes" }, async t => {
  const root = tempDir(t);
  const locked = join(root, "locked");
  mkdirSync(join(locked, "brain"), { recursive: true });
  chmodSync(join(locked, "brain"), 0o000);
  try {
    const failed = await agyFiles([locked], 0);
    assert.equal(failed.rootFailed, true);

    const readable = join(root, "readable");
    mkdirSync(join(readable, "brain"), { recursive: true });
    const mixed = await agyFiles([locked, readable], 0);
    assert.equal(mixed.rootFailed, false);
    assert.equal(mixed.unreadable.length, 1);
  } finally {
    chmodSync(join(locked, "brain"), 0o700);
  }
});

test("agyDirectories reads history.jsonl and conversation_summaries.db without creating WAL files", t => {
  const root = tempDir(t);
  writeFileSync(join(root, "history.jsonl"), [
    JSON.stringify({ conversationId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", workspace: "/work/from-history" }),
    "not-json",
  ].join("\n") + "\n");

  const sqlite = spawnSync("sqlite3", ["--version"], { encoding: "utf8" });
  if (sqlite.status !== 0) {
    const map = agyDirectories([root], process.env);
    assert.equal(map.get("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), "/work/from-history");
    return;
  }

  const dbPath = join(root, "conversation_summaries.db");
  const init = spawnSync("sqlite3", [
    dbPath,
    [
      "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, workspace_uris TEXT, parent_conversation_id TEXT);",
      "INSERT INTO conversation_summaries VALUES ('11111111-1111-1111-1111-111111111111', '[\"file:///work/from-db\"]', '');",
      "INSERT INTO conversation_summaries VALUES ('22222222-2222-2222-2222-222222222222', '[]', '11111111-1111-1111-1111-111111111111');",
    ].join(" "),
  ], { encoding: "utf8" });
  assert.equal(init.status, 0, init.stderr);
  assert.equal(existsSync(`${dbPath}-wal`), false);

  const map = agyDirectories([root], process.env);
  assert.equal(existsSync(`${dbPath}-wal`), false, "immutable=1 read must never create -wal on a closed database");
  assert.equal(existsSync(`${dbPath}-shm`), false, "immutable=1 read must never create -shm on a closed database");
  assert.equal(map.get("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), "/work/from-history");
  assert.equal(map.get("11111111-1111-1111-1111-111111111111"), "/work/from-db");
  assert.equal(map.get("22222222-2222-2222-2222-222222222222"), "/work/from-db");
});
