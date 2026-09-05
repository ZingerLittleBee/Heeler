import { afterEach, beforeEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseSidebarConfig, refreshSidebarSnapshot, resolveConfigPath } from "../src/sidebar-config.js";

const vectors = JSON.parse(readFileSync(new URL("../test-vectors/sidebar-layout-v1.json", import.meta.url), "utf8"));
const defaultConfig = {
  agent_panel_sort: "spaces",
  sidebar: { agents: {
    row_gap: 0,
    rows: [[{ token: "state_icon" }, { token: "workspace" }, { token: "tab" }], [{ token: "agent" }]],
    rows_by_agent: {},
  } },
  diagnostics: [],
};

suite("sidebar layout shared vectors", () => {
  for (const vector of [...vectors.valid, ...vectors.invalid]) {
    test(vector.name, () => {
      const { v, generated_at, source, ...expected } = vector.snapshot;
      const actual = parseSidebarConfig(vector.toml);
      assert.deepEqual(actual, expected);
      if (vector.error) {
        assert.deepEqual(actual, { ...defaultConfig, diagnostics: [vector.error] });
      } else {
        assert.deepEqual(actual.diagnostics, []);
      }
      assert.equal(v, 1);
      assert.equal(typeof generated_at, "number");
      assert.equal(typeof source.mtime_ms, "number");
    });
  }
});

suite("sidebar config paths", () => {
  test("explicit path takes precedence over XDG and HOME", () => {
    assert.equal(resolveConfigPath({ HERDR_CONFIG_PATH: "/custom/config.toml", XDG_CONFIG_HOME: "/xdg", HOME: "/home/u" }), "/custom/config.toml");
  });
  test("XDG takes precedence over HOME and is shared across sessions", () => {
    assert.equal(resolveConfigPath({ XDG_CONFIG_HOME: "/xdg", HOME: "/home/u", HERDR_SESSION: "other" }), "/xdg/herdr/config.toml");
  });
  test("HOME supplies the conventional path", () => {
    assert.equal(resolveConfigPath({ HOME: "/home/u" }), "/home/u/.config/herdr/config.toml");
  });
  test("unset HOME uses herdr's temporary-directory fallback", () => {
    assert.equal(resolveConfigPath({}), join(tmpdir(), "herdr", "config.toml"));
  });
  test("an explicitly empty override stays explicit", () => {
    assert.equal(resolveConfigPath({ HERDR_CONFIG_PATH: "", HOME: "/home/u" }), "");
  });
});

suite("sidebar snapshot files", () => {
  let root, path, configDir, env;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "sidebar-config-"));
    path = join(root, "config.toml");
    configDir = join(root, "plugin-config");
    env = { HERDR_CONFIG_PATH: path };
  });
  afterEach(() => rmSync(root, { recursive: true, force: true }));

  function refresh(now = 1757040000000) {
    return refreshSidebarSnapshot(configDir, { env, now: () => now });
  }

  test("missing source writes complete defaults without diagnostics", () => {
    const actual = refresh();
    assert.deepEqual(actual, {
      v: 1, generated_at: 1757040000,
      source: { path, found: false, mtime_ms: null }, ...defaultConfig,
    });
    assert.deepEqual(JSON.parse(readFileSync(join(configDir, "sidebar.json"), "utf8")), actual);
    assert.equal(statSync(configDir).mode & 0o777, 0o700);
    assert.equal(statSync(join(configDir, "sidebar.json")).mode & 0o777, 0o600);
  });

  test("mtime gates reparsing and rewriting, including cached invalid input", () => {
    writeFileSync(path, '[ui]\nagent_panel_sort = "priority"\n');
    utimesSync(path, 1000, 1000);
    const first = refresh();
    const snapshotPath = join(configDir, "sidebar.json");
    const firstStat = statSync(snapshotPath);
    writeFileSync(path, "[malformed");
    utimesSync(path, 1000, 1000);
    assert.deepEqual(refresh(1757040100000), first);
    assert.equal(statSync(snapshotPath).mtimeMs, firstStat.mtimeMs);
    assert.equal(statSync(snapshotPath).ino, firstStat.ino);
    utimesSync(path, 2000, 2000);
    const invalid = refresh(1757040200000);
    assert.equal(invalid.agent_panel_sort, "spaces");
    assert.deepEqual(invalid.diagnostics, ["parse_error"]);
    assert.equal(invalid.source.mtime_ms, 2000000);
    assert.deepEqual(refresh(1757040300000), invalid);
  });

  test("source creation, deletion and path changes invalidate the cache", () => {
    refresh();
    writeFileSync(path, '[ui]\nagent_panel_sort = "priority"\n');
    utimesSync(path, 1000, 1000);
    assert.equal(refresh().agent_panel_sort, "priority");
    const other = join(root, "other.toml");
    writeFileSync(other, "");
    utimesSync(other, 1000, 1000);
    env.HERDR_CONFIG_PATH = other;
    assert.equal(refresh().agent_panel_sort, "spaces");
    assert.equal(refresh().source.path, other);
    rmSync(other);
    assert.deepEqual(refresh().source, { path: other, found: false, mtime_ms: null });
    assert.deepEqual(refresh().diagnostics, []);
  });

  test("unreadable source reports defaults and retries at the same mtime", () => {
    // Reading a directory fails even when the test process runs as root.
    mkdirSync(path);
    utimesSync(path, 1000, 1000);
    const failed = refresh();
    assert.equal(failed.agent_panel_sort, "spaces");
    assert.deepEqual(failed.diagnostics, ["read_error"]);
    rmSync(path, { recursive: true });
    writeFileSync(path, '[ui]\nagent_panel_sort = "priority"\n');
    utimesSync(path, 1000, 1000);
    assert.equal(refresh().agent_panel_sort, "priority");
    assert.deepEqual(refresh().diagnostics, []);
  });

  test("replacement is atomic, restores mode and leaves no temporary files", () => {
    writeFileSync(path, "");
    refresh();
    const snapshotPath = join(configDir, "sidebar.json");
    const firstInode = statSync(snapshotPath).ino;
    chmodSync(snapshotPath, 0o644);
    writeFileSync(path, '[ui]\nagent_panel_sort = "priority"\n');
    utimesSync(path, 2000, 2000);
    refresh();
    assert.notEqual(statSync(snapshotPath).ino, firstInode);
    assert.equal(statSync(snapshotPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(configDir), ["sidebar.json"]);
  });

  test("corrupt and unsupported snapshots are rebuilt", () => {
    refresh();
    const snapshotPath = join(configDir, "sidebar.json");
    writeFileSync(snapshotPath, "{");
    assert.deepEqual(refresh().sidebar, defaultConfig.sidebar);
    const old = refresh();
    writeFileSync(snapshotPath, JSON.stringify({ ...old, v: 2 }));
    assert.equal(refresh().v, 1);
  });

  test("failed rename preserves the destination and cleans the temporary file", () => {
    mkdirSync(join(configDir, "sidebar.json"), { recursive: true });
    assert.throws(() => refresh());
    assert.deepEqual(readdirSync(configDir), ["sidebar.json"]);
    assert.ok(statSync(join(configDir, "sidebar.json")).isDirectory());
  });
});
