import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  readPairingConfig,
  writePairingConfig,
  MAX_CUSTOM_ADDRESSES,
} from "../src/pairing-config.js";

suite("pairing config", () => {
  let configDir;

  beforeEach(() => {
    configDir = mkdtempSync(join(tmpdir(), "pairing-config-"));
  });

  afterEach(() => rmSync(configDir, { recursive: true, force: true }));

  test("a missing file yields no custom addresses", () => {
    assert.deepEqual(readPairingConfig(configDir), { addresses: [] });
  });

  test("round-trips written addresses in order", () => {
    writePairingConfig(configDir, ["login.example.ts.net", "10.8.4.18"]);
    assert.deepEqual(readPairingConfig(configDir), {
      addresses: ["login.example.ts.net", "10.8.4.18"],
    });
  });

  test("writes v1 with custom_addresses and creates a missing directory", () => {
    const nested = join(configDir, "pairing");
    writePairingConfig(nested, ["host.example.com"]);
    const file = JSON.parse(readFileSync(join(nested, "pairing.json"), "utf8"));
    assert.equal(file.v, 1);
    assert.deepEqual(file.custom_addresses, ["host.example.com"]);
  });

  test("preserves unknown fields across rewrites", () => {
    writePairingConfig(configDir, ["a.example.com"]);
    const path = join(configDir, "pairing.json");
    const file = JSON.parse(readFileSync(path, "utf8"));
    file.future_field = { keep: true };
    writeFileSync(path, JSON.stringify(file));
    writePairingConfig(configDir, ["b.example.com"]);
    const rewritten = JSON.parse(readFileSync(path, "utf8"));
    assert.deepEqual(rewritten.future_field, { keep: true });
    assert.deepEqual(rewritten.custom_addresses, ["b.example.com"]);
  });

  test("malformed or future files fall back to no custom addresses", () => {
    const path = join(configDir, "pairing.json");
    for (const contents of [
      "not json",
      "null",
      "[]",
      '{"v": 2, "custom_addresses": ["a.example.com"]}',
      '{"custom_addresses": ["a.example.com"]}',
      '{"v": 1, "custom_addresses": "a.example.com"}',
      '{"v": 1, "custom_addresses": ["a.example.com", "two words"]}',
      '{"v": 1, "custom_addresses": ["a.example.com", 42]}',
    ]) {
      writeFileSync(path, contents);
      assert.deepEqual(readPairingConfig(configDir), { addresses: [] }, contents);
    }
  });

  test("rejects more than the maximum custom addresses", () => {
    const many = Array.from({ length: MAX_CUSTOM_ADDRESSES + 1 }, (_, i) => `h${i}.example.com`);
    writePairingConfig(configDir, many.slice(0, MAX_CUSTOM_ADDRESSES));
    assert.equal(readPairingConfig(configDir).addresses.length, MAX_CUSTOM_ADDRESSES);
    writeFileSync(
      join(configDir, "pairing.json"),
      JSON.stringify({ v: 1, custom_addresses: many }),
    );
    assert.deepEqual(readPairingConfig(configDir), { addresses: [] });
  });
});
