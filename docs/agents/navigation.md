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
| Host setup, preflight, credentials | [HostOnboardingStore](../../Sources/Heeler/Hosts/HostOnboardingStore.swift), [Preflight](../../Sources/Heeler/Hosts/Preflight.swift), [TransportConnector](../../Sources/Heeler/Hosts/TransportConnector.swift) | [HostOnboardingStoreTests](../../Tests/HeelerTests/HostOnboardingStoreTests.swift), [PreflightReportTests](../../Tests/HeelerTests/PreflightReportTests.swift); [RSA ADR 0019](../adr/0019-rsa-sha2-key-authentication.md), [Herdr Endpoint ADR 0023](../adr/0023-herdr-endpoint-in-pairing-code-v2.md), [plugin launcher ADR 0029](../adr/0029-plugin-generates-the-herdr-endpoint-launcher.md) |
| Installed plugin version and feature notes | [HeelerPlugin](../../Sources/Heeler/Hosts/HeelerPlugin.swift) (version, compatibility, presentation), `Transport.readHeelerPlugin` (`plugin.list`, decoded by [HeelerPluginInstallation](../../Sources/Heeler/Transport/HeelerPluginInstallation.swift)), read by `HostOnboardingStore` and [HeelerPluginStatusStore](../../Sources/Heeler/Console/HeelerPluginStatusStore.swift) for Settings; the notice's action runs `Transport.runHeelerPluginStep` from `HostOnboardingStore.runPluginAction`, an install finding Node.js through [NodeToolchainProbe](../../Sources/Heeler/Transport/NodeToolchainProbe.swift) ([ADR 0027](../adr/0027-update-the-plugin-from-the-app.md)) | [HeelerPluginTests](../../Tests/HeelerTests/HeelerPluginTests.swift), [HostOnboardingStoreTests](../../Tests/HeelerTests/HostOnboardingStoreTests.swift), [test-node-toolchain-probe.py](../../scripts/test-node-toolchain-probe.py) (`make test-tools`); the shared `plugin/test-vectors/plugin-version-v1.json` pins the bundled version |
| Host Routes (several ways to reach one Host), route racing, Host-scoped host-key trust | [Host](../../Sources/Heeler/Hosts/Host.swift) (`HostRoute`), [HostDraft](../../Sources/Heeler/Hosts/HostDraft.swift) and [HostRouteFields](../../Sources/Heeler/Hosts/HostRouteFields.swift) → [SSHTransportSettings](../../Sources/Heeler/Transport/SSHTransportSettings.swift) (`SSHRoute`) → `HeelerSSHTransport.connect` with [RouteRace](../../Sources/Heeler/Transport/RouteRace.swift); trust in [HeelerSSHHostKeyVerifier](../../Sources/Heeler/Transport/HeelerSSHHostKeyVerifier.swift) | [ADR 0022](../adr/0022-host-routes.md); [HostRouteTests](../../Tests/HeelerTests/HostRouteTests.swift), Jump Host route races in [HeelerSSHJumpHostGateE2ETests](../../Tests/HeelerTests/HeelerSSHJumpHostGateE2ETests.swift) |
| Overlay Networks (in-app Tailscale/ZeroTier/EasyTier first hop) | [OverlayNetworkStore](../../Sources/Heeler/Overlay/OverlayNetworkStore.swift) → [OverlayNetworkRuntime](../../Sources/Heeler/Overlay/OverlayNetworkRuntime.swift) → [OverlayRoute](../../Sources/Heeler/Transport/OverlayRoute.swift) in `HeelerSSHTransport`; nodes live in [Packages/HeelerOverlay](../../Packages/HeelerOverlay), native libraries in [heeler-overlay-natives](https://github.com/Ylarod/heeler-overlay-natives) (exact release) | [Setup guides](../guides/overlay-networks.md) and their [maintenance record](overlay-network-guides.md); [ADR 0021](../adr/0021-in-process-overlay-networks.md); [OverlayNetworkTests](../../Tests/HeelerTests/OverlayNetworkTests.swift) |
| Requests, subscriptions, reconnect | [Transport](../../Sources/Heeler/Transport/Transport.swift) → [EventsSession](../../Sources/Heeler/Transport/EventsSession.swift) → [HeelerSSHTransport](../../Sources/Heeler/Transport/HeelerSSHTransport.swift); projection follows subscription acknowledgement with a snapshot | [ADR 0011](../adr/0011-libssh2-direct-streamlocal-transport.md), [versioned compatibility evidence](herdr-compatibility.md); [EventsSessionSubscriptionsTests](../../Tests/HeelerTests/EventsSessionSubscriptionsTests.swift), [EventsSessionBufferingTests](../../Tests/HeelerTests/EventsSessionBufferingTests.swift), real-SSH lanes |
| Native Windows discovery and streams | [RemoteHostEnvironment](../../Sources/Heeler/Transport/RemoteHostEnvironment.swift) → `HeelerSSHTransport` platform branches → [BootstrappedExecChannel](../../Sources/Heeler/Transport/BootstrappedExecChannel.swift) and [WindowsTerminalChannel](../../Sources/Heeler/Transport/WindowsTerminalChannel.swift) | [ADR 0018](../adr/0018-native-windows-hosts.md), [setup](../guides/windows-setup.md), [native acceptance](../guides/native-windows-testing.md); [RemoteHostEnvironmentTests](../../Tests/HeelerTests/RemoteHostEnvironmentTests.swift), [WindowsTerminalChannelTests](../../Tests/HeelerTests/WindowsTerminalChannelTests.swift) |
| Composer and Direct Input | [AgentDetailView](../../Sources/Heeler/Console/AgentDetailView.swift) → [AgentTerminalView](../../Sources/Heeler/Console/AgentTerminalView.swift), [AgentComposerView](../../Sources/Heeler/Console/AgentComposerView.swift), [AgentComposerStore](../../Sources/Heeler/Console/AgentComposerStore.swift), [AttachTerminalStore](../../Sources/Heeler/Console/AttachTerminalStore.swift) → [TerminalInputController](../../Sources/Heeler/Terminal/TerminalInputController.swift) | [ADR 0013](../adr/0013-live-terminal-with-local-composer.md), [ADR 0016](../adr/0016-direct-input-on-agent-attach.md); [AgentComposerStoreTests](../../Tests/HeelerTests/AgentComposerStoreTests.swift), [AgentDirectInputTests](../../Tests/HeelerTests/AgentDirectInputTests.swift) |
| Composer Stop and Chat's folded Composer | [AgentComposerStop](../../Sources/Heeler/Console/AgentComposerStop.swift) (`AgentComposerStopStore`, owned by `AgentComposerStore`; each surface's `AgentComposerInterrupt` with its `AgentStopWait`; `AgentComposerCollapse`), [AgentComposerView](../../Sources/Heeler/Console/AgentComposerView.swift) | [ADR 0024](../adr/0024-native-chat-from-agent-transcripts.md), [ADR 0013](../adr/0013-live-terminal-with-local-composer.md); [AgentComposerStopTests](../../Tests/HeelerTests/AgentComposerStopTests.swift) (suites `AgentComposerPrimaryControlTests`, `AgentComposerCollapseTests`, `AgentComposerStopStoreTests`, `AgentComposerStopOwnershipTests`, `AgentComposerFoldHostedTests`), `AgentComposerSendButtonTests` in [AgentComposerStoreTests](../../Tests/HeelerTests/AgentComposerStoreTests.swift), the terminal's Stop in [AgentDirectInputTests](../../Tests/HeelerTests/AgentDirectInputTests.swift) |
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
per Host. One app-wide `GitExecGate` also serializes Notification Registration
writes, so a change to the gate affects both. `Transport.readChanges`, `readFilePatch`, and `listUntrackedDirectory`
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
[AgentChatAvailability](../../Sources/Heeler/Console/AgentChatAvailability.swift) decides which Agents offer it:
a POSIX Host and a program with a transcript adapter.
`ConsoleStore` keeps an [AgentChatStore](../../Sources/Heeler/Chat/Conversation/AgentChatStore.swift) per Agent,
whose single loop drives a [ChatConversationEngine](../../Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift)
over the session herdr reports. Host files come through
[ChatHostFiles](../../Sources/Heeler/Chat/Source/ChatHostFiles.swift) to `Transport.readHostFileRange`,
`fileStatus`, `listFiles` and `hostHomeDirectory`; OpenCode's conversation
comes through its `queryOpenCode` to `Transport.queryOpenCode`, one bounded
read-only exec per query. Read
[ADR 0024](../adr/0024-native-chat-from-agent-transcripts.md); the formats are
recorded in [Claude Code transcripts](../research/claude-code-transcript-format.md)
and [Codex rollouts](../research/codex-rollout-format.md), and herdr's behavior
in [the compatibility notes](herdr-compatibility.md).
[ADR 0025](../adr/0025-opencode-chat-reads-its-session-store.md) records how Chat reads OpenCode's session store instead of a transcript,
and [OpenCode's session store](../research/opencode-session-store.md) what it was built on.

| Task | Owner | Focused coverage |
| --- | --- | --- |
| Finding and following a transcript | [ConversationReference](../../Sources/Heeler/Chat/Source/ConversationReference.swift) with each program's `ChatSessionNaming`, [ClaudeTranscriptLocator](../../Sources/Heeler/Chat/Source/ClaudeTranscriptLocator.swift), [CodexTranscriptLocator](../../Sources/Heeler/Chat/Source/CodexTranscriptLocator.swift), [ChatTranscriptSource](../../Sources/Heeler/Chat/Source/ChatTranscriptSource.swift), which [TranscriptFollower](../../Sources/Heeler/Chat/Source/TranscriptFollower.swift) implements for files | [ClaudeTranscriptLocatorTests](../../Tests/HeelerTests/ClaudeTranscriptLocatorTests.swift), [CodexTranscriptLocatorTests](../../Tests/HeelerTests/CodexTranscriptLocatorTests.swift), [TranscriptFollowerTests](../../Tests/HeelerTests/TranscriptFollowerTests.swift), [ChatConversationEngineTests](../../Tests/HeelerTests/ChatConversationEngineTests.swift), [AgentChatStoreTests](../../Tests/HeelerTests/AgentChatStoreTests.swift) |
| Claude Code records and rows | [ClaudeTranscriptReducer](../../Sources/Heeler/Chat/Claude/ClaudeTranscriptReducer.swift), [ClaudeChainResolver](../../Sources/Heeler/Chat/Claude/ClaudeChainResolver.swift), [ClaudeTextClassifier](../../Sources/Heeler/Chat/Claude/ClaudeTextClassifier.swift) | [ClaudeTranscriptReducerTests](../../Tests/HeelerTests/ClaudeTranscriptReducerTests.swift), [ClaudeChainResolverTests](../../Tests/HeelerTests/ClaudeChainResolverTests.swift), [ClaudeSyntheticTranscriptTests](../../Tests/HeelerTests/ClaudeSyntheticTranscriptTests.swift) |
| Codex records and rows | [CodexRolloutReducer](../../Sources/Heeler/Chat/Codex/CodexRolloutReducer.swift), [CodexPaginatedReducer](../../Sources/Heeler/Chat/Codex/CodexPaginatedReducer.swift), [CodexLegacyReducer](../../Sources/Heeler/Chat/Codex/CodexLegacyReducer.swift), [CodexTimeline](../../Sources/Heeler/Chat/Codex/CodexTimeline.swift) | [CodexIncrementalTests](../../Tests/HeelerTests/CodexIncrementalTests.swift), [CodexLegacyReplayTests](../../Tests/HeelerTests/CodexLegacyReplayTests.swift), [CodexLineageTests](../../Tests/HeelerTests/CodexLineageTests.swift), [CodexProbeTranscriptTests](../../Tests/HeelerTests/CodexProbeTranscriptTests.swift) |
| Pi and Oh My Pi session paths, tree records and input | [PiTranscriptLocator](../../Sources/Heeler/Chat/Source/PiTranscriptLocator.swift), [PiTranscriptReducer](../../Sources/Heeler/Chat/Pi/PiTranscriptReducer.swift), [PiInputBoxDetector](../../Sources/Heeler/Chat/Screen/PiInputBoxDetector.swift) | [PiChatTests](../../Tests/HeelerTests/PiChatTests.swift), [format observations](../research/pi-transcript-format.md) |
| Grok Build session paths, records and screen | [GrokTranscriptLocator](../../Sources/Heeler/Chat/Source/GrokTranscriptLocator.swift), [GrokTranscriptReducer](../../Sources/Heeler/Chat/Grok/GrokTranscriptReducer.swift) with [GrokToolSummary](../../Sources/Heeler/Chat/Grok/GrokToolSummary.swift) and [GrokFileChanges](../../Sources/Heeler/Chat/Grok/GrokFileChanges.swift); [GrokScreen](../../Sources/Heeler/Chat/Screen/GrokScreen.swift), read by [GrokInputBoxDetector](../../Sources/Heeler/Chat/Screen/GrokInputBoxDetector.swift), [GrokStopGuard](../../Sources/Heeler/Chat/Screen/GrokStopGuard.swift) and [GrokSessionCheck](../../Sources/Heeler/Chat/Screen/GrokSessionCheck.swift); the post-send witness [ChatSendWitness](../../Sources/Heeler/Chat/Conversation/ChatSendWitness.swift) with [GrokPromptHistoryWitness](../../Sources/Heeler/Chat/Grok/GrokPromptHistoryWitness.swift), run by `AgentChatStore.sendConcern` and `checkSendWitnesses`; [GrokSlashCommands](../../Sources/Heeler/Chat/Grok/GrokSlashCommands.swift) | [GrokTranscriptLocatorTests](../../Tests/HeelerTests/GrokTranscriptLocatorTests.swift), [GrokTranscriptReducerTests](../../Tests/HeelerTests/GrokTranscriptReducerTests.swift), [GrokToolActivityTests](../../Tests/HeelerTests/GrokToolActivityTests.swift), [GrokChatTests](../../Tests/HeelerTests/GrokChatTests.swift), [GrokInputBoxDetectorTests](../../Tests/HeelerTests/GrokInputBoxDetectorTests.swift), [GrokStopGuardTests](../../Tests/HeelerTests/GrokStopGuardTests.swift), [GrokSessionCheckTests](../../Tests/HeelerTests/GrokSessionCheckTests.swift), [GrokPromptHistoryWitnessTests](../../Tests/HeelerTests/GrokPromptHistoryWitnessTests.swift), `AgentChatStoreTests`, [format observations](../research/grok-build-transcript-format.md) |
| OpenCode store, rows, input and cards | [OpenCodeProbe](../../Sources/Heeler/Chat/OpenCode/OpenCodeProbe.swift) (the read-only Host script, its SQL and output), [OpenCodeRecordSource](../../Sources/Heeler/Chat/OpenCode/OpenCodeRecordSource.swift) (following by query), [OpenCodeTranscriptReducer](../../Sources/Heeler/Chat/OpenCode/OpenCodeTranscriptReducer.swift) (rows into entries and turns); [OpenCodeScreenReader](../../Sources/Heeler/Chat/Screen/OpenCodeScreenReader.swift) (input box), [OpenCodeSendRules](../../Sources/Heeler/Chat/OpenCode/OpenCodeSendRules.swift) (path-only drafts), [OpenCodeDialogParser](../../Sources/Heeler/Chat/Blocked/OpenCodeDialogParser.swift) and [OpenCodeDialogPlanner](../../Sources/Heeler/Chat/Blocked/OpenCodeDialogPlanner.swift) (cards), [OpenCodeStopGuard](../../Sources/Heeler/Chat/OpenCode/OpenCodeStopGuard.swift) (Stop's two Escs), [OpenCodeTerminalTitle](../../Sources/Heeler/Chat/OpenCode/OpenCodeTerminalTitle.swift) (the start-screen watch and the check before sends, in `AgentChatStore`) | [OpenCodeProbeTests](../../Tests/HeelerTests/OpenCodeProbeTests.swift), [OpenCodeStoreQueryTests](../../Tests/HeelerTests/OpenCodeStoreQueryTests.swift), [OpenCodeRecordSourceTests](../../Tests/HeelerTests/OpenCodeRecordSourceTests.swift), [OpenCodeTranscriptReducerTests](../../Tests/HeelerTests/OpenCodeTranscriptReducerTests.swift), [OpenCodeInputBoxDetectorTests](../../Tests/HeelerTests/OpenCodeInputBoxDetectorTests.swift), [OpenCodeDialogParserTests](../../Tests/HeelerTests/OpenCodeDialogParserTests.swift), `DialogActionPlannerTests`, `ChatStopPlanTests`, [OpenCodeChatStoreTests](../../Tests/HeelerTests/OpenCodeChatStoreTests.swift), real execs in [HeelerSSHTransportBehaviorE2ETests+OpenCodeStore](../../Tests/HeelerTests/HeelerSSHTransportBehaviorE2ETests+OpenCodeStore.swift); [ADR 0025](../adr/0025-opencode-chat-reads-its-session-store.md), [store observations](../research/opencode-session-store.md) |
| Timeline, scrolling, tool output | [ChatTimelineController](../../Sources/Heeler/Chat/Timeline/ChatTimelineController.swift), [ChatTimelineLayout](../../Sources/Heeler/Chat/Timeline/ChatTimelineLayout.swift), [ChatRowBuilder](../../Sources/Heeler/Chat/Timeline/ChatRowBuilder.swift), [ChatToolOutputs](../../Sources/Heeler/Chat/Conversation/ChatToolOutputs.swift) | [ChatTimelineControllerTests](../../Tests/HeelerTests/ChatTimelineControllerTests.swift), [ChatTimelineGeometryTests](../../Tests/HeelerTests/ChatTimelineGeometryTests.swift), [ChatFollowLatchTests](../../Tests/HeelerTests/ChatFollowLatchTests.swift), [ChatToolOutputTests](../../Tests/HeelerTests/ChatToolOutputTests.swift) |
| Image tool previews | [ChatImagePreviewReader](../../Sources/Heeler/Chat/Source/ChatImagePreviewReader.swift), [ChatImagePreviewController](../../Sources/Heeler/Chat/Timeline/ChatImagePreviewController.swift), context menus in `ChatTimelineController`, `AgentChatStore.readImage` | [ChatImagePreviewTests](../../Tests/HeelerTests/ChatImagePreviewTests.swift), `CodexMessageDisplayTests`, `ChatTimelineControllerTests` |
| Turn folds, tool groups and floating Collapse Steps | [ChatTimelineProjection](../../Sources/Heeler/Chat/Timeline/ChatTimelineProjection.swift) owns turn scopes; [ChatTimelineController](../../Sources/Heeler/Chat/Timeline/ChatTimelineController.swift) selects the reading scope and preserves its anchor, with controls in [ChatTimelineView](../../Sources/Heeler/Chat/Timeline/ChatTimelineView.swift) and headers in [ChatRowView](../../Sources/Heeler/Chat/Timeline/ChatRowView.swift). `ChatTurn` comes from the transcript adapters; Fold Finished Turns, with Chat's font and text size, lives in [AppearanceSettingsView](../../Sources/Heeler/Settings/AppearanceSettingsView.swift) | [ChatTimelineProjectionTests](../../Tests/HeelerTests/ChatTimelineProjectionTests.swift), [ChatTimelineControllerTests](../../Tests/HeelerTests/ChatTimelineControllerTests.swift), [ClaudeTranscriptReducerTests](../../Tests/HeelerTests/ClaudeTranscriptReducerTests.swift), [CodexProbeTranscriptTests](../../Tests/HeelerTests/CodexProbeTranscriptTests.swift) |
| File changes under tool rows | [ClaudeTranscriptRecord](../../Sources/Heeler/Chat/Claude/ClaudeTranscriptRecord.swift) (`bashEditDiff`, `structuredPatch`), [ClaudeToolSummary](../../Sources/Heeler/Chat/Claude/ClaudeToolSummary.swift) (git-step note), [ChatFileDiffView](../../Sources/Heeler/Chat/Timeline/ChatFileDiffView.swift) | [ChatFileChangesTests](../../Tests/HeelerTests/ChatFileChangesTests.swift), [ChatTimelineControllerTests](../../Tests/HeelerTests/ChatTimelineControllerTests.swift) |
| Offline entry points and connection prefetch | [ConsoleChatCache](../../Sources/Heeler/Chat/Cache/ConsoleChatCache.swift), [ChatCachedAgent](../../Sources/Heeler/Chat/Cache/ChatCachedAgent.swift), `ConsoleStore.chatDisplayAgents` and `reconcileChatCache`, `AgentChatStore.prefetch` | [ConsoleChatCacheTests](../../Tests/HeelerTests/ConsoleChatCacheTests.swift), `ConsoleStoreTests.connectingCachesChatWithoutOpeningItsDetail`, `AgentChatStoreTests` |
| Cache and its Settings | [FileChatTranscriptCache](../../Sources/Heeler/Chat/Cache/FileChatTranscriptCache.swift), [ChatCacheSettingsSection](../../Sources/Heeler/Settings/ChatCacheSettingsSection.swift) | [ChatTranscriptCacheTests](../../Tests/HeelerTests/ChatTranscriptCacheTests.swift), [ChatCacheSettingsModelTests](../../Tests/HeelerTests/ChatCacheSettingsModelTests.swift) |
| Send rules, `/` menu, delivery check | [ChatSendRules](../../Sources/Heeler/Chat/Compose/ChatSendRules.swift) with each program's `ChatSendProfile`, [ChatDeliveryPolicy](../../Sources/Heeler/Chat/Compose/ChatDeliveryPolicy.swift), [PreSendGate](../../Sources/Heeler/Chat/Screen/PreSendGate.swift), [InputBoxStateDetector](../../Sources/Heeler/Chat/Screen/InputBoxStateDetector.swift) | [ChatSendRulesTests](../../Tests/HeelerTests/ChatSendRulesTests.swift), [ChatDeliveryPolicyTests](../../Tests/HeelerTests/ChatDeliveryPolicyTests.swift), [PreSendGateTests](../../Tests/HeelerTests/PreSendGateTests.swift), [InputBoxStateDetectorTests](../../Tests/HeelerTests/InputBoxStateDetectorTests.swift), [AgentComposerChatRouteTests](../../Tests/HeelerTests/AgentComposerChatRouteTests.swift) |
| Blocked cards | [BlockedCardStore](../../Sources/Heeler/Chat/Blocked/BlockedCardStore.swift) → [ClaudeDialogParser](../../Sources/Heeler/Chat/Blocked/ClaudeDialogParser.swift), [CodexDialogParser](../../Sources/Heeler/Chat/Blocked/CodexDialogParser.swift), [OMPDialogParser](../../Sources/Heeler/Chat/Blocked/OMPDialogParser.swift), [GrokDialogParser](../../Sources/Heeler/Chat/Blocked/GrokDialogParser.swift), [OpenCodeDialogParser](../../Sources/Heeler/Chat/Blocked/OpenCodeDialogParser.swift) → [DialogActionPlanner](../../Sources/Heeler/Chat/Blocked/DialogActionPlanner.swift) with [OMPDialogPlanner](../../Sources/Heeler/Chat/Blocked/OMPDialogPlanner.swift) and [GrokDialogPlanner](../../Sources/Heeler/Chat/Blocked/GrokDialogPlanner.swift); [BlockedHistory](../../Sources/Heeler/Chat/Blocked/BlockedHistory.swift) | [BlockedCardStoreTests](../../Tests/HeelerTests/BlockedCardStoreTests.swift), [BlockedCardViewTests](../../Tests/HeelerTests/BlockedCardViewTests.swift), [DialogActionPlannerTests](../../Tests/HeelerTests/DialogActionPlannerTests.swift), [ClaudeDialogParserTests](../../Tests/HeelerTests/ClaudeDialogParserTests.swift), [CodexDialogParserTests](../../Tests/HeelerTests/CodexDialogParserTests.swift), [OMPDialogParserTests](../../Tests/HeelerTests/OMPDialogParserTests.swift), [GrokDialogParserTests](../../Tests/HeelerTests/GrokDialogParserTests.swift), [GrokDialogPlannerTests](../../Tests/HeelerTests/GrokDialogPlannerTests.swift), [OpenCodeDialogParserTests](../../Tests/HeelerTests/OpenCodeDialogParserTests.swift), [QuestionFormTests](../../Tests/HeelerTests/QuestionFormTests.swift), [BlockedHistoryTests](../../Tests/HeelerTests/BlockedHistoryTests.swift) |
| Background Work over the Composer | [ChatBackgroundWork](../../Sources/Heeler/Chat/Conversation/ChatBackgroundWork.swift), [ClaudeWorkflowJournal](../../Sources/Heeler/Chat/Claude/ClaudeWorkflowJournal.swift), [WorkflowJournalFollower](../../Sources/Heeler/Chat/Source/WorkflowJournalFollower.swift), [ChatBackgroundWorkPresentation](../../Sources/Heeler/Chat/BackgroundWork/ChatBackgroundWorkPresentation.swift), [ChatBackgroundWorkStrip](../../Sources/Heeler/Chat/BackgroundWork/ChatBackgroundWorkStrip.swift), [ChatBackgroundWorkSheet](../../Sources/Heeler/Chat/BackgroundWork/ChatBackgroundWorkSheet.swift) | [ChatBackgroundWorkTests](../../Tests/HeelerTests/ChatBackgroundWorkTests.swift), [ChatBackgroundWorkPresentationTests](../../Tests/HeelerTests/ChatBackgroundWorkPresentationTests.swift), [ClaudeSyntheticTranscriptTests](../../Tests/HeelerTests/ClaudeSyntheticTranscriptTests.swift), [ChatConversationEngineTests](../../Tests/HeelerTests/ChatConversationEngineTests.swift), [AgentChatStoreTests](../../Tests/HeelerTests/AgentChatStoreTests.swift) |
| Tools dock Agent page and Chat's Stop keys | [AgentChatToolsKeyboard](../../Sources/Heeler/Console/AgentChatToolsKeyboard.swift), [ChatAgentKeysStore](../../Sources/Heeler/Chat/Compose/ChatAgentKeysStore.swift), [ChatStopPlan](../../Sources/Heeler/Chat/Compose/ChatStopPlan.swift) | [ChatAgentKeysStoreTests](../../Tests/HeelerTests/ChatAgentKeysStoreTests.swift), [ChatStopPlanTests](../../Tests/HeelerTests/ChatStopPlanTests.swift) |

Transcript and screen fixtures, sanitized from isolated-backend probes, live in
[ChatFixtures](../../Tests/HeelerTests/ChatFixtures); demo mode's conversation
is [DemoChatSample](../../Sources/Heeler/Demo/DemoChatSample.swift).

## Other feature routes

- **Usage Limits and Token Usage:** `ConsoleView.usageTab()` hosts the Usage
  tab: [AgentUsageTabView and the iPad sidebar list](../../Sources/Heeler/Usage/AgentUsageTab.swift)
  around [AgentUsageDashboard](../../Sources/Heeler/Usage/AgentUsageDashboard.swift),
  with [charts](../../Sources/Heeler/Usage/AgentUsageCharts.swift),
  [sheets](../../Sources/Heeler/Usage/AgentUsageSheets.swift), and the iPad
  [wide layout's table, limits strip and Limits view](../../Sources/Heeler/Usage/AgentUsageWide.swift).
  [AgentUsageScope](../../Sources/Heeler/Usage/AgentUsageScope.swift) adds
  Token Usage across Hosts and lists the Hosts left out.
  [HostOnboardingView](../../Sources/Heeler/Hosts/HostOnboardingView.swift)
  embeds the short [AgentUsageSection](../../Sources/Heeler/Usage/AgentUsageSection.swift),
  which opens the tab scoped to that Host.
  `ConsoleStore.agentUsageStore(for:)` retains an
  [AgentUsageStore](../../Sources/Heeler/Usage/AgentUsageStore.swift) per Host;
  it owns refresh polling and the device's per-Host Claude limits preference.
  The Home and Lock Screen widgets read the App Group snapshot that
  [AgentUsageWidgetPublisher](../../Sources/Heeler/Usage/AgentUsageWidgetPublisher.swift)
  writes from those stores, modeled in
  [UsageWidgetSnapshot](../../Sources/HeelerUsageCore/UsageWidgetSnapshot.swift)
  (shared with the extension, as are the formats in `AgentUsageStyle`).
  [UsageWidgetViews](../../Sources/HeelerWidgets/Usage/UsageWidgetViews.swift)
  draws every size and is compiled into the app for tests;
  [UsageWidgets](../../Sources/HeelerWidgets/Usage/UsageWidgets.swift) holds
  the timelines and configuration. Stale Hosts are re-read for the widgets
  by `ConsoleStore.refreshStaleWidgetUsage()` in the foreground and by
  [AgentUsageBackgroundRefresh](../../Sources/Heeler/Usage/AgentUsageBackgroundRefresh.swift)
  (the app refresh task `HeelerApp` registers) in the background. Focused
  tests: `AgentUsageWidgetTests`, `AgentUsageWidgetRefreshTests`.
  `Transport.readAgentUsage` uses [AgentUsageProbe](../../Sources/Heeler/Usage/AgentUsageProbe.swift)
  and the bounded SSH exec to decode [AgentUsageReport](../../Sources/Heeler/Usage/AgentUsageReport.swift).
  On the Host, [usage-runtime.js](../../plugin/src/usage-runtime.js) records
  herdr's environment, [usage-query.js](../../plugin/src/usage-query.js)
  reads snapshots, and [usage-worker.js](../../plugin/src/usage-worker.js)
  coordinates [scanners, limit readers, buckets and pricing](../../plugin/src/usage).
  Read the [design](../design/agent-usage.md) and
  [ADR 0028](../adr/0028-plugin-collects-agent-usage-on-the-host.md).
  Focused app coverage: `AgentUsageStoreTests` and `ClaudeUsagePreferenceTests`
  in [AgentUsageTests](../../Tests/HeelerTests/AgentUsageTests.swift),
  [probe](../../Tests/HeelerTests/AgentUsageProbeTests.swift),
  [presentation](../../Tests/HeelerTests/AgentUsagePresentationTests.swift),
  [scope](../../Tests/HeelerTests/AgentUsageScopeTests.swift),
  [page and interactions](../../Tests/HeelerTests/AgentUsagePageTests.swift),
  [limits and disclosure](../../Tests/HeelerTests/AgentUsageLimitsTests.swift),
  and [real SSH](../../Tests/HeelerTests/HeelerSSHTransportBehaviorE2ETests+Usage.swift).
  Process coverage is `plugin/test/usage-*.test.js`; the worker test produces
  the shared [usage-v1 vector](../../plugin/test-vectors/usage-v1.json).
  Price-table maintenance is in the [plugin README](../../plugin/README.md#maintaining-the-price-table).
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
  Registration state: [NotificationRegistrationFile](../../Sources/Heeler/Notifications/NotificationRegistrationFile.swift)
  models `notifications.json`, [NotificationRegistrationCeremony](../../Sources/Heeler/Notifications/NotificationRegistrationCeremony.swift)
  reads and replaces it over SSH, and [NotificationPreferencesStore](../../Sources/Heeler/Notifications/NotificationPreferencesStore.swift)
  owns the Settings toggles. Entries are scoped to a herdr session and owned by
  a Host's Notification Key ([ADR 0020](../adr/0020-session-scoped-notification-registrations.md));
  the plugin side is `plugin/src/session.js`.
- **Deep links:** `ContentView.onOpenURL` parses `heeler://agent` links with
  [AgentActivityLink](../../Sources/HeelerActivityCore/AgentActivityLink.swift),
  which also builds the Live Activity's links. Another app's link names its
  Host by address or name, and [AgentActivityLink+Hosts](../../Sources/Heeler/Notifications/AgentActivityLink+Hosts.swift)
  resolves it against the saved Hosts before `AgentSceneDirectory` routes it.
  Start with [AgentActivityLinkTests](../../Tests/HeelerTests/AgentActivityLinkTests.swift).

## Sibling deliverables and generated files

| Area | Entry and verification |
| --- | --- |
| herdr plugin | [plugin/README.md](../../plugin/README.md), `plugin/herdr-plugin.toml`, `npm test` in `plugin/`; `make plugin` ([publish-plugin.sh](../../scripts/publish-plugin.sh), `bash scripts/test-publish-plugin.sh`) publishes it to the `plugin` branch ([ADR 0026](../adr/0026-plugin-distribution-branch.md)) |
| Push Relay | [relay/README.md](../../relay/README.md), `npm test` in `relay/` |
| Marketing site | [landing](../../landing), its `package.json` scripts, [landing CI](../../.github/workflows/landing.yml) |
| Docs site | [docs-site/README.md](../../docs-site/README.md) publishes selected `docs/guides/` (English and `docs/guides/zh/`); `pnpm test`, `pnpm run check`, `pnpm run build`, `pnpm run check:links` in `docs-site/`, [docs site CI](../../.github/workflows/docs-site.yml) |
| Wire types | [generate-wire-types.py](../../scripts/generate-wire-types.py) consumes the committed [herdr-schema.json](../../scripts/herdr-schema.json); generated output is [Transport/Generated](../../Sources/Heeler/Transport/Generated) |
| App/package CI | [ci.yml](../../.github/workflows/ci.yml), [run-ci-ios-tests.sh](../../scripts/run-ci-ios-tests.sh), [testing.md](testing.md) |
| Node/codegen CI | [ci-node.yml](../../.github/workflows/ci-node.yml) |

Find a symbol before reading a large file: `rg -n 'symbol' Sources Tests`.
Follow definitions, construction sites, and state updates through the UI;
a search with no matching keyword alone does not establish feature absence.
