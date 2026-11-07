#!/usr/bin/env python3
"""Run real Agents for store screenshots, and replace store assets in App Store Connect.

  up       start the isolated backend, demo repositories and eleven real Agents
  seed     point a booted simulator's Heeler at that backend
  working  give the Search Agent more work, so its ring turns for a capture
  diff     have the Payments Agent edit files, so its terminal shows a colored diff
  restore  put back a simulator's preferences from before `seed`
  down     stop everything and remove what the Agents left in the home directory
  asc      read or replace App Store Connect assets through ego-browser

See docs/agents/store-screenshots.md for the whole flow.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import importlib.util
from dataclasses import dataclass
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
BACKEND = SCRIPTS / "isolated-herdr-backend.py"
ASC_SCRIPT = SCRIPTS / "store-shots-asc.mjs"
BUNDLE_ID = "dev.bybee.heeler"
DEFAULT_ROOT = "/tmp/heeler-shots"
MARKER = ".store-shots"
CLAUDE_SIDECARS = ("session-env", "file-history", "todos", "tasks", "debug")
PREF_KEYS_TO_CLEAR = ("com.apple.UIKit.UISplitViewController.Root", "agent-input-mode",
                      "console.last-list-tab", "pinned-agents", "terminal-list.collapsed-workspaces")


@dataclass(frozen=True)
class Agent:
    name: str
    kind: str
    repo: str
    label: str
    prompts: tuple[str, ...]
    session: str = "default"
    # Stop at the next approval prompt once src and test changed: a Blocked ring.
    leave_blocked: bool = False


AGENTS = (
    Agent("checkout-retry", "claude", "storefront", "Storefront", (
        "Retry failed card charges in src/checkout.js up to 3 times with exponential backoff, "
        "but never retry a declined card. Add tests and run them.",), leave_blocked=True),
    Agent("setup-guide", "codex", "docs-site", "Docs", (
        "Write a short getting-started guide in guides/ that covers install, first run and "
        "common errors. Run the tests when you are done.",)),
    Agent("search-ranking", "codex", "search-service", "Search", (
        "Rank search results in src/search.js by how many query terms appear in the title, with "
        "exact phrase matches first, and add tests for the ordering. Run the tests when you are done.",)),
    Agent("stock-reconcile", "claude", "inventory-sync", "Inventory", (
        "Add reconcile(stock, counts) to src/stock.js. It compares the stock map with a warehouse "
        "count and returns the corrections to apply plus a drift summary. Add tests and run them. "
        "In your final reply, show one code block with sample calls and their output as comments, "
        "then three short bullets with bold lead-ins for the key behaviors, then one sentence "
        "confirming the tests pass.",)),
    Agent("webhook-retries", "claude", "payments-api", "Payments API", (
        "Add retry scheduling for failed webhook deliveries in src/webhooks.js with backoff and a "
        "dead-letter limit. Add tests and run them.",
        "Split this up so it is easier to review: move retry scheduling to src/retry.js, the "
        "dead-letter limit to src/dead-letter.js, add src/config.js for the backoff settings, give "
        "each new module its own test file, and add a Webhooks section to README.md. Run the tests "
        "when you are done.",), session="build"),
    Agent("dark-mode", "codex", "mobile-app", "Mobile App", (
        "Add a theme setting to src/settings.js that follows the system by default and can be "
        "forced to light or dark, with tests. Run the tests when you are done.",)),
    Agent("weekly-retention", "claude", "analytics", "Analytics", (
        "Add weeklyRetention(events) to src/retention.js. It groups users by the week of their "
        "first event and returns the share still active in each later week. Add tests and run them.",)),
    Agent("login-lockout", "claude", "auth-service", "Auth Service", (
        "Lock an account for 15 minutes after 5 failed logins in src/login.js, reset the count on "
        "success, and add tests with a fake clock. Run the tests when you are done.",), session="build"),
    Agent("quiet-hours", "codex", "notifications", "Notifications", (
        "Add quiet hours to src/schedule.js: hold notifications between a user's start and end "
        "hour, including ranges that cross midnight, with tests. Run the tests when you are done.",)),
    Agent("csv-export", "claude", "admin-dashboard", "Admin Dashboard", (
        "Add toCsv(orders) to src/export.js with a header row and proper quoting of commas and "
        "quotes, with tests. Run the tests when you are done.",)),
    Agent("dry-run", "claude", "release-cli", "Release CLI", (
        "Add a dryRun option to src/release.js that returns the planned version and tag without "
        "writing anything, with tests. Run the tests when you are done.",), session="build"),
)
WORKING_PROMPT = ("Now add typo tolerance: treat a title word within edit distance 1 of a query "
                  "term as a weaker match, ranked below exact matches, with tests. Run the tests "
                  "when you are done.")
DIFF_PROMPT = ("Using your Edit tool only, cap the retry delay with the configured maximum and add "
               "jitter of up to 10 percent, add a JSDoc comment above each exported function in "
               "src/retry.js, and cover the jitter in test/retry.test.js. Do not run anything. "
               "Reply with one short sentence.")
STAGED_PATHS = ("src/config.js", "src/retry.js", "test/retry.test.js")


def encode_claude_project(path: Path) -> str:
    """Claude Code's directory name for a project path."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def strip_claude_trust(config: dict, repos: list[Path]) -> dict:
    """Drop exactly these repositories from a ~/.claude.json document."""
    projects = config.get("projects", {})
    for repo in repos:
        projects.pop(str(repo), None)
    return config


def strip_codex_trust(text: str, repos: list[Path]) -> str:
    """Drop exactly these repositories' tables from a ~/.codex/config.toml document."""
    for repo in repos:
        header = re.escape(f'[projects."{repo}"]')
        text = re.sub(rf"^{header}\n(?:(?!\[).*\n?)*", "", text, flags=re.MULTILINE)
    return text


def rollout_cwd(first_line: str) -> str | None:
    """The working directory recorded on a Codex rollout's first line."""
    try:
        return json.loads(first_line).get("payload", {}).get("cwd")
    except (json.JSONDecodeError, AttributeError):
        return None


def workspace_is_ours(workspace: Path) -> bool:
    return (workspace / MARKER).exists()


def seeded_hosts(status: dict) -> bytes:
    """The Host catalog for both sessions, under the names the screenshots show."""
    hosts = []
    for name, session in (("Studio Mac", ""), ("Build Server", "build")):
        host = dict(next(h for h in status["hosts"] if h["sessionName"] == session))
        host["name"] = name
        host["routes"] = [{"id": host["id"], "address": host["address"], "port": host["port"],
                           "jumpAddress": "", "jumpPort": 22, "jumpUsername": ""}]
        hosts.append(host)
    return json.dumps({"version": 1, "hosts": hosts}).encode()


class Rig:
    def __init__(self, root: str, workspace: str):
        self.root = Path(root).resolve()
        self.workspace = Path(workspace).expanduser().resolve()
        self.home = Path.home()

    @property
    def repos(self) -> list[Path]:
        return [self.workspace / name for name in load_repos()]

    def backend(self, *args: str, check: bool = True) -> str:
        done = subprocess.run([sys.executable, str(BACKEND), "--root", str(self.root), *args],
                              capture_output=True, text=True)
        if check and done.returncode:
            raise SystemExit(f"backend {' '.join(args[:3])} failed: {done.stdout}{done.stderr}")
        # herdr reports a failed request on stderr, which `check=False` callers read.
        return done.stdout if done.stdout.strip() else done.stderr

    def herdr(self, session: str, *args: str, check: bool = True) -> dict:
        output = self.backend("run", "--session", session, "--", *args, check=check)
        return json.loads(output) if output.strip().startswith("{") else {}

    def status(self, agent: Agent) -> str | None:
        for row in self.herdr(agent.session, "agent", "list").get("result", {}).get("agents", []):
            if row.get("name") == agent.name:
                return row.get("agent_status")
        return None

    def pane(self, agent: Agent) -> str:
        for row in self.herdr(agent.session, "agent", "list").get("result", {}).get("agents", []):
            if row.get("name") == agent.name:
                return row["pane_id"]
        raise SystemExit(f"Agent {agent.name} is not running")

    def changed(self, agent: Agent) -> bool:
        lines = subprocess.run(["git", "status", "--porcelain"], cwd=self.workspace / agent.repo,
                               capture_output=True, text=True).stdout.splitlines()
        return any("src/" in line for line in lines) and any("test" in line for line in lines)

    def drive(self, agent: Agent, seconds: int = 600) -> str:
        """Approve prompts until the Agent stops, or leave it Blocked when it asks to."""
        started, pane = time.time(), self.pane(agent)
        while time.time() - started < seconds:
            state = self.status(agent)
            if state == "blocked":
                if agent.leave_blocked and self.changed(agent):
                    return "blocked"
                self.herdr(agent.session, "pane", "send-keys", pane, "Enter")
                time.sleep(4)
                continue
            if state in ("idle", "done") and time.time() - started > 8:
                return state
            time.sleep(3)
        raise SystemExit(f"{agent.name} did not finish in {seconds}s")

    def make_repos(self) -> None:
        if self.workspace.exists() and not workspace_is_ours(self.workspace):
            raise SystemExit(f"{self.workspace} exists and is not a store-shots workspace; "
                             "pick another --workspace")
        self.workspace.mkdir(parents=True, exist_ok=True)
        (self.workspace / MARKER).touch()
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "LEFTHOOK": "0",
               "GIT_AUTHOR_NAME": "Demo Developer", "GIT_AUTHOR_EMAIL": "demo@example.invalid",
               "GIT_COMMITTER_NAME": "Demo Developer", "GIT_COMMITTER_EMAIL": "demo@example.invalid"}
        for name, commits in load_repos().items():
            repo = self.workspace / name
            if repo.exists():
                continue
            repo.mkdir()
            git = ["git", "-c", "core.hooksPath=/dev/null"]
            subprocess.run([*git, "init", "-q", "-b", "main"], cwd=repo, env=env, check=True)
            for message, files in commits:
                for relative, text in files.items():
                    path = repo / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(text.lstrip("\n"))
                subprocess.run([*git, "add", "-A"], cwd=repo, env=env, check=True)
                subprocess.run([*git, "commit", "-q", "-m", message], cwd=repo, env=env, check=True)

    def prepare_shell(self) -> None:
        """Real login and tools for Agents, with a short prompt and no version-manager hangs."""
        home = self.root / "home"
        for name in (".claude", ".claude.json", ".codex", ".agents", ".gitconfig"):
            target, link = self.home / name, home / name
            if target.exists() and not link.exists():
                link.symlink_to(target)
        tools = [shutil.which(tool) for tool in ("node", "codex", "claude")]
        missing = [t for t, path in zip(("node", "codex", "claude"), tools) if not path]
        if missing:
            raise SystemExit(f"Not on PATH: {', '.join(missing)}")
        path = ":".join(dict.fromkeys(str(Path(tool).resolve().parent) for tool in tools if tool))
        (home / ".zshrc").write_text(
            f"export HOME={self.home}\nexport PATH={path}:{self.home}/.local/bin:/opt/homebrew/bin:$PATH\n"
            "export NO_UPDATE_NOTIFIER=1\nPROMPT='%F{green}%~%f %# '\n")
        conf = self.root / "ssh/sshd.conf"
        text = conf.read_text()
        line = f"SetEnv MISE_TRUSTED_CONFIG_PATHS={self.home}\n"
        if line not in text:
            conf.write_text(text.replace("ForceCommand", line + "ForceCommand", 1))
            os.kill(int((self.root / "ssh/sshd.pid").read_text()), signal.SIGHUP)
        # A login fish runs `mise activate`, which can block PTY terminals on Connecting forever.
        watcher = (f'while [ -d "{self.root}" ]; do for f in $(pgrep -f '
                   f'"fish -c exec /bin/sh {self.root}/force-command.sh"); do '
                   'pkill -P "$f" -f "mise activate fish"; done; '
                   "perl -e 'select(undef,undef,undef,0.5)'; done")
        subprocess.Popen(["/bin/bash", "-c", watcher], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def start_agent(self, agent: Agent) -> None:
        created = self.herdr(agent.session, "workspace", "create",
                             "--cwd", str(self.workspace / agent.repo), "--label", agent.label)
        pane = created["result"]["root_pane"]["pane_id"]
        extra = (["--permission-mode", "acceptEdits", "--settings", '{"language":"English"}']
                 if agent.kind == "claude" else ["-a", "on-request", "-s", "workspace-write"])
        reply = self.herdr(agent.session, "agent", "start", agent.name, "--kind", agent.kind,
                           "--pane", pane, "--timeout", "40000", "--", *extra, check=False)
        if reply.get("error", {}).get("code") == "agent_not_ready":
            # A first run in this folder stops at its trust prompt, and Claude's default is "No".
            keys = ["Down", "Enter"] if agent.kind == "claude" else ["Enter"]
            self.herdr(agent.session, "pane", "send-keys", pane, *keys)
        for _ in range(40):
            if self.status(agent) in ("idle", "done"):
                return
            time.sleep(1.5)
        raise SystemExit(f"{agent.name} never became ready: {self.status(agent)}")

    def up(self) -> None:
        self.make_repos()
        print(self.backend("start", "--sessions", "default,build", "--plugin").splitlines()[0], flush=True)
        self.prepare_shell()
        for agent in AGENTS:
            self.start_agent(agent)
            print(f"{agent.name}: ready", flush=True)
        for session in ("default", "build"):
            self.herdr(session, "workspace", "close", "w1", check=False)

        def run(agent: Agent) -> None:
            for prompt in agent.prompts:
                self.herdr(agent.session, "agent", "prompt", agent.name, prompt)
                print(f"{agent.name}: {self.drive(agent)}", flush=True)

        threads = [threading.Thread(target=run, args=(agent,)) for agent in AGENTS]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        payments = self.workspace / "payments-api"
        present = [p for p in STAGED_PATHS if (payments / p).exists()]
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "add", *present], cwd=payments, check=True)
        print("Ready. Next: seed a simulator (see docs/agents/store-screenshots.md).")

    def seed(self, udid: str, device_key: str, clock: str | None, app: str | None) -> None:
        self.backend("authorize", device_key)
        status = json.loads(self.backend("status", "--json"))
        if app:
            subprocess.run(["xcrun", "simctl", "install", udid, app], check=True)
        container = subprocess.run(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
                                   capture_output=True, text=True, check=True).stdout.strip()
        device_data = self.home / f"Library/Developer/CoreSimulator/Devices/{udid}/data"
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], capture_output=True)
        # A simulator can hold Hosts in either file, depending on how it was last written.
        for plist in pref_paths(Path(container), device_data):
            prefs = plistlib.loads(plist.read_bytes()) if plist.exists() else {}
            backup = plist.with_name(plist.name + ".before-store-shots")
            if plist.exists() and not backup.exists():
                shutil.copy2(plist, backup)
            prefs["hosts"] = seeded_hosts(status)
            prefs["knownHostFingerprints"] = status["known_host_fingerprints"]
            prefs["agent.detail-surface"] = "chat"
            prefs["agent.back-header-expanded"] = True
            prefs["app-appearance"] = "dark"
            for key in PREF_KEYS_TO_CLEAR:
                prefs.pop(key, None)
            plist.parent.mkdir(parents=True, exist_ok=True)
            plist.write_bytes(plistlib.dumps(prefs, fmt=plistlib.FMT_BINARY))
        restart_cfprefsd(udid)
        subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "dark"], check=True)
        bar = ["--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
               "--cellularMode", "active", "--cellularBars", "4",
               "--batteryState", "charged", "--batteryLevel", "100"]
        if clock:
            bar += ["--time", clock]
        subprocess.run(["xcrun", "simctl", "status_bar", udid, "override", *bar], check=True)
        subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE_ID], check=True, capture_output=True)
        print(f"Seeded {udid}.")

    def down(self) -> None:
        if self.root.exists():
            self.backend("stop", check=False)
        time.sleep(1)
        repos = self.repos
        claude = self.home / ".claude"
        for repo in repos:
            project = claude / "projects" / encode_claude_project(repo)
            if not project.is_dir():
                continue
            for transcript in project.glob("*.jsonl"):
                for sidecar in CLAUDE_SIDECARS:
                    for leftover in (claude / sidecar).glob(f"{transcript.stem}*"):
                        shutil.rmtree(leftover) if leftover.is_dir() else leftover.unlink()
            shutil.rmtree(project)
        config = self.home / ".claude.json"
        if config.exists():
            cleaned = json.dumps(strip_claude_trust(json.loads(config.read_text()), repos), indent=2)
            temporary = config.with_name(config.name + ".store-shots")
            temporary.write_text(cleaned + "\n")
            temporary.replace(config)
        codex = self.home / ".codex/config.toml"
        if codex.exists():
            codex.write_text(strip_codex_trust(codex.read_text(), repos))
        names = {str(repo) for repo in repos}
        if workspace_is_ours(self.workspace):
            since = (self.workspace / MARKER).stat().st_mtime
            for rollout in (self.home / ".codex/sessions").rglob("rollout-*.jsonl"):
                if rollout.stat().st_mtime < since:
                    continue
                with rollout.open(errors="replace") as handle:
                    if rollout_cwd(handle.readline()) in names:
                        rollout.unlink()
            shutil.rmtree(self.workspace)
        elif self.workspace.exists():
            print(f"Left {self.workspace}: it has no {MARKER} marker.")
        print("Stopped and cleaned. ~/.claude/history.jsonl keeps its prompt lines.")


def load_repos() -> dict:
    spec = importlib.util.spec_from_file_location("store_shots_repos", SCRIPTS / "fixtures/store_shots_repos.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.REPOS


def pref_paths(container: Path, device_data: Path) -> list[Path]:
    name = f"{BUNDLE_ID}.plist"
    return [container / "Library/Preferences" / name, device_data / "Library/Preferences" / name]


def restart_cfprefsd(udid: str) -> None:
    """Make the simulator reread edited plists without a reboot, which would drop its posture."""
    subprocess.run(["xcrun", "simctl", "spawn", udid, "launchctl", "kill", "SIGKILL",
                    "user/foreground/com.apple.cfprefsd.xpc.daemon"], capture_output=True)
    time.sleep(1)


def restore(udid: str) -> None:
    home = Path.home()
    container = subprocess.run(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
                               capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], capture_output=True)
    for plist in pref_paths(Path(container), home / f"Library/Developer/CoreSimulator/Devices/{udid}/data"):
        backup = plist.with_name(plist.name + ".before-store-shots")
        if backup.exists():
            backup.replace(plist)
    restart_cfprefsd(udid)
    subprocess.run(["xcrun", "simctl", "status_bar", udid, "clear"], check=True)
    print(f"Restored {udid}.")


TEXT_ACTIONS = ("whats-new", "promo", "keywords", "description")


def asc(args: argparse.Namespace) -> None:
    if args.action != "screenshots" and (args.at is not None or args.remove):
        raise SystemExit("--at and --remove apply only to screenshots")
    # Text fields have no target, so their file lands in the target position.
    named = [args.target, *args.files] if args.action in TEXT_ACTIONS and args.target else args.files
    files = [str(Path(f).resolve()) for f in named]
    missing = [f for f in files if not Path(f).exists()]
    if missing:
        raise SystemExit(f"Missing: {', '.join(missing)}")
    payload = {"action": args.action, "target": args.target, "version": args.version,
               "locale": args.locale, "apply": args.apply, "appId": args.app_id, "at": args.at, "remove": args.remove,
               "files": [{"path": f, "name": Path(f).name, "size": Path(f).stat().st_size} for f in files]}
    script = f"const ARGS = {json.dumps(payload)};\n" + ASC_SCRIPT.read_text()
    raise SystemExit(subprocess.run(["ego-browser", "nodejs"], input=script, text=True).returncode)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=DEFAULT_ROOT, help=f"backend root (default {DEFAULT_ROOT})")
    parser.add_argument("--workspace", default="~/workspace",
                        help="demo repositories; must be under the home directory for ~ paths")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("up", help="start the backend, repositories and Agents")
    seed = commands.add_parser("seed", help="connect a booted simulator's Heeler to the backend")
    seed.add_argument("udid")
    seed.add_argument("device_key", help="the ssh-ed25519 line from Heeler's Add Host sheet")
    seed.add_argument("--clock", help="status bar time, such as 9:41; omit on iPad (see the runbook)")
    seed.add_argument("--app", help="Heeler.app to install first")
    commands.add_parser("working", help="start another Search task")
    commands.add_parser("diff", help="start a Payments edit for a colored diff")
    undo = commands.add_parser("restore", help="restore a simulator's preferences")
    undo.add_argument("udid")
    commands.add_parser("down", help="stop everything and clean the home directory")
    store = commands.add_parser("asc", help="read or replace App Store Connect assets")
    store.add_argument("action", choices=("status", "screenshots", "creative", *TEXT_ACTIONS))
    store.add_argument("target", nargs="?", help="ipad, iphone or duo; header or search; the text file for a text field")
    store.add_argument("files", nargs="*", help="exports")
    store.add_argument("--version", required=True, help="the store version, such as 0.1.16")
    store.add_argument("--locale", default="en-US")
    store.add_argument("--app-id", default="6797263135")
    store.add_argument("--at", type=int, help="screenshots: the position, from 1, for files not yet in the set (default last)")
    store.add_argument("--remove", action="append", default=[], metavar="NAME",
                       help="screenshots: also delete the image with this file name; repeatable")
    store.add_argument("--apply", action="store_true", help="make the change; the default only prints the plan")
    args = parser.parse_args()
    rig = Rig(args.root, args.workspace)
    if args.command == "up":
        rig.up()
    elif args.command == "seed":
        rig.seed(args.udid, args.device_key, args.clock, args.app)
    elif args.command == "working":
        rig.herdr("default", "agent", "prompt", "search-ranking", WORKING_PROMPT)
        print("Search is working. Capture within about a minute.")
    elif args.command == "diff":
        agent = next(a for a in AGENTS if a.name == "webhook-retries")
        rig.herdr(agent.session, "agent", "prompt", agent.name, DIFF_PROMPT)
        print("Payments is editing. Capture frames while it works; its diff scrolls away when it replies.")
    elif args.command == "restore":
        restore(args.udid)
    elif args.command == "down":
        rig.down()
    elif args.command == "asc":
        asc(args)


if __name__ == "__main__":
    main()
