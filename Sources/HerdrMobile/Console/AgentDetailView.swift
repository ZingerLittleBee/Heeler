import SwiftUI

/// Owns Dictation for one Agent detail and translates every surface-level
/// interruption into the same discard-and-release behavior. Keeping these
/// events together prevents a shared microphone engine from surviving a
/// navigation, Attach handover, or app background transition.
@MainActor
final class AgentDetailDictationSession {
    enum Interruption: CaseIterable, Sendable {
        case detailDisappeared
        case openingAttach
        case appBackgrounded
    }

    let dictation: DictationStore

    init(dictation: DictationStore) {
        self.dictation = dictation
    }

    func handle(_ interruption: Interruption) {
        switch interruption {
        case .detailDisappeared, .openingAttach, .appBackgrounded:
            dictation.cancelDictation()
        }
    }
}

/// The Agent detail screen (#9, #10): scrollback plus live output in a real
/// terminal, read-only (Observe semantics per CONTEXT.md), with a native
/// input bar below it (#10) for answering a Blocked agent without Attach,
/// and the full interactive Attach terminal (#11) behind the toolbar button.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    /// Shared app-level Dictation settings, held so the error row's
    /// model-not-ready hint can present the Settings sheet (User Story 15).
    private let dictationSettings: DictationSettingsStore
    /// Kept for the Observe/Attach handover: fresh stores are minted per
    /// surface switch, all sharing this provider.
    private let transport: @Sendable () async -> (any Transport)?
    @State private var store: ObserveTerminalStore
    @State private var input: AgentInputStore
    @State private var dictationSession: AgentDetailDictationSession
    @State private var attach: AttachTerminalStore?
    @State private var close: ClosePaneStore
    @State private var isConfirmingClose = false
    @State private var closeErrorMessage: String?
    @State private var isShowingSettings = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(
        agent: ConsoleAgent, console: ConsoleStore,
        dictationSettings: DictationSettingsStore, dictationEngine: any DictationEngine
    ) {
        self.agent = agent
        self.console = console
        self.dictationSettings = dictationSettings
        let transport = console.transportProvider(for: agent.hostID)
        self.transport = transport
        _store = State(
            initialValue: ObserveTerminalStore(
                target: agent.agent.paneID, transport: transport))
        let inputStore = AgentInputStore(target: agent.agent.paneID, transport: transport)
        _input = State(initialValue: inputStore)
        _dictationSession = State(
            initialValue: AgentDetailDictationSession(
                dictation: DictationStore(
                    engine: dictationEngine, draft: inputStore,
                    language: { dictationSettings.selectedLanguage })))
        _close = State(
            initialValue: ClosePaneStore(paneTitle: Self.displayTitle(for: agent)) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalScreenView(
                feed: store.feed,
                onSizeChanged: { cols, rows in
                    store.viewDidResize(cols: cols, rows: rows)
                },
                onLoadEarlier: { store.loadEarlier() })
            // Keyed on the store: resuming Observe after Attach mints a
            // fresh store, whose feed must get a freshly attached view.
            .id(ObjectIdentifier(store))
            .overlay(alignment: .top) {
                if store.isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .accessibilityLabel("Loading earlier output")
                        .allowsHitTesting(false)
                }
            }
            .overlay { statusOverlay }

            AgentInputBar(
                store: input, dictation: dictationSession.dictation,
                onOpenSettings: { isShowingSettings = true })
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AgentStatusBadge(status: agent.agent.status)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Attach", systemImage: "keyboard") {
                    openAttach()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // Destructive, explicit-confirmation only: closing a pane
                    // destroys the agent, so there is deliberately no
                    // swipe-to-close anywhere (#13, User Story 9).
                    Button("Close Agent", systemImage: "trash", role: .destructive) {
                        isConfirmingClose = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
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
        .fullScreenCover(item: $attach, onDismiss: resumeObserve) { attachStore in
            AttachTerminalView(store: attachStore, title: title)
        }
        .sheet(isPresented: $isShowingSettings) {
            // Same shared settings store the Console gear opens; the error row's
            // model-not-ready hint routes here to download the model (#34).
            SettingsView(store: dictationSettings)
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            guard generation != nil, attach == nil else { return }
            reconnectObserve()
        }
        .onChange(of: scenePhase) {
            // First-use microphone permission can make the scene inactive; only
            // actual backgrounding should cancel that same startup attempt.
            if scenePhase == .background {
                dictationSession.handle(.appBackgrounded)
            }
        }
        .onDisappear {
            dictationSession.handle(.detailDisappeared)
            // Explicit close, never abandonment: a live exec channel ignores
            // task cancellation (ADR 0002). Registering with the Console is
            // synchronous, so the next detail waits for this channel close.
            let observe = store
            console.scheduleTerminalTeardown(for: agent.hostID) {
                await observe.stop()
            }
        }
    }

    /// Observe -> Attach handover: the two surfaces share the Host's single
    /// terminal channel, so Observe must be fully stopped (channel torn
    /// down) before the Attach screen appears and opens its own.
    private func openAttach() {
        dictationSession.handle(.openingAttach)
        let observe = store
        let attachStore = AttachTerminalStore(target: agent.agent.paneID, transport: transport)
        Task {
            await observe.stop()
            attach = attachStore
        }
    }

    /// Attach -> Observe handover, after the cover is dismissed (its Detach
    /// button stops the session before dismissing). `stop()` is terminal, so
    /// resuming means a fresh store; the `.id` above rebuilds the terminal
    /// view around it.
    private func resumeObserve() {
        let previous = store
        let replacement = ObserveTerminalStore(
            target: agent.agent.paneID, transport: transport)
        replacement.reuseViewSize(from: previous)
        store = replacement
    }

    /// A real Host reconnect means the old terminal stream is permanently
    /// closed. Register its teardown before minting the replacement; the new
    /// store's transport provider waits for that task before taking the Host's
    /// single terminal channel.
    private func reconnectObserve() {
        let observe = store
        console.scheduleTerminalTeardown(for: agent.hostID) {
            await observe.stop()
        }
        resumeObserve()
    }

    /// Confirmed close: fire `pane.close`, and only on success stop Observe
    /// (the closed pane ends its stream — stopping first keeps that teardown
    /// from flashing the failure overlay) and leave the now-gone Agent's
    /// screen. A failed close leaves everything untouched and surfaces why.
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
        Self.displayTitle(for: agent)
    }

    /// The Agent's screen title, shared with the close store's dialog copy so
    /// both name the same thing.
    private static func displayTitle(for agent: ConsoleAgent) -> String {
        agent.agent.title.isEmpty ? agent.agent.displayName : agent.agent.title
    }
}
