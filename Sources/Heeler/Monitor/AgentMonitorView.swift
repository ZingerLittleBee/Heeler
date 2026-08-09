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
            initialValue: monitorStore ?? AgentMonitorStore(
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
            initialValue: attachStore ?? AgentAttachStore(
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
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
        VStack(spacing: 0) {
            monitorHeader
            if let snapshot = monitor.snapshot {
                if snapshot.characters.isEmpty {
                    ScrollView(.vertical) {
                        VStack(spacing: 16) {
                            ContentUnavailableView {
                                Label("No Agent output", systemImage: "rectangle.dashed")
                            } description: {
                                Text("The latest snapshot is empty. Refresh to check again.")
                            } actions: {
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    Task { await monitor.refresh() }
                                }
                                .buttonStyle(.bordered)
                            }

                            // Empty snapshots still stamp capturedAt, but nothing is
                            // on screen — do not collapse delivered echoes as "earlier".
                            AgentSentMessagesView(store: composer, capturedAt: nil)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }
                    .refreshable { await monitor.refresh() }
                } else {
                    snapshotScrollView(snapshot)
                }
            } else {
                switch monitor.state {
                case .failed(let message):
                    ScrollView(.vertical) {
                        VStack(spacing: 16) {
                            ContentUnavailableView {
                                Label(
                                    "Unable to load Agent output",
                                    systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(message)
                            } actions: {
                                Button("Try again", systemImage: "arrow.clockwise") {
                                    Task { await monitor.retry() }
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            AgentSentMessagesView(store: composer, capturedAt: monitor.capturedAt)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }
                case .idle, .loading, .loaded:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Agent output…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func snapshotScrollView(_ snapshot: AttributedString) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    historyTopMarker
                    Text("Agent output")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(snapshot)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16))

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

                    AgentSentMessagesView(store: composer, capturedAt: monitor.capturedAt)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.outputBottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var monitorHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    monitorIdentity
                    Spacer(minLength: 12)
                    attachButton
                }

                VStack(alignment: .leading, spacing: 12) {
                    monitorIdentity
                    attachButton
                }
            }

            if !monitor.liveUpdatesAvailable {
                liveUpdatesUnavailableLabel
            }
            if monitor.snapshot != nil, case .failed(let message) = monitor.state {
                HStack(alignment: .center, spacing: 8) {
                    Label(
                        "Refresh failed. Showing the last snapshot. \(message)",
                        systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                    Spacer(minLength: 8)
                    Button("Try again") { Task { await monitor.retry() } }
                        .font(.footnote)
                }
                .padding(12)
                .background(
                    Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var monitorIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monitor")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    AgentStatusBadge(status: monitor.agentStatus)
                    snapshotFreshness
                }

                VStack(alignment: .leading, spacing: 8) {
                    AgentStatusBadge(status: monitor.agentStatus)
                    snapshotFreshness
                }
            }
        }
    }

    @ViewBuilder
    private var snapshotFreshness: some View {
        if let capturedAt = monitor.capturedAt {
            Label(
                "Updated \(capturedAt.formatted(date: .omitted, time: .shortened))",
                systemImage: "clock")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("Waiting for the first snapshot")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var attachButton: some View {
        Button("Attach", systemImage: "terminal") {
            monitor.attachDidOpen()
            isShowingAttach = true
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .accessibilityHint("Opens the live terminal")
    }

    private var title: String {
        AgentAttachView.displayTitle(for: agent)
    }

    private var liveUpdatesUnavailableLabel: some View {
        Label(
            "Updates are paused. Pull down to refresh.",
            systemImage: "wifi.slash")
            .font(.footnote)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private static let outputBottomID = "agent-monitor-output-bottom"
}
