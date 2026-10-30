// Reading Notification Registrations (README.md's `notifications.json`
// contract) from the directory a caller names, with no herdr environment.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  liveActivityPreferences,
  pruneAlertTokens,
  pruneLiveActivityTokens,
  readAlertDevices,
  readLiveActivityDevices,
} from "../src/delivery/registrations.js";

const KEY = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const KEY_TEXT = KEY.toString("base64url");
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);

let dir;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "delivery-registrations-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const writeRegistrations = (file) =>
  writeFileSync(join(dir, "notifications.json"), typeof file === "string" ? file : JSON.stringify(file));
const readRegistrations = () => JSON.parse(readFileSync(join(dir, "notifications.json"), "utf8"));
const alertEntry = (overrides = {}) => ({
  token: TOKEN_A,
  env: "production",
  key: KEY_TEXT,
  notify: { blocked: true, done: false },
  ...overrides,
});
const liveEntry = (live = {}, overrides = {}) =>
  alertEntry({ live_activity: { token: "c".repeat(64), ...live }, ...overrides });

suite("alert device reads", () => {
  test("returns token, environment and raw key for the named flag", () => {
    writeRegistrations({ v: 1, devices: [alertEntry()] });
    assert.deepEqual(readAlertDevices(dir, "blocked", ""), [{ token: TOKEN_A, env: "production", key: KEY }]);
    assert.deepEqual(readAlertDevices(dir, "done", ""), []);
  });

  for (const [name, file] of [
    ["an unreadable file", "{not json"],
    ["a foreign version", { v: 2, devices: [alertEntry()] }],
    ["no devices array", { v: 1 }],
  ]) {
    test(`${name} sends nothing`, () => {
      writeRegistrations(file);
      assert.deepEqual(readAlertDevices(dir, "blocked", ""), []);
    });
  }

  test("an absent file sends nothing", () => {
    assert.deepEqual(readAlertDevices(dir, "blocked", ""), []);
  });

  test("a malformed entry is skipped and its neighbor still delivers", () => {
    writeRegistrations({
      v: 1,
      devices: [
        null,
        alertEntry({ token: "" }),
        alertEntry({ env: "staging" }),
        alertEntry({ key: "c2hvcnQ" }),
        alertEntry({ notify: undefined }),
        alertEntry({ token: TOKEN_B }),
      ],
    });
    assert.deepEqual(readAlertDevices(dir, "blocked", "").map((device) => device.token), [TOKEN_B]);
  });

  test("delivers to the named session and to entries without one", () => {
    writeRegistrations({
      v: 1,
      devices: [
        alertEntry({ token: TOKEN_A, session: "work" }),
        alertEntry({ token: TOKEN_B }),
        alertEntry({ token: "e".repeat(64), session: "" }),
      ],
    });
    assert.deepEqual(readAlertDevices(dir, "blocked", "work").map((device) => device.token), [TOKEN_A, TOKEN_B]);
    assert.deepEqual(readAlertDevices(dir, "blocked", null).map((device) => device.token), [TOKEN_B]);
  });
});

suite("Live Activity device reads", () => {
  test("ignores notify flags and uses the entry's environment when its own is absent", () => {
    writeRegistrations({ v: 1, devices: [liveEntry({}, { notify: undefined, env: "sandbox" })] });
    assert.deepEqual(readLiveActivityDevices(dir, "").map(({ token, env, key }) => ({ token, env, key })), [
      { token: "c".repeat(64), env: "sandbox", key: KEY },
    ]);
  });

  test("its own environment wins, and a row layout and host name pass through parsed", () => {
    writeRegistrations({
      v: 1,
      devices: [liveEntry({ env: "sandbox", pinned_pane_ids: ["w1:p1"], host_name: "lab", row_layout: "nonsense" })],
    });
    const [device] = readLiveActivityDevices(dir, "");
    assert.equal(device.env, "sandbox");
    assert.deepEqual(device.pinnedPaneIds, ["w1:p1"]);
    assert.equal(device.rowHostName, "lab");
    assert.equal(device.rowLayout, null);
  });

  test("skips a missing registration, an implausible token and another session", () => {
    writeRegistrations({
      v: 1,
      devices: [
        alertEntry(),
        liveEntry({ token: "NOT-HEX" }),
        liveEntry({}, { session: "work" }),
        liveEntry({}, { key: "c2hvcnQ" }),
      ],
    });
    assert.deepEqual(readLiveActivityDevices(dir, ""), []);
  });

  test("preferences change with a device's choices, not with its order or key", () => {
    const device = (token, pins) => ({ token, env: "production", key: KEY, pinnedPaneIds: pins, rowLayout: null, rowHostName: null });
    const one = device(TOKEN_A, ["w1:p1"]);
    const two = device(TOKEN_B, []);
    assert.equal(liveActivityPreferences([one, two]), liveActivityPreferences([two, one]));
    assert.equal(liveActivityPreferences([one]), liveActivityPreferences([{ ...one, key: Buffer.alloc(32) }]));
    assert.notEqual(liveActivityPreferences([one]), liveActivityPreferences([device(TOKEN_A, [])]));
  });
});

suite("pruning", () => {
  test("dropping an alert token removes its entry and keeps fields this plugin does not know", () => {
    writeRegistrations({
      v: 1,
      future: "kept",
      devices: [alertEntry({ extra: 1 }), alertEntry({ token: TOKEN_B, extra: 2 })],
    });
    pruneAlertTokens(dir, new Set([TOKEN_A]));
    const file = readRegistrations();
    assert.equal(file.future, "kept");
    assert.deepEqual(file.devices.map((entry) => [entry.token, entry.extra]), [[TOKEN_B, 2]]);
    assert.deepEqual(readdirSync(dir), ["notifications.json"]);
  });

  test("dropping a Live Activity token keeps the alert registration", () => {
    const entry = liveEntry({}, { extra: 1 });
    writeRegistrations({ v: 1, devices: [entry] });
    pruneLiveActivityTokens(dir, new Set([entry.live_activity.token]));
    const { live_activity: removed, ...alert } = entry;
    assert.deepEqual(readRegistrations().devices, [alert]);
    assert.equal(removed.token, "c".repeat(64));
    assert.deepEqual(readdirSync(dir), ["notifications.json"]);
  });

  test("an unreadable or foreign file stays exactly as it was", () => {
    for (const contents of ["{not json", JSON.stringify({ v: 2, devices: [alertEntry()] })]) {
      writeRegistrations(contents);
      pruneAlertTokens(dir, new Set([TOKEN_A]));
      pruneLiveActivityTokens(dir, new Set([TOKEN_A]));
      assert.equal(readFileSync(join(dir, "notifications.json"), "utf8"), contents);
    }
  });
});
