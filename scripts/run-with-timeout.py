#!/usr/bin/env python3
"""Run one command with a hard deadline and preserve useful failure diagnostics."""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Sequence


TIMEOUT_EXIT_STATUS = 124


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=float, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--diagnostics-dir", type=Path, required=True)
    parser.add_argument("--artifact-path", type=Path, action="append", default=[])
    parser.add_argument("--artifact-glob", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if not arguments.command:
        parser.error("a command is required after --")
    return arguments


def process_snapshot() -> str:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,state=,etime=,command="],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout


def descendant_processes(root_pid: int) -> list[tuple[int, str]]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,comm="],
        check=False,
        capture_output=True,
        text=True,
    )
    children: dict[int, list[tuple[int, str]]] = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) != 3:
            continue
        try:
            pid = int(fields[0])
            parent_pid = int(fields[1])
        except ValueError:
            continue
        children.setdefault(parent_pid, []).append((pid, fields[2]))

    descendants: list[tuple[int, str]] = []
    pending = [root_pid]
    seen = {root_pid}
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            if child[0] in seen:
                continue
            seen.add(child[0])
            descendants.append(child)
            pending.append(child[0])
    return descendants


def safe_filename(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return normalized or "process"


def simulator_side_processes(patterns: Sequence[str]) -> list[tuple[int, str]]:
    """Test processes live under CoreSimulator, not under xcodebuild.

    A wedged Simulator test therefore hangs in a process the descendant walk
    never reaches; find those by name instead.
    """
    result = subprocess.run(
        ["ps", "-axo", "pid=,comm="],
        check=False,
        capture_output=True,
        text=True,
    )
    matches: list[tuple[int, str]] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        if any(pattern in fields[1] for pattern in patterns):
            matches.append((pid, fields[1]))
    return matches


def sample_processes(root_pid: int, diagnostics_dir: Path) -> None:
    if os.environ.get("HEELER_TIMEOUT_DISABLE_SAMPLE") == "1":
        return
    sample = shutil.which("sample")
    if sample is None:
        return

    targets = [(root_pid, "command")] + descendant_processes(root_pid)
    seen_pids = {pid for pid, _ in targets}
    for pid, command in simulator_side_processes(
        ("xctest", "testmanagerd", "CoreSimulator/Devices")
    ):
        if pid not in seen_pids:
            targets.append((pid, command))
    for pid, command in targets[:12]:
        output = diagnostics_dir / f"sample-{pid}-{safe_filename(Path(command).name)}.txt"
        try:
            subprocess.run(
                [sample, str(pid), "1", "1", "-file", str(output)],
                check=False,
                timeout=4,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue


def copy_path(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination, dirs_exist_ok=True)
    else:
        shutil.copy2(source, destination)


def capture_artifacts(
    diagnostics_dir: Path,
    artifact_paths: Sequence[Path],
    artifact_globs: Sequence[str],
) -> None:
    artifacts_dir = diagnostics_dir / "artifacts"
    sources = list(artifact_paths)
    for pattern in artifact_globs:
        sources.extend(Path(path) for path in glob.glob(pattern))
    for index, source in enumerate(sources, start=1):
        try:
            copy_path(source, artifacts_dir / f"{index:02d}-{source.name}")
        except OSError as error:
            print(f"could not preserve {source}: {error}", file=sys.stderr)


def record_exit_status(diagnostics_dir: Path, status: int) -> None:
    diagnostics_dir.mkdir(parents=True, exist_ok=True)
    (diagnostics_dir / "status.txt").write_text(f"{status}\n", encoding="utf-8")


def preserve_nonzero_exit(
    arguments: argparse.Namespace,
    status: int,
) -> None:
    """Copy requested artifacts for any nonzero child exit. Timeout-only
    process snapshots stay on the timeout path.
    """
    try:
        record_exit_status(arguments.diagnostics_dir, status)
    except OSError as error:
        print(f"could not record exit status: {error}", file=sys.stderr)
    capture_artifacts(
        arguments.diagnostics_dir,
        arguments.artifact_path,
        arguments.artifact_glob,
    )
    print(
        f"{arguments.label} exited {status}; diagnostics: {arguments.diagnostics_dir}",
        file=sys.stderr,
    )


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # A failed permission probe does not establish whether members can
        # still execute. Ignore only an empty group or one containing zombies;
        # keep a live member visible rather than hiding a signaling error.
        listing = subprocess.run(
            ["ps", "-axo", "pgid=,state="], check=True,
            capture_output=True, text=True,
        )
        return any(
            fields[0] == str(process_group_id) and not fields[1].startswith("Z")
            for line in listing.stdout.splitlines()
            if len(fields := line.split()) >= 2
        )
    return True


def terminate_process_group(
    process: subprocess.Popen[bytes], process_group_id: int
) -> None:
    # The leader may already have exited while a descendant ignores TERM.
    # Keep the session's original PGID and check the whole group, not poll().
    try:
        os.killpg(process_group_id, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    except PermissionError:
        if process_group_exists(process_group_id):
            raise
        process.wait()
        return
    deadline = time.monotonic() + 5
    while True:
        process.poll()  # Reap an exited leader while waiting for descendants.
        if not process_group_exists(process_group_id):
            process.wait()
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.05, remaining))
    try:
        os.killpg(process_group_id, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        if process_group_exists(process_group_id):
            raise
    process.wait()


class CommandCancelled(Exception):
    """Interrupt a command wait immediately after watchdog cancellation."""


def shell_exit_status(return_code: int) -> int:
    if return_code < 0:
        return 128 - return_code
    return return_code


def run(arguments: argparse.Namespace) -> int:
    process: subprocess.Popen[bytes] | None = None
    process_group_id: int | None = None
    cancellation_signal = 0
    terminating = False
    previous_handlers = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }

    def cancel_command(signum: int, _frame: object) -> None:
        nonlocal cancellation_signal, terminating
        if not cancellation_signal:
            cancellation_signal = signum
        # Do not interrupt Popen before it publishes the child, or the bounded
        # termination/reaping sequence itself on a repeated cancellation.
        if process is not None and not terminating:
            terminating = True
            raise CommandCancelled()

    for signum in previous_handlers:
        signal.signal(signum, cancel_command)
    try:
        process = subprocess.Popen(arguments.command, start_new_session=True)
        process_group_id = process.pid
        if cancellation_signal:
            terminating = True
            raise CommandCancelled()
        try:
            status = shell_exit_status(process.wait(timeout=arguments.timeout_seconds))
        except subprocess.TimeoutExpired:
            arguments.diagnostics_dir.mkdir(parents=True, exist_ok=True)
            try:
                record_exit_status(arguments.diagnostics_dir, TIMEOUT_EXIT_STATUS)
                (arguments.diagnostics_dir / "timeout.txt").write_text(
                    f"{arguments.label} exceeded {arguments.timeout_seconds:g} seconds\n",
                    encoding="utf-8",
                )
                (arguments.diagnostics_dir / "processes.txt").write_text(
                    process_snapshot(), encoding="utf-8"
                )
                sample_processes(process.pid, arguments.diagnostics_dir)
            except OSError as error:
                print(f"could not capture process diagnostics: {error}", file=sys.stderr)
            finally:
                terminating = True
                try:
                    terminate_process_group(process, process_group_id)
                finally:
                    terminating = False
            if cancellation_signal:
                terminating = True
                raise CommandCancelled()
            capture_artifacts(
                arguments.diagnostics_dir,
                arguments.artifact_path,
                arguments.artifact_glob,
            )
            print(
                f"{arguments.label} exceeded {arguments.timeout_seconds:g} seconds; "
                f"diagnostics: {arguments.diagnostics_dir}",
                file=sys.stderr,
            )
            return TIMEOUT_EXIT_STATUS
        if status != 0:
            preserve_nonzero_exit(arguments, status)
        return status
    except CommandCancelled:
        terminating = True
        if process is not None:
            # Popen starts a new session, so its PID is the owned PGID even if
            # cancellation interrupts publication of process_group_id.
            terminate_process_group(process, process_group_id or process.pid)
        status = 128 + cancellation_signal
        preserve_nonzero_exit(arguments, status)
        return status
    except KeyboardInterrupt:
        terminating = True
        if process is not None:
            terminate_process_group(process, process_group_id or process.pid)
        return 130
    finally:
        for signum, previous_handler in previous_handlers.items():
            signal.signal(signum, previous_handler)


def main() -> int:
    return run(parse_arguments())


if __name__ == "__main__":
    raise SystemExit(main())
