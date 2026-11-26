# Testing and build routing

Use `make help` for available targets. Choose the lane from the changed owner
in [navigation.md](navigation.md), and record the candidate and executed-test
counts in [the review handoff](review-handoff.md). A successful test command that
selected no tests is a failed verification. Build-only success establishes
compilation, not behavior or test coverage.

## Fast build and full verification

[CI](../../.github/workflows/ci.yml) runs on pull requests and on `main` pushes
that change iOS build inputs:
- On Ubuntu, every pull request checks commit/PR attribution, documentation
  links (`make check-agent-docs`), test membership (`make check-test-membership`),
  localizations (`scripts/check-localizations.py`), and wire-type codegen drift,
  and runs `plugin` or `relay` Node tests when their directories change.
- On `xcode-27` (Xcode 27.2), changes to iOS inputs compile the committed app
  and extensions (`make build-ci-app-only` against the generic Simulator SDK with
  compiler caching), and also compile `HeelerSSH` tests (`make build-ci-package`)
  when `Packages/HeelerSSH` changes, without booting a Simulator. Before merge,
  `HeelerTests` compiles only in the focused tests you run, so run them after an
  app change that renames or removes what tests call.

The [full native workflow](../../.github/workflows/ci-full.yml) runs daily on
`main` at 20:17 UTC (04:17 UTC+8) and on manual dispatch across four `xcode-27`
runners: `app-build` compiles and packs the app/tests (`make build-ci-app`) and
`HeelerSSH` tests (`make build-ci-package`) once, and three shards (`ordinary`,
`session-weak`, and `transport`) unpack those products onto iOS 27.2 `iPhone 17`
Simulators via [run-ci-ios-tests.sh](../../scripts/run-ci-ios-tests.sh) using
unprivileged loopback `sshd`, `herdr-core`, `tmux`, and weak-network fixtures.
Releases neither run it nor wait for it
([ADR 0039](../adr/0039-release-builds-tag-main-without-tests.md)). A scheduled
run or fast build cannot substitute for verifying a different candidate.

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
preparation, so a live suite that reads labels from a window it hosts can miss
SwiftUI labels on a clean Simulator (#339).

`HeelerTests` hosts no real UI. A test there creates no view, view controller
or window, whether directly, through a helper, or through an app view factory
such as `TerminalScreenView.makeConfiguredTerminal`. Test the store, parser or
presentation value behind a screen, and check the screen itself in the
Simulator with [the UI runbook](simulator-ui.md). The hosted suites were
removed to simplify CI; add one back only when the maintainer asks for it.

## Opt-in live suites

`Tests/HeelerLiveTests` is a separate target and scheme, `HeelerLiveTests`,
for suites that run against a real server the operator owns. They are not
members of `HeelerTests`, so `make test`, the `test-ci-*` lanes and every CI
workflow never select them, and the CI coverage contract never counts them.
Each suite reads its configuration from the Simulator's launchd environment
and fails rather than skips when selected without it.

| Suite | Gate | Needs |
| --- | --- | --- |
| `AgentTitleRenameLiveTests` | `HEELER_TITLE_RENAME_CONFIG`, base64 JSON | A loopback SSH fixture and disposable Agents ([contract](../prototypes/title-rename/README.md)) |
| `AmpChatLiveTests` | `HEELER_AMP_CHAT_LAB`, path to private fixture JSON | Two disposable Amp terminals on a loopback Herdr TUI Host, using separate private threads. Installs the plugin in their isolated configuration and sends one text prompt. Reload the first terminal's plugins after installation. |
| `AgyModelSwitchLiveTests` | `HEELER_AGY_MODEL_LIVE_CONFIG`, JSON with `hostID`, `paneID` and optional `screenshotDir` | A connected disposable agy Agent on an isolated backend |
| `RexControlWebSocketLiveTests`, `RexInventoryLiveTests` | `HEELER_REX_LIVE_SOCKET`, the socket path | A Rex server already running on this Mac; they create nothing, except `RexInventoryLiveTests.newTerminalStartsShellsTheInventoryLists`, which creates and destroys one `heeler-lab-new-terminal` session and touches no other |
| `RexTerminalLiveTests`, `RexTerminalAttachLiveTests`, `RexTerminalInputLiveTests`, `RexTerminalSizeLiveTests`, `RexProgramStatusLiveTests`, `RexChatTypingLiveTests` | `HEELER_REX_LIVE_SOCKET` | The same server and `mkdir -p /tmp/heeler-lab-home`; each creates and destroys one `heeler-lab-` session and touches no other |
| `VolcengineSpeechLiveTests` | `HEELER_VOLCENGINE_LIVE_KEY`, a Volcengine API Key, and `HEELER_VOLCENGINE_LIVE_AUDIO`, a 16 kHz mono WAV path on this Mac | Doubao streaming speech recognition 2.0 on that key; each test is billed by the recording's length |
| `RexSSHLiveTests` | `HEELER_REX_LIVE_SSH`, base64 JSON with `host`, `port`, `refusingPort`, `username`, `deviceKeySeed`, `socketPath` and `missingSocketPath` | A disposable sshd on this Mac that allows stream-local forwarding on one port and refuses it on the other, and the running Rex server |

Set the gate, run one suite, then unset it:

```sh
xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
make test-app SCHEME=HeelerLiveTests \
  SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
  TEST_SELECTOR='HeelerLiveTests/RexInventoryLiveTests'
xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
```

Each suite's header comment states what it may create or change. Never commit
or print a configuration, key seed, session label or terminal contents. The
Rex suites print counts and booleans only; record their Rex version in
[rex-compatibility.md](rex-compatibility.md) when they inform an observation.

A Rex terminal the app shows takes its size from every other client of that
server ([ADR 0053](../adr/0053-rex-terminals-fit-the-view-that-shows-them.md)),
so opening one in the Simulator resizes it on the desktop too. Open only
terminals of `heeler-lab-` sessions there, from Terminals and from Agents
alike; reading the lists takes nothing. A Rex Agent opens the Agent detail
([ADR 0056](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md)): its
Terminal surface takes the size like any shown terminal, and its Chat surface
takes none but types into the block and lists the Host's conversations in its
picker, so keep both to lab Agents with stand-in programs. `RexConsoleTests`
runs the Console's stores against `FakeRexServer`;
`RexChatTypingLiveTests` is the live check of Chat's typing, and of its
screen read over hyperlinks and the styles Chat does not keep.

An attachment on a Rex Agent writes the file into a new
`${TMPDIR:-/tmp}/heeler.XXXXXXXX` directory on the Host and types its path
with the message, and Heeler never removes it (ADR 0005). Attach only to
`heeler-lab-` Agents with stand-in programs, note each `heeler.` directory
the stand-in received, and remove exactly those afterwards. `RexStagingTests`
covers the seam, the server-instance pin, the slots and the typing against
`ScriptedRexHost`, with a clipboard that writes nothing, and a native Windows
stage's folders and `.part` file against an in-memory SFTP. In the Simulator,
Add Image takes a picture added with `simctl addmedia`; Paste Image reads the
Simulator's pasteboard, which Simulator.app syncs with the Mac's clipboard, so
use it only with an image copied inside the Simulator. Every finished upload
also copies its Host path to that pasteboard (`SystemAttachmentClipboard`),
so with that sync on the path reaches the Mac's clipboard too.

## Lane selection

| Change | Entry point | What it establishes |
| --- | --- | --- |
| App compilation | `make build-ci-app-only` | Committed app and extensions compile; the test bundle is not compiled |
| App and test compilation | `make build-ci-app` | Committed app, extensions and test bundle compile; no tests executed |
| HeelerSSH and test compilation | `make build-ci-package` | HeelerSSH and its tests compile for the Simulator SDK; no tests executed |
| App stores and parsers | `make test-app TEST_SELECTOR='HeelerTests/<Suite>'` | Selected app behavior on the named candidate and Simulator |
| Full local app and SSH package suites | `make test` or `make test-ipad` | App tests followed by the separate HeelerSSH test plan |
| `Packages/HeelerSSH` | `make test-ci-package` | Committed-project package CI lane with disposable SSH fixtures |
| `Packages/HeelerOverlay` | `xcodebuild test -scheme HeelerOverlay` in that directory (see its README for the live suites) | Overlay nodes against the heeler-overlay-natives release it pins; not part of `make test` |
| App transport/fixture integration | `make test-ci-app SIMULATOR_UDID=<UDID>` | Committed-project app CI lane and real-SSH fixture suites |
| Test/tool runners or agent-doc contracts | `make test-tools` | Concurrent local tool tests and document checks; no iOS build |
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

## Test result constraints

`scripts/run-app-simulator-tests.py` verifies `xcresult` reports after every app
test run: a run that executed zero tests fails, and `withKnownIssue` /
`XCTExpectFailure` expected failures also fail the runner—fix the test or
disable it with a reason instead.

## Intermittent CI diagnosis

No workflow repeats a single test. To chase an intermittent failure, read the failed run's diagnostics artifact, then repeat the test locally with `make test-app TEST_SELECTOR=...`. A suite that needs the SSH fixtures runs with its whole shard: `make test-ci-app CI_APP_SHARD=transport` (or `session-weak`).

The weak-network suite has a two-minute deadlock limit, and every weak read asserts a 10-second deadline (the large Changes reads on the time the link and transport add, excluding the Host's own run of the script, which has a loose 30-second limit). `make test-weak-network-proxy` exercises propagation, bandwidth, bounded buffering and cleanup over real local TCP.

### Keyboard inset timers

`TerminalKeyboardInset` sleeps through two injected sleepers: `sleep` for the
keyboard's own timing (presentation coalesce, dismissal confirmation, tools-dock
exit) and `handoffSleep` for the responder-handoff guards. Unit tests pass
`ManualClock.parkedSleep(for:)` to both and move time with `clock.pass(_:)`,
which waits a bounded time for that deadline to be armed before advancing to
it. `advance` reports how many sleepers woke, so a deadline that must not fire
is asserted as `advance(...) == 0`; pick advances that keep two armed deadlines
from coinciding, or `parks(for:)` can match the wrong one.

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

`HerdrCoreAttachTests` checks a live terminal against the captured frames: its viewer role, DATA, CREDIT only as a consumer reports bytes, RESIZE, FOCUS, FACTS and both CLOSEs. `HerdrCoreTerminalStoreTests` runs `AttachTerminalStore`, `TerminalConnectionPool` and `AgentTerminalCache` over the real Console, Host session and link on `ScriptedCoreHost`, whose `attaches` holds each attach's channel and socket; it covers retention, hidden terminals and the first paint's modes, and a kept restart: `refuseNextAttach` and scripted `lost`, `restarted` and `finished` events show restarting, the reattach and the ended state in the store. Events need a rising `seq`, since the cursor drops a repeated one.

`HerdrCoreHostSessionTests` runs the Host session over that real transport with the manual clock, where `ScriptedCoreHost.Core` answers `hello`, `events.subscribe`, `terminal.attach`, `server.status` and `doc.get` and `setChannel` changes what the next channel finds. `HerdrCoreConsoleProjectionTests` and `HerdrCoreConsolePlacementTests` drive `ConsoleStore` over `ScriptedCoreTransport`, which feeds real event streams from the frame vectors' scrubbed lines and fails any test that writes a document.

`HerdrCoreAgentRuleTests` drives the Agent rule from `plugin/test-vectors/herdr-core-agent-rule-v1.json`, where every case names its source. The file is `provisional` until the owner's captures on hc-lab replace or confirm its cases, so a rule change changes the file too. `HerdrCoreAgentsTests` drives the same rule through `ConsoleStore` over `ScriptedCoreTransport`: the Agents list, Agent Status and the Agent Row Layout of a core Host. `HerdrCorePinsTests` runs Pins the same way on defaults that outlive each launch: quit with `suspend()`, since `setHosts([])` is removing the Host and forgets its core id. `endLink` and `setCoreID` on the transport script a restart and a wiped core.

`HerdrCoreTurnEndTests` drives `HerdrCoreTurnState` from `plugin/test-vectors/herdr-core-turn-end-v1.json`, where every case names its source and each step says whether it ended a turn and reads Done. The file is `provisional` until the owner's captures on hc-lab confirm its cases, and the Helper's Node side reads it too, so a rule change changes the file in the same commit. `HerdrCoreDoneTests` runs Done per device through `ConsoleStore` over `ScriptedCoreTransport`: a second device is a second store with its own Host memory, and a relaunch a new one on the same defaults. An event needs a `seq` above the last, or the cursor drops it. `HerdrCoreTerminalStoreTests` holds the one that goes through the real `AgentDetailView`.

`HerdrCoreEnvironmentCheckTests` covers the leaked-environment check through the Host session on `ScriptedCoreHost` (`ProcessRead` scripts the exec, `holdProcessReads` a slow one), and `HerdrCoreEnvironmentNoticeTests` covers the copy and what reaches Host detail through `ConsoleStore`. `scripts/test-herdr-core-environment-check.py` (in `make test-tools`) runs the script through real shells against fake `/proc` trees, and against a real process on this kernel.

`HerdrCoreLaunchTests` drives New Agent and New Terminal through `ConsoleStore` and the form stores over `ScriptedCoreTransport`, which records each `terminal.run`'s exact params, and `HerdrCoreLaunchTransportTests` drives the shell lookup and the mutation dispatch through `ScriptedCoreHost`. `scripts/test-herdr-core-shell-launch.py` (in `make test-tools`) runs the launch argv and the discovery script through each real bash, zsh and fish it finds.

`HerdrCoreWorktreesTests` drives Worktree creation and removal through `ConsoleStore`, `StartAgentStore` and `WorktreeDetailStore`, with `ScriptedCoreServices` recording each git command and `ScriptedCoreTransport` each kill, so a test can read what was killed when git ran. `HerdrCoreWorktreeBuilderTests` pins the paths and the arguments. `desktopPlacement` in `HerdrCoreTransportE2ETests` runs the same commands against real git.

`HerdrCoreComposerSendTests` runs Composer Send from `AgentComposerStore` down through a real `ConsoleStore`, `AgentAttachStore`, Host session and link on `ScriptedCoreHost`, with `coreSendClock` set to a `ManualClock`, and asserts the DATA frames that reach the core. `terminal.get` waits until `answerTerminalReads`, and `untilParked(for:)` says which deadline is armed. `TerminalKeyEncoderTests` holds literal bytes.

`HerdrCoreTransportE2ETests` runs nine methods against a real core and disposable SSH server in the `session-weak` CI shard (and the local `all` lane): `neverStartsACoreAndReadsNotRunning`, `helloFeaturesCoreIDAndNoHC` (which also checks the extension's `file.write`), `noLegacyFallback`, `coreRestartUnderOneConnection`, `passiveRecentRead`, `attachResizeCreditAndClose`, `launchThroughInteractiveShell`, `composerPasteThenSubmit` and `desktopPlacement`. CI restores the pinned 0.1.13 archive from a cache keyed by its SHA-256 and verifies it again before extraction.

The fixture, `scripts/fixtures/herdr-core-ssh.py`, owns a separate home and session and never updates or stops a user's core. It installs `herdr-core` only at `~/.local/bin`, off the exec's PATH. A core starts only by absolute path in the fixture's explicit environment, and `scripts/fixtures/herdr-core-rpc.py` drives it instead of `hc`. `hc` and `herdr` there are tripwires that log every call. For a local focused run, its `--help` describes setup, the private Simulator configuration and cleanup, from an already installed core:

```bash
python3 scripts/fixtures/herdr-core-ssh.py start --root /tmp/hc-heeler --core ~/.local/bin/herdr-core
xcrun simctl spawn <UDID> launchctl setenv HEELER_SSH_E2E_CONFIG "$(cat /tmp/hc-heeler/core-test-config)"
make test-app SIM_DESTINATION="platform=iOS Simulator,id=<UDID>" TEST_SELECTOR='HeelerTests/HerdrCoreTransportE2ETests'
xcrun simctl spawn <UDID> launchctl unsetenv HEELER_SSH_E2E_CONFIG
python3 scripts/fixtures/herdr-core-ssh.py stop --root /tmp/hc-heeler
```

`TmuxTransportE2ETests` runs thirty-eight methods against a real tmux and disposable SSH server in the transport CI shard (and the serial lane), right after the herdr-core suite and on the port its fixture held: `neverStartsAServer`, `detectionOffersAnsweringSockets`, `resolvesPathsThroughTheLoginShell`, `resolvesAgainAfterTheExecutableMoved`, `readsConnectedAndNoServerRunning`, `readsUpdateRequired`, `readsNotInstalled`, `aHostSessionWaitsForAServer`, `theInventoryLoopPrintsOnceAndThenOnlyOnChange`, `aNewWindowAndARenameReachTheConsole`, `aRestartedServerReadsAsANewInstance`, `aVariableSetInTheGlobalAndSessionEnvironmentIsFoundByName`, `aNewAgentLeavesTheCurrentWindowAndEndsWhenItExits`, `aNewTerminalOpensTheUsersShell`, `aNewWorkspaceUsesTheTypedNameOrTmuxNumbering`, `linuxStartsAServerThroughTheLoginShell`, `macosSaysToStartTmuxOnTheMac`, `renameAndCloseEndWhatTheyName`, `aNamedBranchChecksOutUnderHeelerAndRemovalEndsOnlyThatSession`, `anAttachWatchesAPaneThroughASessionOfItsOwn`, `aPausedPaneIsPaintedAgain`, `aWindowOnlyHeelersSessionHoldsIsClosed`, `keysTypedIntoAnAttachReachTheProgramAsMeasured`, `textAndAPasteTypedIntoAnAttachArriveExactly`, `sizingAPaneLeavesOtherWindowsUntouched`, `hidingARetainedAttachHandsTheWindowBackAndShowingTakesItAgain`, `composerSendPastesExactBytesAndOneMegabyte`, `typedTextThenStopReachThePaneInOrder`, `closingAnAttachWhileItsPaneStreamsLeavesTheServerAnswering`, `aDroppedAttachChannelLeavesTheServerAnswering`, `closingOrDroppingStreamingAttachesUnderConcurrentReadsKeepsTheServerAlive`, `textAfterTheClientExitsIsNotRunByTheShell`, `aPartialControlLineInAnyQuoteStateIsNeverExecuted`, `aPreExistingSessionWithTheAttachNameSurvives`, `aFailedAttachSetupEndsOnlyTheSessionItCreated`, `connectingCleansUpUnattachedMarkedAttachSessionsOnly`, `chatActionsLeaveWindowSizeUnchangedAndCloseTheirAttach` and `chatBinderMatchesOnlyThePanesRealTmuxServerAndReadsBackHeelerChat`. `theInventoryLoopPrintsOnceAndThenOnlyOnChange` and the two after it follow the inventory loop (ADR 0045): the first counts what one loop prints on a connection whose session slots it reads, and the other two drive `ConsoleStore` over the fixture. `aVariableSetInTheGlobalAndSessionEnvironmentIsFoundByName` plants `CLAUDECODE` in the global environment and `CODEX_THREAD_ID` on the session, and checks the Console's leaked-environment notice finds those names and none of the values. The three after them watch a Pane through its own control client (ADR 0045, in `TmuxAttachE2ETests.swift`): the watched Pane is `tail -f` of a file the test appends to, and a pause is `refresh-client -A '<pane>:pause'` aimed at Heeler's client. The next two type into a Pane through an Attach: its program is a `/bin/sh` probe that reads its terminal raw into a file, and what it read must equal `plugin/test-vectors/tmux-input-v1.json`'s reads for the fixture's tmux (3.7b's for a version it does not hold), under `extended-keys off` and under `on` with modifyOtherKeys 2, then text and a bracketed paste byte for byte. `typedTextThenStopReachThePaneInOrder` types `ab` and then Stop's Escape into a capturing Claude stand-in and checks the program reads them in that order. `closingAnAttachWhileItsPaneStreamsLeavesTheServerAnswering` and `aDroppedAttachChannelLeavesTheServerAnswering` attach to a Pane that is streaming, then close the Attach and drop its channel, and check the server still answers `list-sessions` with no `heeler-attach` client left. `textAfterTheClientExitsIsNotRunByTheShell` feeds the Attach script to `/bin/sh -s` and checks that text written after the client exits is not run; `aPartialControlLineInAnyQuoteStateIsNeverExecuted` drops the SSH channel after an unterminated single-quoted, double-quoted and unquoted control line and checks none of them run while `kill-session` still ends the Attach session; `aPreExistingSessionWithTheAttachNameSurvives` checks a pre-existing session with the generated `heeler-attach-*` name survives untouched when `new-session` rejects the duplicate; `aFailedAttachSetupEndsOnlyTheSessionItCreated` checks that when `new-session` succeeds and prints a `session_id` before a later `set-option` or `link-window` fails, that created `session_id` is ended by id (never by session name) so no unmarked or marked session leaks; `connectingCleansUpUnattachedMarkedAttachSessionsOnly` `SIGKILL`s an Attach's remote process tree so an unattached `@heeler-attach` session remains in `tmux ls`, then connects `ConsoleStore` and checks only that unattached marked leftover is ended while a live attached `@heeler-attach` session and an unattached user session named `heeler-attach-user-owned` survive. `chatActionsLeaveWindowSizeUnchangedAndCloseTheirAttach` runs Chat's `capture-pane -e -p` screen read, Send, tools key press and Stop while a desktop client holds the window under `window-size latest`, checking that the window's dimensions never change and no `heeler-attach` session remains after each action. `chatBinderMatchesOnlyThePanesRealTmuxServerAndReadsBackHeelerChat` checks that Chat's binder matches a stand-in `claude` process's real `TMUX` (`<socket>,<pid>,<session index>`) and `TMUX_PANE` only against the Pane's stored socket path and server instance, and round-trips `@heeler-chat` JSON holding quotes, braces, `;`, `#{` and a backslash through the inventory loop before `ConsoleStore` binds the Transcript and clears the superseded pick. `sizingAPaneLeavesOtherWindowsUntouched` and `hidingARetainedAttachHandsTheWindowBackAndShowingTakesItAgain` attach a stand-in desktop terminal over a real PTY to check per-window sizing (`refresh-client -C @<window>:<cols>x<rows>`), the untouched windows across `window-size` and `aggressive-resize` modes and with no desktop client, and the `ignore-size` hand-back and take-back while retained. A window they start is given as two words, which tmux runs itself, so the account's shell is not what holds the pane's foreground, and an agent there is `cat` under a link named for it. CI links Homebrew's tmux, which the workflow installs for the transport shard, and the test script stops before the build on a machine with none (`HEELER_CI_TMUX` names one elsewhere). An old tmux is a stand-in script that prints `tmux 3.2a`: no CI machine has a real one. The six launch methods drive New Agent, New Terminal, New Workspace, rename and close through `ConsoleStore`. `aNamedBranchChecksOutUnderHeelerAndRemovalEndsOnlyThatSession` checks a repository whose path contains a space out at `~/.heeler` on the branch `feature/login`, into a session numbered because that name is already taken, with `@heeler-worktree` set to the checkout on the session id. Removal ends that session's panes and the checkout, and leaves the session that only shared the name. The scripted cases, including a dirty checkout, a submodule and changes left while the panes ended, are `TmuxWorktreesTests`. New Agent's stand-in is a shell script named `claude` that stays in the foreground, since `cat` exits on `--session-id`, and the Console's workspace order is the order `list-panes` prints. `aNewAgentLeavesTheCurrentWindowAndEndsWhenItExits` also checks that the launch passes `--settings`, that Heeler's Claude Code hook script and the stored tmux paths sit where the Helper's `locate` script puts the fixture's data home, and that Host detail's flow adds the hooks to the fixture HOME's default root and removes them again byte for byte. `linuxStartsAServerThroughTheLoginShell` puts a `uname` that prints `Linux` in the fixture root's `bin`, and the server it starts reports the login shell's `TMUX_TMPDIR`.

`TmuxInventoryLoopTests` covers the loop's script and its reader, with `TmuxLoopText` writing what a loop prints, and `scripts/test-tmux-inventory-loop.py` (in `make test-tools`) runs the script through each POSIX shell on the machine against a real tmux on a private `-S` socket (`HEELER_TEST_TMUX` names another tmux; it skips where there is none). `TmuxAgentRuleTests` and `TmuxOrganizationTests` cover the pure Agent rule and the rows. `plugin/test/claude-code-hook-tmux.test.js` runs Heeler's Claude Code hook script as Claude Code would, under a temporary `HOME`, against a real tmux on a private `-S` socket: the `@heeler-status` vector's writes in every POSIX shell on the machine, the blocked hold, `@heeler-session`, the foreground and `TMUX` gates, and parallel hooks. Its tmux suite skips only outside CI, on a machine with no tmux. `ClaudeCodeHooksTests` covers the settings edit over exact bytes, and `ClaudeCodeHooksFlowTests` Host detail's flow over `InMemoryHostFiles`; `TmuxClaudeCodeHooksTests` runs the placement script through a real `/bin/sh` into a temporary folder. `ScriptedTmuxHost` is the scripted tmux transport: it answers the probe and prints a loop's text from the panes a test sets (`startServer`, `stopServer`, `setPanes`, `changePanes`, `failNextLoop`, `breakLoops`, `setGlobalEnvironment`, `setSessionEnvironment`, `failShowEnvironment`), under the real `TmuxSSHTransport`, so `TmuxSSHTransportTests` reads the stream, `TmuxEnvironmentTests` keeps names only, `TmuxEnvironmentConsoleTests` drives the leaked-environment notice, and `TmuxInventoryConsoleTests` drives `ConsoleStore` on defaults that outlive a launch: rows and order, shared windows, Heeler's own sessions, the Agent rule, and Pins across a new server instance.

The fixture, `scripts/fixtures/tmux-ssh.py`, owns a separate home and never reaches, starts or stops a tmux server of the user's. The account's shell startup files (bash's `.bash_profile` and `.bashrc`, zsh, fish and sh) put tmux on `PATH` from `~/.tmux-fixture/bin` and set `TMUX_TMPDIR` to `<root>/t`, so every server, `default` included, lives in `<root>/t/tmux-<uid>`. `.bashrc` is there because an Agent's program starts through the interactive shell (`-ic`), which in bash reads no login file. A session's `SHELL` is the account's login shell, fish on one machine and bash on a hosted macOS runner; `start --login-shell /bin/bash` names another, to run a suite locally as that runner does. The exec itself has no tmux on `PATH` and another `TMUX_TMPDIR`, `<root>/x`, so a login shell that gave up still names a directory inside the root. `start` asks both through its own sshd and refuses to run unless they resolve there, and `stop` ends only the servers on sockets in those two directories, each by its `-S` path. Tests start their servers through [TmuxSSHFixture](../../Tests/HeelerTests/Support/TmuxSSHFixture.swift), whose `with` clears the fixture before and after each test; later tmux suites reuse both. For a local focused run, its `--help` describes setup, the private Simulator configuration and cleanup:

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
provisions disposable sshd instances and rejects skips in mandatory suites.
Read `scripts/run-ci-ios-tests.sh` when changing fixture membership.

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
