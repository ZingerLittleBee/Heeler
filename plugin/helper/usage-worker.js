#!/usr/bin/env node
// The Helper's Usage worker, which its query starts detached. It reads Claude
// Code's limits in place.

import { runUsageWorker } from "./shared/usage/worker.js";
import { readAgyLimitsInDesktop } from "./usage/agy-limits-desktop.js";

try {
  await runUsageWorker({
    readAgyLimitsElsewhere: process.platform === "darwin" ? readAgyLimitsInDesktop : null,
  });
} catch {
  process.exitCode = 1;
}
