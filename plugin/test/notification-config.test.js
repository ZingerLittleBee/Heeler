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
      activityDebounceMs: 1500,
      retryDelayMs: 1000,
      activityRows: "layout",
      activityTimeZone: null,
      activityMinIntervalMs: 15000,
      activityP10PerHour: 6,
      activityContentPerHour: 60,
    });
  });

  test("push volume keys and the display zone take explicit values; invalid ones keep the defaults", () => {
    writeConfig({
      activity_time_zone: "Asia/Kolkata", activity_min_interval_ms: 0, activity_p10_per_hour: 2, activity_content_per_hour: 10,
    });
    const config = readNotificationConfig(configDir);
    assert.deepEqual(
      [config.activityTimeZone, config.activityMinIntervalMs, config.activityP10PerHour, config.activityContentPerHour],
      ["Asia/Kolkata", 0, 2, 10],
    );
    writeConfig({ activity_time_zone: 5, activity_min_interval_ms: -1, activity_p10_per_hour: "6", activity_content_per_hour: 1.5 });
    const fallback = readNotificationConfig(configDir);
    assert.deepEqual(
      [fallback.activityTimeZone, fallback.activityMinIntervalMs, fallback.activityP10PerHour, fallback.activityContentPerHour],
      [null, 15000, 6, 60],
    );
  });

  test("activity_rows opts in to conversational rows; anything else stays on the layout", () => {
    writeConfig({ activity_rows: "conversational" });
    assert.equal(readNotificationConfig(configDir).activityRows, "conversational");
    for (const value of ["layout", "Conversational", true, null, 3]) {
      writeConfig({ activity_rows: value });
      assert.equal(readNotificationConfig(configDir).activityRows, "layout");
    }
  });

  test("preserves an explicit activity debounce override", () => {
    writeConfig({ activity_debounce_ms: 250 });

    assert.equal(readNotificationConfig(configDir).activityDebounceMs, 250);
  });
});
