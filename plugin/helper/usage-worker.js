#!/usr/bin/env node
// The Helper's Usage worker, which its query starts detached. It reads Claude
// Code's limits in place.

import { runUsageWorker } from "./shared/usage/worker.js";

try {
  await runUsageWorker();
} catch {
  process.exitCode = 1;
}
