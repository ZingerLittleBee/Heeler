// The Helper finds a session's socket as the app's locator does (ADR 0031,
// ADR 0033): the session's core.lock, else its default socket path.

import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { locateCoreSocket } from "../helper/core/socket.js";

let root;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "helper-socket-"));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

const noRunUser = () => join(root, "no-such-run-user");

function writeLock(stateHome, session, text) {
  const folder = join(stateHome, "herdr-core", session);
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "core.lock"), text);
}

suite("a session's socket path", () => {
  for (const session of ["default", "phone-work_1.2"]) {
    test(`without a core.lock, ${session} reads the runtime directory's default path`, () => {
      const env = { HOME: root, XDG_RUNTIME_DIR: "/run/user/1000" };
      assert.deepEqual(locateCoreSocket(session, { env, runUserDirectory: noRunUser() }), {
        path: `/run/user/1000/herdr-core/${session}.sock`,
        source: "default",
      });
    });

    test(`${session}'s core.lock wins over the default path`, () => {
      writeLock(join(root, ".local/state"), session, "/somewhere/else.sock");
      const env = { HOME: root, XDG_RUNTIME_DIR: "/run/user/1000" };
      assert.deepEqual(locateCoreSocket(session, { env, runUserDirectory: noRunUser() }), {
        path: "/somewhere/else.sock",
        source: "lock",
      });
    });
  }

  test("a core.lock appearing later is read on the next look", () => {
    const options = { env: { HOME: root, XDG_RUNTIME_DIR: "/run/user/1000" }, runUserDirectory: noRunUser() };
    assert.equal(locateCoreSocket("work", options).source, "default");
    writeLock(join(root, ".local/state"), "work", "/later.sock");
    assert.equal(locateCoreSocket("work", options).path, "/later.sock");
  });

  test("one session's core.lock says nothing about another's", () => {
    writeLock(join(root, ".local/state"), "other", "/other.sock");
    const options = { env: { HOME: root, XDG_RUNTIME_DIR: "/run/user/1000" }, runUserDirectory: noRunUser() };
    assert.equal(locateCoreSocket("work", options).path, "/run/user/1000/herdr-core/work.sock");
  });

  test("XDG_STATE_HOME moves where core.lock is read", () => {
    const state = join(root, "elsewhere");
    writeLock(state, "work", "/elsewhere.sock");
    const env = { HOME: root, XDG_STATE_HOME: state };
    assert.equal(locateCoreSocket("work", { env, runUserDirectory: noRunUser() }).path, "/elsewhere.sock");
  });

  test("a lock's trailing newlines go, as a shell's substitution drops them", () => {
    writeLock(join(root, ".local/state"), "work", "/a.sock\n\n");
    const env = { HOME: root };
    assert.equal(locateCoreSocket("work", { env, runUserDirectory: noRunUser() }).path, "/a.sock");
  });

  test("an empty lock reads as no lock", () => {
    writeLock(join(root, ".local/state"), "work", "");
    const env = { HOME: root, XDG_RUNTIME_DIR: "/r" };
    assert.deepEqual(locateCoreSocket("work", { env, runUserDirectory: noRunUser() }), {
      path: "/r/herdr-core/work.sock",
      source: "default",
    });
  });

  test("with no runtime variable, /run/user/<uid> serves when it exists", () => {
    const run = join(root, "run-user");
    mkdirSync(run);
    assert.equal(
      locateCoreSocket("work", { env: { HOME: root }, runUserDirectory: run }).path,
      join(run, "herdr-core", "work.sock"),
    );
  });

  test("with no runtime directory at all, the socket sits in the session's state folder", () => {
    assert.equal(
      locateCoreSocket("work", { env: { HOME: root }, runUserDirectory: noRunUser() }).path,
      join(root, ".local/state/herdr-core/work/work.sock"),
    );
  });

  test("an empty variable counts as unset, as it does for the core", () => {
    const env = { HOME: root, XDG_RUNTIME_DIR: "", XDG_STATE_HOME: "" };
    assert.equal(
      locateCoreSocket("work", { env, runUserDirectory: noRunUser() }).path,
      join(root, ".local/state/herdr-core/work/work.sock"),
    );
  });
});
