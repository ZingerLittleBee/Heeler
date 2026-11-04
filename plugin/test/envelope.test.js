import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  encodePairingCode,
  decodePairingCode,
  PairingCodeError,
} from "../src/envelope.js";

const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/pairing-code-v1.json", import.meta.url), "utf8"),
);

/** Convert a decoded payload (seed as Buffer) to the vector shape (seed as base64url). */
function toVectorShape(payload) {
  const shape = {
    addresses: payload.addresses,
    port: payload.port,
    username: payload.username,
    hostKeyFingerprint: payload.hostKeyFingerprint,
  };
  if (payload.bootstrapSeed !== undefined) {
    shape.bootstrapSeed = payload.bootstrapSeed.toString("base64url");
  }
  if (payload.expiresAt !== undefined) {
    shape.expiresAt = payload.expiresAt;
  }
  return shape;
}

/** Convert a vector payload (seed as base64url) to the encode input shape (seed as Buffer). */
function fromVectorShape(payload) {
  const input = { ...payload };
  if (input.bootstrapSeed !== undefined) {
    input.bootstrapSeed = Buffer.from(input.bootstrapSeed, "base64url");
  }
  return input;
}

suite("shared vectors", () => {
  test("vector file has cases", () => {
    assert.ok(vectors.valid.length >= 3);
    assert.ok(vectors.invalid.length >= 10);
  });

  for (const vector of vectors.valid) {
    test(`decodes: ${vector.name}`, () => {
      const decoded = decodePairingCode(vector.code);
      assert.deepEqual(toVectorShape(decoded), vector.payload);
    });
  }

  for (const vector of vectors.valid.filter((v) => !v.decodeOnly)) {
    test(`encodes canonically: ${vector.name}`, () => {
      assert.equal(encodePairingCode(fromVectorShape(vector.payload)), vector.code);
    });
  }

  for (const vector of vectors.invalid) {
    test(`rejects (${vector.error}): ${vector.name}`, () => {
      assert.throws(
        () => decodePairingCode(vector.code),
        (error) => error instanceof PairingCodeError && error.code === vector.error,
      );
    });
  }
});

suite("encodePairingCode", () => {
  const base = {
    addresses: ["192.168.1.42"],
    port: 22,
    username: "ada",
    hostKeyFingerprint: "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg",
  };

  test("round-trips through decode", () => {
    const decoded = decodePairingCode(encodePairingCode(base));
    assert.deepEqual(decoded, base);
  });

  test("rejects invalid payloads before encoding", () => {
    const bads = [
      { ...base, addresses: [] },
      { ...base, port: 0 },
      { ...base, port: 22.5 },
      { ...base, username: "" },
      { ...base, hostKeyFingerprint: "MD5:abc" },
      { ...base, bootstrapSeed: Buffer.alloc(31), expiresAt: 1753305600 },
      { ...base, bootstrapSeed: Buffer.alloc(32) },
      { ...base, expiresAt: 1753305600 },
    ];
    for (const bad of bads) {
      assert.throws(
        () => encodePairingCode(bad),
        (error) => error instanceof PairingCodeError && error.code === "bad_payload",
      );
    }
  });

  test("round-trips a bootstrap seed as raw bytes", () => {
    const seed = Buffer.from(Array.from({ length: 32 }, (_, i) => 255 - i));
    const decoded = decodePairingCode(
      encodePairingCode({ ...base, bootstrapSeed: seed, expiresAt: 1753305600 }),
    );
    assert.deepEqual(decoded.bootstrapSeed, seed);
    assert.equal(decoded.expiresAt, 1753305600);
  });
});

const vectorsV2 = JSON.parse(
  readFileSync(new URL("../test-vectors/pairing-code-v2.json", import.meta.url), "utf8"),
);

/** Map a code's wire JSON to the encode input shape, keeping absent keys absent. */
function payloadFromCode(code) {
  const wire = JSON.parse(Buffer.from(code.split(":")[2], "base64url").toString("utf8"));
  return {
    addresses: wire.addrs,
    port: wire.port,
    username: wire.user,
    hostKeyFingerprint: wire.fp,
    socketPath: wire.sock,
    herdrPath: wire.herdr,
    ...(wire.seed !== undefined && { bootstrapSeed: Buffer.from(wire.seed, "base64url") }),
    ...(wire.exp !== undefined && { expiresAt: wire.exp }),
  };
}

suite("Pairing Code v2 encoding", () => {
  const canonical = vectorsV2.valid.filter(
    (vector) => !vector.decodeOnly && vector.code.startsWith("HERDR-PAIR:2:"),
  );

  test("encodes every canonical v2 vector exactly", () => {
    assert.equal(canonical.length, 4);
    for (const vector of canonical) {
      assert.equal(encodePairingCode(fromVectorShape(vector.payload)), vector.code, vector.name);
    }
  });

  for (const vector of vectorsV2.invalid) {
    test(`rejects invalid v2 vector: ${vector.name}`, () => {
      assert.throws(
        () => encodePairingCode(payloadFromCode(vector.code)),
        (error) => error instanceof PairingCodeError && error.code === "bad_payload",
      );
    });
  }

  test("a payload without endpoint fields still encodes v1", () => {
    const { socketPath, herdrPath, ...v1 } = canonical[0].payload;
    assert.ok(encodePairingCode(fromVectorShape(v1)).startsWith("HERDR-PAIR:1:"));
  });

  test("decoding still rejects version 2", () => {
    assert.throws(
      () => decodePairingCode(canonical[0].code),
      (error) => error instanceof PairingCodeError && error.code === "unsupported_version",
    );
  });
});
