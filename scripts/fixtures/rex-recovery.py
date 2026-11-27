#!/usr/bin/env python3
"""Drive RexRecoveryLiveTests on a disposable loopback macOS or Linux SSH account."""

import argparse
import http.server
import json
import os
import pwd
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

LABELS = ("heeler-lab-recovery-target", "heeler-lab-recovery-peer")


def eventually(read, accepts):
    for _ in range(100):
        try:
            value = read()
            if accepts(value):
                return value
        except (OSError, subprocess.CalledProcessError, KeyError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Timed out waiting for " + read.__name__)


def on_host(action, directory, marker):
    if action == "prepare":
        root = Path(tempfile.mkdtemp(prefix="heeler-lab-recovery-", dir="/tmp"))
        (root / "fixture").write_text(marker)
        return {"root": str(root)}
    root = Path(directory)
    if root.parent != Path("/tmp") or not root.name.startswith("heeler-lab-recovery-") or (root / "fixture").read_text() != marker:
        raise ValueError("Unrecognized recovery fixture")
    if action == "initial":
        for name in ("home", "runtime", "config", "state-a", "state-b", "bin"):
            (root / name).mkdir(mode=0o700)
        executable = root / "bin/claude"
        shutil.copyfile("/bin/bash", executable)
        executable.chmod(0o700)
        if sys.platform == "darwin":
            # macOS enforces the system binary signature after copying to a writable volume.
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)], check=True, stderr=subprocess.PIPE)
    sock = root / "runtime/server.sock"
    env = dict(os.environ, HOME=str(root / "home"), REX_RUNTIME_DIR=str(sock.parent),
               XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "home/data"), SHELL="/bin/bash")
    command = ["rex", "--autostart=false", "-S", str(sock)]

    def rex(*args):
        return subprocess.check_output([*command, *args], env=env, text=True, stderr=subprocess.PIPE)

    def status():
        return json.loads(rex("api", "call", "server.status"))

    def list_sessions():
        return json.loads(rex("api", "call", "session.list"))["sessions"]

    def snapshot():
        state = status()
        rows = []
        for entry in sorted(list_sessions(), key=lambda item: item["label"]):
            sid = entry["session_id"]
            block = json.loads(rex("api", "call", "-s", sid, "session.view"))["windows"][0]["focused_block_id"]
            proc = json.loads(rex("api", "call", "-s", sid, "com.superlogical.terminal.process",
                                  json.dumps({"block_id": block})))["foreground"]
            screen = rex("capture", "-s", sid, "-b", block, "--unwrap", "--trim")
            rows.append(dict(label=entry["label"], session=sid, block=block, pid=proc["pid"],
                             program=proc["name"], containsMarker=marker in screen))
        return dict(instance=state["instance_id"], host=state["host_id"], rows=rows)

    def stop_own():
        if status()["instance_id"] != (root / "instance").read_text():
            raise ValueError("Unexpected Rex instance on the fixture socket")
        rex("server", "stop")
        eventually(lambda: sock.exists(), lambda present: not present)

    if action == "cleanup":
        if sock.exists():
            stop_own()
        shutil.rmtree(root)
        return {"cleaned": True}
    if action in ("restored", "fresh"):
        stop_own()
    if action in ("initial", "restored", "fresh"):
        state_dir = root / ("state-b" if action == "fresh" else "state-a")
        if action == "fresh":
            # Carry only the file-host identity. The new state has no session or terminal snapshots.
            shutil.copy2(root / "state-a/host-id", state_dir / "host-id")
        rex("server", "start", "--restore=true", "--state-dir", str(state_dir))
        (root / "instance").write_text(eventually(status, lambda s: bool(s["instance_id"]))["instance_id"])
        if action != "restored":
            if list_sessions():
                raise ValueError("New state unexpectedly has sessions")
            for name in LABELS:
                layout = {"block": {"flavor": "com.superlogical.terminal.shell",
                                    "options": {"cwd": str(root / "home"), "shell": "/bin/bash", "login": False}}}
                created = json.loads(rex("api", "call", "session.create", json.dumps({
                    "label": name, "initial_windows": [{"layout": layout}]})))
                if name == LABELS[0] and action == "initial":
                    sid = created["session_id"]
                    block = created["initial_windows"][0]["block_ids"][0]
                    # Type into this shell once. After restore Rex starts an ordinary shell here.
                    fixture = "printf '\\033]7501;state=idle:app=claude\\007heeler-lab-agent-ready\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done"
                    rex("send", "-s", sid, "-b", block, shlex.join(["exec", str(root / "bin/claude"), "-c", fixture]))
                    rex("send-key", "-s", sid, "-b", block, "enter")
    if action.startswith("inspect-"):
        # PTY echo occurs after the control reply to a paste.
        time.sleep(0.4)
    # Restoring Rex starts the account's login shell, even when the old block
    # explicitly launched bash. New fixture windows always start bash.
    login_shell = Path(pwd.getpwuid(os.getuid()).pw_shell).name
    shell = login_shell if action in ("restored", "inspect-restored") else "bash"
    expected = "claude" if action == "initial" else shell
    def ready(observation):
        programs = {row["label"]: row["program"] for row in observation["rows"]}
        return programs == {LABELS[0]: expected, LABELS[1]: shell}
    observation = eventually(snapshot, ready)
    return dict(root=str(root), rexSocket=str(sock), loginShell=login_shell, **observation)


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def proxy_command(port, command):
    with socket.create_connection(("127.0.0.1", port), timeout=4) as connection:
        connection.sendall(json.dumps({"command": command}).encode() + b"\n")
        return json.loads(connection.makefile("rb").readline())


def serve(args):
    source = Path(__file__).resolve()
    base = json.loads(args.lab.read_text())
    if base.get("host", "127.0.0.1") != "127.0.0.1" or not re.fullmatch(r"heeler-lab-[a-z0-9-]+", args.target):
        raise ValueError("Expected a disposable loopback SSH account")
    args.output.mkdir(mode=0o700)
    script = source.read_bytes()
    marker = "HEELER_LAB_STALE_" + secrets.token_hex(10).upper()
    token = secrets.token_urlsafe(24)
    remote_root = ""

    def remote(action):
        argv = ["python3", "-", "--host", action, remote_root, marker]
        command = ["ssh", "-F", str(args.ssh_config), "-o", "BatchMode=yes", args.target, shlex.join(argv)]
        return json.loads(subprocess.check_output(command, input=script, timeout=35))

    remote_root = remote("prepare")["root"]
    try:
        initial = remote("initial")
    except (OSError, ValueError, subprocess.SubprocessError):
        remote("cleanup")
        raise
    port = available_port()
    control = available_port()
    while control == port:
        control = available_port()
    ssh_proxy = None
    counters = {}
    observations = {"initial": initial}
    steps = iter(("cut", "restored", "inspect-restored", "fresh", "inspect-fresh"))
    next_step = next(steps)

    def perform(action):
        nonlocal next_step
        if action != next_step:
            raise ValueError("Out-of-order recovery phase " + action)
        if action == "cut":
            stats = proxy_command(control, "cut")
            if stats["cutConnections"] < 1:
                raise ValueError("No established SSH connection was cut")
            counters.update(stats)
            result = stats
        else:
            result = remote(action)
            if any(row["containsMarker"] for row in result["rows"]):
                raise ValueError("The stale input appeared in a fixture shell")
            observations[action] = result
        (args.output / "evidence.json").write_text(json.dumps(dict(cut=counters, observations=observations), indent=2))
        next_step = next(steps, "complete")
        return result

    class Controller(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_POST(self):
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403)
                return
            try:
                response = json.dumps(perform(self.path.lstrip("/"))).encode()
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                print(str(error), file=sys.stderr, flush=True)
                self.send_error(409)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

    try:
        with (args.output / "proxy.log").open("w") as log, http.server.HTTPServer(("127.0.0.1", 0), Controller) as controller:
            ssh_proxy = subprocess.Popen([sys.executable, str(source.with_name("weak-network-proxy.py")),
                                          "--listen-port", str(port), "--control-port", str(control),
                                          "--target-port", str(base["port"])], stdout=log, stderr=log)
            eventually(lambda: proxy_command(control, "stats"), lambda reply: reply["ok"])
            config = {name: base[name] for name in ("user", "seed", "fingerprint")}
            config.update(port=port, controller=controller.server_port, token=token, marker=marker, initial=initial)
            with open(args.output / "fixture.json", "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as file:
                json.dump(config, file)
            print(args.output / "fixture.json", flush=True)
            while next_step != "complete":
                controller.handle_request()
    finally:
        if ssh_proxy is not None:
            ssh_proxy.terminate()
            ssh_proxy.wait()
        remote("cleanup")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--host"]:
        print(json.dumps(on_host(*sys.argv[2:])))
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--lab", type=Path, required=True, help="private loopback SSH fixture JSON")
        parser.add_argument("--ssh-config", type=Path, required=True, help="private, pinned OpenSSH config")
        parser.add_argument("--target", required=True, help="heeler-lab- alias in the OpenSSH config")
        parser.add_argument("--output", type=Path, required=True, help="new private directory on the Simulator Mac")
        def terminate(_number, _frame):
            raise SystemExit(1)
        signal.signal(signal.SIGTERM, terminate)
        serve(parser.parse_args())
