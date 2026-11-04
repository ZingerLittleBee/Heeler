import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { accountSuggestions, homeCandidates } from "../src/usage/account-suggestions.js";
import { claudeAccounts } from "../src/usage/accounts.js";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const environmentReadable = ["darwin", "linux"].includes(process.platform) ? false : "reads environments on macOS and Linux only";

function temporary(t, beforeRemoval = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "heeler-suggestions-"));
  t.after(() => {
    beforeRemoval(root);
    rmSync(root, { recursive: true, force: true });
  });
  // A Claude Code config directory holds `.claude.json`, `projects/`, or both.
  const directory = (path, markers = []) => {
    mkdirSync(path, { recursive: true });
    if (markers.includes("projects")) mkdirSync(join(path, "projects"));
    if (markers.includes(".claude.json")) writeFileSync(join(path, ".claude.json"), "{}");
    return path;
  };
  return { root, directory };
}

test("the home listing keeps .claude* directories in HOME and claude* in the config directory that hold Claude Code's markers", t => {
  const { root, directory } = temporary(t);
  const home = join(root, "home");
  const config = join(root, "xdg");
  const expected = [
    directory(join(home, ".claude"), ["projects"]),
    directory(join(home, ".claude-2"), [".claude.json", "projects"]),
    join(home, ".claude-linked"),
    directory(join(home, ".claude-work"), [".claude.json"]),
    directory(join(config, "claude"), ["projects"]),
    directory(join(config, "claude-alt"), [".claude.json"]),
  ];
  symlinkSync(directory(join(root, "elsewhere"), ["projects"]), join(home, ".claude-linked"));
  // Third-party folders hold neither marker, or not as Claude Code does.
  directory(join(home, ".claude-squad"), []);
  writeFileSync(join(directory(join(home, ".claude-mem"), []), "projects"), "");
  mkdirSync(join(directory(join(home, ".claude-tool"), []), ".claude.json"));
  writeFileSync(join(home, ".claude.json"), "{}");
  // Prefixes are case-sensitive: Claude Desktop uses `Claude`.
  directory(join(home, ".Claude-upper"), ["projects"]);
  directory(join(home, "claude-plain"), ["projects"]);
  directory(join(config, ".claude-hidden"), ["projects"]);
  // Nothing below the first level is listed.
  directory(join(home, "src", ".claude-nested"), ["projects"]);
  symlinkSync(join(root, "gone"), join(home, ".claude-dangling"));

  assert.deepEqual(homeCandidates({ env: { HOME: home, XDG_CONFIG_HOME: config } }), expected);
  // Without XDG_CONFIG_HOME, the config directory is ~/.config.
  const fallback = directory(join(home, ".config", "claude-3"), ["projects"]);
  directory(join(home, ".config", "Claude"), ["projects"]);
  assert.deepEqual(homeCandidates({ env: { HOME: home, XDG_CONFIG_HOME: null } }), [...expected.slice(0, 4), fallback]);
  assert.deepEqual(homeCandidates({ env: { HOME: join(root, "absent"), XDG_CONFIG_HOME: null } }), []);
});

test("suggestions leave out counted and dismissed directories, prefer the Agent's string, and stop at 8", t => {
  const { root, directory } = temporary(t);
  const home = join(root, "home");
  const primary = directory(join(root, "primary"));
  const legacy = directory(join(home, ".config", "claude"));
  const added = directory(join(home, ".claude-2"));
  const dismissed = directory(join(home, ".claude-old"));
  const dismissedGone = join(home, ".claude-gone");
  const work = directory(join(home, ".claude-work"));
  const agentWork = join(root, "agent-work");
  symlinkSync(work, agentWork);
  const agentOld = join(root, "agent-old");
  symlinkSync(dismissed, agentOld);
  const agentOwn = directory(join(root, "instances", "personal"));
  const runtime = { env: { HOME: home, CLAUDE_CONFIG_DIR: primary } };
  const accounts = claudeAccounts(runtime, { defaultName: null, accounts: [
    { id: "addedone", directory: added, name: "claude-2" },
    { id: "missing1", directory: join(root, "unmounted"), name: "unmounted" },
  ], ignored: [] });
  const ignored = [dismissed, dismissedGone];

  const suggestions = accountSuggestions({ accounts, ignored,
    agents: [agentWork, agentOld, primary, join(root, "unmounted"), join(root, "deleted"), "relative/dir", agentOwn, agentWork],
    candidates: [directory(join(home, ".claude")), added, dismissed, work, legacy, dismissedGone] });

  assert.deepEqual(suggestions, [
    { directory: agentWork, name: "agent-work", source: "agent" },
    { directory: agentOwn, name: "personal", source: "agent" },
    { directory: join(home, ".claude"), name: "claude", source: "home" },
  ]);

  const many = Array.from({ length: 10 }, (_, index) => directory(join(home, `.claude-${String(index).padStart(2, "0")}`)));
  const capped = accountSuggestions({ accounts, ignored, agents: [agentOwn], candidates: many });
  assert.deepEqual(capped.map(suggestion => suggestion.directory), [agentOwn, ...many.slice(0, 7)]);
  assert.deepEqual(capped.map(suggestion => suggestion.source), ["agent", ...Array(7).fill("home")]);
});

test("on a volume that ignores case, a directory differing only in case from a counted one is not suggested", t => {
  const { root, directory } = temporary(t);
  const primary = directory(join(root, ".claude"));
  if (!existsSync(join(root, ".CLAUDE"))) return t.skip("the volume is case-sensitive");
  const accounts = claudeAccounts({ env: { HOME: join(root, "home"), CLAUDE_CONFIG_DIR: primary } }, { defaultName: null, accounts: [], ignored: [] });
  assert.deepEqual(accountSuggestions({ accounts, ignored: [], agents: [join(root, ".Claude")], candidates: [] }), []);
});

test("the query reports a running Agent's directory first, then the home listing's, as the Account file now allows", { skip: environmentReadable }, async t => {
  const { root, directory } = temporary(t, root => {
    const usage = join(root, "state", "usage");
    for (const name of existsSync(usage) ? readdirSync(usage) : []) {
      try { process.kill(JSON.parse(readFileSync(join(usage, name, "worker.lock"))).pid, "SIGKILL"); } catch { /* Worker ended, or not a cache. */ }
    }
  });
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"), CODEX_HOME: join(root, "codex"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: join(root, "herdr") };
  const run = (name, args = [], extra = {}) => spawnSync(process.execPath, [join(plugin, "src", name), ...args], { env: { ...env, ...extra }, encoding: "utf8", timeout: 10_000 });
  assert.equal(run("sidebar-hook.js").status, 0);
  const suggestions = async () => {
    for (let i = 0; i < 400; i++) {
      const result = run("usage-query.js", ["--tz", "UTC"]);
      assert.equal(result.status, 0, result.stderr);
      const report = JSON.parse(result.stdout);
      if (!report.refreshing) return report.programs.find(program => program.program === "claude").accountSuggestions;
      await sleep(15);
    }
    assert.fail("worker did not finish");
  };
  const agentDirectory = directory(join(root, "ccs", "instances", "team"), [".claude.json"]);
  const home = directory(join(env.HOME, ".claude"), ["projects"]);
  const work = directory(join(env.HOME, ".claude-work"), ["projects"]);
  directory(join(env.HOME, ".claude-squad"));
  const agent = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60_000)"], { env: { CLAUDE_CONFIG_DIR: agentDirectory }, stdio: "ignore" });
  t.after(() => agent.kill("SIGKILL"));
  writeFileSync(env.HERDR_BIN_PATH, `#!${process.execPath}
if (process.argv.slice(2).join(" ") !== "pane process-info --pane w1:p1") process.exit(64);
process.stdout.write(JSON.stringify({ result: { type: "pane_process_info", process_info: { pane_id: "w1:p1",
  foreground_process_group_id: ${agent.pid}, foreground_processes: [{ pid: ${agent.pid}, name: "2.1.312", argv0: "claude" }] } } }));
`, { mode: 0o755 });

  const event = JSON.stringify({ event: "pane_agent_status_changed", data: { pane_id: "w1:p1", agent_status: "working", agent: "claude" } });
  const hook = run("activity-hook.js", [], { HERDR_PLUGIN_EVENT_JSON: event });
  assert.equal(hook.status, 0, hook.stderr);
  assert.deepEqual(await suggestions(), [
    { directory: agentDirectory, name: "team", source: "agent" },
    { directory: home, name: "claude", source: "home" },
    { directory: work, name: "claude-work", source: "home" },
  ]);

  // Adding one and dismissing another takes effect with the next query.
  writeFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "usage-accounts.json"), JSON.stringify({ version: 1, claude: { defaultName: null,
    accounts: [{ id: "agentteam", directory: agentDirectory, name: "team" }], ignored: [home] } }));
  assert.deepEqual(await suggestions(), [{ directory: work, name: "claude-work", source: "home" }]);
});
