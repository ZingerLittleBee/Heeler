import SwiftUI

/// The Agent detail screen (#9, #10): scrollback plus live output in a real
/// terminal, read-only (Observe semantics per CONTEXT.md), with a native
/// input bar below it (#10) for answering a Blocked agent without Attach.
/// The full interactive Attach terminal arrives with #11.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    @State private var store: ObserveTerminalStore
    @State private var input: AgentInputStore

    init(agent: ConsoleAgent, console: ConsoleStore) {
        self.agent = agent
        let transport = console.transportProvider(for: agent.hostID)
        _store = State(
            initialValue: ObserveTerminalStore(
                target: agent.agent.paneID, transport: transport))
        _input = State(
            initialValue: AgentInputStore(
                target: agent.agent.paneID, transport: transport))
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalScreenView(feed: store.feed) { cols, rows in
                store.viewDidResize(cols: cols, rows: rows)
            }
            .overlay { statusOverlay }

            AgentInputBar(store: input)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AgentStatusBadge(status: agent.agent.status)
            }
        }
        .onDisappear {
            // Explicit close, never abandonment: a live exec channel ignores
            // task cancellation (ADR 0002).
            Task { await store.stop() }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status {
        case .waitingForSize, .connecting:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Live View Unavailable", systemImage: "tv.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { store.retry() }
                    .buttonStyle(.borderedProminent)
            }
        case .live, .stopped:
            EmptyView()
        }
    }

    private var title: String {
        agent.agent.title.isEmpty ? agent.agent.kind : agent.agent.title
    }
}
