import { test, suite } from "node:test";
import assert from "node:assert/strict";

import {
  MISSING_ADDRESS,
  MISSING_CONFIG_DIR,
  MISSING_HOST_KEY,
  MISSING_STATE_DIR,
  fatalLines,
  pairingStartFailed,
} from "../src/pair-fatal.js";

suite("fatalLines", () => {
  test("holds the title, body, and keypress hint", () => {
    assert.deepEqual(fatalLines("reason"), [
      "Pairing cannot start",
      "",
      "reason",
      "",
      "Press any key to close.",
    ]);
  });
});

suite("startup copy", () => {
  test("missing host key names the override and the conventional fixes", () => {
    assert.match(MISSING_HOST_KEY, /HEELER_SSH_HOST_KEY/);
    assert.match(MISSING_HOST_KEY, /Remote Login/);
    assert.match(MISSING_HOST_KEY, /sudo ssh-keygen -A/);
  });

  test("other startup failures keep their existing wording", () => {
    assert.equal(
      MISSING_STATE_DIR,
      "HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr.",
    );
    assert.equal(
      MISSING_CONFIG_DIR,
      "HERDR_PLUGIN_CONFIG_DIR is not set. Run this popup through herdr.",
    );
    assert.equal(
      MISSING_ADDRESS,
      "No routable network address found. Connect to a LAN or VPN and retry.",
    );
    assert.equal(pairingStartFailed("disk full"), "Could not start pairing: disk full");
  });
});
