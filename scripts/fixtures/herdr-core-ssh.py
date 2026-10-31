#!/usr/bin/env python3
"""Disposable real-core SSH fixture for HerdrCoreTransportE2ETests.

Reuse the existing isolated backend's sshd, key generation and cleanup:
  python3 scripts/fixtures/herdr-core-ssh.py start --root /tmp/hc-heeler --core <path>
Pass HEELER_SSH_E2E_CONFIG to the chosen Simulator launchctl environment (the
scheme does not forward shell exports). Read <root>/core-test-config privately
and pass its stripped contents as the final argument to this subprocess argv:
  ["xcrun", "simctl", "spawn", "<UDID>", "launchctl", "setenv", "HEELER_SSH_E2E_CONFIG", config]
Then run make test-app. Afterwards clear it with:
  xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
Stop the fixture by invoking this script with stop and the same root.
No installed core, live session, or user configuration is changed.

The app never starts a core, so neither does anything here by accident: the
core runs only from an explicit `server start` by absolute path in the isolated
environment, with its own session (the start-core command, or a test doing the
same over SSH). herdr-core sits only at ~/.local/bin, off the exec's PATH. `hc`
and `herdr` are tripwires that log every call, and the rc files carry a PATH
stub and a marker that a launch through a login shell can be checked by, for
bash, zsh and fish alike.
"""
import argparse
import base64
import importlib.util
import json
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

# The E2E suite's session names: "h" and eight hex digits.
SESSION_LENGTH = 9
# macOS's sun_path limit, the lower of the two platforms' (107 on Linux).
SOCKET_PATH_LIMIT = 103
RC_MARKER = "HEELER_FIXTURE_RC_MARKER"


def core_executable(root):
    return root / "home/.local/bin/herdr-core"


def state_root(root):
    return root / "home/.local/state/herdr-core"


def tripwire_log(root):
    return root / "hc-called.log"


def legacy_log(root):
    return root / "legacy-called"


def longest_socket_path(root, session_length=SESSION_LENGTH):
    """The holder's socket, the longest path a core binds with no XDG directory.

    `<state>/<s>/<s>.holder.<8 hex>.sock` under the home's default state
    directory, which is where a core's sockets land when /run/user has none.
    """
    return len(f"{root}/home/.local/state/herdr-core/") + session_length + len("/") \
        + session_length + len(".holder.") + 8 + len(".sock")


def start_environment(root, user, session=None):
    """Everything a fixture core is given. It has no XDG variable on purpose:
    the default paths are what the locator has to find."""
    environment = dict(backend.isolated_env(root, user), HC_SETTLE_MS="0")
    if session is not None:
        environment["HC_SESSION"] = session
    return environment


def start_core(root, session, extra=None):
    """Starts this session's core: the only way one starts here."""
    state = backend.load_state(root)
    return subprocess.run([str(core_executable(root)), "server", "start"],
        env=dict(start_environment(root, state.user, session), **(extra or {})), stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, check=False)


def write_tripwire(path, log, status):
    path.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {shlex.quote(str(log))}\nexit {status}\n")
    path.chmod(0o700)


def rc_files():
    """Each startup file and the program only it puts on PATH, by path under a home.

    With `--wait` the program reports what a launch gave it, then ends on a line.
    """
    posix = f'export PATH="$HOME/.rc-stub/bin:$PATH"\nexport {RC_MARKER}=rc-sourced\n'
    stub = f"""#!/bin/sh
echo rc-stub
if [ "$1" = --wait ]; then
    shift
    printf 'marker=%s\\npid=%s\\n' "${RC_MARKER}" "$$"
    for argument in "$@"; do printf 'arg=%s\\n' "$argument"; done
    read -r line
fi
"""
    return {
        ".rc-stub/bin/heeler-rc-stub": stub,
        ".bashrc": posix,
        ".zshrc": posix,
        ".config/fish/config.fish": f'set -gx PATH "$HOME/.rc-stub/bin" $PATH\nset -gx {RC_MARKER} rc-sourced\n',
    }


def write_rc_files(root):
    home = root / "home"
    for relative, text in rc_files().items():
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (home / ".rc-stub/bin/heeler-rc-stub").chmod(0o700)


def owned_core_processes(root):
    """A successful CLI stop is not proof: a core with a lost socket says stopped:false.

    Core and holder execute our private binary, so they remain identifiable after
    reparenting. Fail closed if process enumeration fails. Never signal a process
    found this way; retain the fixture and report its PID for an explicit recovery.
    """
    result = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                            text=True, timeout=10, check=True)
    executable = str(core_executable(root))
    found = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and (fields[1] == executable or fields[1].startswith(executable + " ")):
            found.append(int(fields[0]))
    return found


def stop_fixture(root):
    state = backend.load_state(root)  # Refuse arbitrary directories.
    core_failed = False
    for session in sorted(state_root(root).glob("*")):
        if not session.is_dir():
            continue
        try:
            # `server stop` is the one subcommand that cannot start a core.
            stopped = subprocess.run([str(core_executable(root)), "server", "stop"],
                env=start_environment(root, state.user, session.name), capture_output=True,
                timeout=20, check=False)
            if stopped.returncode != 0:
                raise RuntimeError(f"exit status {stopped.returncode}")
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
            core_failed = True
            print(f"Could not stop core session {session.name!r}: {error}", file=sys.stderr)
    # Stop owned SSH processes even after a core stop failure, but do not let the
    # shared helper delete the independent core binary/state needed for retry.
    status = backend.command_stop(argparse.Namespace(root=root, keep=True))
    try:
        deadline = time.monotonic() + 5
        remaining = owned_core_processes(root)
        while remaining and time.monotonic() < deadline:
            time.sleep(0.1)
            remaining = owned_core_processes(root)
        if remaining:
            core_failed = True
            print(f"Core/holder PIDs still own {root}: {remaining}; preserving fixture", file=sys.stderr)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        core_failed = True
        print(f"Cannot verify core process shutdown: {error}; preserving {root}", file=sys.stderr)
    if status or core_failed:
        return status or 1
    # Both process owners have been independently checked, and no SSH client can
    # start a replacement core now. Only this helper-created root is removed.
    shutil.rmtree(root)
    print(f"Stopped; removed {root}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["start", "stop", "start-core"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--core", default=shutil.which("herdr-core"))
    parser.add_argument("--port", type=int)
    parser.add_argument("--session", help="start-core: the session to start")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "stop":
        return stop_fixture(root)
    if args.command == "start-core":
        if not args.session:
            parser.error("start-core needs --session")
        started = start_core(root, args.session)
        sys.stderr.write(started.stderr.decode(errors="replace"))
        return started.returncode
    if not args.core or not Path(args.core).is_file():
        parser.error("install herdr-core or pass --core; this fixture never installs or updates it")
    longest = longest_socket_path(root)
    if longest > SOCKET_PATH_LIMIT or any(c.isspace() for c in str(root)):
        parser.error(f"choose a short scratch path without spaces (the longest socket would be "
                     f"{longest} bytes of {SOCKET_PATH_LIMIT})")
    if state_root(root).exists():
        parser.error("core state already exists; run stop successfully before reusing this root")
    core_source = Path(args.core).resolve()
    if root == core_source or root in core_source.parents:
        parser.error("the input core executable must be outside the new fixture root")
    backend.prepare_root(root)
    state = backend.State(root=str(root), user=backend.current_user(), herdr="", sessions=[], started_at=time.time())
    bin_dir = root / "home/.local/bin"
    bin_dir.mkdir(parents=True)
    # Retain the exact executable with its state if cleanup fails; it must not
    # depend on an outer runner's disposable download directory. Detached serve
    # and holder processes also carry this owned path in argv for shutdown checks.
    core_binary = core_executable(root)
    shutil.copyfile(core_source, core_binary)
    core_binary.chmod(0o700)
    # Keep the same Python selected by the caller/CI, not Apple's shim or a
    # different interpreter found through sshd's minimal PATH.
    (root / "bin/python3").symlink_to(sys.executable)
    rpc_helper = root / "bin/herdr-core-rpc"
    shutil.copyfile(HERE / "herdr-core-rpc.py", rpc_helper)
    rpc_helper.chmod(0o700)
    # On the exec's PATH and at the installer's path: anything that reaches for
    # either program leaves a line behind.
    for directory in (bin_dir, root / "bin"):
        write_tripwire(directory / "hc", tripwire_log(root), 97)
        write_tripwire(directory / "herdr", legacy_log(root), 91)
    write_rc_files(root)
    port = backend.choose_port(args.port, backend.SSH_PORT_RANGE, "SSH")
    backend.start_sshd(state, port, [], use_pam=False, log_level="DEBUG1")
    config = {"coreFixture": True, "host": "127.0.0.1", "port": port,
              "username": state.user, "homePath": str(root / "home"),
              "coreExecutable": str(core_binary),
              "startEnvironment": start_environment(root, state.user),
              "rpcHelper": str(rpc_helper),
              "tripwireLog": str(tripwire_log(root)), "legacyLog": str(legacy_log(root)),
              "deviceKeySeed": base64.b64encode(keys.seed(str(root / "ssh/client_ed25519"))).decode()}
    path = root / "core-test-config"
    path.write_text(base64.b64encode(json.dumps(config).encode()).decode() + "\n")
    path.chmod(0o600)
    print(f"Fixture ready on 127.0.0.1:{port}; configuration: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
