import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  ActivityEnvelopeError,
  activityKeyId,
  decryptActivityEnvelope,
  encryptActivityEnvelope,
} from "../src/activity-envelope.js";

const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/live-activity-content-v1.json", import.meta.url), "utf8"),
);

function vectorKey(vector) {
  return Buffer.from(vector.key, "base64url");
}

function openedFields(payload) {
  return {
    v: payload.v,
    host: payload.host,
    agents: payload.agents.map((agent) => {
      const entry = { kind: agent.kind, pane: agent.pane, status: agent.status };
      if (typeof agent.title === "string" && agent.title.length > 0) entry.title = agent.title;
      return entry;
    }),
  };
}

suite("shared live-activity vectors (seal direction)", () => {
  test("vector file has cases", () => {
    assert.ok(vectors.valid.length >= 4);
    assert.ok(vectors.invalid.length >= 4);
    assert.ok(vectors.invalid.some((vector) => vector.error === "decrypt_failed"));
  });

  for (const vector of vectors.valid) {
    test(`derives the key id: ${vector.name}`, () => {
      assert.equal(activityKeyId(vectorKey(vector)), vector.keyId);
    });
  }

  for (const vector of vectors.valid.filter((vector) => !vector.decodeOnly)) {
    test(`seals canonically: ${vector.name}`, () => {
      const nonce = Buffer.from(JSON.parse(vector.envelope).n, "base64url");
      const envelope = encryptActivityEnvelope(vector.payload, vectorKey(vector), { nonce });
      assert.equal(envelope, vector.envelope);
    });
  }

  for (const vector of vectors.valid) {
    test(`opens: ${vector.name}`, () => {
      const payload = decryptActivityEnvelope(vector.envelope, vectorKey(vector));
      assert.deepEqual(openedFields(payload), openedFields(vector.payload));
    });
  }
});

suite("shared live-activity vectors (invalid)", () => {
  for (const vector of vectors.invalid) {
    test(`fails ${vector.error}: ${vector.name}`, () => {
      assert.throws(
        () => decryptActivityEnvelope(vector.envelope, vectorKey(vector)),
        (error) => error instanceof ActivityEnvelopeError && error.code === vector.error,
      );
    });
  }
});

suite("encryptActivityEnvelope", () => {
  const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
  const plaintext = {
    agents: [{ kind: "claude", pane: "wV:p1", status: "working" }],
    host: "mbp",
    v: 1,
  };

  test("generates a fresh random nonce when none is injected", () => {
    const first = JSON.parse(encryptActivityEnvelope(plaintext, key));
    const second = JSON.parse(encryptActivityEnvelope(plaintext, key));
    assert.equal(Buffer.from(first.n, "base64url").length, 12);
    assert.notEqual(first.n, second.n);
    assert.notEqual(first.ct, second.ct);
    assert.equal(first.kid, activityKeyId(key));
  });

  test("rejects a key that is not 32 bytes", () => {
    assert.throws(() => encryptActivityEnvelope(plaintext, Buffer.alloc(16)), TypeError);
  });
});
