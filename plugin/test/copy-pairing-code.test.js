import { EventEmitter } from "node:events";
import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { copyPairingCode, qrKeyAction } from "../src/copy-pairing-code.js";

suite("qr key action", () => {
  test("plain c copies and stays on the QR screen", () => {
    assert.equal(qrKeyAction({ name: "c" }), "copy");
    assert.equal(qrKeyAction({ name: "c", ctrl: false }), "copy");
  });

  test("any other key closes, including ctrl+c and unnamed presses", () => {
    assert.equal(qrKeyAction({ name: "c", ctrl: true }), "close");
    assert.equal(qrKeyAction({ name: "q" }), "close");
    assert.equal(qrKeyAction({ name: "escape" }), "close");
    assert.equal(qrKeyAction({ name: "return" }), "close");
    assert.equal(qrKeyAction({}), "close");
    assert.equal(qrKeyAction(undefined), "close");
  });
});

suite("copy pairing code", () => {
  const code = "HERDR-PAIR:1:exact-bytes-no-newline";

  /** A stdin that records `end` and then fires the child close/error. */
  function fakePbcopy({ status = 0, failError = null } = {}) {
    const state = { command: "", written: "" };
    const spawnFn = (cmd, args, options) => {
      state.command = cmd;
      assert.deepEqual(args, []);
      assert.equal(options.stdio[0], "pipe");
      const child = new EventEmitter();
      child.stdin = {
        on() {
          return child.stdin;
        },
        end(data) {
          if (data !== undefined && data !== null) {
            state.written = Buffer.from(data).toString("utf8");
          }
          queueMicrotask(() => {
            if (failError !== null) {
              child.emit("error", failError);
              return;
            }
            child.emit("close", status);
          });
        },
      };
      return child;
    };
    return { state, spawnFn };
  }

  test("on darwin, pbcopy receives the exact string and no trailing newline", async () => {
    const { state, spawnFn } = fakePbcopy();
    const result = await copyPairingCode(code, { spawnFn, platform: "darwin" });
    assert.equal(result.copied, true);
    assert.equal(state.command, "pbcopy");
    assert.equal(state.written, code);
  });

  test("a missing pbcopy is a failed copy, not a throw", async () => {
    const { spawnFn } = fakePbcopy({
      failError: Object.assign(new Error("spawn pbcopy"), { code: "ENOENT" }),
    });
    const result = await copyPairingCode(code, { spawnFn, platform: "darwin" });
    assert.equal(result.copied, false);
  });

  test("a non-zero pbcopy exit is a failed copy", async () => {
    const { spawnFn } = fakePbcopy({ status: 1 });
    const result = await copyPairingCode(code, { spawnFn, platform: "darwin" });
    assert.equal(result.copied, false);
  });

  test("non-darwin platforms do not spawn pbcopy", async () => {
    let spawned = false;
    const spawnFn = () => {
      spawned = true;
      throw new Error("should not spawn");
    };
    const result = await copyPairingCode(code, { spawnFn, platform: "linux" });
    assert.equal(result.copied, false);
    assert.equal(spawned, false);
  });

  test("an empty code is not copied", async () => {
    let spawned = false;
    const spawnFn = () => {
      spawned = true;
      throw new Error("should not spawn");
    };
    const result = await copyPairingCode("", { spawnFn, platform: "darwin" });
    assert.equal(result.copied, false);
    assert.equal(spawned, false);
  });
});
