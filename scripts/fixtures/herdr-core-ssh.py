#!/usr/bin/env python3
"""Disposable real-core SSH fixture for HerdrCoreTransportE2ETests.

Reuse the existing isolated backend's sshd, key generation and cleanup:
  python3 scripts/fixtures/herdr-core-ssh.py start --root /tmp/hc-heeler
Pass HEELER_SSH_E2E_CONFIG to the chosen Simulator launchctl environment (the
scheme does not forward shell exports). Read <root>/core-test-config privately
and pass its stripped contents as the final argument to this subprocess argv:
  ["xcrun", "simctl", "spawn", "<UDID>", "launchctl", "setenv", "HEELER_SSH_E2E_CONFIG", config]
Then run make test-app. Afterwards clear it with:
  xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
Stop the fixture by invoking this script with stop and the same root.
No installed core, live session, or user configuration is changed.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


HERE = Path(__file__).resolve().parent
backend = load("isolated_backend", HERE.parent / "isolated-herdr-backend.py")
keys = load("fixture_keys", HERE / "openssh-ed25519-seed.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["start", "stop"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--core", default=shutil.which("herdr-core"))
    parser.add_argument("--port", type=int)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "stop":
        backend.load_state(root)  # Refuse arbitrary directories.
        core_failed = False
        for session in sorted((root / "state/herdr-core").glob("*")):
            if not session.is_dir():
                continue
            try:
                stopped = subprocess.run([str(root / "home/.local/bin/hc"), "server", "stop"],
                    env=dict(os.environ, HC_SESSION=session.name), capture_output=True, timeout=20, check=False)
                if stopped.returncode != 0:
                    raise RuntimeError(f"exit status {stopped.returncode}")
            except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
                core_failed = True
                print(f"Could not stop core session {session.name!r}: {error}", file=sys.stderr)
        # Core daemons are detached and are not in the shared helper's process
        # records. A failed core stop must retain their sockets/state for a
        # retry, while still stopping the SSH server we own.
        status = backend.command_stop(argparse.Namespace(root=root, keep=core_failed))
        return status or int(core_failed)
    if not args.core or not Path(args.core).is_file():
        parser.error("install herdr-core or pass --core; this fixture never installs or updates it")
    if len(str(root)) > 35 or any(c.isspace() for c in str(root)):
        parser.error("choose a short scratch path without spaces (Unix socket length limit)")
    if (root / "state/herdr-core").exists():
        parser.error("core state already exists; run stop successfully before reusing this root")
    backend.prepare_root(root)
    # Keep the same Python selected by the caller/CI, not Apple's shim or a
    # different interpreter found through sshd's minimal PATH.
    (root / "bin/python3").symlink_to(sys.executable)
    state = backend.State(root=str(root), user=backend.current_user(), herdr="", sessions=[], started_at=time.time())
    bin_dir = root / "home/.local/bin"
    bin_dir.mkdir(parents=True)
    for name in ("run", "state", "config"):
        (root / name).mkdir(mode=0o700)
    wrapper = bin_dir / "hc"
    wrapper.write_text("\n".join([
        "#!/bin/sh", "unset HC_SOCKET HC_TERMINAL_ID",
        f"export XDG_RUNTIME_DIR={shlex.quote(str(root / 'run'))}",
        f"export XDG_STATE_HOME={shlex.quote(str(root / 'state'))}",
        f"export XDG_CONFIG_HOME={shlex.quote(str(root / 'config'))}",
        "export HC_SETTLE_MS=0",
        f"exec {shlex.quote(str(Path(args.core).resolve()))} \"$@\"", "",
    ]))
    wrapper.chmod(0o700)
    (bin_dir / "herdr-core").symlink_to("hc")
    legacy = bin_dir / "herdr"
    legacy.write_text(f"#!/bin/sh\nprintf called >> {shlex.quote(str(root / 'legacy-called'))}\nexit 91\n")
    legacy.chmod(0o700)
    port = backend.choose_port(args.port, backend.SSH_PORT_RANGE, "SSH")
    backend.start_sshd(state, port, [])
    config = {"coreFixture": True, "host": "127.0.0.1", "port": port,
              "username": state.user, "homePath": str(root / "home"),
              "deviceKeySeed": base64.b64encode(keys.seed(str(root / "ssh/client_ed25519"))).decode()}
    path = root / "core-test-config"
    path.write_text(base64.b64encode(json.dumps(config).encode()).decode() + "\n")
    path.chmod(0o600)
    print(f"Fixture ready on 127.0.0.1:{port}; configuration: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
