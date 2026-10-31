import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("./pricing.json", import.meta.url), "utf8");
const table = JSON.parse(source);
export const pricingVersion = table.pricingVersion;
export const pricingFingerprint = createHash("sha256").update(source).digest("hex");

/** Attach one request's estimate before deduplication and bucket aggregation. */
export function priceContribution(record) {
  const model = table.models[record.model];
  if (!model) return { ...record, estimatedCostUSD: null, unpricedTokens: record.tokens.total };
  const tokens = record.tokens;
  const context = tokens.input + tokens.cacheRead + tokens.cacheWrite;
  const tier = model.longContext && context > model.longContext.threshold ? model.longContext : model;
  // Claude records carry no tier; an unknown Codex tier has no rates here.
  const mode = record.speed === "fast" || ["priority", "fast"].includes(record.tier) ? "fast"
    : record.tier === "flex" ? "flex" : record.tier === undefined || record.tier === "standard" ? "base" : null;
  const rates = mode && tier[mode];
  if (!rates) return { ...record, estimatedCostUSD: null, unpricedTokens: tokens.total };
  const cacheRead = rates.cacheRead ?? rates.input;
  const cacheWrite = rates.cacheWrite ?? rates.input;
  const writes = record.program === "claude"
    ? record.write5m * cacheWrite + record.write1h * rates.input * 2
    : tokens.cacheWrite * cacheWrite;
  const estimatedCostUSD = tokens.input * rates.input + tokens.cacheRead * cacheRead + writes + tokens.output * rates.output;
  return { ...record, estimatedCostUSD, unpricedTokens: 0 };
}
