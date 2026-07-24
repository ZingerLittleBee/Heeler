// Fixed-window request counting, held entirely in worker-instance memory.
//
// The relay is stateless by design (ADR 0008): no database, so these windows
// are per-isolate and best-effort. That is enough to blunt quota-burning
// abuse of a public endpoint; it is not a billing-grade quota system.

const WINDOW_MS = 60_000;
const MAX_ENTRIES = 10_000;

/**
 * @param {{windowMs?: number, maxEntries?: number}} [options]
 */
export function createFixedWindowLimiter({ windowMs = WINDOW_MS, maxEntries = MAX_ENTRIES } = {}) {
  /** @type {Map<string, {start: number, count: number}>} */
  const windows = new Map();

  function prune(nowMs) {
    for (const [key, entry] of windows) {
      if (nowMs - entry.start >= windowMs) {
        windows.delete(key);
      }
    }
  }

  return {
    /** Entry count, exposed for the pruning tests. */
    get size() {
      return windows.size;
    },

    /**
     * Count one request against `key` and report whether it is within
     * `limit` requests per window.
     *
     * @param {string} key
     * @param {number} limit
     * @param {number} nowMs
     * @returns {{allowed: true} | {allowed: false, retryAfterSeconds: number}}
     */
    check(key, limit, nowMs) {
      const entry = windows.get(key);
      if (entry === undefined || nowMs - entry.start >= windowMs) {
        if (windows.size >= maxEntries) {
          prune(nowMs);
        }
        windows.set(key, { start: nowMs, count: 1 });
        if (limit >= 1) {
          return { allowed: true };
        }
        return { allowed: false, retryAfterSeconds: Math.ceil(windowMs / 1000) };
      }
      entry.count += 1;
      if (entry.count > limit) {
        const retryAfterSeconds = Math.max(1, Math.ceil((entry.start + windowMs - nowMs) / 1000));
        return { allowed: false, retryAfterSeconds };
      }
      return { allowed: true };
    },
  };
}
