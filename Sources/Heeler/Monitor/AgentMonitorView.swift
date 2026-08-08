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
    @State private var monitor: AgentMonitorStore
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
            initialValue: monitorStore ?? AgentMonitorStore(target: agent.agent.paneID) {
                [console, agent] params in
                try await console.readAgent(params, on: agent.hostID)
            })
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
        monitorSurface
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
            .task { await monitor.open() }
    }

    @ViewBuilder
    private var monitorSurface: some View {
        if let snapshot = monitor.snapshot {
            VStack(spacing: 0) {
                statusHeader
                Divider()
                if snapshot.characters.isEmpty {
                    ContentUnavailableView(
                        "No Output", systemImage: "rectangle.dashed",
                        description: Text("The Agent's latest screen is empty."))
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(snapshot)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding()
                    }
                }
            }
        } else {
            switch monitor.state {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Screen", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
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

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let capturedAt = monitor.capturedAt {
                Label(
                    "Updated \(capturedAt.formatted(date: .omitted, time: .standard))",
                    systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
}
