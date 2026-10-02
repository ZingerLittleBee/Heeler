#!/usr/bin/env python3
"""Own a CI build watchdog while the calling shell prepares its test fixture."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class BuildTiming:
    started_unix_seconds: float
    elapsed_seconds: float
    exit_status: int


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timing-path", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a build watchdog command is required")
    started_wall = time.time()
    started = time.monotonic()
    child = None
    interrupted = 0

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = signum
        if child is not None:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)
    child = subprocess.Popen(command)
    # A signal can arrive between installing the handler and publishing child.
    if interrupted:
        try:
            child.send_signal(interrupted)
        except ProcessLookupError:
            pass
    status = child.wait()
    status = 128 + interrupted if interrupted else (-status + 128 if status < 0 else status)
    args.timing_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.timing_path.with_name(args.timing_path.name + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(asdict(BuildTiming(started_wall, time.monotonic() - started, status))) + "\n")
    temporary.replace(args.timing_path)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
