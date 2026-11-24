import SwiftUI

/// Send to Agent: what the Agent is asked to do with a pull request or an
/// issue, then which Agent on the item's Host gets it. Picking one puts the
/// message in that Agent's Composer and opens it; the sheet sends nothing.
struct GitHubSendSheet: View {
    @State private var store: GitHubSendStore
    let gitHub: GitHubStore
    let console: ConsoleStore
    /// The Agent whose Composer now holds the message.
    let onSent: (ConsoleAgent.ID) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        store: GitHubSendStore, gitHub: GitHubStore, console: ConsoleStore,
        onSent: @escaping (ConsoleAgent.ID) -> Void
    ) {
        _store = State(initialValue: store)
        self.gitHub = gitHub
        self.console = console
        self.onSent = onSent
    }

    var body: some View {
        let request = store.request
        let detail = gitHub.detailState(of: request.item, on: request.host).detail
        let item = detail?.item ?? request.item
        let modes = GitHubSendMode.modes(
            for: item, detail: detail, viewer: detail?.viewer ?? gitHub.state(of: request.host).list?.login)
        let mode = store.mode(in: modes)
        let message = mode.message(for: item)
        let agents = console.gitHubSendTargets(on: request.host.records)
        let targets = GitHubSendTarget.ordered(
            agents, checkouts: store.checkouts, item: item, headBranch: detail?.pullRequest?.headBranch)
        NavigationStack {
            List {
                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(modes) { candidate in
                        modeRow(candidate, isSelected: candidate == mode)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 14) {
                        itemLine(item)
                        Text("Ask the Agent To")
                    }
                } footer: {
                    Text(verbatim: message)
                }
                Section {
                    if targets.isEmpty {
                        Text("No Agent on \(request.host.name) can take a message now.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(targets) { target in
                        agentRow(target, message: message)
                    }
                    // A New Agent row, once the sheet can start one, goes last here.
                } header: {
                    HStack(spacing: 6) {
                        Text("Send To")
                        if store.isReadingCheckouts {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    Text("Heeler puts this message in that Agent's Composer. Nothing is sent until you send it.")
                }
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationTitle("Send to Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: Set(agents.compactMap(\.directory))) {
                await store.readCheckouts(of: agents.compactMap(\.directory))
            }
            .onChange(of: store.state) {
                if case .sent(let id) = store.state {
                    onSent(id)
                    dismiss()
                }
            }
            .onDisappear { store.cancel() }
        }
        .presentationDetents([.medium, .large])
    }

    private func itemLine(_ item: GitHubItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: GitHubItemRow.symbol(for: item))
                .foregroundStyle(GitHubItemRow.tint(for: item))
            Text(verbatim: "\(item.repositoryName) #\(item.number)")
                .foregroundStyle(.secondary)
            Text(item.title)
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(1)
        }
        .font(.subheadline)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private func modeRow(_ mode: GitHubSendMode, isSelected: Bool) -> some View {
        Button {
            store.chosenMode = mode
        } label: {
            HStack {
                Text(mode.title)
                    .foregroundStyle(Color(uiColor: .label))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isWorking)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func agentRow(_ target: GitHubSendTarget, message: String) -> some View {
        let agent = target.agent
        let kind = AgentKindMark(kind: agent.agent.kind)
        let title = AgentTerminalView.displayTitle(for: agent)
        let detail = agent.directory.map(agent.displayPath) ?? kind.label
        return Button {
            Task { await store.send(message, to: agent.id) }
        } label: {
            HStack(spacing: 12) {
                AgentStatusAvatar(mark: kind, status: agent.agent.status, diameter: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1)
                    // A Button's label tints `.secondary`, so name the color.
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if store.state == .working(agent.id) {
                    ProgressView()
                } else if let mark = target.mark {
                    Text(mark == .onBranch ? String(localized: "On this branch") : String(localized: "This repository"))
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isWorking)
    }
}

/// Presents Send to Agent for a request from a pull request's or an issue's
/// detail. It sits on the Console, as Hand Off does, so the Agent it opens
/// can take the screen from the GitHub tab.
struct GitHubSendSheetPresenter: ViewModifier {
    @Binding var request: GitHubSendRequest?
    let console: ConsoleStore
    /// The Agent whose Composer now holds the message, for the presenter to open.
    let onSent: (ConsoleAgent.ID) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            GitHubSendSheet(
                store: GitHubSendStore(
                    request: request,
                    readCheckouts: { [gitHub = console.gitHub] directories in
                        await gitHub.readCheckouts(directories, on: request.host)
                    },
                    deliver: { [console] message, id in try await console.deliverDraft(message, to: id) }),
                gitHub: console.gitHub, console: console, onSent: onSent
            )
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
    }
}
