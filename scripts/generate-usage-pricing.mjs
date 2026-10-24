#!/usr/bin/env node
// Price data: LiteLLM and models.dev are MIT licensed. Review the generated diff
// and regenerate this bundled table before each plugin release. No runtime fetch.
import { parseArgs } from "node:util";
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const SOURCES = {
  litellm: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
  "models-dev": "https://models.dev/api.json",
};
const fields = { input: "input_cost_per_token", output: "output_cost_per_token", cacheRead: "cache_read_input_token_cost", cacheWrite: "cache_creation_input_token_cost" };
const valid = value => typeof value === "number" && Number.isFinite(value) && value >= 0;
function rates(entry, suffix = "") {
  const result = {};
  for (const [field, source] of Object.entries(fields)) if (valid(entry[source + suffix])) result[field] = entry[source + suffix];
  return valid(result.input) && valid(result.output) ? result : null;
}
function tier(entry, suffix = "") {
  const base = rates(entry, suffix);
  if (!base) return null;
  const result = { base };
  for (const [mode, name] of [["fast", "priority"], ["flex", "flex"]]) {
    const value = rates(entry, suffix + "_" + name);
    if (value) result[mode] = value;
  }
  // Claude's source explicitly supplies the Fast multiplier; regional uplifts
  // are deliberately ignored. It applies to every token category, caches too.
  const multiplier = entry.provider_specific_entry?.fast;
  if (valid(multiplier) && multiplier > 0 && !result.fast) {
    result.fast = Object.fromEntries(Object.entries(base).map(([key, value]) => [key, Number((value * multiplier).toPrecision(15))]));
  }
  return result;
}
function fromLiteLLM(source) {
  const models = {};
  for (const name of Object.keys(source).sort()) {
    const entry = source[name];
    if (!/^(claude-|gpt-)/.test(name) || !["chat", "responses"].includes(entry.mode)) continue;
    const model = tier(entry);
    if (!model) continue;
    const thresholds = Object.keys(entry).map(key => /^input_cost_per_token_above_(\d+)k_tokens$/.exec(key)?.[1]).filter(Boolean).map(Number).sort((a, b) => a - b);
    if (thresholds.length > 1) throw new Error(`Multiple context thresholds for ${name}; review the contract before generating.`);
    if (thresholds.length) {
      const threshold = thresholds[0];
      const long = tier(entry, `_above_${threshold}k_tokens`);
      if (!long) throw new Error(`Incomplete long-context rates for ${name}.`);
      model.longContext = { threshold: threshold * 1000, ...long };
    }
    models[name] = model;
  }
  return models;
}
function fromModelsDev(source) {
  const models = {};
  for (const provider of ["anthropic", "openai"]) for (const [name, entry] of Object.entries(source[provider]?.models || {})) {
    if (!/^(claude-|gpt-)/.test(name) || !valid(entry.cost?.input) || !valid(entry.cost?.output)) continue;
    const convert = cost => Object.fromEntries([["input", cost.input], ["output", cost.output], ["cacheRead", cost.cache_read], ["cacheWrite", cost.cache_write]].filter(([, value]) => valid(value)).map(([key, value]) => [key, Number((value / 1_000_000).toPrecision(15))]));
    const model = { base: convert(entry.cost) };
    const thresholds = Object.keys(entry.cost).filter(key => /^context_over_\d+k$/.test(key));
    if (thresholds.length > 1) throw new Error(`Multiple context thresholds for ${name}; review the contract before generating.`);
    if (thresholds.length) {
      const key = thresholds[0], cost = entry.cost[key];
      if (!valid(cost.input) || !valid(cost.output)) throw new Error(`Incomplete long-context rates for ${name}.`);
      model.longContext = { threshold: Number(key.match(/\d+/)[0]) * 1000, base: convert(cost) };
    }
    models[name] = model;
  }
  return Object.fromEntries(Object.entries(models).sort(([a], [b]) => a.localeCompare(b, "en")));
}
async function download(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`Price source returned HTTP ${response.status}.`);
  return response.text();
}
try {
  const { values } = parseArgs({ options: { input: { type: "string" }, output: { type: "string" }, date: { type: "string" }, source: { type: "string", default: "litellm" } } });
  let source = values.source;
  if (!Object.hasOwn(SOURCES, source)) throw new Error("Choose litellm or models-dev.");
  const pricingVersion = values.date || new Date().toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(pricingVersion) || new Date(pricingVersion).toISOString().slice(0, 10) !== pricingVersion) throw new Error("Use a valid YYYY-MM-DD price date.");
  let text;
  if (values.input) text = readFileSync(values.input, "utf8");
  else {
    try { text = await download(SOURCES[source]); }
    catch (error) {
      if (source !== "litellm") throw error;
      source = "models-dev";
      console.error("LiteLLM unavailable; using models.dev. Review the resulting coverage and price diff.");
      text = await download(SOURCES[source]);
    }
  }
  const parsed = JSON.parse(text);
  const models = source === "litellm" ? fromLiteLLM(parsed) : fromModelsDev(parsed);
  if (!Object.keys(models).length) throw new Error("The source contains no supported token prices.");
  const table = { pricingVersion, source: SOURCES[source], sourceSHA256: createHash("sha256").update(text).digest("hex"), license: "MIT", models };
  writeFileSync(values.output || fileURLToPath(new URL("../plugin/src/usage/pricing.json", import.meta.url)), JSON.stringify(table, null, 2) + "\n");
  console.log(`Wrote ${Object.keys(models).length} models (${pricingVersion}, ${source}).`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
