import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  decodePairingCodeV2,
  encodePairingCodeV2,
  PairingCodeError,
} from "../src/envelope.js";

const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/pairing-code-v2.json", import.meta.url), "utf8"),
);

function toVectorShape(payload) {
  const shape = {
    addresses: payload.addresses,
    port: payload.port,
    username: payload.username,
    hostKeyFingerprint: payload.hostKeyFingerprint,
  };
  if (payload.bootstrapSeed !== undefined) {
    shape.bootstrapSeed = payload.bootstrapSeed.toString("base64url");
    shape.expiresAt = payload.expiresAt;
  }
  return shape;
}

function fromVectorShape(payload) {
  const input = { ...payload };
  if (input.bootstrapSeed !== undefined) {
    input.bootstrapSeed = Buffer.from(input.bootstrapSeed, "base64url");
  }
  return input;
}

suite("Pairing Code v2 shared vectors", () => {
  test("vector file covers the contract", () => {
    assert.equal(vectors.valid.length, 3);
    assert.ok(vectors.invalid.length >= 13);
  });

  for (const vector of vectors.valid) {
    test(`decodes: ${vector.name}`, () => {
      const decoded = decodePairingCodeV2(Buffer.from(vector.envelopeHex, "hex"));
      assert.deepEqual(toVectorShape(decoded), vector.payload);
    });

    test(`encodes canonically: ${vector.name}`, () => {
      const encoded = encodePairingCodeV2(fromVectorShape(vector.payload));
      assert.equal(encoded.toString("hex"), vector.envelopeHex);
    });

    test(`round-trips: ${vector.name}`, () => {
      const input = fromVectorShape(vector.payload);
      assert.deepEqual(toVectorShape(decodePairingCodeV2(encodePairingCodeV2(input))), vector.payload);
    });
  }

  for (const vector of vectors.invalid) {
    test(`rejects (${vector.error}): ${vector.name}`, () => {
      assert.throws(
        () => decodePairingCodeV2(Buffer.from(vector.envelopeHex, "hex")),
        (error) => error instanceof PairingCodeError && error.code === vector.error,
      );
    });
  }
});

suite("encodePairingCodeV2", () => {
  const base = {
    addresses: ["192.168.1.42"],
    port: 22,
    username: "ada",
    hostKeyFingerprint: "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg",
  };

  test("uses the specified offsets for a hand-computed minimal envelope", () => {
    const bytes = encodePairingCodeV2(base);
    assert.equal(bytes.length, 48);
    assert.equal(bytes.subarray(0, 2).toString("ascii"), "HP");
    assert.equal(bytes[2], 2);
    assert.equal(bytes[3], 0);
    assert.equal(bytes.readUInt16BE(4), 22);
    assert.equal(bytes[6], 3);
    assert.equal(bytes.subarray(7, 10).toString("utf8"), "ada");
    assert.equal(
      bytes.subarray(10, 42).toString("hex"),
      "ebe8e770d7626ec1b672abdfa0b0291ab3bc0af230004333b01f888a53acf2d8",
    );
    assert.equal(bytes[42], 1);
    assert.equal(bytes[43], 4);
    assert.deepEqual([...bytes.subarray(44, 48)], [192, 168, 1, 42]);
  });

  test("canonicalizes IPv6 after a binary round-trip", () => {
    const decoded = decodePairingCodeV2(
      encodePairingCodeV2({ ...base, addresses: ["2001:0DB8:0:0:0:0:0:1"] }),
    );
    assert.deepEqual(decoded.addresses, ["2001:db8::1"]);
  });

  test("falls back to hostname encoding for non-IP address strings", () => {
    const bytes = encodePairingCodeV2({ ...base, addresses: ["fe80::1%en0"] });
    assert.equal(bytes[43], 0);
    assert.deepEqual(decodePairingCodeV2(bytes).addresses, ["fe80::1%en0"]);
  });

  test("rejects values that do not fit v2 length fields", () => {
    const bads = [
      { ...base, addresses: Array(256).fill("192.0.2.1") },
      { ...base, username: "ü".repeat(128) },
      { ...base, addresses: [`${"é".repeat(124)}.example`] },
      { ...base, bootstrapSeed: Buffer.alloc(32), expiresAt: 0x1_0000_0000 },
      { ...base, hostKeyFingerprint: `SHA256:${"/".repeat(43)}` },
    ];
    for (const bad of bads) {
      assert.throws(
        () => encodePairingCodeV2(bad),
        (error) => error instanceof PairingCodeError && error.code === "bad_payload",
      );
    }
  });
});
