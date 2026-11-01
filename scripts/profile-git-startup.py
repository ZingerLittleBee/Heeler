#!/usr/bin/env python3
"""Compare Git launchers with fresh HOME directories, without building an app."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import signal
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


def measure(pair: int, order: int, label: str, phase: str, git: Path,
            developer_git: Path, home: Path, output: Path) -> Sample:
    directory = output / f"{pair:02d}-{order}-{label}-{phase}"
    directory.mkdir()
    trace = directory / "git.jsonl"
    # Match the forced POSIX fixture's system PATH and isolated HOME. Do not
    # inherit DEVELOPER_DIR, XCRUN_*, Git overrides, credentials or other CI env.
    environment = {
        "HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": os.environ.get("USER", "runner"), "SHELL": "/bin/sh",
        "FIELD_GIT": str(git), "FIELD_PHASE": phase,
        "GIT_TRACE2_EVENT": str(trace), "LC_ALL": "C",
    }
    seen_xcodebuild = False
    error = None
    with (output / "seed.sh").open("rb") as stdin, \
            (directory / "stdout.log").open("wb") as stdout, \
            (directory / "stderr.log").open("wb") as stderr, \
            (directory / "processes.log").open("w") as processes:
        started_wall = time.time()
        started = time.monotonic()
        process = subprocess.Popen(
            ["/bin/sh"], stdin=stdin, stdout=stdout, stderr=stderr,
            env=environment, cwd=home, start_new_session=True)
        try:
            while process.poll() is None:
                # Only this probe's process group, with command names rather
                # than argv or environment. This excludes unrelated CI work.
                snapshot = subprocess.check_output(
                    ["ps", "-axo", "pid,ppid,pgid,stat,etime,comm"], text=True)
                processes.write(f"elapsed={time.monotonic() - started:.6f}\n")
                for line in snapshot.splitlines():
                    columns = line.split(maxsplit=5)
                    if len(columns) == 6 and columns[2] == str(process.pid):
                        processes.write(line + "\n")
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

    before_init = init_seconds = None
    try:
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
                  init_seconds, seen_xcodebuild, exit_status, error)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=20)
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
        "definition": "fresh HOME, then same-HOME repeat; OS caches are not reset; no SSH or App",
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    samples: list[Sample] = []
    order = [args.first_path, "developer" if args.first_path == "system" else "system"]
    for pair in range(1, args.iterations + 1):
        for position, label in enumerate(order, 1):
            with tempfile.TemporaryDirectory(prefix="heeler-git-startup-") as temporary:
                for phase in ["fresh", "repeat"]:
                    sample = measure(pair, position, label, phase, paths[label],
                                     paths["developer"], Path(temporary), output)
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
