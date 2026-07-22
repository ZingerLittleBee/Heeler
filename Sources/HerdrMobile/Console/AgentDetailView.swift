import SwiftUI

/// The Agent detail screen: one interactive Attach terminal. Ghostty owns
/// rendering, scrollback, and IME; the adapter routes input-row taps and touch
/// scrolling without adding separate terminal chrome.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminalThemes: TerminalThemeSettings
    private let transport: @Sendable () async -> (any Transport)?
    @State private var store: AttachTerminalStore
    @State private var close: ClosePaneStore
    @State private var isConfirmingClose = false
    @State private var isShowingSettings = false
    @State private var closeErrorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminalThemes: TerminalThemeSettings
    ) {
        self.agent = agent
        self.console = console
        self.terminalThemes = terminalThemes
        let transport = console.transportProvider(for: agent.hostID)
        self.transport = transport
        _store = State(
            initialValue: AttachTerminalStore(
                target: agent.agent.paneID, transport: transport))
        _close = State(
            initialValue: ClosePaneStore(paneTitle: Self.displayTitle(for: agent)) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            })
    }

    var body: some View {
        TerminalScreenView(
            feed: store.feed,
            onSizeChanged: { cols, rows in
                store.viewDidResize(cols: cols, rows: rows)
            },
            onSend: { keystrokes in store.send(keystrokes) },
            theme: terminalThemes.theme
        )
        .id(ObjectIdentifier(store))
        .overlay { statusOverlay }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AgentStatusBadge(status: agent.agent.status)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Terminal Theme", systemImage: "paintpalette") {
                        isShowingSettings = true
                    }
                    Button("Close Agent", systemImage: "trash", role: .destructive) {
                        isConfirmingClose = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(terminalThemes: terminalThemes)
        }
        .confirmationDialog(
            "Close \(title)?", isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            Button("Close Agent", role: .destructive) {
                Task { await performClose() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This closes the pane on the Host and removes the agent everywhere. "
                    + "This can't be undone.")
        }
        .alert(
            "Couldn't Close Agent",
            isPresented: Binding(
                get: { closeErrorMessage != nil },
                set: { if !$0 { closeErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(closeErrorMessage ?? "")
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            guard generation != nil else { return }
            reconnect()
        }
        .onDisappear {
            let terminal = store
            console.scheduleTerminalTeardown(for: agent.hostID) {
                await terminal.stop()
            }
        }
    }

    private func reconnect() {
        let previous = store
        console.scheduleTerminalTeardown(for: agent.hostID) {
            await previous.stop()
        }
        store = AttachTerminalStore(target: agent.agent.paneID, transport: transport)
    }

    private func performClose() async {
        await close.confirmClose()
        switch close.state {
        case .closed:
            await store.stop()
            dismiss()
        case .failed(let message):
            closeErrorMessage = message
        case .idle, .closing:
            break
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status {
        case .waitingForSize, .connecting:
            ProgressView()
        case .ended(let message):
            ContentUnavailableView {
                Label("Session Ended", systemImage: "cable.connector.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Reattach") { store.retry() }
                    .buttonStyle(.borderedProminent)
            }
        case .live, .stopped:
            EmptyView()
        }
    }

    private var title: String {
        Self.displayTitle(for: agent)
    }

    private static func displayTitle(for agent: ConsoleAgent) -> String {
        agent.agent.title.isEmpty ? agent.agent.displayName : agent.agent.title
    }
}
