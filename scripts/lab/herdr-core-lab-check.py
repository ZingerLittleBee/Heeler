#!/usr/bin/env python3
"""Run the herdr-core end-to-end methods and the Linux checks on a lab machine.

    make verify-core-linux-host [LAB=hc-lab] [LAB_PORT=47430] SIM_UDID=<udid>

An owner's check, for a box the instabox CLI is signed in to. What it does there,
all of it undone at the end, also after a failure: authorizes a throwaway key
through a port-forward, writes the fixture's startup files into a directory of
its own for the launch method, starts cores only by absolute path under unique
HC_SESSION names, reads the systemd units, linger and the socket path, captures
scrubbed frames and replays them through a decoder, then stops those cores by
absolute path and removes the key and every file it wrote.

Safety: it runs no `hc` and no `pkill` over SSH, and stops only sessions it
started. See docs/guides/herdr-core-testing.md.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
from pathlib import Path
import secrets
import shlex
import socket as socketlib
import struct
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
E2E_SUITE = "HeelerTests/HerdrCoreTransportE2ETests"
CONFIG_VARIABLE = "HEELER_SSH_E2E_CONFIG"
HEADER = struct.Struct("<IBI")


def load_keys():
    spec = importlib.util.spec_from_file_location("fixture_keys", HERE.parent / "fixtures/openssh-ed25519-seed.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_fixture():
    spec = importlib.util.spec_from_file_location("herdr_core_ssh", HERE.parent / "fixtures/herdr-core-ssh.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["herdr_core_ssh"] = module
    spec.loader.exec_module(module)
    return module


def unique_session():
    """Starts with a letter, and nothing else on the box uses it."""
    return "hl" + secrets.token_hex(4)


def replay(vectors):
    """Each captured frame decodes and encodes back to its exact bytes."""
    frames = 0
    for case in vectors["exchanges"]:
        for name in ("requestFrame", "replyFrame"):
            raw = bytes.fromhex(case[name])
            channel, kind, length = HEADER.unpack_from(raw)
            payload = raw[HEADER.size:HEADER.size + length]
            if HEADER.pack(channel, kind, len(payload)) + payload != raw:
                raise ValueError(f"{case['name']} {name} did not replay unchanged")
            json.loads(payload)
            frames += 1
    for case in vectors["events"]:
        json.loads(case["line"])
    return frames


class Lab:
    """Every remote step goes through `run`, every local one through `local`."""

    def __init__(self, box, port, udid, run=None, local=None, spawn=None, wait_for_port=None, out=None):
        self.box = box
        self.port = port
        self.udid = udid
        self.run = run or self._instabox
        self.local = local or (lambda command: subprocess.run(command, cwd=ROOT, check=False).returncode)
        self.spawn = spawn or (lambda command: subprocess.Popen(command, stdout=subprocess.DEVNULL))
        self.wait_for_port = wait_for_port or self._wait_for_port
        self.out = out or (ROOT / ".local/lab-capture")
        self.session = unique_session()
        self.marker = f"heeler-lab-{self.session}"
        self.failures = []
        self.undo = []

    def _instabox(self, command):
        result = subprocess.run(["instabox", "exec", self.box, "--", "bash", "-c", command],
                                capture_output=True, text=True, timeout=180, check=False)
        return result.returncode, result.stdout

    def _wait_for_port(self, port):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            with socketlib.socket() as probe:
                probe.settimeout(1)
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    return True
            time.sleep(0.2)
        return False

    def remote(self, command):
        status, stdout = self.run(command)
        if status:
            raise RuntimeError(f"on {self.box}: {command.split()[0]} failed with status {status}")
        return stdout

    def check(self, name, passed, detail=""):
        print(f"{'PASS' if passed else 'FAIL'} {name}{': ' + detail if detail else ''}")
        if not passed:
            self.failures.append(name)

    def core_command(self, session, words):
        """The only way a core is touched here: absolute path, explicit environment."""
        pairs = dict(self.environment, HC_SESSION=session)
        env = " ".join(shlex.quote(f"{name}={value}") for name, value in sorted(pairs.items()))
        return f"env -i {env} {shlex.quote(self.executable)} {' '.join(words)} </dev/null"

    def prepare(self):
        facts = self.remote('printf "%s\\n" "$HOME" "$(id -u)" "$(id -un)"').split()
        self.home, self.uid, self.user = facts[0], facts[1], facts[2]
        self.executable = f"{self.home}/.local/bin/herdr-core"
        self.state_root = f"{self.home}/.local/state/herdr-core"
        self.directory = f"{self.home}/.cache/{self.marker}"
        self.environment = {
            "HOME": self.home, "USER": self.user, "LOGNAME": self.user,
            "PATH": "/usr/local/bin:/usr/bin:/bin", "SHELL": "/bin/bash", "TERM": "xterm-256color",
            "LANG": "C.UTF-8", "XDG_RUNTIME_DIR": f"/run/user/{self.uid}",
        }
        self.socket_path = f"/run/user/{self.uid}/herdr-core/{self.session}.sock"
        self.check("core version", "0.1.13" in self.remote(f"{shlex.quote(self.executable)} --version"))
        self.undo.append(lambda: self.remote(f"rm -rf {shlex.quote(self.directory)}"))
        self.remote(f"mkdir -p {shlex.quote(self.directory)}")
        self.sessions_before = set(self.remote(f"ls {shlex.quote(self.state_root)} 2>/dev/null || true").split())
        self.undo.append(self.stop_every_new_session)

    def upload(self, source, name):
        path = f"{self.directory}/{name}"
        encoded = base64.b64encode(source.read_bytes()).decode()
        self.remote(f"printf %s {encoded} | base64 -d > {shlex.quote(path)} && chmod 700 {shlex.quote(path)}")
        return path

    def write_launch_home(self):
        """The launch method reads these, so the account's own startup files stay as they are."""
        home = f"{self.directory}/launch-home"
        for relative, text in load_fixture().rc_files().items():
            path = f"{home}/{relative}"
            encoded = base64.b64encode(text.encode()).decode()
            self.remote(f"mkdir -p {shlex.quote(path.rsplit('/', 1)[0])} && "
                        f"printf %s {encoded} | base64 -d > {shlex.quote(path)} && chmod 700 {shlex.quote(path)}")
        return home

    def authorize_throwaway_key(self, directory):
        key = Path(directory) / "key"
        status = self.local(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", self.marker, "-f", str(key)])
        if status:
            raise RuntimeError("ssh-keygen failed")
        public = (Path(directory) / "key.pub").read_text().strip()
        self.undo.append(lambda: self.remote(
            f"sed -i {shlex.quote(f'/{self.marker}/d')} {shlex.quote(self.home + '/.ssh/authorized_keys')}"))
        self.remote(f"mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' {shlex.quote(public)} >> ~/.ssh/authorized_keys"
                    " && chmod 600 ~/.ssh/authorized_keys")
        return base64.b64encode(load_keys().seed(str(key))).decode()

    def forward(self):
        child = self.spawn(["instabox", "port-forward", self.box, f"{self.port}:22"])
        self.undo.append(child.terminate)
        if not self.wait_for_port(self.port):
            raise RuntimeError(f"the port-forward to {self.box} never opened")

    def configuration(self, seed, helper, launch_home):
        return {
            "coreFixture": True, "host": "127.0.0.1", "port": self.port, "username": self.user,
            "homePath": self.home, "deviceKeySeed": seed, "coreExecutable": self.executable,
            "startEnvironment": self.environment, "rpcHelper": helper, "launchHome": launch_home,
            # The box has a real hc, which this check leaves alone: only the fixture
            # can trip on it, so these logs stay empty here by construction.
            "tripwireLog": f"{self.directory}/hc-called.log", "legacyLog": f"{self.directory}/legacy-called",
        }

    def run_end_to_end(self, config):
        destination = f"platform=iOS Simulator,id={self.udid}"
        encoded = base64.b64encode(json.dumps(config).encode()).decode()
        self.local(["xcrun", "simctl", "bootstatus", self.udid, "-b"])
        self.undo.append(lambda: self.local(
            ["xcrun", "simctl", "spawn", self.udid, "launchctl", "unsetenv", CONFIG_VARIABLE]))
        self.local(["xcrun", "simctl", "spawn", self.udid, "launchctl", "setenv", CONFIG_VARIABLE, encoded])
        status = self.local(["make", "test-app", f"SIM_DESTINATION={destination}", f"TEST_SELECTOR={E2E_SUITE}"])
        self.check("the eight end-to-end methods", status == 0)

    def check_linux_facts(self, helper):
        self.remote(self.core_command(self.session, ["server", "start"]))
        # A holder appears with a first Terminal.
        program = json.dumps({"argv": ["/bin/sleep", "600"], "cwd": self.home})
        self.remote(f"{shlex.quote(helper)} --session {self.session} terminal.run --params {shlex.quote(program)}")
        units = self.remote("systemctl --user list-units --all --no-legend --plain 'hc-serve-*' 'hc-hold-*'")
        self.check("an hc-serve unit", "hc-serve-" in units)
        self.check("an hc-hold unit", "hc-hold-" in units)
        self.check("linger", "Linger=yes" in self.remote(f"loginctl show-user {shlex.quote(self.user)} -p Linger"))
        status, _ = self.run(f"test -S {shlex.quote(self.socket_path)}")
        self.check("the socket at /run/user/<uid>/herdr-core/<s>.sock", status == 0, self.socket_path)

    def capture_and_replay(self):
        script = self.upload(HERE / "herdr-core-capture.py", "capture")
        vectors = f"{self.directory}/vectors.json"
        events = f"{self.directory}/events.ndjson"
        self.remote(f"{shlex.quote(script)} --socket {shlex.quote(self.socket_path)} "
                    f"--vectors {shlex.quote(vectors)} --events {shlex.quote(events)} --seconds 20")
        captured = self.remote(f"cat {shlex.quote(vectors)}")
        self.out.mkdir(parents=True, exist_ok=True)
        path = self.out / f"{self.session}.json"
        path.write_text(captured)
        frames = replay(json.loads(captured))
        self.check("captured frames replay unchanged", frames > 0, f"{frames} frames; read {path} before keeping it")

    def stop_every_new_session(self):
        """Only sessions that were not on the box when this began."""
        now = set(self.remote(f"ls {shlex.quote(self.state_root)} 2>/dev/null || true").split())
        for session in sorted(now - self.sessions_before):
            self.remote(self.core_command(session, ["server", "stop"]))
            self.remote(f"rm -rf {shlex.quote(self.state_root + '/' + session)}")

    def perform(self):
        with tempfile.TemporaryDirectory(prefix="heeler-lab-") as directory:
            try:
                self.prepare()
                helper = self.upload(HERE.parent / "fixtures/herdr-core-rpc.py", "herdr-core-rpc")
                launch_home = self.write_launch_home()
                seed = self.authorize_throwaway_key(directory)
                self.forward()
                self.run_end_to_end(self.configuration(seed, helper, launch_home))
                self.check_linux_facts(helper)
                self.capture_and_replay()
            except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
                self.check("the check ran to its end", False, str(error))
            finally:
                for step in reversed(self.undo):
                    try:
                        step()
                    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
                        self.check("cleanup", False, str(error))
        print(f"{'FAILED: ' + ', '.join(self.failures) if self.failures else 'All lab checks passed.'}")
        return 1 if self.failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--box", default="hc-lab")
    parser.add_argument("--port", type=int, default=47430)
    parser.add_argument("--udid", required=True, help="the Simulator to run the end-to-end methods on")
    args = parser.parse_args()
    return Lab(args.box, args.port, args.udid).perform()


if __name__ == "__main__":
    raise SystemExit(main())
