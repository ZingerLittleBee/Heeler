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
| `Packages/HeelerOverlay` | `xcodebuild test -scheme HeelerOverlay` in that directory (see its README for the live suites) | Overlay nodes against the heeler-overlay-natives release it pins; not part of `make test` |
| App transport/fixture integration | `make test-ci-app SIMULATOR_UDID=<UDID>` | Committed-project app CI lane, real-SSH fixture suites, required test counts |
| Test/tool runners or agent-doc contracts | `make test-tools` | Local tool tests and document checks; no iOS build |
| CI suite/count/skip guard changes | `make test-ci-guards` | Guard behavior through supplied log fixtures; no native SSH or iOS acceptance |
| Agent documentation | `make check-agent-docs` | Document pointers and repository navigation invariants |
| Plugin or relay | `npm test` in its directory | Node behavior; no install step, Node >= 20 |
| Docs site | `pnpm install --frozen-lockfile` and the other pnpm commands in [its README](../../docs-site/README.md#commands), from `docs-site/` | Markdown pipeline tests, Astro checks, static build, and internal links |
| Landing | Its `package.json` `check` and `build` scripts | Astro checks and static build |

App `-only-testing:HeelerTests/...` selectors do not select the HeelerSSH package
plan. The standalone package runner is
`scripts/run-heelerssh-package-tests.sh`; `make test` invokes it after app tests.
For CI parity, use the appropriate `test-ci-*` target. CI does not regenerate
the Xcode project, so a regenerated local build cannot prove the committed
project is complete. `make check-test-membership`, which `make test-tools` and
the merge gate run, fails when the committed HeelerTests target omits a Swift
file under `Tests/HeelerTests` or the shared scheme skips tests.

## CI evidence constraints

The merge gate records every registered method and parameterized argument case
from each native result bundle, then requires the shards together to cover the
whole target ([the recorder](../../scripts/verify-ci-ios-evidence.py)). Two
test-writing rules follow:

- Each argument of a parameterized test needs a distinct display value.
  Result bundles group argument cases by the value Swift Testing displays, so
  `Data([1, 2, 3])` and `Data([4, 5, 6])` run as one `3 bytes` case and fail
  the shard as a duplicate execution. Use distinct values, such as byte arrays,
  or a `CustomTestStringConvertible` description.
- Evidence accepts only passed and skipped results. `withKnownIssue` and
  `XCTExpectFailure` produce expected failures, which fail both `make test-app`
  and the CI recorder; fix the test or disable it with a reason instead.

## Intermittent CI diagnosis

The manual [iOS CI diagnostics workflow](../../.github/workflows/ci-diagnostics.yml), called through the existing `ci.yml` entrypoint, builds once and repeats the original TOFU, staging recovery, weak-network Changes, or diff-layout assertions with fresh per-round state. `staging` selects the whole nine-method suite to retain preceding window lifecycles and the failed-owner cleanup regression; `staging-method` isolates the recovery method. `layout` selects all eight `FileDiffLayoutViewTests` methods in the ordinary shard and repeats the topmost-line method with a fresh window and settings each round. Defaults are 50 SSH, 20 staging or layout, and 10 weak rounds. `all` selects only SSH, staging, and weak; layout requires an explicit selection and adds no work to normal merge CI or the existing `all` diagnostic.

Repeated weak and layout diagnostics have a 30-minute outer deadlock limit. Normal merge CI retains the weak suite's two-minute limit and the layout suite's one-minute limit; every weak read still asserts its original 10-second deadline, and both layout setup waits retain eight seconds. Diagnostic artifacts capture the selected test counts, completion markers and fixture logs; they never establish complete coverage or replace the normal merge gate.

```sh
gh workflow run ci.yml --ref <candidate-branch> -f diagnostic_target=all
gh workflow run ci.yml --ref <candidate-branch> -f diagnostic_target=layout -f diagnostic_iterations=20
```

The committed-project entrypoint is `make test-ci-diagnostics` with `HEELER_CI_DIAGNOSTIC_TARGET` and optional `HEELER_CI_DIAGNOSTIC_ITERATIONS` environment variables. Counts must be integers from 1 through 100. For layout, the runner passes the count as `HEELER_DIFF_LAYOUT_ITERATIONS` and requires eight executed tests plus `[diff-layout-test] completed N iterations`. Every selected test and requested round must pass; a missing or mismatched completion marker or any skip fails the diagnostic command. Fixture and iteration variables follow a replacement Simulator during destination recovery and are cleared from the shell and current Simulator during runner cleanup. `make test-ci-diagnostic-controls` verifies the workflow isolation, source contracts and fake native-boundary execution guards without Xcode; it does not prove native layout behavior. `make test-weak-network-proxy` exercises propagation, bandwidth, bounded buffering and cleanup over real local TCP.

### Navigation surface replacement

A 60-second Shell Terminal return timeout can be a main-thread update loop,
not a slow Attach shutdown. Compare the timeout's spindump with
`TerminalAttachTests.anOutgoingSurfaceUpdateCannotReclaimTheReplacementsControls`.
It keeps the outgoing and replacement surfaces alive together: only creation
may claim their shared keyboard/scroll controls; a later outgoing update must
not steal input or invalidate both representables indefinitely.

Run that regression alongside `AgentDetailShellTerminalPushTests` with
`TEST_FLAGS='-test-iterations 20 -parallel-testing-enabled NO'` on one pinned
Simulator. Repetitions must all pass, not stop at the first success. Verify
each test's 20 `Repetition` children with `xcresulttool get test-results tests`;
the app wrapper's executed-test count counts method identities, not repetitions.
Record the candidate SHA and toolchain separately from full-lane coverage.

### Keyboard geometry sampling

`AgentDirectInputTests` requires a real software keyboard before measuring the
Composer/Direct Input handoff. A zero inset with no keyboard-show notification
is a setup failure, not evidence of a geometry regression. Record that failure
separately; do not remove the presentation precondition.

The sampling probe must observe the current inset and chrome position for the
whole settling interval. Time before an inset change, including a gap with no
samples, does not establish stability afterward. The controlled-timestamp
regression covers this gap; the hosted handoff test still checks the actual
geometry, responder ownership, draft, and one-point movement tolerance.

### Backspace hold timing

Measure the first repeated key inside the key-action callback, relative to the
press, not when the awaiting test task resumes. The callback must still occur
between 150 and 500 milliseconds. A delayed observer is a separate regression
case, not permission for late key delivery. Keep the release, cancellation, and
subsequent-tap assertions so timing fixes cannot hide a stuck repeat timer.

### SSH fixture session setup

Correlate the client's exchange timeout with the same connection in the
timestamped `sshd-modern.log`. In run
[39149165119](https://github.com/ZingerLittleBee/Heeler/actions/runs/39149165119),
public-key authentication completed before an eight-second gap between
`PAM: establishing credentials` and the user session handling its first
channel. Only 1.599 seconds remained in the response-exchange phase when the
ten-second operation expired.

The unprivileged key-only and Pairing fixtures disable PAM account/session
processing. They still authenticate real keys and enforce the forwarding
policies; the separate real-password fixture retains PAM. Do not replace this
isolation with a larger request deadline, a smaller partial-I/O payload, or
retries. The original 4 MiB request and ten-second exchange bound remain intact.

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

### herdr-core backend

A herdr-core Host connects over one framed link: a read-only locator exec, then a direct-streamlocal channel under the events slot. Only the user's confirmed Start starts a core, on Linux (ADR 0031).

`HerdrCoreStartTests` covers the Start command and the parse of its result, `HostOnboardingCoreStartTests` covers what a Host offers and what the scripted exec sees, and `scripts/test-herdr-core-start.py` (in `make test-tools`) runs the command through real bash, zsh and fish against a fake core. The fixture is macOS, so a Simulator reads the macOS instructions. To drive the Linux Start against it, put a `uname` that prints `Linux` in the fixture root's `bin`, whose path comes first on an exec: the confirmed Start then runs a real core in the fixture, through the account's login shell over its sshd. This proves the UI and the command, not Linux; `AllowStreamLocalForwarding no` in the fixture's `sshd.conf`, with a HUP, gives the refused channel.

`ServerKindDetectionTests` covers the detection script and what it parses, and `scripts/test-server-kind-detection.py` (in `make test-tools`) runs that script through a real shell. `HostOnboardingStoreTests` covers the confirmation through `ScriptedCoreHost`, whose `herdrRead` scripts the Herdr TUI half. Launch with `--offer-herdr-core-hosts` to offer herdr-core on a Simulator: `xcrun simctl launch <udid> dev.bybee.heeler --offer-herdr-core-hosts`. The fixture's `herdr` tripwire logs detection's one read, `session list --json`, so its `legacyLog` is not empty after a detection; `hc` stays uncalled.

`HerdrCoreFrameTests`, `HerdrCoreLinkTests`, `HerdrCoreServerInfoTests` and `HerdrCoreEventCursorTests` cover the framed building blocks through `FakeCoreSocket`, a duplex API channel on the manual clock, and `plugin/test-vectors/herdr-core-frames-v1.json`. `HerdrCoreLocatorTests` covers the locator's script and output and reads the core-session vector, `plugin/test-vectors/herdr-core-session-names-v1.json`; `scripts/test-herdr-core-locator.py` runs the real script in each POSIX shell against a fake home. `HerdrCoreSSHTransportTests` and the core cases of `HostOnboardingStoreTests` run the real transport over `ScriptedCoreHost`, a scripted locator exec and fake socket.

The frame vectors are captured: with a fixture started, `scripts/fixtures/herdr-core-capture-scenario.py` drives inert Terminals, and rewrites the file with scrubbed bytes. Every case names its capture, and a case the run did not capture refuses the whole file, so delete a retired case first. Read the output before committing it. `scripts/lab/herdr-core-capture.py` listens on a socket path it is given, starts nothing and never attaches, for a core you started yourself.

`HerdrCoreHostSessionTests` runs the Host session over that real transport with the manual clock, where `ScriptedCoreHost.Core` answers `hello`, `events.subscribe` and `server.status` and `setChannel` changes what the next channel finds. `HerdrCoreConsoleProjectionTests` drives `ConsoleStore` over `ScriptedCoreTransport`, which feeds real event streams from the frame vectors' scrubbed lines.

`HerdrCoreEnvironmentCheckTests` covers the leaked-environment check through the Host session on `ScriptedCoreHost` (`ProcessRead` scripts the exec, `holdProcessReads` a slow one), and `HerdrCoreEnvironmentNoticeTests` covers the copy and what reaches Host detail through `ConsoleStore`. `scripts/test-herdr-core-environment-check.py` (in `make test-tools`) runs the script through real shells against fake `/proc` trees, and against a real process on this kernel.

`HerdrCoreTransportE2ETests` runs five methods against a real core and disposable SSH server in the transport CI shard (and the serial lane): `neverStartsACoreAndReadsNotRunning`, `helloFeaturesCoreIDAndNoHC`, `noLegacyFallback`, `coreRestartUnderOneConnection` and `passiveRecentRead`. CI restores the pinned 0.1.13 archive from a cache keyed by its SHA-256 and verifies it again before extraction. The evidence gate requires those passes before accepting their ordinary-lane skips.

The fixture, `scripts/fixtures/herdr-core-ssh.py`, owns a separate home and session and never updates or stops a user's core. It installs `herdr-core` only at `~/.local/bin`, off the exec's PATH. A core starts only by absolute path in the fixture's explicit environment, and `scripts/fixtures/herdr-core-rpc.py` drives it instead of `hc`. `hc` and `herdr` there are tripwires that log every call. For a local focused run, its `--help` describes setup, the private Simulator configuration and cleanup, from an already installed core:

```bash
python3 scripts/fixtures/herdr-core-ssh.py start --root /tmp/hc-heeler --core ~/.local/bin/herdr-core
xcrun simctl spawn <UDID> launchctl setenv HEELER_SSH_E2E_CONFIG "$(cat /tmp/hc-heeler/core-test-config)"
make test-app SIM_DESTINATION="platform=iOS Simulator,id=<UDID>" TEST_SELECTOR='HeelerTests/HerdrCoreTransportE2ETests'
xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
python3 scripts/fixtures/herdr-core-ssh.py stop --root /tmp/hc-heeler
```

Native fixture success on macOS and the Linux lab check are separate evidence. `make verify-core-linux-host` runs the same five methods on hc-lab; [the lab checklist](../guides/herdr-core-testing.md) has its setup and safety rules.

The Host Helper's Swift tests run through `ScriptedHelperHost`, an in-memory Host that acts on each script's `step`, so they pin what is asked and in what order but no shell text. `scripts/test-host-helper-scripts.py` (in `make test-tools`) runs the same scripts through every POSIX shell on the machine with a fake `systemctl`, `loginctl` and `node`. Neither reaches a real systemd: restart, linger and start-limit behaviour are the [lab checklist](../guides/herdr-core-testing.md)'s. Run `node scripts/generate-host-helper-manifest.mjs` after any change under `plugin/helper`, because `plugin/test/helper-closure.test.js` fails on a stale manifest.

## Host and platform acceptance

Local real-SSH tests may skip without a configured sshd/key. The CI runner
provisions disposable sshd instances and pins counts for mandatory suites.
Read `scripts/run-ci-ios-tests.sh` when changing fixture membership or skip gates;
do not copy old counts from a research note.

For Simulator or plugin acceptance against a throwaway herdr instead of the
live server, run isolated herdr sessions, a loopback sshd, the repository
plugin, and a fake Push Relay that logs to `relay.jsonl`:

```sh
python3 scripts/isolated-herdr-backend.py start --sessions default,work --plugin --relay
python3 scripts/isolated-herdr-backend.py stop
```

Its `--help` covers `status`, `run`, and `authorize`. Isolation relies on the
app deriving the socket from the remote `$HOME`; the sshd allows streamlocal
forwarding to any socket the user can open, the live herdr included.

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
