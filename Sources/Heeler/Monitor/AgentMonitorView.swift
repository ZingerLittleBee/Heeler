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
            Divider()
            AgentComposerView(store: composer)
        }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Attach", systemImage: "terminal") {
                        monitor.attachDidOpen()
                        isShowingAttach = true
                    }
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
            VStack(spacing: 0) {
                statusHeader
                Divider()
                if snapshot.characters.isEmpty {
                    ScrollView {
                        ContentUnavailableView(
                            "No Output", systemImage: "rectangle.dashed",
                            description: Text("The Agent's latest screen is empty."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }
                    .refreshable { await monitor.refresh() }
                } else {
                    snapshotScrollView(snapshot)
                }
                if let sendError = monitor.sendError {
                    Text(sendError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                MonitorControlKeyStrip(isEnabled: !monitor.isSendingKey) { key in
                    Task { await monitor.send(key) }
                }
            }
        } else {
            switch monitor.state {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Screen", systemImage: "exclamationmark.triangle")
                } description: {
                    VStack(spacing: 8) {
                        Text(message)
                        if !monitor.liveUpdatesAvailable {
                            liveUpdatesUnavailableLabel
                        }
                    }
                } actions: {
                    Button("Retry") { Task { await monitor.retry() } }
                        .buttonStyle(.borderedProminent)
                }
            case .idle, .loading, .loaded:
                ProgressView("Loading latest screen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func snapshotScrollView(_ snapshot: AttributedString) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    historyTopMarker
                    Text(snapshot)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.outputBottomID)
                }
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
            .overlay(alignment: .bottomTrailing) {
                if monitor.hasNewOutput {
                    Button("New Output", systemImage: "arrow.down") {
                        monitor.jumpToLatestOutput()
                        withAnimation(.snappy) {
                            proxy.scrollTo(Self.outputBottomID, anchor: .bottom)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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
                .padding(.horizontal)
                .padding(.vertical, 10)
            case .idle:
                EmptyView()
            }
        }
    }

    private func historyMarkerLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Agent output")
                    .font(.subheadline.weight(.semibold))
                AgentStatusBadge(status: monitor.agentStatus)
                Spacer(minLength: 8)
                if let capturedAt = monitor.capturedAt {
                    Label(
                        "Updated \(capturedAt.formatted(date: .omitted, time: .standard))",
                        systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !monitor.liveUpdatesAvailable {
                liveUpdatesUnavailableLabel
            }
            if case .failed(let message) = monitor.state {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await monitor.retry() } }
                        .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var title: String {
        AgentAttachView.displayTitle(for: agent)
    }

    private var liveUpdatesUnavailableLabel: some View {
        Label(
            "Live updates unavailable. Pull to refresh.",
            systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private static let outputBottomID = "agent-monitor-output-bottom"
}
