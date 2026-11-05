const amount = value => Number.isFinite(value) && value >= 0 ? value : 0;
const usageFields = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"];
const normalizedUsage = usage => Object.fromEntries(usageFields.map(key => [key, amount(usage?.[key])]));
export function codexTotalSignature(usage) { return JSON.stringify(normalizedUsage(usage)); }

export function createCodexState(logicalPath) {
  return { logicalPath, threadId: null, directory: "unknown", model: "unknown", tier: "standard", previousTotal: null,
    recordSinceAdvance: false, inheritance: null, parentId: null, parentCursor: 0, inheritedEnded: true,
    leadingClosed: false, leadingLastTime: null, pending: [] };
}
function acceptCount(state, event, parentTotals) {
  if (state.inheritedEnded) return event.candidate ? [event.candidate] : [];
  if (state.inheritance === "fork" && parentTotals) {
    if (event.signature === parentTotals[state.parentCursor]) { state.parentCursor++; return []; }
    state.inheritedEnded = true;
    return event.candidate ? [event.candidate] : [];
  }
  return [];
}
function endLeadingBurst(state, parentTotals) {
  state.leadingClosed = true;
  const result = [];
  for (const event of state.pending) {
    if (event.trigger) {
      if (state.inheritance === "subagent") state.inheritedEnded = true;
    } else result.push(...acceptCount(state, event, parentTotals));
  }
  state.pending = [];
  if (state.inheritance === "fork" && !parentTotals) state.inheritedEnded = true;
  return result;
}
export function finishCodexRead(state, now, parentTotals = null) {
  return !state.leadingClosed && state.leadingLastTime !== null && now - state.leadingLastTime > 1000
    ? endLeadingBurst(state, parentTotals) : [];
}
function contribution(state, raw, timestamp, key, cutoff) {
  if (!Number.isFinite(timestamp) || timestamp < cutoff) return null;
  const usage = normalizedUsage(raw);
  const tokens = {
    input: Math.max(0, usage.input_tokens - usage.cached_input_tokens - usage.cache_write_input_tokens),
    cacheRead: usage.cached_input_tokens, cacheWrite: usage.cache_write_input_tokens,
    output: usage.output_tokens, reasoning: usage.reasoning_output_tokens,
  };
  tokens.total = tokens.input + tokens.cacheRead + tokens.cacheWrite + tokens.output;
  if (!tokens.total) return null;
  return { key, program: "codex", model: state.model, directory: state.directory, timestamp,
    bucket: Math.floor(timestamp / 900_000) * 900_000, tokens, tier: state.tier };
}
/** State contains only metadata and usage, so it can safely survive a partial read. */
export function consumeCodexLine(state, line, offset, cutoff, parentTotals = null) {
  if (!line || typeof line.payload !== "object" || !line.payload) return [];
  const payload = line.payload;
  const timestamp = Date.parse(line.timestamp);
  const result = [];
  if (line.type === "session_meta" && !state.threadId) {
    if (typeof payload.id !== "string") return [];
    state.threadId = payload.id;
    if (typeof payload.cwd === "string") state.directory = payload.cwd;
    if (!payload.history_base) {
      state.inheritance = typeof payload.session_id === "string" && payload.session_id !== payload.id ? "subagent"
        : typeof payload.forked_from_id === "string" ? "fork" : null;
      state.parentId = payload.forked_from_id || null;
      state.inheritedEnded = state.inheritance === null;
    }
  }
  if (!state.threadId) return [];
  if (Number.isFinite(timestamp) && !state.leadingClosed) {
    if (state.leadingLastTime !== null && timestamp - state.leadingLastTime > 1000) result.push(...endLeadingBurst(state, parentTotals));
    else state.leadingLastTime = timestamp;
  }
  if (line.type === "turn_context" && typeof payload.model === "string") state.model = payload.model;
  if (line.type === "event_msg" && payload.type === "thread_settings_applied") {
    if (typeof payload.thread_settings?.model === "string") state.model = payload.thread_settings.model;
    // The thread's requested tier. Absent or "default" is standard routing;
    // a tier this table cannot price stays unknown instead of standard.
    const tier = payload.thread_settings?.service_tier;
    state.tier = tier == null || tier === "default" || tier === "standard" ? "standard" : tier === "priority" || tier === "fast" ? "fast"
      : tier === "flex" ? "flex" : `unknown:${typeof tier === "string" ? tier : ""}`;
    if (!state.leadingClosed && payload.thread_id === state.threadId) {
      state.pending = [];
      state.inheritedEnded = true;
    }
  }
  if ((line.type === "inter_agent_communication_metadata" || line.type === "inter_agent_communication") && payload.trigger_turn === true) {
    if (state.leadingClosed && state.inheritance === "subagent") state.inheritedEnded = true;
    else if (!state.inheritedEnded) state.pending.push({ trigger: true });
  }
  if (line.type === "token_usage_record" && payload.thread_id === state.threadId && typeof payload.response_id === "string" && payload.usage) {
    state.recordSinceAdvance = true;
    return [...result, contribution(state, payload.usage, timestamp, JSON.stringify(["codex", "response", payload.response_id]), cutoff)].filter(Boolean);
  }
  if (line.type !== "event_msg" || payload.type !== "token_count" || !payload.info?.total_token_usage) return result;
  const total = normalizedUsage(payload.info.total_token_usage);
  const repeated = state.previousTotal && codexTotalSignature(total) === codexTotalSignature(state.previousTotal);
  const delta = payload.info.last_token_usage || Object.fromEntries(usageFields.map(key => [key, Math.max(0, total[key] - (state.previousTotal?.[key] || 0))]));
  const alreadyCounted = state.recordSinceAdvance;
  if (!repeated) {
    state.previousTotal = total;
    state.recordSinceAdvance = false;
  }
  const event = { signature: codexTotalSignature(total), candidate: repeated || alreadyCounted ? null
    : contribution(state, delta, timestamp, JSON.stringify(["codex", "event", state.threadId, state.logicalPath, offset]), cutoff) };
  if (!state.inheritedEnded && !state.leadingClosed) state.pending.push(event);
  else result.push(...acceptCount(state, event, parentTotals));
  return result;
}
