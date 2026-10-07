#!/usr/bin/env python3
"""Run a throwaway herdr + sshd backend for Simulator and plugin acceptance.

Everything lives under one short root (default /tmp/heeler-iso):

  start   one headless herdr server per session (each with workspace w1 and
          pane w1:p1), an sshd on 127.0.0.1 modeled on the CI fixture, and
          optionally the repository plugin (--plugin) and a fake Push Relay
          (--relay) that records every POST to <root>/relay.jsonl.
  status  what is running, the Host settings an app needs, and the host key
          as a knownHostFingerprints entry.
  run     a herdr command inside the isolated environment.
  authorize  append a public key (for example the app's Device Key).
  stop    stop exactly the recorded processes and remove the root.

Every herdr process gets a constructed environment (the equivalent of
`env -i`), so an inherited HERDR_SOCKET_PATH can never reach a live server.
The script only signals PIDs it recorded in <root>/state.json, after checking
that each still runs the command it started.

The relay answers 200, or 410 for any token listed (whitespace-separated) in
<root>/relay-410.txt; edit that file while it runs. The session name
"default" means herdr's default session (Host sessionName ""). Typical use:

  python3 scripts/isolated-herdr-backend.py start --sessions default,work --plugin --relay
  python3 scripts/isolated-herdr-backend.py run --session work -- \\
      pane report-agent --source verify --agent claude --state blocked w1:p1
  python3 scripts/isolated-herdr-backend.py stop
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import pwd
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Optional


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = Path("/tmp/heeler-iso")
DEFAULT_SESSION = "default"
MARKER = ".heeler-isolated-backend"
# sockaddr_un.sun_path is 104 bytes on macOS, including the terminating NUL.
MAX_SOCKET_PATH_BYTES = 103
SSH_PORT_RANGE = range(47420, 47440)
RELAY_PORT_RANGE = range(47412, 47420)
SYSTEM_PATH = ("/usr/bin", "/bin", "/usr/sbin", "/sbin")
SESSION_NAME = re.compile(r"^[0-9A-Za-z._-]{1,64}$")
SFTP_SERVER_CANDIDATES = ("/usr/libexec/sftp-server", "/usr/lib/openssh/sftp-server",
                          "/usr/lib/ssh/sftp-server")
PLUGIN_ID = "heeler"
# Short windows keep a test loop fast; the plugin defaults are 5000/1500/1000.
RELAY_NOTIFY_CONFIG = {"debounce_ms": 1500, "activity_debounce_ms": 500,
                       "retry_delay_ms": 100}
# A namespace for deterministic Host ids, so re-seeding an app is idempotent.
HOST_ID_NAMESPACE = uuid.UUID("6f1d4c52-3a0e-4f1b-9c55-0e2a6b7d8c91")


class BackendError(Exception):
    """A refusal or failure the user should read; printed without a traceback."""


# ---------------------------------------------------------------------------
# Pure helpers (unit tested)


def validate_sessions(sessions: List[str]) -> List[str]:
    if not sessions:
        raise BackendError("At least one session is required")
    seen = set()
    for name in sessions:
        if name in (".", "..") or not SESSION_NAME.match(name):
            raise BackendError(
                f"Invalid herdr session name {name!r}: use 1-64 ASCII letters, digits, '.', '_' or '-'")
        if name in seen:
            raise BackendError(f"Session {name!r} is listed twice")
        seen.add(name)
    return sessions


def herdr_session_args(session: str) -> List[str]:
    """CLI arguments selecting a session; the default session takes none."""
    return [] if session == DEFAULT_SESSION else ["--session", session]


def app_session_name(session: str) -> str:
    """The Host sessionName the app stores: blank for the default session."""
    return "" if session == DEFAULT_SESSION else session


def session_dir(root: Path, session: str) -> Path:
    base = root / "home" / ".config" / "herdr"
    return base if session == DEFAULT_SESSION else base / "sessions" / session


def socket_paths(root: Path, session: str) -> Dict[str, Path]:
    directory = session_dir(root, session)
    return {"api": directory / "herdr.sock", "client": directory / "herdr-client.sock"}


def check_socket_paths(root: Path, sessions: List[str]) -> None:
    """Refuse a root whose herdr sockets would overflow AF_UNIX's path limit."""
    for session in sessions:
        for kind, candidate in socket_paths(root, session).items():
            length = len(os.fsencode(str(candidate)))
            if length > MAX_SOCKET_PATH_BYTES:
                raise BackendError(
                    f"The {kind} socket for session {session!r} would be {candidate} "
                    f"({length} bytes), over the {MAX_SOCKET_PATH_BYTES}-byte AF_UNIX limit; "
                    "choose a shorter --root (for example /tmp/heeler-iso) or session name")


def isolated_path(root: Path) -> str:
    return ":".join([str(root / "bin"), *SYSTEM_PATH])


def isolated_env(root: Path, user: str) -> Dict[str, str]:
    """The complete environment for every isolated process (nothing inherited)."""
    return {
        "HOME": str(root / "home"),
        "USER": user,
        "LOGNAME": user,
        "PATH": isolated_path(root),
        "SHELL": "/bin/zsh",
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
    }


def force_command_script(root: Path) -> str:
    """The sshd ForceCommand body: a clean isolated session for any command."""
    return "\n".join([
        "#!/bin/sh",
        "# ForceCommand for the isolated sshd: only the isolated herdr is reachable.",
        "unset HERDR_SOCKET_PATH HERDR_SESSION HERDR_ENV HERDR_PANE_ID",
        "unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR",
        f"HOME={root / 'home'}; export HOME",
        f"PATH={isolated_path(root)}; export PATH",
        'if [ -n "$SSH_ORIGINAL_COMMAND" ]; then exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"; fi',
        "exec /bin/sh",
        "",
    ])


def sshd_config(root: Path, port: int, user: str, sftp_server: str) -> str:
    """sshd settings mirroring write_common_config in scripts/run-ci-ios-tests.sh."""
    ssh = root / "ssh"
    return "\n".join([
        f"Port {port}",
        "ListenAddress 127.0.0.1",
        f"HostKey {ssh / 'host_ed25519'}",
        f"PidFile {ssh / 'sshd.pid'}",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "PubkeyAuthentication yes",
        f"AuthorizedKeysFile {ssh / 'authorized_keys'}",
        "UsePAM yes",
        "PermitRootLogin no",
        f"AllowUsers {user}",
        "StrictModes no",
        "PerSourcePenalties no",
        "PrintMotd no",
        "PrintLastLog no",
        "LogLevel VERBOSE",
        "AllowStreamLocalForwarding yes",
        f"Subsystem sftp {sftp_server}",
        f"SetEnv HOME={root / 'home'}",
        f"ForceCommand exec /bin/sh {root / 'force-command.sh'}",
        "",
    ])


def public_key_blob(public_key_line: str) -> bytes:
    fields = public_key_line.split()
    if len(fields) < 2:
        raise BackendError(f"Not an OpenSSH public key: {public_key_line!r}")
    try:
        return base64.b64decode(fields[1], validate=True)
    except ValueError as error:
        raise BackendError(f"Not an OpenSSH public key: {error}") from error


def blob_algorithm(blob: bytes) -> str:
    """The first SSH string in the key blob, as HostKeyFingerprint.readAlgorithm reads it."""
    if len(blob) < 4:
        raise BackendError("Public key blob is truncated")
    (length,) = struct.unpack(">I", blob[:4])
    if len(blob) < 4 + length:
        raise BackendError("Public key blob is truncated")
    return blob[4:4 + length].decode("ascii")


def known_host_entry(host: str, port: int, public_key_line: str) -> Dict[str, str]:
    """One knownHostFingerprints item, as UserDefaultsKnownHostsStore persists it."""
    blob = public_key_blob(public_key_line)
    endpoint = f"{host}:{port}"
    key = f"v2|{len(endpoint.encode('utf-8'))}|{endpoint}|{blob_algorithm(blob)}"
    return {key: base64.b64encode(hashlib.sha256(blob).digest()).decode("ascii")}


def display_fingerprint(public_key_line: str) -> str:
    digest = hashlib.sha256(public_key_blob(public_key_line)).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")


def host_entries(port: int, user: str, sessions: List[str]) -> List[Dict[str, object]]:
    """Hosts in the app's Codable shape (HostStore wraps them in {version, hosts})."""
    entries = []
    for session in sessions:
        entries.append({
            "id": str(uuid.uuid5(HOST_ID_NAMESPACE, f"127.0.0.1:{port}/{session}")).upper(),
            "name": f"Isolated {session}",
            "address": "127.0.0.1",
            "port": port,
            "username": user,
            "authMethod": "deviceKey",
            "sessionName": app_session_name(session),
            "jumpAddress": "",
            "jumpPort": 22,
            "jumpUsername": "",
        })
    return entries


def relay_status(token: object, gone_tokens: List[str]) -> int:
    return 410 if isinstance(token, str) and token in gone_tokens else 200


@dataclass
class ProcessRecord:
    pid: int
    marker: str
    log: str


@dataclass
class State:
    root: str
    user: str
    herdr: str
    sessions: List[str]
    servers: Dict[str, ProcessRecord] = field(default_factory=dict)
    ssh_port: Optional[int] = None
    sshd: Optional[ProcessRecord] = None
    relay_port: Optional[int] = None
    relay: Optional[ProcessRecord] = None
    plugin: Optional[str] = None
    started_at: float = 0.0

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, sort_keys=True) + "\n"

    @classmethod
    def from_json(cls, text: str) -> "State":
        raw = json.loads(text)
        record = lambda value: ProcessRecord(**value) if value else None  # noqa: E731
        return cls(
            root=raw["root"], user=raw["user"], herdr=raw["herdr"],
            sessions=list(raw["sessions"]),
            servers={name: ProcessRecord(**value) for name, value in raw.get("servers", {}).items()},
            ssh_port=raw.get("ssh_port"), sshd=record(raw.get("sshd")),
            relay_port=raw.get("relay_port"), relay=record(raw.get("relay")),
            plugin=raw.get("plugin"), started_at=raw.get("started_at", 0.0),
        )

    def records(self) -> List[ProcessRecord]:
        found = list(self.servers.values())
        found += [record for record in (self.sshd, self.relay) if record]
        return found


# ---------------------------------------------------------------------------
# Process and filesystem plumbing


def state_file(root: Path) -> Path:
    return root / "state.json"


def save_state(state: State) -> None:
    target = state_file(Path(state.root))
    temporary = target.with_suffix(".tmp")
    temporary.write_text(state.to_json())
    temporary.replace(target)


def load_state(root: Path) -> State:
    try:
        return State.from_json(state_file(root).read_text())
    except FileNotFoundError:
        raise BackendError(f"No isolated backend at {root} (no state.json)") from None


def process_command(pid: int) -> Optional[str]:
    result = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                            capture_output=True, text=True, check=False)
    command = result.stdout.strip()
    return command or None


def is_ours(record: ProcessRecord) -> bool:
    """Alive and still running what we started (guards against PID reuse)."""
    command = process_command(record.pid)
    return command is not None and record.marker in command


def wait_for_exit(pid: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process_command(pid) is None:
            return True
        time.sleep(0.2)
    return process_command(pid) is None


def wait_until(predicate, seconds: float, interval: float = 0.2) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def port_accepts(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def choose_port(requested: Optional[int], candidates: range, label: str) -> int:
    if requested is not None:
        if not port_is_free(requested):
            raise BackendError(f"{label} port {requested} is already in use")
        return requested
    for candidate in candidates:
        if port_is_free(candidate):
            return candidate
    raise BackendError(f"No free {label} port in {candidates.start}-{candidates.stop - 1}; pass one explicitly")


def spawn(arguments: List[str], *, env: Dict[str, str], cwd: Path, log: Path) -> int:
    with open(log, "ab") as output:
        process = subprocess.Popen(arguments, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    return process.pid


def herdr_command(state: State, session: str, arguments: List[str], *,
                  timeout: float = 30) -> subprocess.CompletedProcess:
    root = Path(state.root)
    return subprocess.run(
        [str(root / "bin" / "herdr"), *herdr_session_args(session), *arguments],
        env=isolated_env(root, state.user), cwd=root / "proj",
        capture_output=True, text=True, timeout=timeout, check=False)


def descendants(pids: List[int]) -> List[int]:
    result = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True,
                            check=False)
    children: Dict[int, List[int]] = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found: List[int] = []
    pending = list(pids)
    while pending:
        for child in children.get(pending.pop(), []):
            if child not in found:
                found.append(child)
                pending.append(child)
    return found


def processes_mentioning(text: str) -> List[str]:
    """Processes whose command line names `text`, excluding this script's callers."""
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True,
                            text=True, check=False)
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows[int(parts[0])] = (int(parts[1]), parts[2])
    # The invoking shell often quotes the root itself (`...; ls /tmp/heeler-iso`).
    callers = set()
    pid = os.getpid()
    while pid > 1 and pid not in callers:
        callers.add(pid)
        pid = rows.get(pid, (1, ""))[0]
    return [f"{pid} {command}" for pid, (_, command) in sorted(rows.items())
            if text in command and pid not in callers]


def resolve_executable(explicit: Optional[str], name: str) -> Optional[str]:
    candidate = explicit or shutil.which(name)
    if not candidate:
        return None
    resolved = os.path.realpath(candidate)
    # A version-manager shim (mise, asdf) resolves to the manager itself, which
    # cannot pick a version inside the isolated HOME.
    if not os.path.basename(resolved).startswith(name):
        option = "--herdr" if name == "herdr" else f"a real {name} earlier on PATH"
        raise BackendError(f"{candidate} resolves to {resolved}, not {name}; use {option}")
    return resolved


def current_user() -> str:
    return pwd.getpwuid(os.getuid()).pw_name


def prepare_root(root: Path) -> None:
    if root.exists():
        if not (root / MARKER).exists():
            if any(root.iterdir()):
                raise BackendError(f"{root} exists and was not created by this script; pick another --root")
        else:
            if state_file(root).exists():
                live = [record.pid for record in load_state(root).records() if is_ours(record)]
                if live:
                    raise BackendError(f"An isolated backend is already running at {root} (PIDs {live}); stop it first")
            shutil.rmtree(root)
    for relative in ("bin", "home", "proj", "logs", "ssh"):
        (root / relative).mkdir(parents=True, exist_ok=True)
    (root / MARKER).write_text("Created by scripts/isolated-herdr-backend.py\n")
    # An interactive zsh without rc files would prompt with zsh-newuser-install.
    (root / "home" / ".zshrc").write_text("")


# ---------------------------------------------------------------------------
# start


def read_key_argument(value: str) -> List[str]:
    candidate = Path(value).expanduser()
    text = candidate.read_text() if candidate.is_file() else value
    keys = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
    for key in keys:
        public_key_blob(key)
    return keys


def start_relay(state: State, port: int) -> None:
    root = Path(state.root)
    log = root / "logs" / "relay.log"
    pid = spawn([sys.executable, str(Path(__file__).resolve()), "--root", str(root),
                 "relay-serve", "--port", str(port)],
                env=isolated_env(root, state.user), cwd=root, log=log)
    state.relay = ProcessRecord(pid=pid, marker=f"--root {root} relay-serve", log=str(log))
    state.relay_port = port
    save_state(state)
    if not wait_until(lambda: port_accepts(port), 10):
        raise BackendError(f"The fake relay did not listen on {port}; see {log}")


def write_notify_config(root: Path, relay_port: int) -> Path:
    directory = root / "home" / ".config" / "herdr" / "plugins" / "config" / PLUGIN_ID
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "notify.json"
    config = {}
    if target.exists():
        config = json.loads(target.read_text())
    config.update(RELAY_NOTIFY_CONFIG)
    config["relay_url"] = f"http://127.0.0.1:{relay_port}"
    target.write_text(json.dumps(config, indent=2) + "\n")
    return target


def start_server(state: State, session: str) -> None:
    root = Path(state.root)
    log = root / "logs" / f"server-{session}.log"
    pid = spawn([str(root / "bin" / "herdr"), *herdr_session_args(session), "server"],
                env=isolated_env(root, state.user), cwd=root / "proj", log=log)
    state.servers[session] = ProcessRecord(pid=pid, marker=str(root / "bin" / "herdr"), log=str(log))
    save_state(state)
    api = socket_paths(root, session)["api"]
    if not wait_until(api.exists, 15):
        raise BackendError(f"herdr server for session {session!r} did not create {api}; see {log}")
    created = herdr_command(state, session, ["workspace", "create", "--cwd", str(root / "proj")])
    if created.returncode:
        raise BackendError(f"workspace create failed in session {session!r}: {created.stderr or created.stdout}")


def start_sshd(state: State, port: int, extra_keys: List[str]) -> None:
    root = Path(state.root)
    ssh = root / "ssh"
    for name in ("host_ed25519", "client_ed25519"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"heeler-iso-{name}",
                        "-f", str(ssh / name)], check=True, capture_output=True)
    client_key = (ssh / "client_ed25519.pub").read_text().strip()
    (ssh / "authorized_keys").write_text("\n".join([client_key, *extra_keys]) + "\n")
    host_key = (ssh / "host_ed25519.pub").read_text().strip()
    (ssh / "known_hosts").write_text(f"[127.0.0.1]:{port} {host_key}\n")
    force = root / "force-command.sh"
    force.write_text(force_command_script(root))
    force.chmod(0o755)
    sftp = next((candidate for candidate in SFTP_SERVER_CANDIDATES if Path(candidate).exists()),
                SFTP_SERVER_CANDIDATES[0])
    config = ssh / "sshd.conf"
    config.write_text(sshd_config(root, port, state.user, sftp))
    sshd = shutil.which("sshd", path="/usr/sbin:/usr/local/sbin:/opt/homebrew/sbin") or "/usr/sbin/sshd"
    checked = subprocess.run([sshd, "-t", "-f", str(config)], capture_output=True, text=True, check=False)
    if checked.returncode:
        raise BackendError(f"sshd rejected {config}: {checked.stderr.strip()}")
    log = root / "logs" / "sshd.log"
    pid = spawn([sshd, "-D", "-e", "-f", str(config)], env=isolated_env(root, state.user),
                cwd=root, log=log)
    state.sshd = ProcessRecord(pid=pid, marker=str(config), log=str(log))
    state.ssh_port = port
    save_state(state)
    if not wait_until(lambda: port_accepts(port), 10):
        raise BackendError(f"sshd did not listen on {port}; see {log}")


def command_start(args: argparse.Namespace) -> int:
    root = Path(os.path.abspath(args.root))
    sessions = validate_sessions([name.strip() for name in args.sessions.split(",") if name.strip()])
    check_socket_paths(root, sessions)
    herdr = resolve_executable(args.herdr, "herdr")
    if not herdr:
        raise BackendError("herdr not found on PATH; pass --herdr")
    node = resolve_executable(None, "node")
    if args.plugin and not node:
        raise BackendError("--plugin needs node on PATH (the plugin hooks run under node)")
    extra_keys = [key for value in args.authorized_key for key in read_key_argument(value)]
    ssh_port = choose_port(args.port, SSH_PORT_RANGE, "SSH")
    relay_port = choose_port(args.relay_port, RELAY_PORT_RANGE, "relay") if args.relay else None

    prepare_root(root)
    os.symlink(herdr, root / "bin" / "herdr")
    if node:
        os.symlink(node, root / "bin" / "node")
        npm = Path(node).with_name("npm")
        if npm.exists():
            os.symlink(npm, root / "bin" / "npm")
    state = State(root=str(root), user=current_user(), herdr=herdr, sessions=sessions,
                  started_at=time.time())
    save_state(state)
    try:
        if args.plugin:
            plugin = Path(args.plugin_dir).resolve()
            linked = herdr_command(state, DEFAULT_SESSION, ["plugin", "link", str(plugin)])
            if linked.returncode:
                raise BackendError(f"herdr plugin link failed: {linked.stderr or linked.stdout}")
            state.plugin = str(plugin)
            save_state(state)
        if relay_port is not None:
            start_relay(state, relay_port)
            write_notify_config(root, relay_port)
        for session in sessions:
            start_server(state, session)
        start_sshd(state, ssh_port, extra_keys)
    except BaseException:
        print(f"start failed; stopping what was started (logs kept in {root}/logs)", file=sys.stderr)
        stop_processes(state)
        raise
    print_status(state)
    return 0


# ---------------------------------------------------------------------------
# status


def status_report(state: State) -> Dict[str, object]:
    root = Path(state.root)
    report: Dict[str, object] = {"root": state.root, "herdr": state.herdr, "user": state.user}
    report["servers"] = {
        session: {"pid": record.pid, "alive": is_ours(record),
                  "socket": str(socket_paths(root, session)["api"]),
                  "app_session_name": app_session_name(session)}
        for session, record in state.servers.items()}
    if state.sshd:
        report["sshd"] = {"pid": state.sshd.pid, "alive": is_ours(state.sshd),
                          "port": state.ssh_port, "log": state.sshd.log}
        host_key = (root / "ssh" / "host_ed25519.pub").read_text().strip()
        report["host_key_fingerprint"] = display_fingerprint(host_key)
        report["known_host_fingerprints"] = known_host_entry("127.0.0.1", state.ssh_port, host_key)
        report["hosts"] = host_entries(state.ssh_port, state.user, state.sessions)
        report["client_key"] = str(root / "ssh" / "client_ed25519")
    if state.relay:
        relay_log = root / "relay.jsonl"
        requests = len(relay_log.read_text().splitlines()) if relay_log.exists() else 0
        report["relay"] = {"pid": state.relay.pid, "alive": is_ours(state.relay),
                           "url": f"http://127.0.0.1:{state.relay_port}",
                           "log": str(relay_log), "requests": requests,
                           "gone_tokens_file": str(root / "relay-410.txt")}
    if state.plugin:
        report["plugin"] = {"source": state.plugin,
                            "config_dir": str(root / "home/.config/herdr/plugins/config" / PLUGIN_ID)}
    return report


def print_status(state: State, as_json: bool = False) -> bool:
    report = status_report(state)
    healthy = all(record_alive for record_alive in _alive_flags(report))
    if as_json:
        print(json.dumps(report, indent=2))
        return healthy
    alive = lambda flag: "running" if flag else "NOT RUNNING"  # noqa: E731
    script = "python3 scripts/isolated-herdr-backend.py" + (
        f" --root {state.root}" if Path(state.root) != DEFAULT_ROOT else "")
    print(f"root: {state.root}")
    print(f"herdr: {state.herdr}")
    for session, server in report["servers"].items():
        print(f"herdr session {session}: pid {server['pid']} {alive(server['alive'])}, "
              f"socket {server['socket']}")
    if "sshd" in report:
        sshd = report["sshd"]
        print(f"sshd: pid {sshd['pid']} {alive(sshd['alive'])} on 127.0.0.1:{sshd['port']} "
              f"(log {sshd['log']})")
    if "relay" in report:
        relay = report["relay"]
        print(f"relay: pid {relay['pid']} {alive(relay['alive'])} at {relay['url']}, "
              f"{relay['requests']} request(s) in {relay['log']}")
    if "plugin" in report:
        print(f"plugin: linked from {report['plugin']['source']}, "
              f"config dir {report['plugin']['config_dir']}")
    if "sshd" in report:
        port = report["sshd"]["port"]
        sessions = ", ".join(json.dumps(app_session_name(name)) for name in state.sessions)
        print()
        print(f"App Host: address 127.0.0.1, port {port}, username {state.user}, "
              f"Device Key auth; one Host per sessionName {sessions}")
        print(f"Host key: {report['host_key_fingerprint']}")
        print("knownHostFingerprints: " + json.dumps(report["known_host_fingerprints"]))
        print(f"Test login: ssh -i {report['client_key']} -p {port} "
              f"-o UserKnownHostsFile={state.root}/ssh/known_hosts {state.user}@127.0.0.1 'herdr --version'")
        print(f"Authorize the app's Device Key: {script} authorize 'ssh-ed25519 AAAA...'")
        print(f"Host JSON for seeding prefs: {script} status --json (key \"hosts\")")
    return healthy


def _alive_flags(report: Dict[str, object]) -> List[bool]:
    flags = [server["alive"] for server in report["servers"].values()]
    flags += [report[name]["alive"] for name in ("sshd", "relay") if name in report]
    return flags


def command_status(args: argparse.Namespace) -> int:
    state = load_state(Path(os.path.abspath(args.root)))
    return 0 if print_status(state, args.json) else 1


# ---------------------------------------------------------------------------
# run / authorize


def command_run(args: argparse.Namespace) -> int:
    state = load_state(Path(os.path.abspath(args.root)))
    if args.session not in state.sessions:
        raise BackendError(f"Session {args.session!r} is not part of this backend ({', '.join(state.sessions)})")
    arguments = list(args.herdr_args)
    if arguments and arguments[0] == "--":
        arguments = arguments[1:]
    if not arguments:
        raise BackendError("Nothing to run; pass herdr arguments after --")
    root = Path(state.root)
    return subprocess.run([str(root / "bin" / "herdr"), *herdr_session_args(args.session), *arguments],
                          env=isolated_env(root, state.user), cwd=root / "proj", check=False).returncode


def command_authorize(args: argparse.Namespace) -> int:
    root = Path(os.path.abspath(args.root))
    load_state(root)
    keys = [key for value in args.keys for key in read_key_argument(value)]
    with open(root / "ssh" / "authorized_keys", "a") as output:
        for key in keys:
            output.write(key + "\n")
    print(f"Authorized {len(keys)} key(s) in {root / 'ssh' / 'authorized_keys'}")
    return 0


# ---------------------------------------------------------------------------
# stop


def terminate(record: ProcessRecord, label: str) -> None:
    if not is_ours(record):
        return
    os.kill(record.pid, signal.SIGTERM)
    if not wait_for_exit(record.pid, 5) and is_ours(record):
        print(f"{label} (pid {record.pid}) ignored SIGTERM; sending SIGKILL", file=sys.stderr)
        os.kill(record.pid, signal.SIGKILL)
        wait_for_exit(record.pid, 3)


def stop_processes(state: State) -> List[int]:
    """Stop recorded processes and their descendants; return any that survive."""
    tracked = [record.pid for record in state.records() if is_ours(record)]
    children = descendants(tracked)
    for session, record in state.servers.items():
        if not is_ours(record):
            continue
        try:
            stopped = herdr_command(state, session, ["server", "stop"], timeout=20).returncode == 0
        except subprocess.TimeoutExpired:
            stopped = False
        if not stopped or not wait_for_exit(record.pid, 10):
            print(f"herdr server stop did not end session {session!r}; signalling pid {record.pid}",
                  file=sys.stderr)
            terminate(record, f"herdr session {session}")
    if state.sshd:
        terminate(state.sshd, "sshd")
    if state.relay:
        terminate(state.relay, "relay")
    wait_until(lambda: all(process_command(pid) is None for pid in children), 5)
    # Children of our processes are ours too (an SSH login, herdr's own curl).
    for pid in children:
        if process_command(pid) is not None:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    wait_until(lambda: all(process_command(pid) is None for pid in children), 3)
    return [pid for pid in children if process_command(pid) is not None]


def command_stop(args: argparse.Namespace) -> int:
    root = Path(os.path.abspath(args.root))
    if not (root / MARKER).exists():
        raise BackendError(f"{root} is not an isolated backend root (no {MARKER})")
    state = load_state(root) if state_file(root).exists() else None
    survivors = stop_processes(state) if state else []
    leftovers = [record.pid for record in (state.records() if state else []) if is_ours(record)]
    mentioning = processes_mentioning(str(root) + "/")
    # A process executing from the root is ours; one that only names a path in
    # it (`tail -f <root>/relay.jsonl`) is reported but does not block removal.
    running = [line for line in mentioning if line.split(None, 1)[1].startswith(str(root) + "/")]
    if survivors or leftovers or running:
        print("Still running after stop (root kept for inspection):", file=sys.stderr)
        for pid in sorted(set(survivors + leftovers)):
            print(f"  {pid} {process_command(pid)}", file=sys.stderr)
        for line in running:
            print(f"  {line}", file=sys.stderr)
        return 1
    for line in mentioning:
        print(f"Note: still references {root}: {line}", file=sys.stderr)
    if args.keep:
        print(f"Stopped; kept {root}")
    else:
        shutil.rmtree(root)
        print(f"Stopped; removed {root}")
    return 0


# ---------------------------------------------------------------------------
# relay-serve (internal)


def command_relay_serve(args: argparse.Namespace) -> int:
    root = Path(os.path.abspath(args.root))
    log = root / "relay.jsonl"
    gone_file = root / "relay-410.txt"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8", "replace")
            try:
                body: object = json.loads(raw) if raw else None
            except ValueError:
                body = raw
            gone = gone_file.read_text().split() if gone_file.exists() else []
            status = relay_status(body.get("token") if isinstance(body, dict) else None, gone)
            record = {"at": int(time.time() * 1000), "status": status, "method": "POST",
                      "path": self.path, "body": body}
            with open(log, "a") as output:
                output.write(json.dumps(record) + "\n")
            payload = b'{"error":"Unregistered"}' if status == 410 else b"{}"
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format: str, *values: object) -> None:  # noqa: A002
            sys.stderr.write("relay: " + (format % values) + "\n")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print(f"relay listening on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


# ---------------------------------------------------------------------------


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    top.add_argument("--root", default=str(DEFAULT_ROOT),
                     help=f"state directory, kept short for AF_UNIX paths (default {DEFAULT_ROOT})")
    commands = top.add_subparsers(dest="command", required=True)

    start = commands.add_parser("start", help="start herdr servers, sshd, and optional plugin/relay")
    start.add_argument("--sessions", default=DEFAULT_SESSION,
                       help="comma-separated herdr sessions; 'default' is the default session")
    start.add_argument("--port", type=int, help=f"sshd port (default: first free in "
                       f"{SSH_PORT_RANGE.start}-{SSH_PORT_RANGE.stop - 1})")
    start.add_argument("--plugin", action="store_true", help="herdr plugin link the repository plugin")
    start.add_argument("--plugin-dir", default=str(REPO_ROOT / "plugin"), help=argparse.SUPPRESS)
    start.add_argument("--relay", action="store_true",
                       help="start a fake Push Relay and point notify.json relay_url at it")
    start.add_argument("--relay-port", type=int, help=f"relay port (default: first free in "
                       f"{RELAY_PORT_RANGE.start}-{RELAY_PORT_RANGE.stop - 1})")
    start.add_argument("--authorized-key", action="append", default=[], metavar="KEY_OR_FILE",
                       help="extra public key line or file to authorize (repeatable); a client "
                            "key is always generated at <root>/ssh/client_ed25519")
    start.add_argument("--herdr", help="herdr executable (default: herdr on PATH)")
    start.set_defaults(handler=command_start)

    status = commands.add_parser("status", help="show processes, Host settings, and host key entry")
    status.add_argument("--json", action="store_true", help="machine-readable output")
    status.set_defaults(handler=command_status)

    run = commands.add_parser("run", help="run herdr in the isolated environment")
    run.add_argument("--session", default=DEFAULT_SESSION)
    run.add_argument("herdr_args", nargs=argparse.REMAINDER, help="-- <herdr arguments>")
    run.set_defaults(handler=command_run)

    authorize = commands.add_parser("authorize", help="append public keys to the sshd's authorized_keys")
    authorize.add_argument("keys", nargs="+", metavar="KEY_OR_FILE")
    authorize.set_defaults(handler=command_authorize)

    stop = commands.add_parser("stop", help="stop recorded processes and remove the root")
    stop.add_argument("--keep", action="store_true", help="keep the root (logs, relay.jsonl)")
    stop.set_defaults(handler=command_stop)

    relay = commands.add_parser("relay-serve", help=argparse.SUPPRESS)
    relay.add_argument("--port", type=int, required=True)
    relay.set_defaults(handler=command_relay_serve)
    return top


def main(argv: Optional[List[str]] = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.handler(args)
    except BackendError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
