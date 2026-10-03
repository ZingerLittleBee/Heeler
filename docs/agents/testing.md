# Testing and build routing

Use `make help` for available targets. Choose the lane from the changed owner
in [navigation.md](navigation.md), and record the candidate and executed-test
counts in [the review handoff](review-handoff.md). A successful command that
selected no tests is a failed verification.

## Focused app tests

```sh
make test-app TEST_SELECTOR='HeelerTests/ChangesStoreTests'
```

For one method, replace the suite and method with their Swift test identifiers:

```sh
make test-app TEST_SELECTOR='HeelerTests/Suite/method()'
```

`TEST_SELECTOR` is one opaque selection value, exported to the Python wrapper;
parentheses do not become shell syntax. The wrapper checks the result bundle
for executed tests and the selected identity. A missing, empty, or mismatched
result fails the command. `TEST_FLAGS` remains supported for existing callers
and additional xcodebuild flags; it is parsed by the wrapper rather than expanded
as shell command text. Prefer `TEST_SELECTOR` for a single selection.

Pin a requested Simulator and give parallel work a distinct output directory:

```sh
make test-app \
  SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
  DERIVED='build/DerivedData-changes' \
  TEST_SELECTOR='HeelerTests/ChangesStoreTests'
```

The app wrapper resolves a Simulator name once, enables the accessibility tree,
then restores only the preferences it changed. Direct `xcodebuild` skips that
preparation and can miss SwiftUI labels on a clean Simulator (#339).

## Lane selection

| Change | Entry point | What it establishes |
| --- | --- | --- |
| App stores, parsers, SwiftUI hosting | `make test-app TEST_SELECTOR='HeelerTests/<Suite>'` | Selected app behavior on the named candidate and Simulator |
| Full local app and SSH package suites | `make test` or `make test-ipad` | App tests followed by the separate HeelerSSH test plan |
| `Packages/HeelerSSH` | `make test-ci-package` | Committed-project package CI lane with disposable SSH fixtures and count gates |
| App transport/fixture integration | `make test-ci-app SIMULATOR_UDID=<UDID>` | Committed-project app CI lane, real-SSH fixture suites, required test counts |
| Test/tool runners or agent-doc contracts | `make test-tools` | Local tool tests and document checks; no iOS build |
| CI suite/count/skip guard changes | `make test-ci-guards` | Guard behavior through supplied log fixtures; no native SSH or iOS acceptance |
| Agent documentation | `make check-agent-docs` | Document pointers and repository navigation invariants |
| Plugin or relay | `npm test` in its directory | Node behavior; no install step, Node >= 20 |
| Landing | Its `package.json` `check` and `build` scripts | Astro checks and static build |

App `-only-testing:HeelerTests/...` selectors do not select the HeelerSSH package
plan. The standalone package runner is
`scripts/run-heelerssh-package-tests.sh`; `make test` invokes it after app tests.
For CI parity, use the appropriate `test-ci-*` target. CI does not regenerate
the Xcode project, so a regenerated local build cannot prove the committed
project is complete.

## Intermittent CI diagnosis

The manual [iOS CI diagnostics workflow](../../.github/workflows/ci-diagnostics.yml), called through the existing `ci.yml` entrypoint, builds once and repeats the original TOFU, staging recovery, weak-network Changes, or diff-layout assertions with fresh per-round state. `staging` selects the whole eight-method suite to retain preceding window lifecycles; `staging-method` isolates the recovery method. `layout` selects all eight `FileDiffLayoutViewTests` methods in the ordinary shard and repeats the topmost-line method with a fresh window and settings each round. Defaults are 50 SSH, 20 staging or layout, and 10 weak rounds. `all` selects only SSH, staging, and weak; layout requires an explicit selection and adds no work to normal merge CI or the existing `all` diagnostic.

Repeated weak and layout diagnostics have a 30-minute outer deadlock limit. Normal merge CI retains the weak suite's two-minute limit and the layout suite's one-minute limit; every weak read still asserts its original 10-second deadline, and both layout setup waits retain eight seconds. Diagnostic artifacts capture the selected test counts, completion markers and fixture logs; they never establish complete coverage or replace the normal merge gate.

```sh
gh workflow run ci.yml --ref <candidate-branch> -f diagnostic_target=all
gh workflow run ci.yml --ref <candidate-branch> -f diagnostic_target=layout -f diagnostic_iterations=20
```

The committed-project entrypoint is `make test-ci-diagnostics` with `HEELER_CI_DIAGNOSTIC_TARGET` and optional `HEELER_CI_DIAGNOSTIC_ITERATIONS` environment variables. Counts must be integers from 1 through 100. For layout, the runner passes the count as `HEELER_DIFF_LAYOUT_ITERATIONS` and requires eight executed tests plus `[diff-layout-test] completed N iterations`. Every selected test and requested round must pass; a missing or mismatched completion marker or any skip fails the diagnostic command. Fixture and iteration variables follow a replacement Simulator during destination recovery and are cleared from the shell and current Simulator during runner cleanup. `make test-ci-diagnostic-controls` verifies the workflow isolation, source contracts and fake native-boundary execution guards without Xcode; it does not prove native layout behavior. `make test-weak-network-proxy` exercises propagation, bandwidth, bounded buffering and cleanup over real local TCP.

## Build outputs and concurrency

`DERIVED_DEVICE` and `DERIVED_SIMULATOR` separate device and Simulator outputs.
The device build targets use the device default; app test and Simulator build
targets use the Simulator default. An explicit `DERIVED=<path>` overrides the
target default. Use a separate `DERIVED` for each concurrently built checkout or
candidate; distinct destinations alone do not isolate an Xcode build database.

Each Simulator also owns app data and accessibility preferences. Serialize tests
or interactive work on the same UDID, even with distinct DerivedData directories.
Use [simulator-ui.md](simulator-ui.md) for UUID-pinned installation and UI tools.

New sources or `project.yml` changes need `make generate` and the regenerated
`Heeler.xcodeproj` committed. Wire types are regenerated from the snapshot:

```sh
python3 scripts/generate-wire-types.py --schema scripts/herdr-schema.json
python3 scripts/generate-wire-types.py --schema scripts/herdr-schema.json --check
```

The flag-less generator queries the locally installed herdr. Generation,
`git diff --check`, parsing, and guard-fixture success are different evidence
from compilation, an executed suite, or native UI acceptance.

## Host and platform acceptance

Local real-SSH tests may skip without a configured sshd/key. The CI runner
provisions disposable sshd instances and pins counts for mandatory suites.
Read `scripts/run-ci-ios-tests.sh` when changing fixture membership or skip gates;
do not copy old counts from a research note.

For Changes reads on Linux, with Docker running:

```sh
SIMULATOR_UDID=<UDID> scripts/verify-changes-linux-host.sh
```

The runner uses the fixture in `scripts/fixtures/linux-host/` and exercises fish
and POSIX sh login accounts, then cleans up its container, image, and throwaway
key. macOS fixture success alone does not prove Linux shell behavior.

Native Windows requires [the acceptance checklist](../guides/native-windows-testing.md).
Local protocol tests and real Unix SSH tests do not establish Windows named-pipe,
DefaultShell, terminal-controller, or reboot behavior. Record each platform and
authentication mode separately.

For performance changes, distinguish parser benchmarks from Simulator UI and
physical-device measurements. Compare the same fixture, layout, destination,
and measurement method on the candidate and its baseline.
