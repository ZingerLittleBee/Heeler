#!/bin/bash
# Pin what each workflow runs, what starts it and which toolchain it uses.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Fast builds must not publish full-coverage check names or artifacts, even
# as skipped jobs. Releases never wait for full CI (ADR 0039).
python3 - "$repo_root/.github/workflows/ci-full.yml" <<'PYWORKFLOW'
from pathlib import Path
import re
import shlex
import subprocess
import sys

workflow = Path(sys.argv[1]).read_text()
workflows = Path(sys.argv[1]).parent

def require_line(body, expected):
    if [line.strip() for line in body.splitlines()].count(expected) != 1:
        raise SystemExit(f"Workflow contract missing or duplicated: {expected}")

def job(name, source=workflow):
    match = re.search(rf"(?m)^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)",
                      source, re.DOTALL)
    if match is None:
        raise SystemExit(f"Missing CI job: {name}")
    return match.group(1)

def events(source):
    block = re.search(r"(?m)^on:\n(.*?)(?=^[^\s#]|\Z)", source, re.DOTALL)
    if block is None:
        raise SystemExit("Missing workflow triggers")
    return set(re.findall(r"(?m)^  ([\w_]+):", block.group(1)))

require_line(workflow, "workflow_dispatch:")
release = workflows.joinpath("release.yml").read_text()
if "ci-full" in release:
    raise SystemExit("release.yml must not call or wait for full verification")
if events(workflow) != {"schedule", "workflow_dispatch"}:
    raise SystemExit("Full native verification must run only daily or manually")
require_line(workflow, "- cron: '17 20 * * *'")
# A manual run must not cancel the scheduled run on the same ref.
require_line(workflow, "group: ci-ios-full-${{ github.ref }}-${{ github.event_name }}")
# One job compiles the app and its tests, with no Simulator. Only a cold
# manual benchmark skips the compiler object cache.
app_build = job("app-build")
if "HEELER_CI_DISABLE_COMPILATION_CACHE" in app_build:
    raise SystemExit("The shared app build must not disable the compilation cache")
require_line(app_build, '-- make build-ci-app 2>&1 | tee "$HEELER_CI_BUILD_EVIDENCE_DIR/build.log"')
if re.search(r"\bmake test-ci-|\bsimctl\b|verify-ci-ios-evidence", app_build):
    raise SystemExit("The shared app build must not boot a Simulator, run tests or claim evidence")
restore = re.search(r"(?m)^      - name: Restore app compilation cache\n(.*?)(?=^      - |\Z)", app_build, re.DOTALL)
if restore is None:
    raise SystemExit("Missing app compilation cache restore")
require_line(restore.group(1), "if: ${{ github.event_name != 'workflow_dispatch' || inputs.cache_mode == 'warm' }}")
# An archive of a build its deadline ended fills the next runner's disk.
save = re.search(r"(?m)^      - name: Save app compilation cache\n(.*?)(?=^      - |\Z)", app_build, re.DOTALL)
if save is None or "if: ${{ success() && " not in save.group(1):
    raise SystemExit("The app compilation cache must be saved only after a finished build")
# The app workers wait for that build, test its products and compile nothing.
app_tests = job("app-tests")
require_line(app_tests, "needs: app-build")
require_line(app_build, "make pack-ci-app-products")
require_line(app_build, "name: ios-ci-app-products-${{ github.run_id }}")
require_line(app_build, "path: .ci/app-products.tar.gz")
require_line(app_tests, "name: ios-ci-app-products-${{ github.run_id }}")
require_line(app_tests, "path: .ci/app-products")
require_line(app_tests, "HEELER_CI_APP_PRODUCTS_ARCHIVE: ${{ github.workspace }}/.ci/app-products/app-products.tar.gz")
if re.search(r"compilation|\bmake build-ci-|HEELER_XCODEBUILD_BUILD_TIMEOUT_SECONDS", app_tests, re.IGNORECASE):
    raise SystemExit("The app workers must not compile or carry a build deadline")
names = {
    "app-build": "App build (shared)",
    "app-tests": "App tests (${{ matrix.shard }})",
    "heelerssh-package-e2e": "HeelerSSH package E2E (iOS Simulator)",
    "build-test": "Build & test (iOS Simulator)",
}
for name, display in names.items():
    body = job(name)
    require_line(body, "name: " + display)
    if name != "build-test" and re.search(r"(?m)^    if:", body):
        raise SystemExit(f"Full verification must not skip {name}")
require_line(job("build-test"), "if: ${{ always() }}")
require_line(job("build-test"), "needs: [app-build, app-tests, heelerssh-package-e2e]")

# Full verification stays read-only, so only the listener may write.
alert = workflows.joinpath("ci-full-alert.yml").read_text()
full_name = re.search(r"(?m)^name: (.+)$", workflow).group(1)
require_line(alert, f"workflows: [{full_name}]")
require_line(alert, "if: ${{ github.event.workflow_run.event == 'schedule' && github.event.workflow_run.conclusion != 'cancelled' }}")
if re.search(r"(?m)^\s+[\w-]+: write\s*$", workflow):
    raise SystemExit("ci-full.yml must stay read-only")

def trigger_paths(source, name):
    block = re.search(r"(?m)^on:\n(.*?)(?=^[^\s#]|\Z)", source, re.DOTALL).group(1)
    if "paths-ignore:" in block:
        raise SystemExit(f"{name} must use positive paths, not paths-ignore")
    lists = []
    for event in ("pull_request", "push"):
        match = re.search(rf"(?m)^  {event}:\n(.*?)(?=^  \S|\Z)", block, re.DOTALL)
        lists.append(re.findall(r"(?m)^      - (.+)$", match.group(1)) if match else [])
    if lists[0] != lists[1]:
        raise SystemExit(f"{name} must list the same paths for pull_request and push")
    return set(lists[0])

# Each fast workflow starts only for what it compiles or executes: a
# script-only change never builds the app, and exports or the marketing site
# never spend a macOS worker. This runs on Ubuntu for every PR, so a trigger
# edit cannot slip past the workflow it changes.
fast_workflows = {
    "ci.yml": ("app-build", "Build app (tests not compiled)", {
        "Sources/**", "Packages/**", "Heeler.xcodeproj/**", "project.yml",
        "Makefile", "scripts/run-ci-background-build.py",
        "scripts/ci-compilation-cache-prefix.sh", ".github/workflows/ci.yml"}),
    "ci-scripts.yml": ("gate-scripts", "CI and VPS scripts (macOS)", {
        "scripts/**", "Makefile", ".github/workflows/ci-full.yml",
        ".github/workflows/ci-scripts.yml"}),
    "ci-package.yml": ("package-build", "Build HeelerSSH and tests (not run)", {
        "Packages/HeelerSSH/**", ".github/workflows/ci-package.yml"}),
}
sources = {}
for name, (job_id, display, expected) in fast_workflows.items():
    source = sources[name] = workflows.joinpath(name).read_text()
    if events(source) != {"workflow_dispatch", "pull_request", "push"}:
        raise SystemExit(f"{name} must run on PR/push and support manual runs")
    if re.findall(r"(?m)^  ([\w-]+):", source.split("\njobs:\n", 1)[1]) != [job_id]:
        raise SystemExit(f"{name} must have the single job {job_id}")
    require_line(job(job_id, source), "name: " + display)
    paths = trigger_paths(source, name)
    if paths != expected:
        raise SystemExit(f"{name} trigger paths differ: missing {sorted(expected - paths)}, extra {sorted(paths - expected)}")
    if any("name: " + full in source for full in names.values()):
        raise SystemExit("Only full verification may publish full coverage check names")
fast = sources["ci.yml"]
if ("ios-ci-evidence-" in fast or "verify-ci-ios-evidence" in fast or "simctl" in fast
        or re.search(r"\bmake test-ci-(?:app|package)\b", fast)):
    raise SystemExit("The fast build must not execute or claim native tests")
# A PR waits for the app alone; the test bundle compiles in full verification.
if re.findall(r"\bmake (build-[\w-]+)", fast) != ["build-ci-app-only"]:
    raise SystemExit("The fast build must compile the app without its test bundle")
if re.findall(r"(?m)^\s+run: (.+)$", sources["ci-scripts.yml"]) != [
        "scripts/test-vps-ssh-access-scripts.sh", "make test-ci-watchdog",
        "make test-ci-guards", "make test-ci-workflow-contracts"]:
    raise SystemExit("Script self-tests must not build the app or run native tests")
if re.findall(r"(?m)^\s+run: (.+)$", sources["ci-package.yml"]) != ["make build-ci-package"]:
    raise SystemExit("The HeelerSSH build must only compile the package and its tests")

# Compare whole tokens: the checkout path may contain words such as `test`.
actions = {"build", "build-for-testing", "test", "test-without-building", "analyze", "archive", "clean"}
for target, scheme, action in [
        ("build-ci-app-only", "Heeler", "build"),
        ("build-ci-app", "Heeler", "build-for-testing"),
        ("build-ci-package", "HeelerSSH", "build-for-testing")]:
    command = subprocess.check_output(
        ["make", "--no-print-directory", "-n", target],
        cwd=workflows.resolve().parents[1], text=True)
    tokens = shlex.split(command.replace("\\\n", " "))
    if any(Path(token).name in {"xcodegen", "simctl"} for token in tokens) or "xcodebuild" not in tokens:
        raise SystemExit(f"{target} must run xcodebuild on the committed project without a Simulator")
    tokens = tokens[tokens.index("xcodebuild"):]
    if [token for token in tokens if token in actions] != [action]:
        raise SystemExit(f"{target} must run only xcodebuild {action} on {scheme}")
    if "-scheme" not in tokens or tokens[tokens.index("-scheme") + 1] != scheme:
        raise SystemExit(f"{target} must build the {scheme} scheme")
    if "-destination" not in tokens or tokens[tokens.index("-destination") + 1] != "generic/platform=iOS Simulator":
        raise SystemExit(f"{target} must not need a booted Simulator destination")
    if "-arch" in tokens:
        raise SystemExit("The generic destination conflicts with -arch; use the ARCHS build setting")
# `xcodebuild build` compiles what the scheme's Build action lists, so a test
# target added there would return to every PR.
scheme = workflows.resolve().parents[1].joinpath(
    "Heeler.xcodeproj/xcshareddata/xcschemes/Heeler.xcscheme").read_text()
built = re.search(r"<BuildAction\b.*?</BuildAction>", scheme, re.DOTALL).group(0)
if re.findall(r'BlueprintName = "([^"]+)"', built) != ["Heeler"]:
    raise SystemExit("The Heeler scheme's Build action must list only the app")
# The app workers unpack exactly this: build-ci-app's Build/Products, whole.
root = workflows.resolve().parents[1]
pack = shlex.split(subprocess.check_output(
    ["make", "--no-print-directory", "-n", "pack-ci-app-products"], cwd=root, text=True))
if pack != ["tar", "-czf", f"{root}/.ci/app-products.tar.gz", "-C", f"{root}/.ci/app-derived", "Build/Products"]:
    raise SystemExit("pack-ci-app-products must archive build-ci-app's Build/Products for the app workers")

# Every macOS job builds with the release archive's runner and Xcode, so CI
# never checks a toolchain that nothing ships with, and every Simulator lane
# tests the same pinned iOS runtime (#634).
def settings(body, key):
    return re.findall(rf"(?m)^\s+{re.escape(key)}: (.+)$", body)

archive = job("archive", release)
toolchain = (settings(archive, "runs-on"), settings(archive, "DEVELOPER_DIR"))
if len(toolchain[0]) != 1 or len(toolchain[1]) != 1:
    raise SystemExit("The release archive must name one runner and one DEVELOPER_DIR")
simulator_lanes = {}
for path in sorted(workflows.glob("*.yml")):
    source = path.read_text()
    sections = re.split(r"(?m)^jobs:[ \t]*(?:#.*)?\n", source, maxsplit=1)
    if len(sections) == 1:
        if re.search(r"(?m)^jobs:", source):
            raise SystemExit(f"{path.name} has a jobs key this check cannot read")
        continue
    jobs = sections[1]
    headers = re.findall(r"(?m)^  [^\s#][^\n]*$", jobs)
    parsed = list(re.finditer(r"(?m)^  ([\w-]+):[ \t]*(?:#[^\n]*)?\n(.*?)(?=^  [^\s#]|\Z)", jobs, re.DOTALL))
    if not parsed or len(parsed) != len(headers):
        raise SystemExit(f"{path.name} has jobs this check cannot read")
    for match in parsed:
        name, body = f"{path.name} {match.group(1)}", match.group(2)
        runner = settings(body, "runs-on")
        if len(runner) != 1:
            raise SystemExit(f"{name} must name one runner")
        if runner[0].startswith("ubuntu-"):
            continue
        if (runner, settings(body, "DEVELOPER_DIR")) != toolchain:
            raise SystemExit(f"{name} must use the release archive's runner and Xcode")
        if re.search(r"\bmake test-ci-(?:app|package)\b", body):
            simulator_lanes[name] = settings(body, "HEELER_CI_SIMULATOR_OS")
if set(simulator_lanes) != {"ci-full.yml app-tests", "ci-full.yml heelerssh-package-e2e"}:
    raise SystemExit(f"Unexpected Simulator lanes: {sorted(simulator_lanes)}")
runtimes = {tuple(values) for values in simulator_lanes.values()}
if len(runtimes) != 1 or len(next(iter(runtimes))) != 1:
    raise SystemExit("Every Simulator lane must pin the same HEELER_CI_SIMULATOR_OS")
runner_script = (workflows.parent.parent / "scripts/run-ci-ios-tests.sh").read_text()
if not re.search(r"(?m)^ci_simulator_os=\"\$\{HEELER_CI_SIMULATOR_OS:-\}\"$", runner_script):
    raise SystemExit("run-ci-ios-tests.sh must read the pinned runtime from HEELER_CI_SIMULATOR_OS")
print("Passed fast build, full verification, scheduled alert and toolchain contracts.")
PYWORKFLOW
