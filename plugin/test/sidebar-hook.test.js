import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "smol-toml";

suite("sidebar hook process boundary", () => {
  let root, path, configDir, stateDir;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "sidebar-hook-"));
    path = join(root, "config.toml");
    configDir = join(root, "config");
    stateDir = join(root, "state");
    mkdirSync(configDir);
    mkdirSync(stateDir);
  });
  afterEach(() => rmSync(root, { recursive: true, force: true }));

  function run(script, event = false) {
    const env = { ...process.env, HOME: root, HERDR_CONFIG_PATH: path, HERDR_PLUGIN_CONFIG_DIR: configDir };
    delete env.HERDR_PLUGIN_EVENT_JSON;
    delete env.HERDR_PLUGIN_STATE_DIR;
    delete env.HERDR_BIN_PATH;
    if (event) {
      env.HERDR_PLUGIN_EVENT_JSON = JSON.stringify({ data: { pane_id: "w1:pA", agent_status: "working" } });
      env.HERDR_PLUGIN_STATE_DIR = stateDir;
      env.HERDR_BIN_PATH = join(root, "must-not-run-herdr");
    }
    const result = spawnSync(process.execPath, [fileURLToPath(new URL(`../src/${script}`, import.meta.url))], {
      env, encoding: "utf8", timeout: 5000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr);
    return result;
  }
  function snapshot() {
    return JSON.parse(readFileSync(join(configDir, "sidebar.json"), "utf8"));
  }

  test("manifest and package agree on 0.4.0 with a 0.7.5 startup hook", () => {
    const manifest = parse(readFileSync(new URL("../herdr-plugin.toml", import.meta.url), "utf8"));
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    assert.equal(manifest.version, "0.4.0");
    assert.equal(pkg.version, manifest.version);
    assert.equal(manifest.min_herdr_version, "0.7.5");
    assert.deepEqual(manifest.startup, [{ command: ["node", "src/sidebar-hook.js"] }]);
    assert.deepEqual(manifest.build, [{ command: ["npm", "ci"] }]);
  });

  test("startup needs no event, state directory or herdr binary", () => {
    writeFileSync(path, '[ui.sidebar.agents]\nrows = [["terminal_title_stripped"]]\n');
    run("sidebar-hook.js");
    assert.deepEqual(snapshot().sidebar.agents.rows, [[{ token: "terminal_title_stripped" }]]);
    assert.equal(snapshot().source.path, path);
    assert.equal(snapshot().source.mtime_ms, statSync(path).mtimeMs);
    assert.equal(statSync(join(configDir, "sidebar.json")).mode & 0o777, 0o600);
    assert.equal(existsSync(join(stateDir, "sidebar.json")), false);
  });

  test("startup with no config safely writes defaults", () => {
    run("sidebar-hook.js");
    assert.deepEqual(snapshot().source, { path, found: false, mtime_ms: null });
    assert.equal(snapshot().agent_panel_sort, "spaces");
    assert.deepEqual(snapshot().diagnostics, []);
  });

  for (const script of ["notify-hook.js", "activity-hook.js"]) {
    test(`${script} refreshes before no-device and no-notification exits`, () => {
      writeFileSync(path, "");
      utimesSync(path, 1000, 1000);
      run("sidebar-hook.js");
      writeFileSync(path, '[ui]\nagent_panel_sort = "priority"\n');
      utimesSync(path, 2000, 2000);
      run(script, true);
      assert.equal(snapshot().agent_panel_sort, "priority");
      assert.equal(snapshot().source.mtime_ms, 2000000);
      const snapshotPath = join(configDir, "sidebar.json");
      const before = statSync(snapshotPath);
      run(script, true);
      assert.equal(statSync(snapshotPath).ino, before.ino);
      assert.equal(statSync(snapshotPath).mtimeMs, before.mtimeMs);
    });

    test(`${script} keeps its event path working when snapshot writes fail`, () => {
      mkdirSync(join(configDir, "sidebar.json"));
      const result = run(script, true);
      assert.match(result.stderr, /sidebar-hook: snapshot refresh failed/);
    });
  }
});
