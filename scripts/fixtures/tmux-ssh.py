#!/usr/bin/env python3
"""Disposable real-tmux SSH fixture for the tmux Host E2E suites.

Reuse the existing isolated backend's sshd, key generation and cleanup:
  python3 scripts/fixtures/tmux-ssh.py start --root /tmp/ht-heeler --tmux <path>
Pass HEELER_SSH_E2E_CONFIG to the chosen Simulator launchctl environment (the
scheme does not forward shell exports). Read <root>/tmux-test-config privately
and pass its stripped contents as the final argument to this subprocess argv:
  ["xcrun", "simctl", "spawn", "<UDID>", "launchctl", "setenv", "HEELER_SSH_E2E_CONFIG", config]
Then run make test-app. Afterwards clear it with:
  xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
Stop the fixture by invoking this script with stop and the same root.
No tmux server of yours, installed tmux, or user configuration is changed.

The fixture account has its own home and its own tmux directories, both under
the root, so the socket name `default` can never be yours:

  <root>/t   TMUX_TMPDIR in the login shell's startup files, for bash, zsh, fish
             and sh alike. Every server lives in <root>/t/tmux-<uid>.
  <root>/x   TMUX_TMPDIR of the exec itself, so a login shell that gave up still
             names a directory in here. No server is ever started in it.

tmux is only at ~/.tmux-fixture/bin, which those same startup files put on
PATH: the exec's own PATH has no tmux, so finding it proves the login shell was
asked. ~/.tmux-fixture/first comes before it on PATH and is empty; a test drops
a stand-in there (one that prints `tmux 3.2a`, say) and removes it again.

The app never starts a server, so neither does anything here: a test starts
one over SSH with `-S` and a path in <root>/t/tmux-<uid>, and ends it by that
same path. `start` asks the account's login shell through the fixture's own
sshd where `default` resolves, and refuses to run unless that is inside the
root. `stop` ends only the servers on sockets in the two directories above,
each by its `-S` path, and removes the root.
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

# The longest socket name Heeler takes (TmuxSocketName.maximumUTF8Length).
SOCKET_NAME_LENGTH = 64
# macOS's sun_path limit, the lower of the two platforms' (107 on Linux).
SOCKET_PATH_LIMIT = 103
CHECK_MARKER = "heeler-tmux-fixture-check"
FIXTURE_MARKER = ".heeler-tmux-fixture"


def tmux_directory(root):
    """Where tmux is, off the exec's PATH."""
    return root / "home/.tmux-fixture/bin"


def tmux_executable(root):
    return tmux_directory(root) / "tmux"


def first_directory(root):
    """Before `tmux_directory` on the login shell's PATH: a test's stand-in goes here."""
    return root / "home/.tmux-fixture/first"


def login_tmpdir(root):
    return root / "t"


def exec_tmpdir(root):
    return root / "x"


def socket_directory(tmpdir, uid=None):
    """Where tmux puts a named socket under a TMUX_TMPDIR."""
    return Path(tmpdir) / f"tmux-{os.getuid() if uid is None else uid}"


def user_socket_directories(uid=None):
    """The directories a tmux of the user's own listens in. Never touched."""
    uid = os.getuid() if uid is None else uid
    return {Path(f"/tmp/tmux-{uid}"), Path(f"/private/tmp/tmux-{uid}"), Path(f"/tmp/tmux-{uid}").resolve()}


def longest_socket_path(root, uid=None):
    return len(str(socket_directory(login_tmpdir(root), uid))) + len("/") + SOCKET_NAME_LENGTH


def is_inside(path, directory):
    path, directory = Path(path), Path(directory)
    return path == directory or directory in path.parents


def socket_directory_refusal(directory, root, uid=None):
    """Why a resolved socket directory cannot be used, None when it can.

    It has to be the fixture's own: inside the root, and nowhere a tmux of the
    user's could be listening.
    """
    if not directory or not os.path.isabs(directory):
        return f"the socket directory resolved to {directory!r}, not an absolute path"
    resolved = Path(os.path.realpath(directory))
    if any(is_inside(candidate, user) for candidate in (Path(directory), resolved)
           for user in user_socket_directories(uid)):
        return f"the socket directory {directory} is the user's own tmux directory"
    if not is_inside(resolved, Path(os.path.realpath(root))):
        return f"the socket directory {directory} is outside the fixture root {root}"
    return None


def login_path(root):
    """The login shell's whole PATH: the system's, and tmux before it."""
    return [str(first_directory(root)), str(tmux_directory(root)), str(root / "bin"), *backend.SYSTEM_PATH]


def login_files(root):
    """Each startup file an interactive login shell reads, by path under the home.

    They set the PATH outright instead of adding to it, so a tmux the machine
    has elsewhere (Homebrew's, through /etc/paths.d) is never the one found.
    """
    path = login_path(root)
    posix = (f"PATH={shlex.quote(':'.join(path))}; export PATH\n"
             f"TMUX_TMPDIR={shlex.quote(str(login_tmpdir(root)))}; export TMUX_TMPDIR\n")
    fish = (f"set -gx PATH {' '.join(shlex.quote(part) for part in path)}\n"
            f"set -gx TMUX_TMPDIR {shlex.quote(str(login_tmpdir(root)))}\n")
    return {
        ".profile": posix,
        ".bash_profile": posix,
        ".zshrc": posix,
        ".config/fish/config.fish": fish,
    }


def write_login_files(root):
    home = root / "home"
    for relative, text in login_files(root).items():
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def force_command_script(root):
    """The isolated backend's ForceCommand, with a tmux directory of the exec's own.

    A probe whose login shell gave up reads the exec's environment. It must
    still name a directory in the root, never /tmp/tmux-<uid>.
    """
    return "\n".join([
        "#!/bin/sh",
        "# ForceCommand for the tmux fixture's sshd: only the fixture's tmux is reachable.",
        "unset TMUX TMUX_PANE",
        "unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR",
        f"HOME={shlex.quote(str(root / 'home'))}; export HOME",
        f"PATH={shlex.quote(backend.isolated_path(root))}; export PATH",
        f"TMUX_TMPDIR={shlex.quote(str(exec_tmpdir(root)))}; export TMUX_TMPDIR",
        'if [ -n "$SSH_ORIGINAL_COMMAND" ]; then exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"; fi',
        "exec /bin/sh",
        "",
    ])


def check_script(through_login_shell):
    """What a session resolves, read the way the app's probe reads it."""
    body = (f"printf '\\n{CHECK_MARKER} tmpdir %s\\n' \"$TMUX_TMPDIR\"; "
            f"printf '{CHECK_MARKER} tmux %s\\n' \"$(command -v tmux 2>/dev/null)\"; "
            f"printf '{CHECK_MARKER} home %s\\n' \"$HOME\"")
    if not through_login_shell:
        return body
    return (f"__heeler_fixture_check={shlex.quote(body)}; export __heeler_fixture_check; "
            "\"${SHELL:-/bin/sh}\" -lic 'exec /bin/sh -c \"$__heeler_fixture_check\"' </dev/null 2>/dev/null")


def parse_check(output):
    found = {}
    for line in output.splitlines():
        fields = line.split(" ", 2)
        if len(fields) >= 2 and fields[0] == CHECK_MARKER:
            found[fields[1]] = fields[2] if len(fields) == 3 else ""
    return found


def session_facts(root, state, through_login_shell):
    """Runs the check through the fixture's own sshd, as an app's exec arrives."""
    ssh = root / "ssh"
    result = subprocess.run(
        ["ssh", "-F", "/dev/null", "-i", str(ssh / "client_ed25519"), "-p", str(state.ssh_port),
         "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
         "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={ssh / 'known_hosts'}",
         "-o", "ConnectTimeout=20", f"{state.user}@127.0.0.1", check_script(through_login_shell)],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90, check=False)
    facts = parse_check(result.stdout)
    if result.returncode != 0 or set(facts) != {"tmpdir", "tmux", "home"}:
        raise backend.BackendError(
            f"could not read what a session resolves (exit {result.returncode}): {result.stderr.strip()}")
    return facts


def resolution_refusal(root, login, bare, uid=None):
    """Why this fixture cannot run with what its sessions resolve, None when it can."""
    if login["home"] != str(root / "home") or bare["home"] != str(root / "home"):
        return f"a session's home is {login['home']!r}, not the fixture's"
    for label, facts, expected in (("login shell", login, login_tmpdir(root)), ("exec", bare, exec_tmpdir(root))):
        refusal = socket_directory_refusal(str(socket_directory(facts["tmpdir"], uid)) if facts["tmpdir"] else "",
                                           root, uid)
        if refusal:
            return f"through the {label}, {refusal}"
        if Path(os.path.realpath(facts["tmpdir"])) != Path(os.path.realpath(expected)):
            return f"the {label} names TMUX_TMPDIR {facts['tmpdir']!r}, not {expected}"
    if login["tmux"] != str(tmux_executable(root)):
        return f"the login shell finds tmux at {login['tmux']!r}, not {tmux_executable(root)}"
    if bare["tmux"]:
        return f"the exec's own PATH has a tmux ({bare['tmux']}), so no login shell is needed to find one"
    return None


def fixture_sockets(root):
    """Every socket file in the fixture's two tmux directories."""
    found = []
    for tmpdir in (login_tmpdir(root), exec_tmpdir(root)):
        directory = socket_directory(tmpdir)
        if socket_directory_refusal(str(directory), root):
            continue
        if directory.is_dir():
            found += sorted(path for path in directory.iterdir() if path.is_socket())
    return found


def kill_servers(root, state):
    """Ends the server on each fixture socket by its `-S` path. `-N` starts none.

    Returns the sockets whose server would not go. A socket nothing answers on
    is a killed server's file, and in the way of nothing.
    """
    environment = dict(backend.isolated_env(root, state.user), TMUX_TMPDIR=str(exec_tmpdir(root)))

    def ask(path, *words):
        return subprocess.run([str(tmux_executable(root)), "-N", "-S", str(path), *words], env=environment,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, check=False)

    failed = []
    for path in fixture_sockets(root):
        try:
            asked = ask(path, "display-message", "-p", "#{pid}")
            if asked.returncode != 0:
                continue
            pid = int(asked.stdout.strip()) if asked.stdout.strip().isdigit() else None
            ask(path, "kill-server")

            def gone():
                if ask(path, "display-message", "-p", "#{pid}").returncode == 0:
                    return False
                return pid is None or backend.process_command(pid) is None

            if not backend.wait_until(gone, 5):
                failed.append(path)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Could not end the tmux server on {path}: {error}", file=sys.stderr)
            failed.append(path)
    return failed


def stop_fixture(root):
    state = backend.load_state(root)  # Refuse arbitrary directories.
    if not (root / FIXTURE_MARKER).exists():
        raise backend.BackendError(f"{root} is not a tmux fixture root")
    failed = kill_servers(root, state) if tmux_executable(root).exists() else []
    # sshd goes next, so no client can start another server; then one more pass
    # for a server a client started in between.
    status = backend.command_stop(argparse.Namespace(root=root, keep=True))
    if tmux_executable(root).exists():
        failed = kill_servers(root, state)
    remaining = backend.processes_mentioning(str(root) + "/")
    if failed or remaining:
        for path in failed:
            print(f"A tmux server still answers on {path}; preserving fixture", file=sys.stderr)
        for line in remaining:
            print(f"Still references {root}: {line}", file=sys.stderr)
        return status or 1
    if status:
        return status
    shutil.rmtree(root)
    print(f"Stopped; removed {root}")
    return 0


def tmux_version(executable):
    result = subprocess.run([executable, "-V"], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                            timeout=20, check=False)
    line = result.stdout.splitlines()[0] if result.stdout else ""
    if result.returncode != 0 or not line.startswith("tmux "):
        raise backend.BackendError(f"{executable} -V did not name a tmux version")
    return line[len("tmux "):].strip()


def start_fixture(args, root):
    source = args.tmux and Path(args.tmux)
    if not source or not source.is_file() or not os.access(source, os.X_OK):
        raise backend.BackendError("install tmux or pass --tmux; this fixture never installs or updates it")
    source = source.resolve()
    if any(c.isspace() for c in str(root)) or longest_socket_path(root) > SOCKET_PATH_LIMIT:
        raise backend.BackendError(
            f"choose a short scratch path without spaces (the longest socket would be "
            f"{longest_socket_path(root)} bytes of {SOCKET_PATH_LIMIT})")
    refusal = socket_directory_refusal(str(socket_directory(login_tmpdir(root))), root)
    if refusal or any(is_inside(root, user) or is_inside(user, root) for user in user_socket_directories()):
        raise backend.BackendError(refusal or f"{root} holds or is inside the user's own tmux directory")
    if is_inside(source, root):
        raise backend.BackendError("the input tmux executable must be outside the new fixture root")
    system = shutil.which("tmux", path=":".join(backend.SYSTEM_PATH))
    if system:
        raise backend.BackendError(
            f"{system} is on every exec's PATH, so this fixture cannot keep tmux off it")
    if (root / FIXTURE_MARKER).exists():
        raise backend.BackendError("a tmux fixture is already there; run stop successfully before reusing this root")
    version = tmux_version(str(source))
    port = backend.choose_port(args.port, backend.SSH_PORT_RANGE, "SSH")

    backend.prepare_root(root)
    (root / FIXTURE_MARKER).write_text("Created by scripts/fixtures/tmux-ssh.py\n")
    state = backend.State(root=str(root), user=backend.current_user(), herdr="", sessions=[], started_at=time.time())
    backend.save_state(state)
    for directory in (tmux_directory(root), first_directory(root)):
        directory.mkdir(parents=True)
    # The servers' own directories exist before any tmux runs: a TMUX_TMPDIR
    # that does not resolve makes tmux, and the app's probe, fall back to /tmp.
    for tmpdir in (login_tmpdir(root), exec_tmpdir(root)):
        socket_directory(tmpdir).mkdir(parents=True, mode=0o700)
    # A link, not a copy: Homebrew's tmux finds its libraries from where it is.
    tmux_executable(root).symlink_to(source)
    write_login_files(root)
    try:
        backend.start_sshd(state, port, [], use_pam=False, log_level="DEBUG1")
        # sshd reads the ForceCommand's file for each session, and none has begun.
        force = root / "force-command.sh"
        replacement = root / "force-command.sh.new"
        replacement.write_text(force_command_script(root))
        replacement.chmod(0o755)
        replacement.replace(force)
        refusal = resolution_refusal(
            root, session_facts(root, state, through_login_shell=True),
            session_facts(root, state, through_login_shell=False))
        if refusal:
            raise backend.BackendError(f"refusing to run: {refusal}")
    except BaseException:
        print(f"start failed; stopping what was started (logs kept in {root}/logs; run stop to remove it)",
              file=sys.stderr)
        backend.stop_processes(state)
        raise
    config = {"tmuxFixture": True, "host": "127.0.0.1", "port": port,
              "username": state.user, "homePath": str(root / "home"),
              "tmuxExecutable": str(tmux_executable(root)), "tmuxVersion": version,
              "firstDirectory": str(first_directory(root)),
              "socketDirectory": str(socket_directory(login_tmpdir(root))),
              "execSocketDirectory": str(socket_directory(exec_tmpdir(root))),
              "deviceKeySeed": base64.b64encode(keys.seed(str(root / "ssh/client_ed25519"))).decode()}
    path = root / "tmux-test-config"
    path.write_text(base64.b64encode(json.dumps(config).encode()).decode() + "\n")
    path.chmod(0o600)
    print(f"Fixture ready on 127.0.0.1:{port}; configuration: {path}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["start", "stop"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--tmux", default=shutil.which("tmux"),
                        help="the tmux the fixture account finds (default: tmux on PATH)")
    parser.add_argument("--port", type=int)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        return stop_fixture(root) if args.command == "stop" else start_fixture(args, root)
    except backend.BackendError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
