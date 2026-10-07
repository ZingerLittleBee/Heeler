# Source map

Start with the row matching the task, then follow its state owner before reading
the concrete transport. The paths are current implementation pointers; dated
research and original ADR rationale remain evidence for their recorded versions.
Use [CONTEXT.md](../../CONTEXT.md) for vocabulary and [testing.md](testing.md) to
choose the verification lane. Update a row when moving its owner or replacing
its contract.

## App entry and Console

- **App/window lifetime:** [HeelerApp](../../Sources/Heeler/HeelerApp.swift) and
  [HeelerAppModel](../../Sources/Heeler/HeelerAppModel.swift) lead to
  [ConsoleView](../../Sources/Heeler/Console/ConsoleView.swift).
- **Agent and Terminal lists:** `ConsoleView` composes
  [ConsoleListPresentationStore](../../Sources/Heeler/Console/ConsoleListPresentationStore.swift),
  [TerminalListView](../../Sources/Heeler/Console/TerminalListView.swift), and
  [ConsoleStore](../../Sources/Heeler/Console/ConsoleStore.swift).
  [HostConsoleProjection](../../Sources/Heeler/Console/HostConsoleProjection.swift)
  owns each Host's snapshot/delta convergence; start there for missing, stale,
  or resurrected inventory. Focused coverage:
  [ConsoleStoreTests](../../Tests/HeelerTests/ConsoleStoreTests.swift).
- **Agent row fields:** [AgentRowRenderer](../../Sources/Heeler/Console/AgentRowRenderer.swift)
  consumes [AgentRowLayoutStore](../../Sources/Heeler/Console/AgentRowLayoutStore.swift)
  and [AgentRowLayoutResolver](../../Sources/Heeler/Console/AgentRowLayoutResolver.swift).
  Their matching `AgentRow*Tests` suites cover configuration and rendering.

## Connection, input, and terminals

| Task | Follow these owners | Contract and focused coverage |
| --- | --- | --- |
| Host setup, preflight, credentials | [HostOnboardingStore](../../Sources/Heeler/Hosts/HostOnboardingStore.swift), [Preflight](../../Sources/Heeler/Hosts/Preflight.swift), [TransportConnector](../../Sources/Heeler/Hosts/TransportConnector.swift) | [HostOnboardingStoreTests](../../Tests/HeelerTests/HostOnboardingStoreTests.swift), [PreflightReportTests](../../Tests/HeelerTests/PreflightReportTests.swift); [RSA ADR 0019](../adr/0019-rsa-sha2-key-authentication.md) |
| Requests, subscriptions, reconnect | [Transport](../../Sources/Heeler/Transport/Transport.swift) → [EventsSession](../../Sources/Heeler/Transport/EventsSession.swift) → [HeelerSSHTransport](../../Sources/Heeler/Transport/HeelerSSHTransport.swift); projection follows subscription acknowledgement with a snapshot | [ADR 0011](../adr/0011-libssh2-direct-streamlocal-transport.md), [versioned compatibility evidence](herdr-compatibility.md); [EventsSessionSubscriptionsTests](../../Tests/HeelerTests/EventsSessionSubscriptionsTests.swift), [EventsSessionBufferingTests](../../Tests/HeelerTests/EventsSessionBufferingTests.swift), real-SSH lanes |
| Native Windows discovery and streams | [RemoteHostEnvironment](../../Sources/Heeler/Transport/RemoteHostEnvironment.swift) → `HeelerSSHTransport` platform branches → [BootstrappedExecChannel](../../Sources/Heeler/Transport/BootstrappedExecChannel.swift) and [WindowsTerminalChannel](../../Sources/Heeler/Transport/WindowsTerminalChannel.swift) | [ADR 0018](../adr/0018-native-windows-hosts.md), [setup](../guides/windows-setup.md), [native acceptance](../guides/native-windows-testing.md); [RemoteHostEnvironmentTests](../../Tests/HeelerTests/RemoteHostEnvironmentTests.swift), [WindowsTerminalChannelTests](../../Tests/HeelerTests/WindowsTerminalChannelTests.swift) |
| Composer and Direct Input | [AgentDetailView](../../Sources/Heeler/Console/AgentDetailView.swift) → [AgentTerminalView](../../Sources/Heeler/Console/AgentTerminalView.swift), [AgentComposerView](../../Sources/Heeler/Console/AgentComposerView.swift), [AgentComposerStore](../../Sources/Heeler/Console/AgentComposerStore.swift), [AttachTerminalStore](../../Sources/Heeler/Console/AttachTerminalStore.swift) → [TerminalInputController](../../Sources/Heeler/Terminal/TerminalInputController.swift) | [ADR 0013](../adr/0013-live-terminal-with-local-composer.md), [ADR 0016](../adr/0016-direct-input-on-agent-attach.md); [AgentComposerStoreTests](../../Tests/HeelerTests/AgentComposerStoreTests.swift), [AgentDirectInputTests](../../Tests/HeelerTests/AgentDirectInputTests.swift) |
| Composer Stop and Chat's folded Composer | [AgentComposerStop](../../Sources/Heeler/Console/AgentComposerStop.swift) (`AgentComposerStopStore`, owned by `AgentComposerStore`; `AgentComposerCollapse`), [AgentComposerView](../../Sources/Heeler/Console/AgentComposerView.swift) | [ADR 0020](../adr/0020-native-chat-from-agent-transcripts.md), [ADR 0013](../adr/0013-live-terminal-with-local-composer.md); [AgentComposerStopTests](../../Tests/HeelerTests/AgentComposerStopTests.swift) (suites `AgentComposerPrimaryControlTests`, `AgentComposerCollapseTests`, `AgentComposerStopStoreTests`, `AgentComposerStopOwnershipTests`, `AgentComposerFoldHostedTests`), `AgentComposerSendButtonTests` in [AgentComposerStoreTests](../../Tests/HeelerTests/AgentComposerStoreTests.swift), the terminal's Stop in [AgentDirectInputTests](../../Tests/HeelerTests/AgentDirectInputTests.swift) |
| Workspace shell selection and retention | [WorkspaceTerminalDrawer](../../Sources/Heeler/Console/WorkspaceTerminalDrawer.swift), [ShellTerminalStore](../../Sources/Heeler/Console/ShellTerminalStore.swift), [TerminalConnectionPool](../../Sources/Heeler/Console/TerminalConnectionPool.swift), [TerminalRetentionBudget](../../Sources/Heeler/Console/TerminalRetentionBudget.swift) | [ADR 0017](../adr/0017-workspace-terminal-inventory-and-retention.md) updates [ADR 0015](../adr/0015-shell-terminal-via-direct-terminal-attach.md); [TerminalConnectionPoolTests](../../Tests/HeelerTests/TerminalConnectionPoolTests.swift), [AttachTerminalStoreTests](../../Tests/HeelerTests/AttachTerminalStoreTests.swift) |
| Rendering, scroll, keyboard geometry | [TerminalScreenView](../../Sources/Heeler/Terminal/TerminalScreenView.swift), [TerminalTouchScroll](../../Sources/Heeler/Terminal/TerminalTouchScroll.swift), [TerminalScrollControl](../../Sources/Heeler/Terminal/TerminalScrollControl.swift), [TerminalKeyboardInset](../../Sources/Heeler/Terminal/TerminalKeyboardInset.swift) | [ADR 0004](../adr/0004-libghostty-terminal.md), [scroll observations](herdr-compatibility.md); native checks use [simulator-ui.md](simulator-ui.md) |

The app adapter and the SSH package have different test plans.
`Sources/Heeler/Transport` implements product semantics;
[Packages/HeelerSSH](../../Packages/HeelerSSH) owns SSH channels and the native
driver. Package changes need the package lane, even when app tests pass.

## Changes and Agent directory

The Agent menu enters [AgentChangesPresentation](../../Sources/Heeler/Changes/AgentChangesPresentation.swift).
It builds [ChangesStore](../../Sources/Heeler/Changes/ChangesStore.swift) through
`ConsoleStore`, sharing a [GitExecGate](../../Sources/Heeler/Changes/GitExecGate.swift)
per Host. `Transport.readChanges`, `readFilePatch`, and `listUntrackedDirectory`
reach `HeelerSSHTransport.runGitScript`; the watchdog and admission lifetime live
there. [GitProbe](../../Sources/Heeler/Changes/GitProbe.swift) and its neighboring
extensions build POSIX scripts and parse byte-framed output.

| Task | Owner | Focused coverage |
| --- | --- | --- |
| Current Agent directory, wrong Checkout, stale event | [ConsoleAgent.directory](../../Sources/Heeler/Console/ConsoleAgent.swift), `HostConsoleProjection` pane deltas/snapshots, `Agent.foregroundCwd` in `Transport`; launch-directory consumers still use `agent.cwd` | [ConsoleStoreTests](../../Tests/HeelerTests/ConsoleStoreTests.swift), [ChangesStoreTests](../../Tests/HeelerTests/ChangesStoreTests.swift) |
| Refresh and stale state | [ChangesStore+AutoRefresh](../../Sources/Heeler/Changes/ChangesStore+AutoRefresh.swift), [ChangesFreshness](../../Sources/Heeler/Changes/ChangesFreshness.swift) | [ChangesAutoRefreshTests](../../Tests/HeelerTests/ChangesAutoRefreshTests.swift), [ChangesFreshnessTests](../../Tests/HeelerTests/ChangesFreshnessTests.swift) |
| File diff loading and display | [FileDiffStore](../../Sources/Heeler/Changes/FileDiffStore.swift), [GitProbe+PatchParser](../../Sources/Heeler/Changes/GitProbe+PatchParser.swift), [FileDiffView](../../Sources/Heeler/Changes/FileDiffView.swift), [SideBySideDiff](../../Sources/Heeler/Changes/SideBySideDiff.swift), [DiffLayout](../../Sources/Heeler/Changes/DiffLayout.swift) | [GitProbePatchTests](../../Tests/HeelerTests/GitProbePatchTests.swift), [FileDiffStoreTests](../../Tests/HeelerTests/FileDiffStoreTests.swift), [FileDiffScrollMeasurementTests](../../Tests/HeelerTests/FileDiffScrollMeasurementTests.swift) |
| Untracked directories, counts, Copy/Ask | `ChangesStore+FileDiff`, `ChangesStore+References`, `GitProbe+UntrackedDirectory`, `GitProbe+Numstat` in [Changes](../../Sources/Heeler/Changes) | [ChangesUntrackedDirectoryTests](../../Tests/HeelerTests/ChangesUntrackedDirectoryTests.swift), [ChangesStoreLineCountsTests](../../Tests/HeelerTests/ChangesStoreLineCountsTests.swift), [ChangesReferenceTests](../../Tests/HeelerTests/ChangesReferenceTests.swift) |
| Host quoting, locks, bounds, cancellation | `GitProbe` script builders → `runGitScript`; [HeelerSSHTransportBehaviorE2ETests](../../Tests/HeelerTests/HeelerSSHTransportBehaviorE2ETests.swift) and its Changes extensions | [ChangesGitExecGateTests](../../Tests/HeelerTests/ChangesGitExecGateTests.swift), [ChangesFieldHostE2ETests](../../Tests/HeelerTests/ChangesFieldHostE2ETests.swift), [WeakNetworkE2ETests+Changes](../../Tests/HeelerTests/WeakNetworkE2ETests+Changes.swift); [Linux/field lane](testing.md#host-and-platform-acceptance) |

[The original Changes research](../research/mobile-git-changes.md) records the
pre-implementation investigation and later measurements. Its old proposed
method names and source-line anchors are not current implementation instructions.
For screenshot/demo fixtures, follow [Demo](../../Sources/Heeler/Demo) separately
from live Host reads.

## Chat

Agent detail swaps the Agent terminal for
[AgentChatSurfaceView](../../Sources/Heeler/Console/AgentChatSurfaceView.swift) through
[AgentDetailSurfaceSettings](../../Sources/Heeler/Settings/AgentDetailSurfaceSettings.swift);
[AgentChatAvailability](../../Sources/Heeler/Console/AgentChatAvailability.swift) decides which Agents offer it.
`ConsoleStore` keeps an [AgentChatStore](../../Sources/Heeler/Chat/Conversation/AgentChatStore.swift) per Agent,
whose single loop drives a [ChatConversationEngine](../../Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift)
over the session herdr reports. Host files come through
[ChatHostFiles](../../Sources/Heeler/Chat/Source/ChatHostFiles.swift) to `Transport.readHostFileRange`,
`fileStatus`, `listFiles` and `hostHomeDirectory`. Read
[ADR 0020](../adr/0020-native-chat-from-agent-transcripts.md); the formats are
recorded in [Claude Code transcripts](../research/claude-code-transcript-format.md)
and [Codex rollouts](../research/codex-rollout-format.md), and herdr's behavior
in [the compatibility notes](herdr-compatibility.md).

| Task | Owner | Focused coverage |
| --- | --- | --- |
| Finding and following a transcript | [ConversationReference](../../Sources/Heeler/Chat/Source/ConversationReference.swift), [ClaudeTranscriptLocator](../../Sources/Heeler/Chat/Source/ClaudeTranscriptLocator.swift), [CodexTranscriptLocator](../../Sources/Heeler/Chat/Source/CodexTranscriptLocator.swift), [TranscriptFollower](../../Sources/Heeler/Chat/Source/TranscriptFollower.swift) | [ClaudeTranscriptLocatorTests](../../Tests/HeelerTests/ClaudeTranscriptLocatorTests.swift), [CodexTranscriptLocatorTests](../../Tests/HeelerTests/CodexTranscriptLocatorTests.swift), [TranscriptFollowerTests](../../Tests/HeelerTests/TranscriptFollowerTests.swift), [ChatConversationEngineTests](../../Tests/HeelerTests/ChatConversationEngineTests.swift), [AgentChatStoreTests](../../Tests/HeelerTests/AgentChatStoreTests.swift) |
| Claude Code records and rows | [ClaudeTranscriptReducer](../../Sources/Heeler/Chat/Claude/ClaudeTranscriptReducer.swift), [ClaudeChainResolver](../../Sources/Heeler/Chat/Claude/ClaudeChainResolver.swift), [ClaudeTextClassifier](../../Sources/Heeler/Chat/Claude/ClaudeTextClassifier.swift) | [ClaudeTranscriptReducerTests](../../Tests/HeelerTests/ClaudeTranscriptReducerTests.swift), [ClaudeChainResolverTests](../../Tests/HeelerTests/ClaudeChainResolverTests.swift), [ClaudeSyntheticTranscriptTests](../../Tests/HeelerTests/ClaudeSyntheticTranscriptTests.swift) |
| Codex records and rows | [CodexRolloutReducer](../../Sources/Heeler/Chat/Codex/CodexRolloutReducer.swift), [CodexPaginatedReducer](../../Sources/Heeler/Chat/Codex/CodexPaginatedReducer.swift), [CodexLegacyReducer](../../Sources/Heeler/Chat/Codex/CodexLegacyReducer.swift), [CodexTimeline](../../Sources/Heeler/Chat/Codex/CodexTimeline.swift) | [CodexIncrementalTests](../../Tests/HeelerTests/CodexIncrementalTests.swift), [CodexLegacyReplayTests](../../Tests/HeelerTests/CodexLegacyReplayTests.swift), [CodexLineageTests](../../Tests/HeelerTests/CodexLineageTests.swift), [CodexProbeTranscriptTests](../../Tests/HeelerTests/CodexProbeTranscriptTests.swift) |
| Timeline, scrolling, tool output | [ChatTimelineController](../../Sources/Heeler/Chat/Timeline/ChatTimelineController.swift), [ChatTimelineLayout](../../Sources/Heeler/Chat/Timeline/ChatTimelineLayout.swift), [ChatRowBuilder](../../Sources/Heeler/Chat/Timeline/ChatRowBuilder.swift), [ChatToolOutputs](../../Sources/Heeler/Chat/Conversation/ChatToolOutputs.swift) | [ChatTimelineControllerTests](../../Tests/HeelerTests/ChatTimelineControllerTests.swift), [ChatTimelineGeometryTests](../../Tests/HeelerTests/ChatTimelineGeometryTests.swift), [ChatFollowLatchTests](../../Tests/HeelerTests/ChatFollowLatchTests.swift), [ChatToolOutputTests](../../Tests/HeelerTests/ChatToolOutputTests.swift) |
| File changes under tool rows | [ClaudeTranscriptRecord](../../Sources/Heeler/Chat/Claude/ClaudeTranscriptRecord.swift) (`bashEditDiff`, `structuredPatch`), [ClaudeToolSummary](../../Sources/Heeler/Chat/Claude/ClaudeToolSummary.swift) (git-step note), [ChatFileDiffView](../../Sources/Heeler/Chat/Timeline/ChatFileDiffView.swift) | [ChatFileChangesTests](../../Tests/HeelerTests/ChatFileChangesTests.swift), [ChatTimelineControllerTests](../../Tests/HeelerTests/ChatTimelineControllerTests.swift) |
| Cache and its Settings | [FileChatTranscriptCache](../../Sources/Heeler/Chat/Cache/FileChatTranscriptCache.swift), [ChatCacheSettingsSection](../../Sources/Heeler/Settings/ChatCacheSettingsSection.swift) | [ChatTranscriptCacheTests](../../Tests/HeelerTests/ChatTranscriptCacheTests.swift), [ChatCacheSettingsModelTests](../../Tests/HeelerTests/ChatCacheSettingsModelTests.swift) |
| Send rules, `/` menu, delivery check | [ChatSendRules](../../Sources/Heeler/Chat/Compose/ChatSendRules.swift), [ChatDeliveryPolicy](../../Sources/Heeler/Chat/Compose/ChatDeliveryPolicy.swift), [PreSendGate](../../Sources/Heeler/Chat/Screen/PreSendGate.swift), [InputBoxStateDetector](../../Sources/Heeler/Chat/Screen/InputBoxStateDetector.swift) | [ChatSendRulesTests](../../Tests/HeelerTests/ChatSendRulesTests.swift), [ChatDeliveryPolicyTests](../../Tests/HeelerTests/ChatDeliveryPolicyTests.swift), [PreSendGateTests](../../Tests/HeelerTests/PreSendGateTests.swift), [InputBoxStateDetectorTests](../../Tests/HeelerTests/InputBoxStateDetectorTests.swift), [AgentComposerChatRouteTests](../../Tests/HeelerTests/AgentComposerChatRouteTests.swift) |
| Blocked cards | [BlockedCardStore](../../Sources/Heeler/Chat/Blocked/BlockedCardStore.swift) → [ClaudeDialogParser](../../Sources/Heeler/Chat/Blocked/ClaudeDialogParser.swift), [CodexDialogParser](../../Sources/Heeler/Chat/Blocked/CodexDialogParser.swift) → [DialogActionPlanner](../../Sources/Heeler/Chat/Blocked/DialogActionPlanner.swift); [BlockedHistory](../../Sources/Heeler/Chat/Blocked/BlockedHistory.swift) | [BlockedCardStoreTests](../../Tests/HeelerTests/BlockedCardStoreTests.swift), [DialogActionPlannerTests](../../Tests/HeelerTests/DialogActionPlannerTests.swift), [ClaudeDialogParserTests](../../Tests/HeelerTests/ClaudeDialogParserTests.swift), [CodexDialogParserTests](../../Tests/HeelerTests/CodexDialogParserTests.swift), [QuestionFormTests](../../Tests/HeelerTests/QuestionFormTests.swift), [BlockedHistoryTests](../../Tests/HeelerTests/BlockedHistoryTests.swift) |
| Background Work over the Composer | [ChatBackgroundWork](../../Sources/Heeler/Chat/Conversation/ChatBackgroundWork.swift), [ClaudeWorkflowJournal](../../Sources/Heeler/Chat/Claude/ClaudeWorkflowJournal.swift), [WorkflowJournalFollower](../../Sources/Heeler/Chat/Source/WorkflowJournalFollower.swift), [ChatBackgroundWorkPresentation](../../Sources/Heeler/Chat/BackgroundWork/ChatBackgroundWorkPresentation.swift), [ChatBackgroundWorkStrip](../../Sources/Heeler/Chat/BackgroundWork/ChatBackgroundWorkStrip.swift), [ChatBackgroundWorkSheet](../../Sources/Heeler/Chat/BackgroundWork/ChatBackgroundWorkSheet.swift) | [ChatBackgroundWorkTests](../../Tests/HeelerTests/ChatBackgroundWorkTests.swift), [ChatBackgroundWorkPresentationTests](../../Tests/HeelerTests/ChatBackgroundWorkPresentationTests.swift), [ClaudeSyntheticTranscriptTests](../../Tests/HeelerTests/ClaudeSyntheticTranscriptTests.swift), [ChatConversationEngineTests](../../Tests/HeelerTests/ChatConversationEngineTests.swift), [AgentChatStoreTests](../../Tests/HeelerTests/AgentChatStoreTests.swift) |
| Tools dock Agent page and Stop's Esc | [AgentChatToolsKeyboard](../../Sources/Heeler/Console/AgentChatToolsKeyboard.swift), [ChatAgentKeysStore](../../Sources/Heeler/Chat/Compose/ChatAgentKeysStore.swift) | [ChatAgentKeysStoreTests](../../Tests/HeelerTests/ChatAgentKeysStoreTests.swift) |

Transcript and screen fixtures, sanitized from isolated-backend probes, live in
[ChatFixtures](../../Tests/HeelerTests/ChatFixtures); demo mode's conversation
is [DemoChatSample](../../Sources/Heeler/Demo/DemoChatSample.swift).

## Other feature routes

- **Remote directory browsing:** [RemoteDirectoryBrowser](../../Sources/Heeler/Console/RemoteDirectoryBrowser.swift)
  and `ConsoleStore.listRemoteDirectories` reach the app SSH adapter.
  [RemoteDirectoryBrowserTests](../../Tests/HeelerTests/RemoteDirectoryBrowserTests.swift)
  cover store behavior; the first-presentation native check is in
  [the UI runbook](simulator-ui.md).
- **Image/file staging:** [ComposerStagingStore](../../Sources/Heeler/Attachments/ComposerStagingStore.swift)
  belongs to the Agent's [AgentComposerSession](../../Sources/Heeler/Console/AgentComposerSession.swift),
  which `ConsoleStore` keeps per Agent above the detail, its Attach and Chat;
  the last detail leaving the Agent cancels an upload, and suspension
  interrupts it.
  [ImagePreparer](../../Sources/Heeler/Images/ImagePreparer.swift) and
  [FilePreparer](../../Sources/Heeler/Files/FilePreparer.swift) prepare local media;
  typed `Transport.stageImage`/`stageFile` use SFTP.
  Read [ADR 0005](../adr/0005-keep-staged-image-cleanup-outside-mobile.md) and
  [ADR 0006](../adr/0006-stage-images-over-sftp.md); start with
  [ComposerStagingStoreTests](../../Tests/HeelerTests/ComposerStagingStoreTests.swift)
  and [ComposerStagingOwnershipTests](../../Tests/HeelerTests/ComposerStagingOwnershipTests.swift).
- **Notifications and Live Activities:** [AgentNotificationRouter](../../Sources/Heeler/Notifications/AgentNotificationRouter.swift)
  routes scenes; [HostLiveActivityCoordinator](../../Sources/Heeler/LiveActivities/HostLiveActivityCoordinator.swift)
  owns Host activity updates. Payloads cross the app, `HeelerActivityCore`,
  `HeelerNotificationCore`, extensions, `plugin/`, and `relay/`.
  [The shared contract](live-activity-contract.md) and vectors own their wire
  agreement; [ADRs 0008](../adr/0008-agent-notifications-via-plugin-hooks-and-push-relay.md)
  and [0014](../adr/0014-lock-screen-live-activities.md) explain the boundaries.

## Sibling deliverables and generated files

| Area | Entry and verification |
| --- | --- |
| herdr plugin | [plugin/README.md](../../plugin/README.md), `plugin/herdr-plugin.toml`, `npm test` in `plugin/` |
| Push Relay | [relay/README.md](../../relay/README.md), `npm test` in `relay/` |
| Marketing site | [landing](../../landing), its `package.json` scripts, [landing CI](../../.github/workflows/landing.yml) |
| Wire types | [generate-wire-types.py](../../scripts/generate-wire-types.py) consumes the committed [herdr-schema.json](../../scripts/herdr-schema.json); generated output is [Transport/Generated](../../Sources/Heeler/Transport/Generated) |
| App/package CI | [ci.yml](../../.github/workflows/ci.yml), [run-ci-ios-tests.sh](../../scripts/run-ci-ios-tests.sh), [testing.md](testing.md) |
| Node/codegen CI | [ci-node.yml](../../.github/workflows/ci-node.yml) |

Find a symbol before reading a large file: `rg -n 'symbol' Sources Tests`.
Follow definitions, construction sites, and state updates through the UI;
a search with no matching keyword alone does not establish feature absence.
