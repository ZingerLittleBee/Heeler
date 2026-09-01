#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$repo_root/scripts/run-with-timeout.py"
gate_script="$repo_root/scripts/run-ci-ios-tests.sh"
workflow="$repo_root/.github/workflows/ci.yml"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-timeout-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

[[ -x "$runner" ]] || {
    echo "watchdog runner is missing or not executable: $runner" >&2
    exit 1
}

"$runner" \
    --timeout-seconds 2 \
    --label success \
    --diagnostics-dir "$work/success" \
    -- /bin/sh -c 'printf "success\n"'

[[ ! -e "$work/success/status.txt" ]] || {
    echo "successful runs must not write failure diagnostics" >&2
    exit 1
}
[[ ! -e "$work/success/processes.txt" ]] || {
    echo "successful runs must not capture a process snapshot" >&2
    exit 1
}

set +e
mkdir -p "$work/evidence"
printf 'partial xcresult' > "$work/evidence/result.txt"
# One full second of deadline: the child only needs to write its pid file
# before the watchdog fires, and 0.1s lost that race on loaded machines.
# The `$$`/`$1` below belong to the child shell, deliberately unexpanded.
# shellcheck disable=SC2016
HEELER_TIMEOUT_DISABLE_SAMPLE=1 "$runner" \
    --timeout-seconds 1 \
    --label stalled-test \
    --diagnostics-dir "$work/timeout" \
    --artifact-path "$work/evidence" \
    -- /bin/sh -c 'printf "%s" "$$" > "$1"; sleep 30' sh "$work/stalled.pid"
timeout_status=$?
set -e

[[ "$timeout_status" == 124 ]] || {
    echo "watchdog returned $timeout_status instead of 124" >&2
    exit 1
}
[[ -s "$work/stalled.pid" ]] || {
    echo "the stalled child never wrote its pid; cannot assert termination" >&2
    exit 1
}
[[ -s "$work/timeout/processes.txt" ]] || {
    echo "watchdog did not capture the process table" >&2
    exit 1
}
[[ -s "$work/timeout/timeout.txt" ]] || {
    echo "watchdog did not record the timeout" >&2
    exit 1
}
[[ "$(cat "$work/timeout/status.txt")" == 124 ]] || {
    echo "watchdog did not record timeout status 124" >&2
    exit 1
}
[[ -s "$work/timeout/artifacts/01-evidence/result.txt" ]] || {
    echo "watchdog did not preserve the requested diagnostic artifact" >&2
    exit 1
}
stalled_pid="$(cat "$work/stalled.pid")"
if kill -0 "$stalled_pid" 2>/dev/null; then
    echo "watchdog left the stalled process group alive" >&2
    exit 1
fi

if grep -qE '^[[:space:]]*xcodebuild ' "$gate_script"; then
    echo "run-ci-ios-tests.sh contains an xcodebuild call outside the watchdog" >&2
    exit 1
fi
wrapped_calls=$(grep -cE '^[[:space:]]*run_xcodebuild "' "$gate_script")
[[ "$wrapped_calls" == 5 ]] || {
    echo "expected 5 watchdog-wrapped xcodebuild call sites, found $wrapped_calls" >&2
    exit 1
}
[[ "$(grep -c 'timeout-minutes: 35' "$workflow")" == 1 ]] || {
    echo "the iOS job must retain its 35-minute deadline" >&2
    exit 1
}
[[ "$(grep -c 'timeout-minutes: 32' "$workflow")" == 1 ]] || {
    echo "the Build and test step must retain its 32-minute deadline" >&2
    exit 1
}

set +e
mkdir -p "$work/failure-evidence"
printf 'failure xcresult' > "$work/failure-evidence/result.txt"
"$runner" \
    --timeout-seconds 2 \
    --label failure \
    --diagnostics-dir "$work/failure" \
    --artifact-path "$work/failure-evidence" \
    -- /bin/sh -c 'exit 65'
failure_status=$?
set -e

[[ "$failure_status" == 65 ]] || {
    echo "watchdog changed child exit 65 to $failure_status" >&2
    exit 1
}
[[ "$(cat "$work/failure/status.txt")" == 65 ]] || {
    echo "watchdog did not record the original nonzero status" >&2
    exit 1
}
[[ -s "$work/failure/artifacts/01-failure-evidence/result.txt" ]] || {
    echo "watchdog did not preserve artifacts for a nonzero child exit" >&2
    exit 1
}
[[ ! -e "$work/failure/processes.txt" ]] || {
    echo "process snapshots must stay timeout-only" >&2
    exit 1
}
[[ ! -e "$work/failure/timeout.txt" ]] || {
    echo "timeout.txt must stay timeout-only" >&2
    exit 1
}
shopt -s nullglob
failure_samples=("$work/failure"/sample-*)
shopt -u nullglob
[[ "${#failure_samples[@]}" == 0 ]] || {
    echo "sample diagnostics must stay timeout-only" >&2
    exit 1
}

awk '
    /^run_xcodebuild\(\) \{/ { inside = 1 }
    inside && /test-without-building/ { gated = 1 }
    inside && /-disableAutomaticPackageResolution/ { flag = 1 }
    inside && /^}$/ { exit (gated && flag) ? 0 : 1 }
    END { exit (gated && flag) ? 0 : 1 }
' "$gate_script" || {
    echo "test-without-building must skip automatic package resolution" >&2
    exit 1
}
if grep -E '^[[:space:]]*run_xcodebuild "Build for testing"' -A 8 "$gate_script" \
    | grep -q -- '-disableAutomaticPackageResolution'; then
    echo "build-for-testing must keep automatic package resolution" >&2
    exit 1
fi
awk '
    /if \[\[ "\$ci_lane" == "package" \]\]; then/ { in_pkg = 1 }
    in_pkg && /HeelerSSH package build/ { saw_build_label = 1 }
    in_pkg && /build-for-testing/ { build = NR }
    in_pkg && /simctl bootstatus/ { boot = NR }
    in_pkg && /test-without-building/ { test_action = NR }
    in_pkg && /^exit 0$/ {
        ok = (saw_build_label && build && boot && test_action \
            && build < boot && boot < test_action)
        exit
    }
    END { exit ok ? 0 : 1 }
' "$gate_script" || {
    echo "package lane must overlap simulator boot with build-for-testing" >&2
    exit 1
}
[[ "$(grep -cF '==> Simulator boot wait after the build overlap:' "$gate_script")" == 2 ]] || {
    echo "app and package lanes must each attribute the boot/build overlap" >&2
    exit 1
}
[[ "$(grep -cF -- '-disableAutomaticPackageResolution' "$gate_script")" == 1 ]] || {
    echo "package-resolution skip must stay a single run_xcodebuild gate" >&2
    exit 1
}
awk '
    /^run_xcodebuild\(\) \{/ { inside = 1 }
    inside && /ci_lane" == "app"/ { app_gate = 1 }
    inside && /clonedSourcePackagesDirPath/ { flag = 1 }
    inside && /^}$/ { exit (app_gate && flag) ? 0 : 1 }
    END { exit (app_gate && flag) ? 0 : 1 }
' "$gate_script" || {
    echo "app lane must reuse a cached clonedSourcePackagesDirPath" >&2
    exit 1
}
if grep -E '^[[:space:]]*run_xcodebuild "HeelerSSH package' -A 12 "$gate_script" \
    | grep -q -- '-clonedSourcePackagesDirPath'; then
    echo "package lane must not take the app SourcePackages cache path" >&2
    exit 1
fi
[[ "$(grep -cF 'Cache SwiftPM checkouts' "$workflow")" == 1 ]] || {
    echo "the app job must cache SwiftPM checkouts" >&2
    exit 1
}
if grep -qE '^[[:space:]]+xcrun simctl list runtimes' "$workflow"; then
    echo "CI must not list simulator runtimes on the critical path" >&2
    exit 1
fi
[[ "$(grep -cF 'Show Xcode version' "$workflow")" == 2 ]] || {
    echo "both macOS jobs must keep the lightweight Xcode version step" >&2
    exit 1
}
awk '
    /^claim_port_block$/ { ports = NR }
    /xcrun simctl boot "/ { boot = NR }
    /ssh-keygen -q -t rsa -b 3072/ { keygen = NR }
    END { exit (ports && boot && keygen && ports < boot && boot < keygen) ? 0 : 1 }
' "$gate_script" || {
    echo "simulator boot must overlap fixture provisioning, not follow it" >&2
    exit 1
}

if ! awk '
    /pull_request:/ { in_pr = 1 }
    in_pr && /output\/\*\*/ { found = 1 }
    in_pr && /^  push:/ { exit found ? 0 : 1 }
    END { exit found ? 0 : 1 }
' "$workflow"; then
    echo "pull_request paths-ignore must include output/**" >&2
    exit 1
fi
if ! awk '
    /^  push:/ { in_push = 1 }
    in_push && /output\/\*\*/ { found = 1 }
    in_push && /^# One in-flight/ { exit found ? 0 : 1 }
    END { exit found ? 0 : 1 }
' "$workflow"; then
    echo "push paths-ignore must include output/**" >&2
    exit 1
fi
[[ "$(grep -cE '^[[:space:]]+- output/\*\*' "$workflow")" == 2 ]] || {
    echo "output/** must appear once per paths-ignore list" >&2
    exit 1
}

# The `$$`/`$1` below belong to the child shell, deliberately unexpanded.
# shellcheck disable=SC2016
"$runner" \
    --timeout-seconds 30 \
    --label cancellation \
    --diagnostics-dir "$work/cancellation" \
    -- /bin/sh -c 'printf "%s" "$$" > "$1"; sleep 30' sh "$work/cancelled.pid" &
runner_pid=$!
for _ in $(seq 1 100); do
    [[ -s "$work/cancelled.pid" ]] && break
    sleep 0.05
done
[[ -s "$work/cancelled.pid" ]] || {
    echo "watchdog child did not start for the cancellation probe" >&2
    exit 1
}
kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
cancellation_status=$?
set -e
[[ "$cancellation_status" == 143 ]] || {
    echo "watchdog returned $cancellation_status instead of 143 on SIGTERM" >&2
    exit 1
}
cancelled_pid="$(cat "$work/cancelled.pid")"
if kill -0 "$cancelled_pid" 2>/dev/null; then
    echo "watchdog left its child alive after SIGTERM" >&2
    exit 1
fi

echo "run-with-timeout behavior passed"
