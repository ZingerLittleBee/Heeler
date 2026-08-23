import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  encryptNotificationEnvelope,
  notificationKeyId,
  NotificationEnvelopeError,
} from "../src/notification-envelope.js";

const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/notification-payload-v1.json", import.meta.url), "utf8"),
);

/** Decode a vector's unpadded-base64url Notification Key to raw bytes. */
function vectorKey(vector) {
  return Buffer.from(vector.key, "base64url");
}

suite("shared vectors (encrypt direction)", () => {
  test("vector file has cases", () => {
    assert.ok(vectors.valid.length >= 3);
    assert.ok(vectors.invalid.length >= 10);
    assert.ok(vectors.invalid.some((v) => v.error === "decrypt_failed"));
  });

  for (const vector of vectors.valid) {
    test(`derives the key id: ${vector.name}`, () => {
      assert.equal(notificationKeyId(vectorKey(vector)), vector.keyId);
    });
  }

  for (const vector of vectors.valid.filter((v) => !v.decodeOnly)) {
    test(`encrypts canonically: ${vector.name}`, () => {
      const nonce = Buffer.from(JSON.parse(vector.envelope).n, "base64url");
      const envelope = encryptNotificationEnvelope(vector.payload, vectorKey(vector), { nonce });
      assert.equal(envelope, vector.envelope);
    });
  }
});

suite("encryptNotificationEnvelope", () => {
  const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
  // Observed-family herdr pane id (opaque `w…:p…`, uppercase included).
  // This payload only needs a non-empty string; the live shape keeps the
  // fixture from re-teaching the retired tmux-style `%N` habit.
  const payload = {
    paneId: "wV:p1",
    agentKind: "claude",
    status: "blocked",
    timestamp: 1753305600,
  };

  test("generates a fresh random nonce when none is injected", () => {
    const first = JSON.parse(encryptNotificationEnvelope(payload, key));
    const second = JSON.parse(encryptNotificationEnvelope(payload, key));
    assert.equal(Buffer.from(first.n, "base64url").length, 12);
    assert.notEqual(first.n, second.n);
    assert.notEqual(first.ct, second.ct);
    assert.equal(first.kid, notificationKeyId(key));
  });

  test("rejects invalid payloads before encrypting", () => {
    const bads = [
      { ...payload, paneId: "" },
      { ...payload, paneId: 5 },
      { ...payload, agentKind: "" },
      { ...payload, status: "" },
      { ...payload, status: undefined },
      { ...payload, timestamp: 0 },
      { ...payload, timestamp: 17.5 },
      { ...payload, timestamp: "1753305600" },
      { ...payload, project: 5 },
      { ...payload, title: {} },
      { ...payload, title: "x".repeat(257) },
    ];
    for (const bad of bads) {
      assert.throws(
        () => encryptNotificationEnvelope(bad, key),
        (error) => error instanceof NotificationEnvelopeError && error.code === "bad_payload",
      );
    }
  });

  /// Absent, null, and empty must all encode the same way, so a Host that
  /// failed to resolve a display field still produces a canonical envelope.
  test("omits display fields that are absent, null, or empty", () => {
    const nonce = Buffer.alloc(12);
    const baseline = encryptNotificationEnvelope(payload, key, { nonce });
    for (const variant of [
      { ...payload, project: null, title: null },
      { ...payload, project: "", title: "" },
      { ...payload, project: undefined, title: undefined },
    ]) {
      assert.equal(encryptNotificationEnvelope(variant, key, { nonce }), baseline);
    }
    assert.notEqual(
      encryptNotificationEnvelope({ ...payload, project: "Caterm" }, key, { nonce }),
      baseline,
    );
  });

  test("rejects a key that is not 32 bytes", () => {
    assert.throws(() => encryptNotificationEnvelope(payload, Buffer.alloc(16)), TypeError);
  });

  test("rejects an injected nonce that is not 12 bytes", () => {
    assert.throws(
      () => encryptNotificationEnvelope(payload, key, { nonce: Buffer.alloc(8) }),
      TypeError,
    );
  });
});
