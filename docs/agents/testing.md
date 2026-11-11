# Testing and build routing

Use `make help` for available targets. Choose the lane from the changed owner
in [navigation.md](navigation.md), and record the candidate and executed-test
counts in [the review handoff](review-handoff.md). A successful test command that
selected no tests is a failed verification. Build-only success establishes
compilation, not behavior or test coverage.

## Fast build and full verification

The [fast iOS build](../../.github/workflows/ci.yml) runs on PRs and pushes to
`main` that change app, test, package, project or shared-vector paths, the
Makefile, or the two scripts it executes. It compiles the committed app,
extensions and HeelerTests bundle once with `make build-ci-app`
(`build-for-testing` against the generic Simulator SDK, stable paths and
compiler caching), so an app change that breaks test sources fails before
merge. It never boots a Simulator or runs a test. That build compiles
HeelerSSH only as a library, so [the HeelerSSH build](../../.github/workflows/ci-package.yml)
runs `make build-ci-package` (the package and its tests, not run) when
`Packages/HeelerSSH` changes. Other script and `ci-full.yml` changes skip both
builds; [the script self-tests](../../.github/workflows/ci-scripts.yml) run
`scripts/test-vps-ssh-access-scripts.sh`, `make test-ci-watchdog`,
`make test-ci-guards` and `make test-ci-diagnostic-controls` on macOS, under
the `/bin/bash` 3.2 that full verification executes.
`make test-ci-diagnostic-controls`, which Agent tooling runs on Ubuntu for
every PR, pins each fast workflow's trigger paths and commands.
Documentation-only edits get the Ubuntu tooling checks; Node and site checks
keep their own path filters.

Every macOS job runs on the `xcode-27` runner with Xcode 27.2, the toolchain
that archives releases, and `make test-ci-diagnostic-controls` fails when one
leaves it. The full and diagnostic lanes test an iPhone 17 on the iOS 27.2
runtime, which `HEELER_CI_SIMULATOR_OS` pins because the image also has one
on iOS 27.0. Without it, a local `make test-ci-app` or `make test-ci-package`
takes any available iPhone 17; pin one with `SIMULATOR_UDID=<UDID>`.

Run focused behavior tests for the feature being changed. The
[full native workflow](../../.github/workflows/ci-full.yml) retains all app,
UI, real-SSH and weak-network tests, package E2E and coverage checks. It runs
daily on the latest `main` commit at 20:17 UTC (04:17 UTC+8), using the sharded
layout and warm caches. The schedule takes effect only after the workflow is
merged into the default branch; GitHub may delay its start under load. PRs and
pushes retain fast feedback without starting this full native workflow.
A failed scheduled run opens or comments on the issue "Scheduled full iOS
verification is failing" ([the alert workflow](../../.github/workflows/ci-full-alert.yml));
the next passing scheduled run closes it. Run it manually for broader
acceptance of a candidate branch; manual runs default to warm caches, and
`cache_mode=cold` measures a first build. Releases neither run it nor wait
for it ([ADR 0039](../adr/0039-release-builds-tag-main-without-tests.md)). A
scheduled run or fast build cannot substitute for verifying a different
candidate.

```sh
gh workflow run ci-full.yml --ref <candidate-branch>
```

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
| App and test compilation | `make build-ci-app` | Committed app, extensions and test bundle compile; no tests executed |
| HeelerSSH and test compilation | `make build-ci-package` | HeelerSSH and its tests compile for the Simulator SDK; no tests executed |
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
full verification run, fails when the committed HeelerTests target omits a Swift
file under `Tests/HeelerTests` or the shared scheme skips tests.

## CI evidence constraints

Full verification records every registered method and parameterized argument case
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

The manual [iOS CI diagnostics workflow](../../.github/workflows/ci-diagnostics.yml) builds once and repeats the original TOFU, staging recovery, weak-network Changes, or diff-layout assertions with fresh per-round state. `staging` selects the whole nine-method suite to retain preceding window lifecycles and the failed-owner cleanup regression; `staging-method` isolates the recovery method. `layout` selects all eight `FileDiffLayoutViewTests` methods in the ordinary shard and repeats the topmost-line method with a fresh window and settings each round. Defaults are 50 SSH, 20 staging or layout, and 10 weak rounds. `all` selects only SSH, staging, and weak; layout requires an explicit selection and adds no work to the fast build, full verification or the existing `all` diagnostic.

Repeated weak and layout diagnostics have a 30-minute outer deadlock limit. Full verification retains the weak suite's two-minute limit and the layout suite's one-minute limit; every weak read still asserts its original 10-second deadline (the large Changes reads on the time the link and transport add, excluding the Host's own run of the script, which has a loose 30-second limit), and both layout setup waits retain eight seconds. Diagnostic artifacts capture the selected test counts, completion markers and fixture logs; they never establish complete coverage or replace full verification.

```sh
gh workflow run ci-diagnostics.yml --ref <candidate-branch> -f target=all
gh workflow run ci-diagnostics.yml --ref <candidate-branch> -f target=layout -f iterations=20
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
whole settling interval, on display frames. Keyboard-notification samples read
the model inset before anything renders and do not count, and each gap between
frames credits at most two frame intervals, so a stall that stops the display
link cannot supply the interval: the first frames after one can still show the
old layout. Time before an inset change does not establish stability afterward
either. The wait also requires the Agent switcher to have moved as far as the
inset, so a slow render waits and a switcher that never follows times out. At
10-20 frames a second the stable tail takes about a second, inside the
`eventually` budget. The controlled-timestamp regression covers the gap and the
stall; the hosted handoff test still checks the actual geometry, responder
ownership, draft, and one-point movement tolerance, and its failures list each
sample's time and source.

### Keyboard inset timers

`TerminalKeyboardInset` sleeps through two injected sleepers: `sleep` for the
keyboard's own timing (presentation coalesce, dismissal confirmation, tools-dock
exit) and `handoffSleep` for the responder-handoff guards. Unit tests pass
`ManualClock.parkedSleep(for:)` to both and move time with `clock.pass(_:)`,
which waits a bounded time for that deadline to be armed before advancing to
it. `advance` reports how many sleepers woke, so a deadline that must not fire
is asserted as `advance(...) == 0`; pick advances that keep two armed deadlines
from coinciding, or `parks(for:)` can match the wrong one. A test that needs
UIKit's real notification cadence passes only `handoffSleep`, so the guards
hold while presentations coalesce in real time. Hosted handoff tests keep both
real. The hosted transfer passes a recording `handoffSleep` that still sleeps
for real, and checks that each destination's acceptance re-armed the switch's
guard. `HeelerTerminalView` waits out its own keyboard leash through
`keyboardTransitionSleep` the same way: a test holds the leash on a
`ManualClock` it never moves, or passes the leash at the step where it should
run out, instead of stretching or shrinking the delay.

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

### herdr-core Hosts

A herdr-core Host connects over one framed link: a read-only locator exec, then, on Unix, a direct-streamlocal channel under the events slot, or, on native Windows, an exec of `herdr-core connect` once the probe finds the pipe. Only the user's confirmed Start starts a core on purpose, on Linux; on Windows a core that stops between the probe and `connect` is started by `connect` (ADR 0031).

Never start a core on a developer machine. `hc` and every core subcommand but `server stop` can start one with the caller's environment, so on a developer Mac never run `hc` at all, and run `herdr-core` only for `--version`, `--help` and the fixture's explicit start below. Answer questions about the core from its source at the pinned tag.

`HerdrCoreStartTests` covers the Start command and the parse of its result, `HostOnboardingCoreStartTests` covers what a Host offers and what the scripted exec sees, and `scripts/test-herdr-core-start.py` (in `make test-tools`) runs the command through real bash, zsh and fish against a fake core. The fixture is macOS, so a Simulator reads the macOS instructions. To drive the Linux Start against it, put a `uname` that prints `Linux` in the fixture root's `bin`, whose path comes first on an exec: the confirmed Start then runs a real core in the fixture, through the account's login shell over its sshd. This proves the UI and the command, not Linux; `AllowStreamLocalForwarding no` in the fixture's `sshd.conf`, with a HUP, gives the refused channel.

`ServerKindDetectionTests` covers the detection script and what it parses, and `scripts/test-server-kind-detection.py` (in `make test-tools`) runs that script through a real shell. `HostOnboardingStoreTests` covers the confirmation through `ScriptedCoreHost`, whose `herdrRead` scripts the Herdr TUI half. Every build offers herdr-core when adding a Host by hand. The fixture's `herdr` tripwire logs detection's one read, `session list --json`, so its `legacyLog` is not empty after a detection; `hc` stays uncalled.

`HerdrCoreFrameTests`, `HerdrCoreLinkTests`, `HerdrCoreServerInfoTests` and `HerdrCoreEventCursorTests` cover the framed building blocks through `FakeCoreSocket`, a duplex API channel on the manual clock, and `plugin/test-vectors/herdr-core-frames-v1.json`. `HerdrCoreLocatorTests` covers the locator's script and output and reads the core-session vector, `plugin/test-vectors/herdr-core-session-names-v1.json`; `scripts/test-herdr-core-locator.py` runs the real script in each POSIX shell against a fake home. `HerdrCoreSSHTransportTests` and the core cases of `HostOnboardingStoreTests` run the real transport over `ScriptedCoreHost`, a scripted locator exec and fake socket.

The frame vectors are captured: with a fixture started, `scripts/fixtures/herdr-core-capture-scenario.py` drives inert Terminals, and rewrites the file with scrubbed bytes. Every case names its capture, and a case the run did not capture refuses the whole file, so delete a retired case first. Read the output before committing it. `scripts/lab/herdr-core-capture.py` listens on a socket path it is given, starts nothing and never attaches, for a core you started yourself.

`HerdrCoreWindowsLocatorTests`, `HerdrCoreWindowsTransportTests` and `HerdrCoreWindowsConsoleTests` cover a native Windows core Host: the probe's text and what its output means, the real transport and link with `ScriptedCoreHost(windowsLocator:)` scripting the probe and `FakeCoreSocket` behind the exec's bootstrap, and `ConsoleStore` over Windows directories and capabilities. There is no Windows lane and no new real-core E2E method, so these say what the app does with what the owner's machine recorded; the steps a machine must prove are in [the native Windows checklist](../guides/native-windows-testing.md#9-connect-a-herdr-core-host). `HostProcessReaderWindowsTests`, `HerdrCoreWindowsSessionBinderTests` and `HerdrCoreWindowsChatTests` cover Chat there through the Windows read's real command and parser, with `WindowsProcessTable` printing what its script would: no PowerShell runs in them.

`HerdrCoreWindowsLaunchTests` and `HerdrCoreWindowsStagingTests` cover New Agent, New Terminal, New Workspace, discovery and `terminal.put` the same way, from `ConsoleStore` and the Composer down to the argv and the frame. No PowerShell runs in them: the launch and discovery text is checked as text, against the forms recorded in the compatibility notes. A native Windows Herdr TUI Host's refusal of uploads runs on the real `HeelerSSHTransport`, over `SSHConnection.neverConnectedForTesting`, which carries the server's banner and reaches no server.

`HerdrCoreWindowsCaptureTests` replays `plugin/test-vectors/herdr-core-frames-windows-v1.json`, a scrubbed capture from a native Windows core, taken from a Mac over an SSH exec of `herdr-core connect`. Each case's source says how it was kept, and the file's description says which hex strings are wire bytes and which are rebuilt from scrubbed JSON. It has no fixture: a new capture replaces the file by hand after reading it, and the capture script scrubs the machine it runs on, so search the output for the far end's names too.

`HerdrCoreAttachTests` checks a live terminal against the captured frames: its viewer role, DATA, CREDIT only as a consumer reports bytes, RESIZE, FOCUS, FACTS and both CLOSEs. `HerdrCoreTerminalStoreTests` runs `AttachTerminalStore`, `TerminalConnectionPool` and `AgentTerminalCache` over the real Console, Host session and link on `ScriptedCoreHost`, whose `attaches` holds each attach's channel and socket; it covers retention, hidden terminals and the first paint's modes, and a kept restart: `refuseNextAttach` and scripted `lost`, `restarted` and `finished` events show restarting, the reattach and the ended state, in the store and on the real Agent detail. Events need a rising `seq`, since the cursor drops a repeated one. The same suite shows the real Agent detail and Shell Terminal in a test window, asserts what they offer through accessibility, and reads the attach's `display` and the FACTS frames for the colors of the window's theme and the cell of its real surface. A SwiftUI `Menu`'s items exist only once it opens, so `HostedMenu` (`Support/TestWindow.swift`) opens it and reads or runs the `UIMenu` UIKit built.

`HerdrCoreHostSessionTests` runs the Host session over that real transport with the manual clock, where `ScriptedCoreHost.Core` answers `hello`, `events.subscribe`, `terminal.attach`, `server.status` and `doc.get` and `setChannel` changes what the next channel finds. `HerdrCoreConsoleProjectionTests` and `HerdrCoreConsolePlacementTests` drive `ConsoleStore` over `ScriptedCoreTransport`, which feeds real event streams from the frame vectors' scrubbed lines and fails any test that writes a document.

`HerdrCoreAgentRuleTests` drives the Agent rule from `plugin/test-vectors/herdr-core-agent-rule-v1.json`, where every case names its source. The file is `provisional` until the owner's captures on hc-lab replace or confirm its cases, so a rule change changes the file too. `HerdrCoreAgentsTests` drives the same rule through `ConsoleStore` over `ScriptedCoreTransport`: the Agents list, Agent Status and the Agent Row Layout of a core Host. `HerdrCorePinsTests` runs Pins the same way on defaults that outlive each launch: quit with `suspend()`, since `setHosts([])` is removing the Host and forgets its core id. `endLink` and `setCoreID` on the transport script a restart and a wiped core.

`HerdrCoreTurnEndTests` drives `HerdrCoreTurnState` from `plugin/test-vectors/herdr-core-turn-end-v1.json`, where every case names its source and each step says whether it ended a turn and reads Done. The file is `provisional` until the owner's captures on hc-lab confirm its cases, and the Helper's Node side reads it too, so a rule change changes the file in the same commit. `HerdrCoreDoneTests` runs Done per device through `ConsoleStore` over `ScriptedCoreTransport`: a second device is a second store with its own Host memory, and a relaunch a new one on the same defaults. An event needs a `seq` above the last, or the cursor drops it. `HerdrCoreTerminalStoreTests` holds the one that goes through the real `AgentDetailView`.

`HerdrCoreEnvironmentCheckTests` covers the leaked-environment check through the Host session on `ScriptedCoreHost` (`ProcessRead` scripts the exec, `holdProcessReads` a slow one), and `HerdrCoreEnvironmentNoticeTests` covers the copy and what reaches Host detail through `ConsoleStore`. `scripts/test-herdr-core-environment-check.py` (in `make test-tools`) runs the script through real shells against fake `/proc` trees, and against a real process on this kernel.

`HerdrCoreLaunchTests` drives New Agent and New Terminal through `ConsoleStore` and the form stores over `ScriptedCoreTransport`, which records each `terminal.run`'s exact params, and `HerdrCoreLaunchTransportTests` drives the shell lookup and the mutation dispatch through `ScriptedCoreHost`. `scripts/test-herdr-core-shell-launch.py` (in `make test-tools`) runs the launch argv and the discovery script through each real bash, zsh and fish it finds.

`HerdrCoreWorktreesTests` drives Worktree creation and removal through `ConsoleStore`, `StartAgentStore` and `WorktreeDetailStore`, with `ScriptedCoreServices` recording each git command and `ScriptedCoreTransport` each kill, so a test can read what was killed when git ran. `HerdrCoreWorktreeBuilderTests` pins the paths and the arguments. `desktopPlacement` in `HerdrCoreTransportE2ETests` runs the same commands against real git.

`HerdrCoreComposerSendTests` runs Composer Send from `AgentComposerStore` down through a real `ConsoleStore`, `AgentAttachStore`, Host session and link on `ScriptedCoreHost`, with `coreSendClock` set to a `ManualClock`, and asserts the DATA frames that reach the core. `terminal.get` waits until `answerTerminalReads`, and `untilParked(for:)` says which deadline is armed. `TerminalKeyEncoderTests` holds literal bytes, and `TerminalKeyModifiersTests.theKeyEncoderMatchesGhosttyAcrossTheSubmitGrammar()` holds the encoder against a Ghostty surface.

`HerdrCoreTransportE2ETests` runs nine methods against a real core and disposable SSH server in the transport CI shard (and the serial lane): `neverStartsACoreAndReadsNotRunning`, `helloFeaturesCoreIDAndNoHC` (which also checks the extension's `file.write`), `noLegacyFallback`, `coreRestartUnderOneConnection`, `passiveRecentRead`, `attachResizeCreditAndClose`, `launchThroughInteractiveShell`, `composerPasteThenSubmit` and `desktopPlacement`. CI restores the pinned 0.1.13 archive from a cache keyed by its SHA-256 and verifies it again before extraction. The evidence gate requires those passes before accepting their ordinary-lane skips.

The fixture, `scripts/fixtures/herdr-core-ssh.py`, owns a separate home and session and never updates or stops a user's core. It installs `herdr-core` only at `~/.local/bin`, off the exec's PATH. A core starts only by absolute path in the fixture's explicit environment, and `scripts/fixtures/herdr-core-rpc.py` drives it instead of `hc`. `hc` and `herdr` there are tripwires that log every call. For a local focused run, its `--help` describes setup, the private Simulator configuration and cleanup, from an already installed core:

```bash
python3 scripts/fixtures/herdr-core-ssh.py start --root /tmp/hc-heeler --core ~/.local/bin/herdr-core
xcrun simctl spawn <UDID> launchctl setenv HEELER_SSH_E2E_CONFIG "$(cat /tmp/hc-heeler/core-test-config)"
make test-app SIM_DESTINATION="platform=iOS Simulator,id=<UDID>" TEST_SELECTOR='HeelerTests/HerdrCoreTransportE2ETests'
xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
python3 scripts/fixtures/herdr-core-ssh.py stop --root /tmp/hc-heeler
```

`TmuxTransportE2ETests` runs twenty-seven methods against a real tmux and disposable SSH server in the transport CI shard (and the serial lane), right after the herdr-core suite and on the port its fixture held: `neverStartsAServer`, `detectionOffersAnsweringSockets`, `resolvesPathsThroughTheLoginShell`, `resolvesAgainAfterTheExecutableMoved`, `readsConnectedAndNoServerRunning`, `readsUpdateRequired`, `readsNotInstalled`, `aHostSessionWaitsForAServer`, `theInventoryLoopPrintsOnceAndThenOnlyOnChange`, `aNewWindowAndARenameReachTheConsole`, `aRestartedServerReadsAsANewInstance`, `aVariableSetInTheGlobalAndSessionEnvironmentIsFoundByName`, `aNewAgentLeavesTheCurrentWindowAndEndsWhenItExits`, `aNewTerminalOpensTheUsersShell`, `aNewWorkspaceUsesTheTypedNameOrTmuxNumbering`, `linuxStartsAServerThroughTheLoginShell`, `macosSaysToStartTmuxOnTheMac`, `renameAndCloseEndWhatTheyName`, `anAttachWatchesAPaneThroughASessionOfItsOwn`, `aPausedPaneIsPaintedAgain`, `aWindowOnlyHeelersSessionHoldsIsClosed`, `aPaneOnItsAlternateScreenOpensWithBothScreensAndItsModes`, `keysTypedIntoAnAttachReachTheProgramAsMeasured`, `textAndAPasteTypedIntoAnAttachArriveExactly`, `aShownPaneFitsTheDeviceAndRespectsADesktopCeiling`, `sizingAPaneLeavesOtherWindowsUntouched` and `hidingARetainedAttachHandsTheWindowBackAndShowingTakesItAgain`. `theInventoryLoopPrintsOnceAndThenOnlyOnChange` and the two after it follow the inventory loop (ADR 0043): the first counts what one loop prints on a connection whose session slots it reads, and the other two drive `ConsoleStore` over the fixture. `aVariableSetInTheGlobalAndSessionEnvironmentIsFoundByName` plants `CLAUDECODE` in the global environment and `CODEX_THREAD_ID` on the session, and checks the Console's leaked-environment notice finds those names and none of the values. The four after them watch a Pane through its own control client (ADR 0043, in `TmuxAttachE2ETests.swift`): the watched Pane is `tail -f` of a file the test appends to, a pause is `refresh-client -A '<pane>:pause'` aimed at Heeler's client, and the fourth opens the Pane through `ConsoleStore` into a real `TerminalScreenView`. The next two type into a Pane through an Attach: its program is a `/bin/sh` probe that reads its terminal raw into a file, and what it read must equal `plugin/test-vectors/tmux-input-v1.json`'s reads for the fixture's tmux (3.7b's for a version it does not hold), under `extended-keys off` and under `on` with modifyOtherKeys 2, then text and a bracketed paste byte for byte. The last three attach a stand-in desktop terminal over a real PTY to check per-window sizing (`refresh-client -C @<window>:<cols>x<rows>`), split scaling and correction without zooming, the smaller desktop client's ceiling and blank remainder in `TerminalScreenView`, the untouched windows across `window-size` and `aggressive-resize` modes and with no desktop client, and the `ignore-size` hand-back and take-back while retained. A window they start is given as two words, which tmux runs itself, so the account's shell is not what holds the pane's foreground, and an agent there is `cat` under a link named for it. CI links Homebrew's tmux, which the workflow installs for those shards, and the test script stops before the build on a machine with none (`HEELER_CI_TMUX` names one elsewhere). The evidence gate requires those passes before accepting their ordinary-lane skips. An old tmux is a stand-in script that prints `tmux 3.2a`: no CI machine has a real one. The six launch methods drive New Agent, New Terminal, New Workspace, rename and close through `ConsoleStore`. New Agent's stand-in is a shell script named `claude` that stays in the foreground, since `cat` exits on `--session-id`, and the Console's workspace order is the order `list-panes` prints. `aNewAgentLeavesTheCurrentWindowAndEndsWhenItExits` also checks that the launch passes `--settings`, that Heeler's Claude Code hook script and the stored tmux paths sit where the Helper's `locate` script puts the fixture's data home, and that Host detail's flow adds the hooks to the fixture HOME's default root and removes them again byte for byte. `linuxStartsAServerThroughTheLoginShell` puts a `uname` that prints `Linux` in the fixture root's `bin`, and the server it starts reports the login shell's `TMUX_TMPDIR`.

`TmuxInventoryLoopTests` covers the loop's script and its reader, with `TmuxLoopText` writing what a loop prints, and `scripts/test-tmux-inventory-loop.py` (in `make test-tools`) runs the script through each POSIX shell on the machine against a real tmux on a private `-S` socket (`HEELER_TEST_TMUX` names another tmux; it skips where there is none). `TmuxAgentRuleTests` and `TmuxOrganizationTests` cover the pure Agent rule and the rows. `plugin/test/claude-code-hook-tmux.test.js` runs Heeler's Claude Code hook script as Claude Code would, under a temporary `HOME`, against a real tmux on a private `-S` socket: the `@heeler-status` vector's writes in every POSIX shell on the machine, the blocked hold, `@heeler-session`, the foreground and `TMUX` gates, and parallel hooks. Its tmux suite skips only outside CI, on a machine with no tmux. `ClaudeCodeHooksTests` covers the settings edit over exact bytes, and `ClaudeCodeHooksFlowTests` Host detail's flow over `InMemoryHostFiles`; `TmuxClaudeCodeHooksTests` runs the placement script through a real `/bin/sh` into a temporary folder. `ScriptedTmuxHost` is the scripted tmux transport: it answers the probe and prints a loop's text from the panes a test sets (`startServer`, `stopServer`, `setPanes`, `changePanes`, `failNextLoop`, `breakLoops`, `setGlobalEnvironment`, `setSessionEnvironment`, `failShowEnvironment`), under the real `TmuxSSHTransport`, so `TmuxSSHTransportTests` reads the stream, `TmuxEnvironmentTests` keeps names only, `TmuxEnvironmentConsoleTests` drives the leaked-environment notice, and `TmuxInventoryConsoleTests` drives `ConsoleStore` on defaults that outlive a launch: rows and order, shared windows, Heeler's own sessions, the Agent rule, and Pins across a new server instance.

The fixture, `scripts/fixtures/tmux-ssh.py`, owns a separate home and never reaches, starts or stops a tmux server of the user's. The account's login shell files (bash, zsh, fish and sh) put tmux on `PATH` from `~/.tmux-fixture/bin` and set `TMUX_TMPDIR` to `<root>/t`, so every server, `default` included, lives in `<root>/t/tmux-<uid>`. The exec itself has no tmux on `PATH` and another `TMUX_TMPDIR`, `<root>/x`, so a login shell that gave up still names a directory inside the root. `start` asks both through its own sshd and refuses to run unless they resolve there, and `stop` ends only the servers on sockets in those two directories, each by its `-S` path. Tests start their servers through [TmuxSSHFixture](../../Tests/HeelerTests/Support/TmuxSSHFixture.swift), whose `with` clears the fixture before and after each test; later tmux suites reuse both. For a local focused run, its `--help` describes setup, the private Simulator configuration and cleanup:

```bash
python3 scripts/fixtures/tmux-ssh.py start --root /tmp/ht-heeler --tmux "$(command -v tmux)"
xcrun simctl spawn <UDID> launchctl setenv HEELER_SSH_E2E_CONFIG "$(cat /tmp/ht-heeler/tmux-test-config)"
make test-app SIM_DESTINATION="platform=iOS Simulator,id=<UDID>" TEST_SELECTOR='HeelerTests/TmuxTransportE2ETests'
xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
python3 scripts/fixtures/tmux-ssh.py stop --root /tmp/ht-heeler
```

Native fixture success on macOS and the Linux lab check are separate evidence. `make verify-core-linux-host` is the scripted hc-lab check: it runs the same nine methods there, then checks the core's units, linger, socket and captured frames, with its cleanup; [the lab checklist](../guides/herdr-core-testing.md) has its setup and safety rules.

The Host Helper's Swift tests run through `ScriptedHelperHost`, an in-memory Host that acts on each script's `step`, so they pin what is asked and in what order but no shell text. `scripts/test-host-helper-scripts.py` (in `make test-tools`) runs the same scripts through every POSIX shell on the machine with a fake `uname`, `systemctl`, `loginctl`, `launchctl` and `node`, and a real Node.js for the step that finds the extension folders. `plugin/test/helper-usage.test.js` runs the service's record and Agent directories against a fake core and a real process, and the Helper's Usage query and worker from a bare copy, with a fake program for each harness. `plugin/test/helper-extensions.test.js` loads a bare copy of the Pi and Oh My Pi extension, with a fake program and terminal socket; a Pi package placed beside the copy stands in for Pi's loader. `LaunchctlPrintParserTests` and `HostHelperMacOSTests` read the spike's real `launchctl print` outputs in `plugin/test/fixtures/launchctl/`. Neither reaches a real systemd or launchd: restart, linger and start-limit behaviour, and everything of a real Mac's, are the [lab checklist](../guides/herdr-core-testing.md)'s. Run `node scripts/generate-host-helper-manifest.mjs` after any change under `plugin/helper` or to a `plugin/src` file it mirrors, because `plugin/test/helper-closure.test.js` fails on a stale manifest.

`HostHelperNotificationsTests` runs a core Host's registration, seen marks, banners and Live Activity through the real `ConsoleStore` and `NotificationPreferencesStore`, with `ScriptedCoreTransport(helper:)` lending a `ScriptedHelperHost` for the Helper's files. `plugin/test/helper-notifications.test.js` and `helper-activity.test.js` run the Helper's side against the fake core and a fake relay on real sockets, decrypting each push with its device's key. Both sides read `plugin/test-vectors/herdr-core-seen-mark-v1.json`; `notification-payload-v1.json` holds the Error case the Helper seals and the app renders, and `live-activity-content-v1.json` holds an inventory with an Error Agent, which `activity-state.test.js`, `helper-activity.test.js` and `AgentActivityContentBuilderTests` all build.

The Helper's core connection is tested in Node against `plugin/test/support/fake-core.js`, a real Unix socket that answers with the captured bytes of `plugin/test-vectors/herdr-core-frames-v1.json` and records each connection's bytes and credit (`helper-core-frames`, `-socket`, `-client`, `-follower`). `helper-core-process.test.js` runs the real `main.js` from a bare copy with `hc`, `herdr-core` and `herdr` on its `PATH` as tripwires. `node --test` also runs the fake's own file, which defines no tests, and counts it as one passing test. None of them reaches a real core or systemd.

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
