#!/usr/bin/env node

import { parseArgs } from "node:util";

import { answerAgyLimitsRequest } from "./shared/usage/agy-limits.js";
import { cacheDirectory } from "./shared/usage/cache.js";
import { readUsageRuntime } from "./shared/usage/runtime-record.js";

try {
  const { values } = parseArgs({ options: { config: { type: "string" } }, allowPositionals: false });
  const runtime = readUsageRuntime(values.config);
  if (runtime) await answerAgyLimitsRequest(runtime, cacheDirectory(runtime));
} catch {
  process.exitCode = 1;
}
