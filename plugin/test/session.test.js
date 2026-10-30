// Session scoping rules, driven by the shared vectors the Swift app tests
// also read (test-vectors/notification-session-v1.json).

import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { deliversToSession } from "../src/delivery/registrations.js";
import {
  hookSession,
  isValidSessionName,
  sessionFromSocketPath,
  sessionStateDir,
} from "../src/session.js";

const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/notification-session-v1.json", import.meta.url), "utf8"),
);

suite("session: shared vectors", () => {
  for (const vector of vectors.names) {
    test(`name ${JSON.stringify(vector.name)} is ${vector.valid ? "valid" : "invalid"}`, () => {
      assert.equal(isValidSessionName(vector.name), vector.valid);
    });
  }

  for (const vector of vectors.derivation) {
    test(`derivation: ${vector.name}`, () => {
      const env = vector.socketPath === null ? {} : { HERDR_SOCKET_PATH: vector.socketPath };
      assert.equal(sessionFromSocketPath(vector.socketPath ?? undefined), vector.session);
      assert.equal(hookSession(env), vector.session);
    });
  }

  for (const vector of vectors.delivery) {
    test(`delivery: ${vector.name}`, () => {
      const delivered = vector.entries
        .map((entry, index) => (deliversToSession(entry, vector.ownSession) ? index : null))
        .filter((index) => index !== null);
      assert.deepEqual(delivered, vector.delivered);
    });
  }
});

suite("session: state directory", () => {
  test("named sessions get their own directory; default and unknown keep the root", () => {
    assert.equal(sessionStateDir("/state", "work"), join("/state", "sessions", "work"));
    assert.equal(sessionStateDir("/state", "herdr"), join("/state", "sessions", "herdr"));
    assert.equal(sessionStateDir("/state", ""), "/state");
    assert.equal(sessionStateDir("/state", null), "/state");
  });
});
