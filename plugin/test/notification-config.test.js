import { afterEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_RELAY_URL,
  LEGACY_DEFAULT_RELAY_URLS,
  readNotificationConfig,
} from "../src/notification-config.js";

let configDir;

afterEach(() => {
  if (configDir) rmSync(configDir, { recursive: true, force: true });
  configDir = undefined;
});

function writeConfig(config) {
  configDir = mkdtempSync(join(tmpdir(), "notification-config-"));
  mkdirSync(configDir, { recursive: true });
  writeFileSync(join(configDir, "notify.json"), JSON.stringify(config));
}

suite("notification config", () => {
  test("uses the production relay when notify.json is absent", () => {
    configDir = mkdtempSync(join(tmpdir(), "notification-config-"));

    assert.equal(readNotificationConfig(configDir).relayUrl, DEFAULT_RELAY_URL);
  });

  test("preserves an explicit custom relay and normalizes trailing slashes", () => {
    writeConfig({ relay_url: " https://relay.example.com/// " });

    assert.equal(readNotificationConfig(configDir).relayUrl, "https://relay.example.com");
  });

  // Driven by the endpoint list itself, so retiring another production
  // endpoint cannot ship without its migration being covered.
  for (const legacy of LEGACY_DEFAULT_RELAY_URLS) {
    test(`migrates the retired ${legacy} endpoint to production`, () => {
      writeConfig({ relay_url: `${legacy}/` });

      assert.equal(readNotificationConfig(configDir).relayUrl, DEFAULT_RELAY_URL);
    });
  }

  test("uses the documented debounce and retry defaults", () => {
    configDir = mkdtempSync(join(tmpdir(), "notification-config-"));

    assert.deepEqual(readNotificationConfig(configDir), {
      relayUrl: DEFAULT_RELAY_URL,
      debounceMs: 5000,
      retryDelayMs: 1000,
    });
  });
});
