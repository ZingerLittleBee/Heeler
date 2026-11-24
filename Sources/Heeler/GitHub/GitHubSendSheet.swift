import SwiftUI

/// Send to Agent: what the Agent is asked to do with a pull request or an
/// issue, then which Agent on the item's Host gets it. Picking one puts the
/// message in that Agent's Composer and opens it; the sheet sends nothing.
struct GitHubSendSheet: View {
    @State private var store: GitHubSendStore
    /// New Agent's form, opened from this sheet.
    @State private var newAgent: NewAgent?
    @State private var newAgentDetent = PresentationDetent.large
    /// The Agent New Agent started, which takes the message once the form
    /// has gone and the Agent is listed.
    @State private var startedAgent: StartedAgent?
    let gitHub: GitHubStore
    let console: ConsoleStore
    /// The Servers New Agent can start on, as the Console's New Agent has them.
    let hosts: [Host]
    /// The Agent whose Composer now holds the message.
    let onSent: (ConsoleAgent.ID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// New Agent for the message the sheet showed when it was chosen.
    private struct NewAgent: Identifiable {
        let id = UUID()
        let message: String
        let launch: StartAgentStore.GitHubLaunch
    }

    private struct StartedAgent {
        let id: ConsoleAgent.ID
        let message: String
    }

    init(
        store: GitHubSendStore, gitHub: GitHubStore, console: ConsoleStore, hosts: [Host],
        onSent: @escaping (ConsoleAgent.ID) -> Void
    ) {
        _store = State(initialValue: store)
        self.gitHub = gitHub
        self.console = console
        self.hosts = hosts
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
        let servers = newAgentServers(of: request.host)
        NavigationStack {
            List {
                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(GitHubInk.red)
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
                    if !servers.isEmpty {
                        newAgentRow {
                            // Only an Agent this form starts takes the message.
                            startedAgent = nil
                            newAgentDetent = .large
                            newAgent = NewAgent(
                                message: message,
                                launch: launch(for: item, detail: detail, targets: targets, servers: servers))
                        }
                    }
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
            // The message goes once the form has left the screen: opening the
            // Agent while it is still going drops the Agent list's selection.
            .sheet(item: $newAgent, onDismiss: deliverToStartedAgent) { newAgent in
                // StartAgentView brings its own NavigationStack.
                StartAgentView(
                    hosts: hosts, console: console, gitHubLaunch: newAgent.launch,
                    onStarted: { id in
                        startedAgent = StartedAgent(id: id, message: newAgent.message)
                    }
                )
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass),
                    fitsContent: true))
                // This sheet's detents, opening at the large one this sheet
                // takes on beneath it. Without them an iPad gave New Agent
                // a form's height, and this sheet showed below it; with
                // `.large` alone it still did.
                .presentationDetents([.medium, .large], selection: $newAgentDetent)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func deliverToStartedAgent() {
        guard let startedAgent else { return }
        Task { await store.send(startedAgent.message, to: startedAgent.id) }
    }

    /// The Host's connected Servers that start Agents, in its order. A Rex
    /// Server starts none.
    private func newAgentServers(of host: GitHubHost) -> [Host.ID] {
        host.records.filter { id in
            hosts.contains { $0.id == id } && console.isConnected(id) && console.capabilities(for: id).startsAgents
        }
    }

    /// New Agent opens on the Workspace of the first Agent that works in a
    /// checkout of the item's repository, as the list orders them, and its
    /// Worktree follows the item there.
    private func launch(
        for item: GitHubItem, detail: GitHubItemDetail?, targets: [GitHubSendTarget], servers: [Host.ID]
    ) -> StartAgentStore.GitHubLaunch {
        let host = URL(string: item.url)?.host() ?? "github.com"
        let checkouts: [StartAgentStore.GitHubLaunch.Checkout] = targets.compactMap { target in
            let agent = target.agent
            guard target.mark != nil, let directory = agent.directory, let checkout = store.checkouts[directory],
                let remote = checkout.remote(for: item.repository, host: host)
            else { return nil }
            var checkedOut: [String: String] = [:]
            for worktree in checkout.worktrees {
                if let branch = worktree.branch { checkedOut[branch] = agent.displayPath(worktree.path) }
            }
            // The checkout's own branch even when the list did not answer.
            if let branch = checkout.branch { checkedOut[branch] = agent.displayPath(checkout.topLevel) }
            return StartAgentStore.GitHubLaunch.Checkout(
                hostID: agent.hostID, workspaceID: agent.agent.workspaceID,
                agentName: AgentTerminalView.displayTitle(for: agent),
                topLevel: checkout.topLevel, remote: remote.name, checkedOut: checkedOut)
        }
        let preset = checkouts.first { servers.contains($0.hostID) }
        let source: GitHubWorktreeStart.Source? =
            switch item.kind {
            case .pullRequest:
                detail?.pullRequest.map { pullRequest in
                    .pullRequest(
                        number: item.number, headBranch: pullRequest.headBranch,
                        isCrossRepository: pullRequest.isCrossRepository)
                }
            case .issue:
                detail?.defaultBranch.map { .defaultBranch($0) }
            }
        return StartAgentStore.GitHubLaunch(
            repository: item.repository, hostName: store.request.host.name,
            hostID: preset?.hostID ?? servers.first, workspaceID: preset?.workspaceID,
            source: source, defaultBranch: detail?.defaultBranch, checkouts: checkouts,
            worktreeStart: { [gitHub] start, record in try await gitHub.worktreeStart(start, on: record) })
    }

    /// Last among the Agents. It waits for the checkout read, which decides
    /// where the form opens.
    private func newAgentRow(_ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            // The Agents' columns: the plus in the avatars', the title in
            // the names'. Past the size where it fills that column the
            // plus stops growing, as the avatars do.
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    // Named here, or the row's own font, uncapped, sizes it.
                    .font(.body)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .frame(width: Self.avatarDiameter)
                    .accessibilityHidden(true)
                Text("New Agent…")
                    .foregroundStyle(Color(uiColor: .label))
                Spacer(minLength: 0)
                if let startedAgent, store.state == .working(startedAgent.id) {
                    ProgressView()
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isWorking || store.isReadingCheckouts)
    }

    private func itemLine(_ item: GitHubItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: GitHubItemRow.symbol(for: item))
                .foregroundStyle(GitHubItemRow.tint(for: item))
            // One Text: side by side, a long repository name wrapped in a
            // narrow column and squeezed the title to a few letters.
            // The header is secondary already; `.secondary` again dimmed
            // the repository to 1.8:1.
            (Text(verbatim: "\(item.repositoryName) #\(item.number)  ")
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                + Text(item.title).foregroundStyle(Color(uiColor: .label)))
                .lineLimit(dynamicTypeSize >= .xxxLarge ? 4 : 2)
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

    private static let avatarDiameter: CGFloat = 34

    private func agentRow(_ target: GitHubSendTarget, message: String) -> some View {
        let agent = target.agent
        let kind = AgentKindMark(kind: agent.agent.kind)
        let title = AgentTerminalView.displayTitle(for: agent)
        let detail = agent.directory.map(agent.displayPath) ?? kind.label
        let server = serverLabel(of: agent)
        let markText = target.mark.map { mark in
            Text(mark == .onBranch ? String(localized: "On this branch") : String(localized: "This repository"))
                .font(.footnote)
                .foregroundStyle(GitHubInk.green)
        }
        // From the largest standard size the mark goes under the path,
        // which beside it was cut to a few characters.
        let marksBelow = dynamicTypeSize >= .xxxLarge
        return Button {
            Task { await store.send(message, to: agent.id) }
        } label: {
            HStack(spacing: 12) {
                AgentStatusAvatar(mark: kind, status: agent.agent.status, diameter: Self.avatarDiameter)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1)
                    // A Button's label tints `.secondary`, so name the color.
                    HStack(spacing: 0) {
                        if let server {
                            // The Server stays whole; the directory gives way.
                            Text(verbatim: "\(server) · ")
                                .layoutPriority(1)
                                .accessibilityLabel(Text(verbatim: server))
                        }
                        Text(verbatim: detail)
                            .truncationMode(.head)
                    }
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
                    if marksBelow, let markText {
                        markText
                    }
                }
                Spacer(minLength: 0)
                if store.state == .working(agent.id) {
                    ProgressView()
                } else if !marksBelow, let markText {
                    markText
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isWorking)
    }

    /// The Server an Agent is on, when the sheet lists Agents of more than
    /// one of the Host's Servers; nil leaves the row as a one-Server Host's.
    private func serverLabel(of agent: ConsoleAgent) -> String? {
        let host = store.request.host
        let servers = Set(console.gitHubSendTargets(on: host.records).map(\.hostID))
        return servers.count > 1 ? host.serverLabels[agent.hostID] : nil
    }
}

/// Presents Send to Agent for a request from a pull request's or an issue's
/// detail. It sits on the Console, as Hand Off does, so the Agent it opens
/// can take the screen from the GitHub tab.
struct GitHubSendSheetPresenter: ViewModifier {
    @Binding var request: GitHubSendRequest?
    let console: ConsoleStore
    /// The Servers New Agent can start on.
    let hosts: [Host]
    /// The Agent whose Composer now holds the message, for the presenter to open.
    let onSent: (ConsoleAgent.ID) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            // Fixed at open: following a resize rebuilt the sheet, closing
            // New Agent over it and forgetting the chosen ask.
            ConsoleSheetContent(ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)) { presentation in
                GitHubSendSheet(
                    store: GitHubSendStore(
                        request: request,
                        readCheckouts: { [gitHub = console.gitHub] directories in
                            await gitHub.readCheckouts(directories, on: request.host)
                        },
                        deliver: { [console] message, id in try await console.deliverDraft(message, to: id) }),
                    gitHub: console.gitHub, console: console, hosts: hosts, onSent: onSent
                )
                .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
            }
        }
    }
}
