#!/usr/bin/env bash
# Exercise the merge gate's own assertions without running the merge gate.
#
# A developer tool, run by hand. It is deliberately not wired into CI or into
# run-ci-ios-tests.sh: it proves the gate's guards can fail, which is a claim
# about the gate rather than about the app.
#
# The guards it exercises are the ones the full lane gained under #135. Those
# guards exist because a gate run reported `864 tests in 92 suites passed` while
# 95 of those tests executed nothing, so the standard they are held to here is
# that each one has been *seen* to go red for its own stated reason. A guard
# that has only ever been seen green is not known to work.
#
# Four properties of this script matter as much as the cases:
#
#   * It does not copy the guards. It extracts their function text verbatim out
#     of scripts/run-ci-ios-tests.sh and evals it, so what runs here is the code
#     that ships. A transcription would drift silently and this file would keep
#     reporting green about a function nobody runs.
#   * It does not restate the gate's numbers either. The executed floor is read
#     back out of the gate's own call site, because a second copy of it here
#     drifted silently and left the gate loosenable with every case still green.
#   * A red case must print the words of the guard it is named after, not merely
#     exit non-zero. One case here used to go red through a different guard than
#     its name claimed, which reads as coverage while being none.
#   * It refuses to report success having run nothing. A missing function, a
#     missing call site, a swapped capture and a miscounted case list are all
#     fatal. Passing zero cases while printing a summary is precisely the
#     failure #135 exists to oppose, and it would be an unusually poor thing to
#     ship inside the fix for it.
#
# Fixtures are derived from one committed capture of a real passing gate run,
# scripts/testdata/gate-2f50170.log, whose only edit is that the developer home
# path it was recorded under is rewritten to /Users/ci. That substitution is
# mechanical and total, and provably touches no line any guard or the lane
# splitter reads. Everything else -- the per-lane logs the gate writes, and
# every degraded variant -- is generated from it here, so a fresh clone
# reproduces the whole set with no manual reconstruction.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gate_script="$repo_root/scripts/run-ci-ios-tests.sh"
green_log="$repo_root/scripts/testdata/gate-2f50170.log"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-gate-guards.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Facts about the committed capture, asserted rather than assumed: if the
# fixture is ever replaced, these say which number moved.
expected_full_lane_total=864
expected_full_lane_skips=95
expected_capture_executed=769
expected_cases=38

# The lanes run-ci-ios-tests.sh writes, in the order it writes them. The capture
# is the concatenation of exactly these, so splitting it on the xcodebuild
# invocation banners reproduces the files the gate's own assertions read.
lane_names=(
    HeelerSSHSessionE2ETests
    HeelerSSHPTYE2ETests
    HeelerSSHDirectStreamLocalE2ETests
    HeelerSSHJumpHostGateE2ETests
    HeelerSSHTransportBehaviorE2ETests
    ImageStagingE2ETests
    WeakNetworkE2ETests
    PairingCeremonyE2ETests
    package-e2e
    full-lane
)

die() {
    printf 'FATAL: %s\n' "$1" >&2
    exit 2
}

[[ -r "$gate_script" ]] || die "cannot read $gate_script"
[[ -r "$green_log" ]] || die "cannot read $green_log"

# Lift a function out of the shipped gate script by name. Renaming a guard over
# there must break this loudly rather than quietly leave it untested, so an
# empty extraction is fatal and so is a body that does not define the function.
extract_shipped_function() {
    local name=$1 body
    body=$(awk -v fn="$name" \
        '$0 ~ "^" fn "\\(\\) \\{$" { inside = 1 }
         inside { print }
         inside && /^\}$/ { exit }' "$gate_script")
    [[ -n "$body" ]] || die "no function '$name' in $gate_script (renamed?)"
    eval "$body" || die "could not eval '$name' from $gate_script"
    [[ "$(type -t "$name")" == function ]] || die "'$name' did not define a function"
}

extract_shipped_function assert_full_lane_coverage
extract_shipped_function assert_behavior
extract_shipped_function run_suite
extract_shipped_function cleanup
extract_shipped_function clear_simulator_environment
extract_shipped_function stop_privileged_sshd

# The floor is read out of the gate's own call site rather than restated here.
# Restating it made the two literals drift silently, and the drift that matters
# is someone loosening the gate: with the floor duplicated, lowering the gate's
# call site to 1 left every case green, so the harness could not see the one
# regression it most needs to. Reading it means lowering the gate makes the
# coverage-loss cases stop failing, and raising it makes the control case stop
# passing -- drift in either direction lands on a case rather than nowhere.
# The literal `$full_lane_log` is the gate's text, not an expansion here.
# shellcheck disable=SC2016
gate_executed_floor=$(sed -n \
    's/^assert_full_lane_coverage "\$full_lane_log" \([0-9][0-9]*\)$/\1/p' \
    "$gate_script")
[[ -n "$gate_executed_floor" ]] \
    || die "no assert_full_lane_coverage call site with a floor in $gate_script"
[[ "$(printf '%s\n' "$gate_executed_floor" | wc -l | tr -d ' ')" == 1 ]] \
    || die "more than one assert_full_lane_coverage call site in $gate_script"

# The gate's named full-lane assertions. Counted so that adding one over there
# without adding a case here is fatal: the case total below checks how many
# cases ran, not which, so a tenth gate assertion would otherwise go untested.
gate_full_lane_assertions=$(awk '
    { line = cont ? line " " $0 : $0 }
    line ~ /\\$/ { sub(/[ \t]*\\$/, "", line); cont = 1; next }
    { cont = 0; if (line ~ /^assert_behavior .* full-lane /) count += 1 }
    END { print count + 0 }' "$gate_script")

# Split the capture into the per-lane logs. Each chunk carries its own
# `Command line invocation:` banner, so the split is checked against the
# -only-testing identifier in the banner rather than trusted to line arithmetic.
split_capture() {
    mkdir -p "$work/lanes"
    LANES="${lane_names[*]}" /usr/bin/python3 - "$green_log" "$work/lanes" <<'PY'
import os, re, sys

source, out_dir = sys.argv[1], sys.argv[2]
names = os.environ["LANES"].split()
lines = open(source, encoding="utf-8").read().splitlines(keepends=True)
starts = [i for i, l in enumerate(lines) if l.startswith("Command line invocation:")]
if len(starts) != len(names):
    sys.exit(f"capture has {len(starts)} lanes, expected {len(names)}")

bounds = starts + [len(lines)]
for index, name in enumerate(names):
    chunk = lines[bounds[index]:bounds[index + 1]]
    banner = chunk[1] if len(chunk) > 1 else ""
    found = re.search(r"only-testing:HeelerTests/(\w+)", banner)
    if name == "package-e2e":
        expected_ok = "-scheme HeelerSSH" in banner
    elif name == "full-lane":
        expected_ok = found is None and "-scheme Heeler" in banner
    else:
        expected_ok = found is not None and found.group(1) == name
    if not expected_ok:
        sys.exit(f"lane {index} is not {name}: {banner.strip()[:120]}")
    with open(os.path.join(out_dir, name + ".log"), "w", encoding="utf-8") as handle:
        handle.writelines(chunk)
PY
}

split_capture || die "could not split $green_log into lanes"

# Confirm the capture still says what the cases below are calibrated against,
# so replacing it surfaces as a named mismatch instead of as odd case results.
actual_total=$(sed -n \
    's/^.*Test run with \([0-9][0-9]*\) tests in .* passed after .*$/\1/p' \
    "$work/lanes/full-lane.log" | tail -n 1)
actual_skips=$(grep -c 'Test .* skipped:' "$work/lanes/full-lane.log")
[[ -n "$actual_total" ]] \
    || die "capture's full lane states no passing run summary (truncated?)"
[[ "$actual_total" == "$expected_full_lane_total" ]] \
    || die "capture full lane totals $actual_total, expected $expected_full_lane_total"
[[ "$actual_skips" == "$expected_full_lane_skips" ]] \
    || die "capture full lane skips $actual_skips, expected $expected_full_lane_skips"
(( actual_total - actual_skips == expected_capture_executed )) \
    || die "capture executes $((actual_total - actual_skips)), expected $expected_capture_executed"

passed=0
failed=0
ran=0
case_labels=()

new_case() {
    local dir="$work/cases/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$work/lanes/"*.log "$dir/"
    printf '%s' "$dir"
}

# Run one assertion against one case directory and compare its verdict to the
# expected one. $1 pass|fail, $2 the text a red case must print (empty for a
# green one), $3 label, $4 case directory, rest the invocation.
#
# The expected text is not decoration. A red case proves nothing unless it went
# red for the reason its label claims, and this harness already shipped one that
# did not: "a missing run summary is caught" went red through the *floor*
# (total="" reads as 0, and 0 - 95 is below any floor) rather than through the
# guard it was named after, so deleting that guard entirely left the case green.
# Matching the message is what makes each case discriminate between the guards.
#
# fixture_dir is set to the case directory because that is where the gate's
# assertions look: assert_behavior derives its log path as
# "$fixture_dir/$log_name.log" rather than taking a path. Pointing fixture_dir
# somewhere else makes every assert_behavior case go red on a missing file while
# claiming it went red because the behaviour was neutered -- an expected-fail
# case that passes for the wrong reason, which this harness produced once before
# the derivation was noticed. Any change here should be re-checked against the
# control block, which is the only part that would notice.
run_case() {
    local expect=$1 expect_text=$2 label=$3 case_dir=$4
    shift 4
    local output status verdict lane reason
    output=$(
        set +e
        # Read by the extracted functions, which shellcheck cannot see into.
        # shellcheck disable=SC2034
        fixture_dir="$case_dir"
        # shellcheck disable=SC2034
        password_fixture_available="$case_password_fixture"
        pinned_lane_logs=()
        for lane in "${lane_names[@]}"; do
            [[ "$lane" == full-lane ]] && continue
            pinned_lane_logs+=("$case_dir/$lane.log")
        done
        # The guards signal failure with `exit`, which would take this capture
        # subshell down with them and leave no status to read. Nesting one more
        # subshell keeps the status observable, so a red case is recorded as the
        # code the gate would really exit with rather than as an absence.
        ( "$@" ) 2>&1
        printf 'HARNESS_STATUS=%s\n' "$?"
    )
    status=$(printf '%s' "$output" | sed -n 's/^HARNESS_STATUS=//p' | tail -n 1)
    [[ -n "$status" ]] || die "case '$label' produced no status"
    verdict=pass
    [[ "$status" != 0 ]] && verdict=fail

    reason=""
    if [[ "$verdict" != "$expect" ]]; then
        reason="expected $expect, got $verdict"
    elif [[ "$expect" == fail ]]; then
        # A red case must carry the guard's own words, not merely a non-zero
        # status that some other guard in the same function could have produced.
        # Every line of expect_text must appear, so a case can demand both the
        # guard that spoke and the specific test it named.
        local fragment
        while IFS= read -r fragment; do
            [[ -n "$fragment" ]] || continue
            printf '%s\n' "$output" | grep -qF "$fragment" && continue
            reason="went red without saying: $fragment"
            break
        done <<< "$expect_text"
    elif [[ -n "$expect_text" ]]; then
        die "green case '$label' declares an expected failure message"
    fi

    case_labels+=("$label")
    ran=$((ran + 1))
    if [[ -z "$reason" ]]; then
        printf 'ok    expected-%-4s  exit=%-3s  %s\n' "$expect" "$status" "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$status" "$label" "$reason"
        failed=$((failed + 1))
    fi
    if [[ "$verdict" == fail ]]; then
        printf '%s\n' "$output" | grep -v '^HARNESS_STATUS=' | sed 's/^/        | /'
    fi
}

# The capture is a laptop run: no passwordless sudo, so the privileged
# password fixture was absent. Cases that need the other setting say so.
case_password_fixture=0

# Each entry is `assert_behavior label|test name`, for the behaviours that
# appear only in the full lane and so had no assertion of any kind before #135.
full_lane_behaviors=(
    "admission reserves the production slots|productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling()"
    "admission stays non-blocking|sessionSaturationDoesNotBlockForwardingAdmission()"
    "admission respects the connection ceiling|connectionCeilingBoundsForwardingAndSessionTogether()"
    "a cancelled waiter frees its capacity|cancelledWaiterDoesNotLeakConnectionCapacity()"
    "TOFU migrates a legacy record|matchingLegacyRecordMigratesAlgorithmMetadata()"
    "TOFU refuses a changed key|changedKeyFailsWithoutConfirmationOrOverwrite()"
    "no obsolete algorithm is negotiable|\"the session driver negotiates no obsolete algorithm\""
    "no private key entry point exists|\"the SSH package has no private key entry point\""
    "signing never exports a key|\"the transport signs through CryptoKit rather than exporting a key\""
)

jump_host_product_path='"protocol 17 ping traverses independent SSH hops"'

# The provenance guard's own opening words. Naming it once keeps the cases below
# demanding that guard specifically rather than any non-zero exit.
unproven_says="no pinned lane proved:"

echo "== control: the unmodified capture of a passing gate run =="
case_dir=$(new_case green)
run_case pass '' "full-lane coverage holds" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"
for entry in "${full_lane_behaviors[@]}"; do
    run_case pass '' "full lane proves: ${entry%%|*}" "$case_dir" \
        assert_behavior "${entry%%|*}" full-lane "${entry#*|}"
done
run_case pass '' "Jump Host product path is proven" "$case_dir" \
    assert_behavior "Jump Host product path" HeelerSSHJumpHostGateE2ETests \
    "$jump_host_product_path"

echo
echo "== a ninth suite silently joins the full-lane skip list =="
# The headline case. `SSH channel admission` runs only in the full lane, so
# nothing else in the gate would notice it stopping.
case_dir=$(new_case ninth-suite)
/usr/bin/python3 - "$case_dir/full-lane.log" <<'PY'
import re, sys

path = sys.argv[1]
out = []
for line in open(path, encoding="utf-8").read().splitlines(keepends=True):
    admission = 'Suite "SSH channel admission"' in line or re.search(
        r"Test (productionLimits|sessionSaturation|connectionCeiling|cancelledWaiter)\w*\(\)",
        line)
    if admission and " passed after" in line:
        out.append(re.sub(r" passed after .*$",
                          ' skipped: "requires the disposable unprivileged sshd fixture"\n',
                          line))
    elif admission and " started." in line:
        continue
    else:
        out.append(line)
open(path, "w", encoding="utf-8").writelines(out)
PY
run_case fail \
    "$unproven_says
sessionSaturationDoesNotBlockForwardingAdmission()" \
    "a ninth skipping suite is caught by name" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== coverage removed outright, with nothing skipped to show for it =="
retotal() {
    TOTAL="$1" SUITES="$2" /usr/bin/python3 - "$3" <<'PY'
import os, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "Test run with 864 tests in 92 suites passed"
assert old in text, "capture no longer states 864 in 92"
new = f"Test run with {os.environ['TOTAL']} tests in {os.environ['SUITES']} suites passed"
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}
case_dir=$(new_case lost-many)
retotal 800 88 "$case_dir/full-lane.log"
run_case fail \
    "executed 705 tests (800 minus 95 skipped); at least $gate_executed_floor must run" \
    "sixty-four lost tests are caught" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

case_dir=$(new_case lost-one)
retotal 863 92 "$case_dir/full-lane.log"
run_case fail \
    "executed 768 tests (863 minus 95 skipped); at least $gate_executed_floor must run" \
    "a single lost test is caught" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

case_dir=$(new_case added-tests)
retotal 871 93 "$case_dir/full-lane.log"
run_case pass '' "added tests do not require editing the gate" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== a full-lane skip loses the lane that proved it =="
case_dir=$(new_case unproven-skip)
/usr/bin/python3 - "$case_dir/HeelerSSHPTYE2ETests.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'Test "PTY EOF remains observable after a clean remote exit" passed'
assert old in text, "capture no longer proves the PTY EOF test"
open(path, "w", encoding="utf-8").write(text.replace(old, old.replace('"', '" ', 1)))
PY
run_case fail \
    "$unproven_says
\"PTY EOF remains observable after a clean remote exit\"" \
    "an unproven full-lane skip is caught" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== each named full-lane behaviour, neutered one at a time =="
neuter() {
    NAME="$1" /usr/bin/python3 - "$2" <<'PY'
import os, sys

path, name = sys.argv[1], os.environ["NAME"]
text = open(path, encoding="utf-8").read()
old = f"Test {name} passed"
assert old in text, f"capture does not prove {name}; nothing to neuter"
open(path, "w", encoding="utf-8").write(text.replace(old, f"Test {name}Renamed passed"))
PY
}
index=0
for entry in "${full_lane_behaviors[@]}"; do
    index=$((index + 1))
    case_dir=$(new_case "neutered-$index")
    neuter "${entry#*|}" "$case_dir/full-lane.log" || die "could not neuter ${entry%%|*}"
    run_case fail "Mandatory behaviour not proven: ${entry%%|*} (${entry#*|})" \
        "neutered: ${entry%%|*}" "$case_dir" \
        assert_behavior "${entry%%|*}" full-lane "${entry#*|}"
done

case_dir=$(new_case neutered-jump-host)
neuter "$jump_host_product_path" "$case_dir/HeelerSSHJumpHostGateE2ETests.log" \
    || die "could not neuter the Jump Host product path"
run_case fail \
    "Mandatory behaviour not proven: Jump Host product path ($jump_host_product_path)" \
    "neutered: Jump Host product path" "$case_dir" \
    assert_behavior "Jump Host product path" HeelerSSHJumpHostGateE2ETests \
    "$jump_host_product_path"

echo
echo "== the full lane reports no passing run at all =="
case_dir=$(new_case no-summary)
/usr/bin/python3 - "$case_dir/full-lane.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "Test run with 864 tests in 92 suites passed"
assert old in text
open(path, "w", encoding="utf-8").write(text.replace(old, "TEST EXECUTE SUCCEEDED"))
PY
run_case fail "The full lane printed no passing run summary" \
    "a missing run summary is caught by its own guard" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== the developer-laptop exemption is narrow, not a blanket pass =="
# The capture's two real-password tests skip in both lanes, because the machine
# had no passwordless sudo. Told the privileged fixture was present -- which is
# what merge CI is -- the gate must refuse exactly those two.
case_dir=$(new_case exemption)
case_password_fixture=1
run_case fail \
    "$unproven_says
\"password authentication and exec round trip through real sshd\"
\"incorrect password has a distinct authentication error\"" \
    "with the privileged fixture present, the two password skips fail" \
    "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"
case_password_fixture=0
run_case pass '' "with it absent, exactly those two are exempt" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

case_dir=$(new_case exemption-cannot-widen)
/usr/bin/python3 - "$case_dir/HeelerSSHTransportBehaviorE2ETests.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'Test "Jump Host Events preserve framing, concurrency, and slot reuse" passed'
assert old in text
open(path, "w", encoding="utf-8").write(text.replace(old, old.replace('"', '" ', 1)))
PY
run_case fail \
    "$unproven_says
\"Jump Host Events preserve framing, concurrency, and slot reuse\"" \
    "a third unproven skip is not absorbed by the exemption" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== the evidence run_suite feeds the provenance guard =="
# Everything above hands the guards a pinned_lane_logs array this harness builds
# itself, which tests the guards but not the plumbing that fills that array in
# the real script. Deleting `pinned_lane_logs+=("$log")` from run_suite left
# every case above green while leaving the gate with no evidence at all, so
# run_suite is driven here for real, against a stubbed xcodebuild that replays
# one lane of the capture.
#
# $1 pass|fail, $2 expected text, $3 label, $4 lane, then run_suite's arguments.
run_suite_case() {
    local expect=$1 expect_text=$2 label=$3 lane=$4
    shift 4
    local case_dir output status verdict reason
    case_dir=$(new_case "run-suite-$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-')")
    mv "$case_dir/$lane.log" "$case_dir/replay.log"
    output=$(
        set +e
        # run_suite reports on stderr, so point it at the capture. run_suite is
        # then called unnested, because the property under test is a side effect
        # on pinned_lane_logs that a nested subshell would discard: a lane it
        # refuses exits here and simply prints no status, which reads as red.
        exec 2>&1
        # Both read by the extracted run_suite, which shellcheck cannot see.
        # shellcheck disable=SC2034
        fixture_dir="$case_dir"
        # shellcheck disable=SC2034
        simulator_destination="stub"
        pinned_lane_logs=()
        # run_suite pipes xcodebuild through tee, so replaying the lane here
        # exercises the real capture, count guard, skip guard and append.
        # shellcheck disable=SC2329
        xcodebuild() { cat "$case_dir/replay.log"; }
        run_suite "$@" >/dev/null
        printf 'PINNED_COUNT=%s\n' "${#pinned_lane_logs[@]}"
        printf 'PINNED_LAST=%s\n' "${pinned_lane_logs[*]-}"
        printf 'HARNESS_STATUS=0\n'
    )
    status=$(printf '%s' "$output" | sed -n 's/^HARNESS_STATUS=//p' | tail -n 1)
    verdict=fail
    [[ "$status" == 0 ]] && verdict=pass

    reason=""
    if [[ "$verdict" != "$expect" ]]; then
        reason="expected $expect, got $verdict"
    elif ! printf '%s\n' "$output" | grep -qF "$expect_text"; then
        reason="did not report: $expect_text"
    fi

    case_labels+=("$label")
    ran=$((ran + 1))
    if [[ -z "$reason" ]]; then
        printf 'ok    expected-%-4s  %s\n' "$expect" "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL  %s\n          (%s)\n' "$label" "$reason"
        failed=$((failed + 1))
        printf '%s\n' "$output" | sed 's/^/        | /'
    fi
}

# A lane that passes its counts must be appended, or the provenance guard has
# nothing to reason from. This is the case that dies if the append is removed.
run_suite_case pass "PINNED_LAST=$work/cases" \
    "a passing lane is recorded as evidence" HeelerSSHPTYE2ETests \
    HeelerSSHPTYE2ETests 3 1

# And run_suite's own guards, which were equally untested: a lane whose executed
# count moved, and a lane that skipped where no skip was budgeted.
run_suite_case fail "did not execute all 4 tests" \
    "a lane with the wrong executed count is refused" HeelerSSHPTYE2ETests \
    HeelerSSHPTYE2ETests 4 1
run_suite_case fail "skipped 2 tests; exactly 0 may skip" \
    "an unbudgeted skip is refused" HeelerSSHSessionE2ETests \
    HeelerSSHSessionE2ETests 14 1

echo
echo "== privileged sshd stop is bounded before preserving evidence =="
case_dir=$(new_case privileged-stop-timeout)
command_log="$case_dir/commands.log"
printf '%s\n' 4242 > "$case_dir/sshd-password.pid"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
(
    fixture_dir="$case_dir"
    fixture_username=ci
    fixture_home="$case_dir/home"
    simulator_udid=""
    stall_pid=""
    fake_herdr_pid=""
    weak_network_pid=""
    unprivileged_sshd_pids=()
    password_pid=4242
    password_pid_file="$case_dir/sshd-password.pid"
    password_log="$case_dir/sshd-password.log"
    password_log_printed=0
    password_username=heeler-ci-password
    password_user_cleanup_needed=1
    password_ssh_sacl_added=1
    ps_probe_count=0

    sudo() {
        printf 'sudo %s\n' "$*" >> "$command_log"
        return 0
    }
    ps() {
        ps_probe_count=$((ps_probe_count + 1))
        (( ps_probe_count <= 100 ))
    }
    sleep() {
        printf 'sleep %s\n' "$*" >> "$command_log"
    }
    wait() {
        printf 'wait %s\n' "$*" >> "$command_log"
        return 0
    }

    cleanup
)
cleanup_exit=$?
sleep_count=$(grep -c '^sleep ' "$command_log")
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded while privileged sshd stayed live"
elif grep -q '^wait ' "$command_log"; then
    reason="cleanup waited on a privileged sshd that was still live"
elif (( sleep_count == 0 )); then
    reason="cleanup did not poll for bounded privileged sshd shutdown"
elif (( sleep_count > 60 )); then
    reason="cleanup exceeded the bounded privileged sshd shutdown polls"
elif grep -qE 'dseditgroup|sysadminctl' "$command_log"; then
    reason="cleanup modified the account after privileged sshd stop failed"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after privileged sshd stop failed"
fi
case_labels+=("a live privileged sshd times out and preserves evidence")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a live privileged sshd times out and preserves evidence"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a live privileged sshd times out and preserves evidence" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== a distinct privileged sshd launcher is also bounded =="
case_dir=$(new_case privileged-launcher-timeout)
command_log="$work/privileged-launcher-timeout-commands.log"
printf '%s\n' 4242 > "$case_dir/sshd-password.pid"
# The target daemon is already gone, but the distinct sudo launcher remains a
# live non-zombie. Cleanup must not enter an unbounded Bash 3 wait for it.
# shellcheck disable=SC2034,SC2329
(
    fixture_dir="$case_dir"
    fixture_username=ci
    fixture_home="$case_dir/home"
    simulator_udid=""
    stall_pid=""
    fake_herdr_pid=""
    weak_network_pid=""
    unprivileged_sshd_pids=()
    password_pid=4343
    password_pid_file="$case_dir/sshd-password.pid"
    password_log="$case_dir/sshd-password.log"
    password_log_printed=0
    password_username=heeler-ci-password
    password_user_cleanup_needed=0
    password_ssh_sacl_added=0

    sudo() {
        printf 'sudo %s\n' "$*" >> "$command_log"
        return 0
    }
    ps() {
        local pid=""
        while (( $# > 0 )); do
            if [[ "$1" == "-p" && $# -gt 1 ]]; then
                pid=$2
            fi
            shift
        done
        if [[ "$pid" == "4343" ]]; then
            printf 'S\n'
            return 0
        fi
        return 1
    }
    sleep() {
        printf 'sleep %s\n' "$*" >> "$command_log"
    }
    wait() {
        printf 'wait %s\n' "$*" >> "$command_log"
        return 0
    }

    cleanup
)
cleanup_exit=$?
sleep_count=$(grep -c '^sleep ' "$command_log" || true)
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded while the distinct launcher stayed live"
elif grep -q '^wait ' "$command_log"; then
    reason="cleanup waited on a live non-zombie launcher"
elif (( sleep_count == 0 )); then
    reason="cleanup did not poll the distinct launcher for bounded shutdown"
elif (( sleep_count > 60 )); then
    reason="cleanup exceeded the bounded distinct-launcher shutdown polls"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence while the distinct launcher stayed live"
fi
case_labels+=("a live distinct privileged launcher times out without wait")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a live distinct privileged launcher times out without wait"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a live distinct privileged launcher times out without wait" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== password SSH access removal failure preserves evidence =="
case_dir=$(new_case password-sacl-removal-failure)
command_log="$work/password-sacl-removal-failure-commands.log"
# The extracted cleanup function consumes these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=heeler-ci-password
        password_user_cleanup_needed=1
        password_ssh_sacl_added=1

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            if [[ "$*" == *"/usr/sbin/dseditgroup -o edit -d "* ]]; then
                return 1
            fi
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded after SSH access removal failed"
elif grep -qF '/usr/sbin/sysadminctl -deleteUser' "$command_log"; then
    reason="cleanup deleted the account after SSH access removal failed"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after SSH access removal failed"
elif ! printf '%s\n' "$cleanup_output" \
    | grep -qF "Failed to remove password account heeler-ci-password from SSH access."; then
    reason="cleanup did not diagnose the SSH access removal failure"
fi
case_labels+=("password SSH access removal failure preserves evidence")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "password SSH access removal failure preserves evidence"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "password SSH access removal failure preserves evidence" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== an absent password account is a successful cleanup no-op =="
# There is no hermetic seam for injecting EXIT/INT/TERM between the cleanup
# intent assignment and the privileged sysadminctl spawn. The cases below
# prove both resulting record states instead; do not replace them with a
# source-order assertion.
case_dir=$(new_case password-account-absent)
command_log="$work/password-account-absent-commands.log"
# The extracted cleanup function consumes these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
(
    fixture_dir="$case_dir"
    fixture_username=ci
    fixture_home="$case_dir/home"
    simulator_udid=""
    stall_pid=""
    fake_herdr_pid=""
    weak_network_pid=""
    unprivileged_sshd_pids=()
    password_pid=""
    password_pid_file="$case_dir/sshd-password.pid"
    password_log="$case_dir/sshd-password.log"
    password_log_printed=0
    password_username=heeler-ci-password
    password_user_cleanup_needed=1
    password_ssh_sacl_added=0

    dscl() {
        printf 'dscl %s\n' "$*" >> "$command_log"
        return 1
    }
    sudo() {
        printf 'sudo %s\n' "$*" >> "$command_log"
        return 0
    }

    cleanup
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" != 0 ]]; then
    reason="cleanup failed when the password account record was absent"
elif ! grep -qF 'dscl . -read /Users/heeler-ci-password' "$command_log"; then
    reason="cleanup did not query the exact password account record"
elif grep -qF '/usr/sbin/sysadminctl -deleteUser' "$command_log"; then
    reason="cleanup tried to delete an absent password account"
elif [[ -d "$case_dir" ]]; then
    reason="cleanup preserved fixture evidence for an absent password account"
fi
case_labels+=("an absent password account is a successful cleanup no-op")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "an absent password account is a successful cleanup no-op"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "an absent password account is a successful cleanup no-op" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== password account deletion failure preserves evidence =="
case_dir=$(new_case password-delete-failure)
command_log="$work/password-delete-failure-commands.log"
# The extracted cleanup functions consume these variables and the sudo stub
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=heeler-ci-password
        password_user_cleanup_needed=1
        password_ssh_sacl_added=0

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            return 1
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded after password account deletion failed"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after password account deletion failed"
elif ! grep -qF 'dscl . -read /Users/heeler-ci-password' "$command_log"; then
    reason="cleanup did not query the exact partial password account record"
elif ! grep -qF '/usr/sbin/sysadminctl -deleteUser' "$command_log"; then
    reason="cleanup did not try to delete the partial password account record"
elif ! printf '%s\n' "$cleanup_output" \
    | grep -qF "Failed to delete password account heeler-ci-password."; then
    reason="cleanup did not diagnose the password account deletion failure"
fi
case_labels+=("password account deletion failure preserves evidence")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "password account deletion failure preserves evidence"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "password account deletion failure preserves evidence" "$reason"
    failed=$((failed + 1))
fi

echo
# The point of the count: a harness that silently stops running cases would
# otherwise report the same "0 failed" as one that runs them all and passes.
# It counts quantity, not identity -- see the note at the foot of this file.
if (( ran != expected_cases )); then
    printf 'FATAL: ran %s cases, expected %s\n' "$ran" "$expected_cases" >&2
    exit 2
fi

# Two cheap identity checks the count cannot make. Neither closes the gap fully.
#
# Duplicated labels: two entries with the same name keep the count right while
# testing one thing twice and something else not at all.
duplicate_label=$(printf '%s\n' "${case_labels[@]}" | LC_ALL=C sort \
    | LC_ALL=C uniq -d | head -n 1)
[[ -z "$duplicate_label" ]] || die "two cases share the label: $duplicate_label"

# A tenth full-lane assertion added to the gate with no case added here. The
# count would still read 33, because it never knew there should be 34.
if (( gate_full_lane_assertions != ${#full_lane_behaviors[@]} )); then
    printf 'FATAL: the gate makes %s full-lane assertions, this harness knows %s\n' \
        "$gate_full_lane_assertions" "${#full_lane_behaviors[@]}" >&2
    exit 2
fi

printf '%s of %s gate-guard cases behaved as expected, %s did not.\n' \
    "$passed" "$ran" "$failed"
(( failed == 0 ))

# Known gap, stated rather than papered over: the checks above catch a case
# being duplicated and a gate assertion going unmirrored, but not a case whose
# body is replaced by something vacuous. Closing that needs each case to prove
# it exercised its subject, which is a bigger machine than this file deserves.
# The mutation runs in the commit message are what stand in for it today.
