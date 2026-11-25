import SwiftUI

/// Hand Off, as an Agent's detail and its row in the Agents list name it.
enum HandOffCopy {
    static let action = String(localized: "Hand Off")
    static let symbol = "arrowshape.turn.up.right"
}

/// The Agent whose conversation a Hand Off gives away.
struct HandOffRequest: Identifiable, Equatable, Sendable {
    let source: ConsoleAgent

    var id: ConsoleAgent.ID { source.id }
}

/// Hand Off: what the receiving Agent is asked to do with the conversation,
/// then which Agent gets it. Picking one writes the record and fills that
/// Agent's Composer; the sheet sends nothing.
struct HandOffSheet: View {
    @State private var store: HandOffStore
    @State private var isStartingAgent = false
    @State private var newAgentDetent = PresentationDetent.large
    let console: ConsoleStore
    let hosts: [Host]
    /// The Agent whose Composer now holds the Hand Off.
    let onHandedOff: (ConsoleAgent.ID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        store: HandOffStore, console: ConsoleStore, hosts: [Host],
        onHandedOff: @escaping (ConsoleAgent.ID) -> Void
    ) {
        _store = State(initialValue: store)
        self.console = console
        self.hosts = hosts
        self.onHandedOff = onHandedOff
    }

    var body: some View {
        @Bindable var store = store
        let source = store.source
        let targets = console.handOffTargets(for: source)
        let startsAgents = console.capabilities(for: source.hostID).startsAgents
        NavigationStack {
            List {
                // First, where a sheet at half height still shows it.
                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.errorInk)
                    }
                }
                Section {
                    Picker("Ask the Agent to", selection: $store.mode) {
                        ForEach(HandOffMode.allCases) { @Sendable mode in
                            MainActorContent {
                                Text(verbatim: mode.title).tag(mode)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(store.isWorking)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(verbatim: store.mode.explanation)
                }
                Section {
                    ForEach(targets) { @Sendable agent in
                        MainActorContent {
                            agentRow(agent)
                        }
                    }
                    if startsAgents {
                        newAgentRow
                    }
                } header: {
                    Text("Hand Off To")
                } footer: {
                    Text(
                        "Heeler writes this conversation to a file on \(source.hostName) and puts a message about it in that Agent's Composer. Nothing is sent until you send it.",
                        comment: "Hand Off footer. The placeholder is the Host's name.")
                }
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationTitle("Hand Off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: store.state) {
                if case .handedOff(let id) = store.state {
                    onHandedOff(id)
                    dismiss()
                }
            }
            .onDisappear { store.cancel() }
            .sheet(isPresented: $isStartingAgent) {
                // StartAgentView brings its own NavigationStack.
                StartAgentView(
                    hosts: hosts,
                    console: console,
                    origin: StartAgentStore.LaunchOrigin(beside: source, in: console),
                    onStarted: { id in
                        Task { await store.handOff(toStarted: id) }
                    }
                )
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass),
                    fitsContent: true))
                // This sheet's detents, opening at the large one this sheet
                // takes on beneath it. Without them an iPad gave New Agent a
                // form's height, and Hand Off showed below it.
                .presentationDetents([.medium, .large], selection: $newAgentDetent)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func agentRow(_ agent: ConsoleAgent) -> some View {
        let mark = AgentKindMark(kind: agent.agent.kind)
        let title = AgentTerminalView.displayTitle(for: agent)
        // An Agent with no title of its own is named by its program already.
        let program = title.caseInsensitiveCompare(mark.label) == .orderedSame ? nil : mark.label
        let detail = [program, agent.workspaceLabel].compactMap { $0 }.joined(separator: " · ")
        return Button {
            Task { await store.handOff(to: agent.id) }
        } label: {
            HStack(spacing: 12) {
                AgentStatusAvatar(mark: mark, status: agent.agent.status, diameter: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1)
                    if !detail.isEmpty {
                        // A Button's label tints `.secondary`, so name the color.
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if store.isWorking(on: .agent(agent.id)) {
                    ProgressView()
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isWorking)
    }

    private var newAgentRow: some View {
        Button {
            Task {
                if await store.prepareForNewAgent() {
                    newAgentDetent = .large
                    isStartingAgent = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                Label {
                    Text("New Agent…")
                        .foregroundStyle(Color(uiColor: .label))
                } icon: {
                    Image(systemName: "plus")
                }
                Spacer(minLength: 0)
                if store.isWorking(on: .newAgent) {
                    ProgressView()
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isWorking)
    }
}

/// Presents Hand Off for a request, from the Agents list or an Agent's detail.
struct HandOffSheetPresenter: ViewModifier {
    @Binding var request: HandOffRequest?
    let console: ConsoleStore
    let hosts: [Host]
    /// The Agent whose Composer now holds the Hand Off, for the presenter to open.
    let onHandedOff: (ConsoleAgent.ID) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            // Fixed at open: following a resize rebuilt the sheet, closing
            // New Agent over it and forgetting the chosen ask.
            ConsoleSheetContent(ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)) { presentation in
                HandOffSheet(
                    store: HandOffStore(
                        source: request.source,
                        read: { [console] in try await console.handOffSource(for: request.source) },
                        deliver: { [console] record, message, id in
                            try await console.deliverHandOff(record, message: message, to: id)
                        }),
                    console: console, hosts: hosts, onHandedOff: onHandedOff
                )
                .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
            }
        }
    }
}
