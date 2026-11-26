#!/usr/bin/env python3
"""Run non-Simulator repository and script self-tests concurrently."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

# Ordered approximately slowest-first so long shell/tmux suites start at t=0.
COMMANDS: list[tuple[str, list[str]]] = [
    ("test-tmux-inventory-loop", [PY, "scripts/test-tmux-inventory-loop.py"]),
    ("test-testflight", [PY, "scripts/test-testflight.py"]),
    ("test-host-helper-scripts", [PY, "scripts/test-host-helper-scripts.py"]),
    ("test-host-process-reader", [PY, "scripts/test-host-process-reader.py"]),
    ("test-node-toolchain-probe", [PY, "scripts/test-node-toolchain-probe.py"]),
    ("test-server-kind-detection", [PY, "scripts/test-server-kind-detection.py"]),
    ("test-tmux-probe", [PY, "scripts/test-tmux-probe.py"]),
    ("test-bounded-host-script", [PY, "scripts/test-bounded-host-script.py"]),
    ("test-herdr-core-locator", [PY, "scripts/test-herdr-core-locator.py"]),
    ("test-run-app-simulator-tests", [PY, "scripts/test-run-app-simulator-tests.py"]),
    ("test-herdr-core-start", [PY, "scripts/test-herdr-core-start.py"]),
    ("test-publish-plugin", ["bash", "scripts/test-publish-plugin.sh"]),
    ("test-herdr-core-environment-check", [PY, "scripts/test-herdr-core-environment-check.py"]),
    ("test-weak-network-proxy", [PY, "scripts/test-weak-network-proxy.py"]),
    ("test-herdr-core-shell-launch", [PY, "scripts/test-herdr-core-shell-launch.py"]),
    ("test-herdr-app-control", [PY, "scripts/test-herdr-app-control.py"]),
    ("test-tmux-ssh-fixture", [PY, "scripts/test-tmux-ssh-fixture.py"]),
    ("test-isolated-herdr-backend", [PY, "scripts/test-isolated-herdr-backend.py"]),
    ("test-vps-ssh-access-scripts", ["bash", "scripts/test-vps-ssh-access-scripts.sh"]),
    ("test-host-helper-manifest", [PY, "scripts/test-host-helper-manifest.py"]),
    ("test-store-shots", [PY, "scripts/test-store-shots.py"]),
    ("test-check-test-target-membership", [PY, "scripts/test-check-test-target-membership.py"]),
    ("test-adhoc-publish", [PY, "scripts/test-adhoc-publish.py"]),
    ("test-source-revision", ["sh", "scripts/test-source-revision.sh"]),
    ("test-adhoc", [PY, "scripts/test-adhoc.py"]),
    ("test-check-agent-docs", [PY, "scripts/test-check-agent-docs.py"]),
    ("test-check-localizations", [PY, "scripts/test-check-localizations.py"]),
    ("check-localizations", [PY, "scripts/check-localizations.py"]),
    ("adhoc-host", ["sh", "-c", "node --test adhoc-host/test/*.test.mjs"]),
    ("test-herdr-core-lab-check", [PY, "scripts/test-herdr-core-lab-check.py"]),
    ("test-herdr-core-capture", [PY, "scripts/test-herdr-core-capture.py"]),
    ("test-amp-chat", ["node", "--test", "scripts/test-amp-chat.mjs"]),
    ("test-simulator-ui", [PY, "scripts/test-simulator-ui.py"]),
    ("test-native-test-lifecycle", [PY, "scripts/test-native-test-lifecycle.py"]),
    ("test-format-release-notes", [PY, "scripts/test-format-release-notes.py"]),
]


def run_one(name: str, argv: list[str], env: dict[str, str]) -> tuple[str, int, float, str]:
    started = time.monotonic()
    completed = subprocess.run(
        argv,
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return name, completed.returncode, time.monotonic() - started, completed.stdout


def main() -> int:
    started = time.monotonic()
    workers = min(8, max(2, os.cpu_count() or 4))
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    failures: list[tuple[str, int, str]] = []

    print(f"==> Running {len(COMMANDS)} tool checks across {workers} workers", flush=True)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(run_one, name, argv, env) for name, argv in COMMANDS]
        for future in as_completed(futures):
            name, code, elapsed, output = future.result()
            status = "PASS" if code == 0 else "FAIL"
            print(f"  [{status} {elapsed:5.1f}s] {name}", flush=True)
            if code != 0:
                failures.append((name, code, output))

    total = time.monotonic() - started
    if failures:
        for name, code, output in failures:
            print(f"\n=== FAILED: {name} (exit {code}) ===", file=sys.stderr)
            if output:
                print(output.rstrip(), file=sys.stderr)
        print(f"\n{len(failures)} of {len(COMMANDS)} tool checks failed in {total:.1f}s.", file=sys.stderr)
        return 1

    print(f"==> All {len(COMMANDS)} tool checks passed in {total:.1f}s.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
