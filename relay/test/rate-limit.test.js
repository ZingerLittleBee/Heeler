import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { createFixedWindowLimiter } from "../src/rate-limit.js";

suite("createFixedWindowLimiter", () => {
  const t0 = 1_753_305_600_000;

  test("allows up to the limit within one window", () => {
    const limiter = createFixedWindowLimiter();
    for (let i = 0; i < 3; i += 1) {
      assert.equal(limiter.check("a", 3, t0 + i * 1000).allowed, true);
    }
  });

  test("rejects over the limit with the seconds left in the window", () => {
    const limiter = createFixedWindowLimiter();
    limiter.check("a", 2, t0);
    limiter.check("a", 2, t0);
    const verdict = limiter.check("a", 2, t0 + 10_000);
    assert.equal(verdict.allowed, false);
    assert.equal(verdict.retryAfterSeconds, 50);
  });

  test("resets when the window rolls over", () => {
    const limiter = createFixedWindowLimiter();
    limiter.check("a", 1, t0);
    assert.equal(limiter.check("a", 1, t0 + 30_000).allowed, false);
    assert.equal(limiter.check("a", 1, t0 + 60_000).allowed, true);
  });

  test("tracks keys independently", () => {
    const limiter = createFixedWindowLimiter();
    limiter.check("a", 1, t0);
    assert.equal(limiter.check("a", 1, t0).allowed, false);
    assert.equal(limiter.check("b", 1, t0).allowed, true);
  });

  test("a zero limit rejects the first request", () => {
    const limiter = createFixedWindowLimiter();
    assert.equal(limiter.check("a", 0, t0).allowed, false);
  });

  test("prunes expired entries instead of growing without bound", () => {
    const limiter = createFixedWindowLimiter({ maxEntries: 100 });
    for (let i = 0; i < 100; i += 1) {
      limiter.check(`old-${i}`, 1, t0);
    }
    assert.equal(limiter.size, 100);
    // All 100 windows expired; inserting a new key sweeps them.
    limiter.check("fresh", 1, t0 + 120_000);
    assert.equal(limiter.size, 1);
  });
});
