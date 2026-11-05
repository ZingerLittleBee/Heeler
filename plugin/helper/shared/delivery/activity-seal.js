// Sealing Live Activity content to fit, and delivering it through the Push
// Relay (docs/agents/live-activity-contract.md). Content over budget, or that
// the relay refuses as too large, sheds titles, then rows, then agents. Shared
// by the activity hook and the Host Helper (ADR 0033).

import { encryptActivityEnvelope } from "../activity-envelope.js";
import { sendLiveActivityPush } from "./push.js";

const CT_BUDGET = 2800;
const APNS_PAYLOAD_BUDGET = 4096;
const RELAY_REQUEST_BUDGET = 8192;
const STALE_AFTER_SECONDS = 900;

function dropTitles(plaintextObject) {
  return {
    agents: plaintextObject.agents.map((agent) => {
      const entry = {};
      entry.kind = agent.kind;
      entry.pane = agent.pane;
      if (Array.isArray(agent.rows)) entry.rows = agent.rows;
      entry.status = agent.status;
      if (typeof agent.workspace === "string" && agent.workspace.length > 0) {
        entry.workspace = agent.workspace;
      }
      return entry;
    }),
    host: plaintextObject.host,
    v: plaintextObject.v,
  };
}

function emptyAgents(plaintextObject) {
  return { agents: [], host: plaintextObject.host, v: plaintextObject.v };
}

function plaintextAtStep(plaintextObject, step) {
  if (step <= 0) return plaintextObject;
  if (step === 1) return dropTitles(plaintextObject);
  if (step === 2) {
    const content = dropTitles(plaintextObject);
    content.agents = content.agents.map(({ rows, ...agent }) => agent);
    return content;
  }
  return emptyAgents(plaintextObject);
}

function projectedApnsBytes(envelope, { event, timestamp, counts }) {
  const apns = {
    aps: {
      timestamp,
      event,
      "content-state": { counts, envelope: JSON.parse(envelope) },
    },
  };
  if (event === "update") apns.aps["stale-date"] = timestamp + STALE_AFTER_SECONDS;
  else apns.aps["dismissal-date"] = timestamp;
  return Buffer.byteLength(JSON.stringify(apns));
}

function relayBody({ device, event, priority, timestamp, counts, envelope }) {
  const body = {
    kind: "liveactivity",
    token: device.token,
    env: device.env,
    event,
    priority,
    timestamp,
    counts,
    envelope,
  };
  if (event === "update") body.stale_date = timestamp + STALE_AFTER_SECONDS;
  else body.dismissal_date = timestamp;
  return body;
}

function envelopeFits(envelope, request) {
  let parsed;
  try {
    parsed = JSON.parse(envelope);
  } catch {
    return false;
  }
  if (typeof parsed.ct === "string" && parsed.ct.length > CT_BUDGET) return false;
  if (projectedApnsBytes(envelope, request) > APNS_PAYLOAD_BUDGET) return false;
  const body = JSON.stringify(relayBody({ ...request, envelope }));
  if (Buffer.byteLength(body) > RELAY_REQUEST_BUDGET) return false;
  return true;
}

function sealFitting(plaintextObject, device, request) {
  let step = 0;
  let envelope = encryptActivityEnvelope(plaintextAtStep(plaintextObject, step), device.key);
  const sized = { ...request, device };
  while (step < 3 && !envelopeFits(envelope, sized)) {
    step += 1;
    envelope = encryptActivityEnvelope(plaintextAtStep(plaintextObject, step), device.key);
  }
  return { envelope, step };
}

/**
 * Seal `plaintextObject` for one device, send it, and keep shedding content
 * while the relay answers a 413. Returns "ok" or "pruned" (APNs 410); `config`
 * names the relay (`relayUrl`, `retryDelayMs`) and `request` the push's
 * `event`, `priority`, `timestamp` and `counts`. Conclusive failures throw.
 */
export async function deliverLiveActivity(config, device, plaintextObject, request) {
  let { envelope, step } = sealFitting(plaintextObject, device, request);
  while (true) {
    const outcome = await sendLiveActivityPush(
      config.relayUrl,
      relayBody({ ...request, device, envelope }),
      config.retryDelayMs,
    );
    if (outcome === "ok" || outcome === "pruned") return outcome;
    if (outcome === "too_large" && step < 3) {
      step += 1;
      envelope = encryptActivityEnvelope(plaintextAtStep(plaintextObject, step), device.key);
      continue;
    }
    throw new Error(`push for token ${device.token.slice(0, 8)}… failed: payload too large`);
  }
}
