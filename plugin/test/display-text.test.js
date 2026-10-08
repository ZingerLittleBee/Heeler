import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { displayDirectory } from "../src/display-text.js";

describe("displayDirectory", () => {
  test("shortens the home directory to ~", () => {
    assert.equal(displayDirectory("/home/dev/Github", "/home/dev"), "~/Github");
    assert.equal(displayDirectory("/home/dev", "/home/dev/"), "~");
  });

  test("leaves other paths and look-alike prefixes alone", () => {
    assert.equal(displayDirectory("/home/devops/x", "/home/dev"), "/home/devops/x");
    assert.equal(displayDirectory("/srv/work", "/home/dev"), "/srv/work");
    assert.equal(displayDirectory("/srv/work", ""), "/srv/work");
  });

  test("absent or empty input is null", () => {
    assert.equal(displayDirectory(null, "/home/dev"), null);
    assert.equal(displayDirectory("", "/home/dev"), null);
  });
});
