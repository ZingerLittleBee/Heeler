import SwiftUI

/// The default Agent detail surface (ADR 0012). It reads one local-rendered
/// snapshot and pushes the existing live terminal only when the user chooses
/// Attach.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    private let isOnStage: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var monitor: AgentMonitorStore
    @State private var composer: AgentComposerStore
    @State private var attach: AgentAttachStore
    @State private var isShowingAttach = false

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        isOnStage: @escaping () -> Bool,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        monitorStore: AgentMonitorStore? = nil,
        composerStore: AgentComposerStore? = nil,
        attachStore: AgentAttachStore? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        self.isOnStage = isOnStage
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        _monitor = State(
            initialValue: monitorStore
                ?? AgentMonitorStore(
                    target: agent.agent.paneID,
                    initialStatus: agent.agent.status,
                    statusUpdates: console.agentStatusUpdates(for: agent.id),
                    read: { [console, agent] params in
                        try await console.readAgent(params, on: agent.hostID)
                    },
                    sendKeys: { [console, agent] params in
                        try await console.sendAgentKeys(params, on: agent.hostID)
                    }))
        _composer = State(
            initialValue: composerStore ?? console.composerStore(for: agent))
        _attach = State(
            initialValue: attachStore
                ?? AgentAttachStore(
                    target: agent.agent.paneID,
                    paneTitle: AgentAttachView.displayTitle(for: agent),
                    transportGeneration: console.hostConnectionGenerations[agent.hostID],
                    isOnStage: isOnStage,
                    runTerminal: console.terminalRunner(for: agent.hostID),
                    stageImage: console.imageStager(for: agent.hostID)
                ) {
                    try await console.closePane(agent.agent.paneID, on: agent.hostID)
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            monitorSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            AgentComposerView(
                store: composer,
                isControlKeyEnabled: !monitor.isSendingKey
            ) { key in
                Task { await monitor.send(key) }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    agentStatus
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .primaryAction) {
                attachButton
            }
        }
        .navigationDestination(isPresented: $isShowingAttach) {
            AgentAttachView(
                agent: agent,
                console: console,
                terminal: terminal,
                hosts: hosts,
                activity: activity,
                keyboardHandoff: keyboardHandoff,
                keyboardInset: keyboardInset,
                isOnStage: isOnStage,
                onSwitch: onSwitch,
                onClosed: onClosed,
                attachStore: attach)
        }
        .onChange(of: isShowingAttach) { wasShowing, isShowing in
            guard wasShowing, !isShowing else { return }
            Task {
                await attach.leave().value
                await monitor.refreshOnReturn()
            }
        }
        .task {
            composer.open()
            await monitor.open()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            monitor.setForeground(phase == .active)
        }
    }

    @ViewBuilder
    private var monitorSurface: some View {
        if let snapshot = monitor.snapshot {
            if snapshot.characters.isEmpty {
                emptyConversation
            } else {
                snapshotScrollView(snapshot)
            }
        } else {
            switch monitor.state {
            case .failed(let message):
                failedConversation(message)
            case .idle, .loading, .loaded:
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Agent response…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func snapshotScrollView(_ snapshot: AttributedString) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    monitorNotices
                    historyTopMarker
                    agentTurn(snapshot)

                    if let sendError = monitor.sendError {
                        Label(sendError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                Color.red.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12))
                    }

                    AgentSentMessagesView(store: composer)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.outputBottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .refreshable { await monitor.refresh() }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            } action: { _, isPinned in
                monitor.setBottomPinned(isPinned)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.minY <= 24
            } action: { _, isAtTop in
                guard isAtTop else { return }
                monitor.topEdgeReached()
            }
            .onChange(of: monitor.contentChangeCount) {
                guard monitor.isBottomPinned else { return }
                proxy.scrollTo(Self.outputBottomID, anchor: .bottom)
            }
            .onChange(of: composer.messages.count) {
                guard monitor.isBottomPinned else { return }
                proxy.scrollTo(Self.outputBottomID, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if monitor.hasNewOutput {
                    Button("Jump to latest", systemImage: "arrow.down") {
                        monitor.jumpToLatestOutput()
                        proxy.scrollTo(Self.outputBottomID, anchor: .bottom)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(20)
                }
            }
        }
    }

    private var emptyConversation: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
                monitorNotices
                AgentConversationStateView(
                    systemImage: "rectangle.dashed",
                    title: "No Agent response yet",
                    message: "The latest snapshot is empty. Refresh to check again.",
                    actionTitle: "Refresh"
                ) {
                    Task { await monitor.refresh() }
                }
                AgentSentMessagesView(store: composer)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        }
        .refreshable { await monitor.refresh() }
    }

    private func failedConversation(_ message: String) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
                monitorNotices
                AgentConversationStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Unable to load the Agent response",
                    message: message,
                    actionTitle: "Try again"
                ) {
                    Task { await monitor.retry() }
                }
                AgentSentMessagesView(store: composer)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        }
        .refreshable { await monitor.refresh() }
    }

    private func agentTurn(_ snapshot: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot)
                .font(snapshotFont)
                .lineSpacing(horizontalSizeClass == .compact ? 2 : 3)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(horizontalSizeClass == .compact ? 12 : 16)
                .background(
                    Color.black.opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)

            snapshotFreshness
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent response")
    }

    private var agentStatus: some View {
        HStack(spacing: 4) {
            if monitor.agentStatus == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(monitor.agentStatus.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(monitor.agentStatus.rawValue.capitalized)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(monitor.agentStatus.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(monitor.agentStatus.rawValue.capitalized)
    }

    private var snapshotFont: Font {
        horizontalSizeClass == .compact
            ? .system(.footnote, design: .monospaced)
            : .system(.callout, design: .monospaced)
    }

    /// The only place history states are visible: a thin marker above the
    /// cached content. While the Agent works the notice replaces any
    /// spinner outright — history is unavailable, never "loading".
    @ViewBuilder
    private var historyTopMarker: some View {
        if monitor.agentStatus == .working, monitor.historyState != .exhausted {
            historyMarkerLabel(
                "History unavailable while the Agent works",
                systemImage: "clock.badge.exclamationmark")
        } else {
            switch monitor.historyState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading earlier history…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            case .unavailable:
                historyMarkerLabel(
                    "History unavailable while the Agent works",
                    systemImage: "clock.badge.exclamationmark")
            case .exhausted:
                historyMarkerLabel(
                    "Beginning of captured history",
                    systemImage: "arrow.up.to.line")
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await monitor.loadEarlierHistory() } }
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            case .idle:
                EmptyView()
            }
        }
    }

    private func historyMarkerLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var snapshotFreshness: some View {
        if let capturedAt = monitor.capturedAt {
            Text("Updated \(capturedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("Waiting for the first snapshot")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var attachButton: some View {
        Button("Terminal", systemImage: "terminal") {
            monitor.attachDidOpen()
            isShowingAttach = true
        }
        .accessibilityHint("Opens the live terminal")
    }

    private var title: String {
        AgentAttachView.displayTitle(for: agent)
    }

    @ViewBuilder
    private var monitorNotices: some View {
        if !monitor.liveUpdatesAvailable {
            conversationNotice(
                "Updates are paused. Pull down to refresh.",
                systemImage: "wifi.slash")
        }
        if monitor.snapshot != nil, case .failed(let message) = monitor.state {
            HStack(alignment: .center, spacing: 8) {
                Label(
                    "Refresh failed. Showing the last response. \(message)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                Spacer(minLength: 8)
                Button("Try again") { Task { await monitor.retry() } }
                    .font(.footnote)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.orange.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func conversationNotice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private static let outputBottomID = "agent-monitor-output-bottom"
}

private struct AgentConversationStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
