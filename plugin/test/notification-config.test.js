import { afterEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_RELAY_URL,
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

  test("migrates the previous workers.dev endpoint to production", () => {
    writeConfig({
      relay_url: "https://herdr-push-relay.69709991236.workers.dev/",
    });

    assert.equal(readNotificationConfig(configDir).relayUrl, DEFAULT_RELAY_URL);
  });

  test("uses the documented debounce and retry defaults", () => {
    configDir = mkdtempSync(join(tmpdir(), "notification-config-"));

    assert.deepEqual(readNotificationConfig(configDir), {
      relayUrl: DEFAULT_RELAY_URL,
      debounceMs: 5000,
      retryDelayMs: 1000,
    });
  });
});
