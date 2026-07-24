import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { generateBootstrapKey, publicLineFromSeed } from "../src/bootstrap-key.js";
import { fingerprintPublicKeyLine } from "../src/host-key.js";

// Key generated with `ssh-keygen -t ed25519`; the seed was extracted from the
// openssh-key-v1 private file, so the expected line is independent of the
// implementation under test.
const VECTOR_SEED = Buffer.from("1n6mUQHut1FJ4pJcfRp09db_30WxtZPx7lGUIYAl0Hk", "base64url");
const VECTOR_PUBLIC_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce";
const VECTOR_FINGERPRINT = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";

suite("publicLineFromSeed", () => {
  test("matches what ssh-keygen derives from the same seed", () => {
    assert.equal(publicLineFromSeed(VECTOR_SEED), VECTOR_PUBLIC_LINE);
  });

  test("fingerprints like ssh-keygen -lf", () => {
    const line = publicLineFromSeed(VECTOR_SEED);
    assert.equal(fingerprintPublicKeyLine(line).fingerprint, VECTOR_FINGERPRINT);
  });

  test("rejects a seed that is not 32 bytes", () => {
    assert.throws(() => publicLineFromSeed(Buffer.alloc(31)));
    assert.throws(() => publicLineFromSeed(Buffer.alloc(33)));
  });
});

suite("generateBootstrapKey", () => {
  test("returns a 32-byte seed that re-derives the same public line", () => {
    const { seed, publicLine } = generateBootstrapKey();
    assert.equal(seed.length, 32);
    assert.equal(publicLineFromSeed(seed), publicLine);
  });

  test("generates a distinct key each time", () => {
    assert.notEqual(generateBootstrapKey().publicLine, generateBootstrapKey().publicLine);
  });
});
