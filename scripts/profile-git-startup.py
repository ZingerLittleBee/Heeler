#!/usr/bin/env python3
"""Compare Git launchers with fresh HOME directories, without building an app."""

from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
from dataclasses import asdict, dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shlex
import signal
import socket
import statistics
import subprocess
import tempfile
import time


# The same seed operations and hostile names as ChangesFieldCheckout. Each
# arm receives identical script bytes; only FIELD_GIT and its scratch HOME vary.
NAMES = [
    "--", "-dash.txt", "sp ace.txt", 'quo"te.txt', "sq'uote.txt",
    r"two\\bs.txt", "trail\\", "bang!.txt", "$HOME.txt", "*.txt",
    "[ab].txt", "ünï.txt", "中文.txt", "line\nbreak.txt", "tab\tname.txt",
]
SEED = r"""{
set -ex
git() { "$FIELD_GIT" "$@"; }
r="$HOME/$FIELD_PHASE"
mkdir -p "$r/repo/sub" "$r/repo/newdir/deep"
cd "$r/repo"
git init -q .
git symbolic-ref HEAD refs/heads/main
printf 'one\ntwo\nthree\n' > tracked.txt
printf 'rename me\nline 2\nline 3\nline 4\nline 5\n' > old-name.txt
printf '\000\001\002binary\000' > image.bin
printf 'nested\n' > sub/nested.txt
@WRITES@
git add -A
git -c user.name=Heeler -c user.email=fixture@heeler.invalid commit -q -m 'Seed the field Checkout'
printf 'one\nTWO\nthree\nfour\n' > tracked.txt
git mv old-name.txt new-name.txt
printf '\000\003\004binary\000' > image.bin
@EDITS@
printf 'new\nfile\n' > untracked.txt
printf 'a\n' > newdir/a.txt
printf 'b\n' > newdir/deep/b.txt
printf 's\n' > 'newdir/sp ace.txt'
touch -t 203001010000 sub/nested.txt
printf '#!/bin/sh\n: > "%s/fsmonitor-ran"\n' "$r" > "$r/fsmonitor.sh"
mkdir -p .git/hooks
printf '#!/bin/sh\n: > "%s/post-index-change-ran"\n' "$r" > .git/hooks/post-index-change
chmod +x "$r/fsmonitor.sh" .git/hooks/post-index-change
git config core.fsmonitor "$r/fsmonitor.sh"
: > "$r/index-stamp"
printf '__FIELD_TOP__=%s\n' "$(pwd -P)"
printf '__FIELD_INDEX__=%s %s\n' "$(ls -di .git/index | awk '{print $1}')" "$(cksum < .git/index)"
} </dev/null
""".replace("@WRITES@", "\n".join(
    "printf 'hostile\\n' > " + shlex.quote(name) for name in NAMES
)).replace("@EDITS@", "\n".join(
    "printf 'edited\\n' >> " + shlex.quote(name) for name in NAMES
))


@dataclass
class Sample:
    pair: int
    order: int
    path: str
    phase: str
    elapsed_seconds: float
    before_git_init_seconds: float | None
    git_init_seconds: float | None
    xcodebuild_observed: bool
    exit_status: int
    error: str | None
    ssh_connect_seconds: float | None
    exec_shell_seconds: float | None
    shell_to_git_init_seconds: float | None


@dataclass
class SSHExec:
    command: list[str]
    server_pid: int
    connect_seconds: float


def process_tree(roots: set[int]) -> list[list[str]]:
    snapshot = subprocess.check_output(
        ["ps", "-axo", "pid,ppid,pgid,stat,etime,comm"], text=True, timeout=5)
    rows = [line.split(maxsplit=5) for line in snapshot.splitlines()]
    rows = [row for row in rows if len(row) == 6 and row[0].isdigit()]
    owned = set(roots)
    while True:
        children = {int(row[0]) for row in rows if int(row[1]) in owned}
        if children <= owned:
            return [row for row in rows if int(row[0]) in owned]
        owned.update(children)


@contextmanager
def ssh_exec(home: Path, git: Path, evidence: Path):
    """Own one key-only loopback sshd and an authenticated, non-PTY connection."""
    evidence.mkdir()
    private = home / "ssh-private"
    private.mkdir(mode=0o700)
    for name in ["host", "client"]:
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(private / name)], check=True)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    username = pwd.getpwuid(os.getuid()).pw_name
    known_hosts = private / "known_hosts"
    known_hosts.write_text(f"[127.0.0.1]:{port} " + (private / "host.pub").read_text())
    config = private / "sshd.conf"
    config.write_text("\n".join([
        f"Port {port}", "ListenAddress 127.0.0.1", f"HostKey {private / 'host'}",
        f"PidFile {private / 'sshd.pid'}", f"AuthorizedKeysFile {private / 'client.pub'}",
        "PasswordAuthentication no", "KbdInteractiveAuthentication no", "PubkeyAuthentication yes",
        "UsePAM no", "PermitRootLogin no", f"AllowUsers {username}", "StrictModes no",
        "PrintMotd no", "PrintLastLog no", "LogLevel DEBUG1", "KexAlgorithms curve25519-sha256",
        f"SetEnv HOME={home} FIELD_GIT={git} LC_ALL=C",
        "ForceCommand exec /bin/sh -c 'PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH;"
        ' exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"' + "'",
    ]) + "\n")
    command = [
        "/usr/bin/ssh", "-F", "/dev/null", "-T", "-p", str(port),
        "-i", str(private / "client"), "-S", str(private / "control"),
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "GlobalKnownHostsFile=/dev/null", f"{username}@127.0.0.1",
    ]
    server = master = None
    with (evidence / "sshd.log").open("w") as server_log, \
            (evidence / "client.log").open("w") as client_log:
        try:
            subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(config)], check=True)
            server = subprocess.Popen(
                ["/usr/sbin/sshd", "-D", "-e", "-f", str(config)],
                stdout=server_log, stderr=server_log, start_new_session=True)
            deadline = time.monotonic() + 10
            # Do not probe with unauthenticated TCP connections: newer sshd
            # versions penalize them, which would change the measured startup.
            while "Server listening on" not in (evidence / "sshd.log").read_text():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("disposable sshd did not start; see sshd.log")
                time.sleep(0.02)
            started = time.monotonic()
            master = subprocess.Popen(command[:-1] + ["-M", "-N", command[-1]],
                                      stdout=client_log, stderr=client_log, start_new_session=True)
            deadline = started + 15
            while subprocess.run(command[:-1] + ["-O", "check", command[-1]],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                if master.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("SSH authentication did not complete; see client.log")
                time.sleep(0.02)
            # A dead master must fail, not silently open a new TCP connection
            # whose authentication would be charged to the exec measurement.
            yield SSHExec(command[:-1] + ["-o", "ProxyCommand=false", command[-1]],
                          server.pid, time.monotonic() - started)
        finally:
            # Only descendants of this owned daemon can be remote execs. Stop
            # them before the daemon and remove all private material with HOME.
            try:
                if server is not None and server.poll() is None:
                    for row in reversed(process_tree({server.pid})):
                        if int(row[0]) != server.pid:
                            try:
                                os.kill(int(row[0]), signal.SIGKILL)
                            except ProcessLookupError:
                                pass
            finally:
                for process in [master, server]:
                    if process is not None and process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()


def measure(pair: int, order: int, label: str, phase: str, git: Path,
            developer_git: Path, home: Path, output: Path, ssh: SSHExec | None = None) -> Sample:
    directory = output / f"{pair:02d}-{order}-{label}-{phase}"
    directory.mkdir()
    trace = directory / "git.jsonl"
    shell_ready = directory / "shell-ready"
    # Match the forced POSIX fixture's system PATH and isolated HOME. Do not
    # inherit DEVELOPER_DIR, XCRUN_*, Git overrides, credentials or other CI env.
    environment = {
        "HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": os.environ.get("USER", "runner"), "SHELL": "/bin/sh",
        "FIELD_GIT": str(git), "FIELD_PHASE": phase,
        "GIT_TRACE2_EVENT": str(trace), "LC_ALL": "C",
    }
    command = ["/bin/sh"]
    if ssh is not None:
        # HOME and FIELD_GIT were set by sshd before the account's shell starts.
        # Send the same seed on stdin; only per-exec output/checkout names vary.
        # A shell builtin timestamps readiness without launching a clock tool.
        command = ssh.command + [
            f": > {shlex.quote(str(shell_ready))}; "
            f"FIELD_PHASE={shlex.quote(phase)} GIT_TRACE2_EVENT={shlex.quote(str(trace))} exec /bin/sh -s"
        ]
    seen_xcodebuild = False
    error = None
    with (output / "seed.sh").open("rb") as stdin, \
            (directory / "stdout.log").open("wb") as stdout, \
            (directory / "stderr.log").open("wb") as stderr, \
            (directory / "processes.log").open("w") as processes:
        started_wall = time.time()
        started = time.monotonic()
        process = subprocess.Popen(
            command, stdin=stdin, stdout=stdout, stderr=stderr,
            env=environment, cwd=home, start_new_session=True)
        try:
            while process.poll() is None:
                # SSH's remote exec has a different process group. Follow the
                # owned daemon's descendants, not just the local client.
                roots = {process.pid}
                if ssh is not None:
                    roots.add(ssh.server_pid)
                processes.write(f"elapsed={time.monotonic() - started:.6f}\n")
                for columns in process_tree(roots):
                    processes.write(" ".join(columns) + "\n")
                    seen_xcodebuild |= Path(columns[5]).name == "xcodebuild"
                if time.monotonic() - started > 30:
                    error = "probe exceeded the 30-second measurement safety bound"
                    break
                try:
                    process.wait(timeout=0.05)
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            exit_status = process.wait()
        elapsed = time.monotonic() - started

    before_init = init_seconds = exec_shell_seconds = shell_to_init = None
    try:
        if ssh is not None and shell_ready.exists():
            exec_shell_seconds = shell_ready.stat().st_mtime_ns / 1e9 - started_wall
        if error or exit_status != 0:
            raise ValueError(error or f"seed exited with status {exit_status}")
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        init = next(event for event in events
                    if event["event"] == "start" and event["argv"][1:] == ["init", "-q", "."])
        if Path(init["argv"][0]).resolve() != developer_git.resolve():
            raise ValueError("the launchers selected different Git binaries")
        exited = next(event for event in events
                      if event["event"] == "exit" and event["sid"] == init["sid"])
        before_init = datetime.fromisoformat(init["time"].replace("Z", "+00:00")).timestamp() - started_wall
        init_seconds = exited["t_abs"]
        if ssh is not None:
            if exec_shell_seconds is None:
                raise ValueError("missing remote exec shell readiness marker")
            shell_to_init = before_init - exec_shell_seconds
        checkout = home / phase / "repo"
        actual = (directory / "stdout.log").read_text().splitlines()
        if len(actual) != 2 or actual[0] != f"__FIELD_TOP__={checkout.resolve()}" \
                or not actual[1].startswith("__FIELD_INDEX__="):
            raise ValueError("missing or incorrect seed completion markers")
        if (checkout / ".git/HEAD").read_text() != "ref: refs/heads/main\n" \
                or not (checkout / ".git/refs/heads/main").is_file():
            raise ValueError("seed did not create its main commit")
        if any((checkout / name).read_text() != "hostile\nedited\n" for name in NAMES):
            raise ValueError("hostile filenames or edited contents changed")
    except (OSError, ValueError, KeyError, StopIteration) as failure:
        error = str(failure) or type(failure).__name__
    return Sample(pair, order, label, phase, elapsed, before_init,
                  init_seconds, seen_xcodebuild, exit_status, error,
                  ssh.connect_seconds if ssh else None, exec_shell_seconds, shell_to_init)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--transport", choices=["local", "ssh"], default="local")
    parser.add_argument("--first-path", choices=["system", "developer"], default="system")
    parser.add_argument("--system-git", type=Path, default=Path("/usr/bin/git"))
    parser.add_argument("--developer-git", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100:
        parser.error("iterations must be between 1 and 100")
    developer_git = args.developer_git or Path(subprocess.check_output(
        ["/usr/bin/xcrun", "--find", "git"], text=True).strip())
    paths = {"system": args.system_git.absolute(), "developer": developer_git.absolute()}
    if any(not os.access(path, os.X_OK) for path in paths.values()):
        parser.error("both Git paths must be executable")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "seed.sh").write_text(SEED)
    metadata = {
        "sha": os.environ.get("GITHUB_SHA"), "platform": platform.platform(),
        "image_version": os.environ.get("ImageVersion"), "first_path": args.first_path,
        "paths": {key: str(value) for key, value in paths.items()},
        "binary_sha256": {key: hashlib.sha256(value.read_bytes()).hexdigest() for key, value in paths.items()},
        "seed_sha256": hashlib.sha256(SEED.encode()).hexdigest(),
        "poll_interval_seconds": 0.05,
        "transport": args.transport,
        "definition": "fresh HOME, then same-HOME repeat; OS caches are not reset; no App",
        "ssh_client": "OpenSSH ControlMaster, no PTY; not the app's libssh2 client" if args.transport == "ssh" else None,
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    samples: list[Sample] = []
    order = [args.first_path, "developer" if args.first_path == "system" else "system"]
    for pair in range(1, args.iterations + 1):
        for position, label in enumerate(order, 1):
            # A short path also fits OpenSSH's Unix-domain ControlPath limit.
            with tempfile.TemporaryDirectory(prefix="heeler-git-", dir="/tmp") as temporary:
                home = Path(temporary)
                connection = ssh_exec(home, paths[label], output / f"ssh-{pair:02d}-{position}-{label}") \
                    if args.transport == "ssh" else nullcontext()
                with connection as ssh:
                    for phase in ["fresh", "repeat"]:
                        sample = measure(pair, position, label, phase, paths[label],
                                         paths["developer"], home, output, ssh)
                        samples.append(sample)
                        print(json.dumps(asdict(sample)), flush=True)
                        (output / "samples.json").write_text(json.dumps(
                            [asdict(value) for value in samples], indent=2) + "\n")
        order.reverse()
    print("\npath phase n median_seconds max_seconds over_10_seconds failures")
    for label in paths:
        for phase in ["fresh", "repeat"]:
            group = [sample for sample in samples if sample.path == label and sample.phase == phase]
            durations = [sample.elapsed_seconds for sample in group]
            print(label, phase, len(group), round(statistics.median(durations), 4),
                  round(max(durations), 4), sum(value > 10 for value in durations),
                  sum(sample.error is not None for sample in group))
    return int(any(sample.error is not None for sample in samples))


if __name__ == "__main__":
    raise SystemExit(main())
