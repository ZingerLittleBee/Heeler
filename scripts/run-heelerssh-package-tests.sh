#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
destination=${1:-platform=iOS Simulator,name=iPhone 17}
test_log=$(mktemp -t heeler-ssh-tests.XXXXXX)

cleanup() {
    rm -f "$test_log"
}
trap cleanup EXIT

(
    cd "$repo_root/Packages/HeelerSSH"
    xcodebuild test \
        -scheme HeelerSSH \
        -destination "$destination" \
        -derivedDataPath "$repo_root/build/HeelerSSHDerivedData" \
        -collect-test-diagnostics never
) 2>&1 | tee "$test_log"

total=$(sed -n \
    's/^.*Test run with \([0-9][0-9]*\) tests in .* passed after .*$/\1/p' \
    "$test_log" | tail -n 1)
if [[ -z "$total" ]]; then
    echo "The HeelerSSH package suite printed no passing run summary" >&2
    exit 1
fi

skips=$(grep -c 'Test .* skipped:' "$test_log" || true)
executed=$((total - skips))
if ((executed <= 0)); then
    echo "The HeelerSSH package suite executed no tests ($total registered, $skips skipped)" >&2
    exit 1
fi

echo "HeelerSSH package suite executed $executed of $total tests ($skips skipped)."
