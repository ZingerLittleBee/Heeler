import SwiftUI

/// The new-agent sheet (#12, User Story 8): pick a Host and a launch target
/// (an existing Workspace or a new one at a remote directory), type an
/// installed Agent and its native arguments, and dispatch it through the
/// Transport launch flow. On success the sheet dismisses and hands the
/// started Agent's identity to `onStarted`; the owner opens it, so a fresh
/// launch lands in its terminal instead of back on the list.
struct StartAgentView: View {
    /// The form's store, made once per presentation. A sheet's parent builds
    /// this view again on every pass of its `body`; a store made in `init`
    /// would be made each time, only for `@State` to keep the first.
    @State private var storage: LazyStore
    @State private var directoryBrowser: RemoteDirectoryBrowser?
    private let onStarted: (ConsoleAgent.ID) -> Void
    private let console: ConsoleStore
    @Environment(\.dismiss) private var dismiss

    init(
        store: StartAgentStore, console: ConsoleStore,
        onStarted: @escaping (ConsoleAgent.ID) -> Void = { _ in }
    ) {
        self.init(console: console, onStarted: onStarted) { store }
    }

    private init(
        console: ConsoleStore, onStarted: @escaping (ConsoleAgent.ID) -> Void,
        makeStore: @escaping () -> StartAgentStore
    ) {
        self.onStarted = onStarted
        self.console = console
        _storage = State(initialValue: LazyStore(make: makeStore))
    }

    init(
        hosts: [Host], console: ConsoleStore,
        origin: StartAgentStore.LaunchOrigin? = nil,
        onStarted: @escaping (ConsoleAgent.ID) -> Void
    ) {
        self.init(console: console, onStarted: onStarted) {
            StartAgentStore(
                hosts: hosts,
                workspaces: { console.workspaces(for: $0) },
                existingAgentNames: { console.takenAgentNames(on: $0) },
                discoverAgentKinds: { try await console.availableAgentKinds(on: $0) },
                discoverTemplates: { try await console.availableTemplates(on: $0) },
                startTemplate: { try await console.startTemplate($0, on: $1) },
                remoteHome: { try await console.remoteHomeDirectory(on: $0) },
                start: { params, destination, hostID in
                    switch destination {
                    case .existingWorkspace:
                        try await console.startAgent(params, on: hostID)
                    case .newWorktree(let worktree):
                        try await console.startAgentInNewWorktree(
                            params, worktree: worktree, on: hostID)
                    case .newWorkspace(let workspace):
                        try await console.startAgentInNewWorkspace(
                            params, workspace: workspace, on: hostID)
                    }
                },
                awaitAgentVisible: { await console.waitForAgent($0) },
                isAgentListed: { id in console.agents.contains { $0.id == id } },
                programExit: { console.programExit(of: $0) },
                origin: origin,
                offersDesktopAppNames: { console.capabilities(for: $0).namesNewWorkspaces },
                offersConnectedWorktrees: { console.capabilities(for: $0).worktrees },
                presets: { console.launchPresets.presets },
                accountVariable: { hostID, kind in try await console.accountVariable(for: kind, on: hostID) })
        }
    }

    private var store: StartAgentStore { storage.store }

    var body: some View {
        @Bindable var store = self.store
        NavigationStack {
            Form {
                if let origin = store.origin {
                    Section {
                        Text(origin.cwd)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } header: {
                        Text("Directory")
                    } footer: {
                        Text(store.offersWorkspaceAndTabNames
                            ? String(localized: "The Agent starts in a new tab here, next to the one you opened this from.")
                            : String(localized: "The Agent starts in this directory."))
                    }
                } else {
                    Section("Host") {
                        StartHostPickers(
                            hosts: store.hostChoices,
                            selectedHost: $store.selectedHostConnection,
                            servers: store.serversForSelectedHost,
                            offersServerChoice: store.offersServerChoice,
                            selectedServerID: $store.selectedHostID)
                    }

                    Section {
                        StartWorkspacePicker(
                            workspaces: store.workspaces,
                            selectedWorkspaceID: store.launchTarget == .existingWorkspace
                                ? store.selectedWorkspaceID : nil,
                            newDirectory: store.newWorkspaceDirectory.isEmpty
                                ? nil : store.newWorkspaceDirectory,
                            isNewWorkspaceSelected: store.launchTarget == .newWorkspace,
                            canBrowse: store.selectedHostID != nil,
                            onSelect: store.selectExistingWorkspace,
                            onSelectNewWorkspace: store.selectNewWorkspace,
                            onNewWorkspace: openDirectoryBrowser)
                        if store.launchTarget == .newWorkspace {
                            if store.offersWorkspaceName {
                                TextField(
                                    String(localized: "Workspace name (optional)"),
                                    text: $store.newWorkspaceLabel)
                                    .autocorrectionDisabled()
                            }
                            if store.newWorkspaceDirectory.isEmpty {
                                Label(
                                    "Directory: the Host's home directory",
                                    systemImage: "house")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label(store.newWorkspaceDirectory, systemImage: "folder")
                                    .font(.callout.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Button("Browse Directory…", systemImage: "folder.badge.plus") {
                                openDirectoryBrowser()
                            }
                        }
                    } header: {
                        Text("Workspace")
                    } footer: {
                        if store.launchTarget == .newWorkspace {
                            Text(store.offersWorkspaceName
                                ? String(localized: "Creates a fresh Workspace on the Host. An empty name uses the directory's name.")
                                : String(localized: "Creates a Workspace in this directory, named after its folder."))
                        }
                    }
                }

                if store.offersWorktree {
                    Section {
                        Toggle("Start in a new worktree", isOn: $store.startsInNewWorktree)
                            .disabled(store.selectedWorkspaceID == nil)
                        if store.startsInNewWorktree {
                            HStack(spacing: 10) {
                                TextField(
                                    store.worktreeNeedsBranch ? "Branch" : "Branch (optional)",
                                    text: $store.worktreeBranch)
                                    .font(.callout.monospaced())
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .accessibilityIdentifier("startAgent.worktreeBranch")
                                if !store.worktreeBranch.isEmpty {
                                    Button {
                                        store.worktreeBranch = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.monochrome)
                                            .foregroundStyle(Color(uiColor: .systemGray))
                                    }
                                    // Borderless, or the whole row would be the button.
                                    .buttonStyle(.borderless)
                                    .tint(Color(uiColor: .systemGray))
                                    .contentShape(Rectangle().inset(by: -4))
                                    .accessibilityLabel(
                                        Text(
                                            "Clear text",
                                            comment: "Accessibility label for the button that clears the rename text field."
                                        ))
                                }
                                Button {
                                    store.regenerateWorktreeBranch()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .tint(.secondary)
                                .contentShape(Rectangle().inset(by: -4))
                                .accessibilityLabel(
                                    Text(
                                        "Generate random branch",
                                        comment: "Accessibility label for the button that generates a random worktree branch name."
                                    ))
                                .accessibilityIdentifier("startAgent.regenerateBranch")
                            }
                            if !store.worktreeNeedsBranch {
                                TextField("Base (optional)", text: $store.worktreeBase)
                                    .font(.callout.monospaced())
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        }
                    } header: {
                        Text("Worktree")
                    } footer: {
                        if let message = store.worktreeBranchErrorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        } else if store.startsInNewWorktree, store.worktreeNeedsBranch {
                            Text(
                                "A fresh checkout of the workspace's repository. A branch that exists is checked out; a new one starts from HEAD."
                            )
                        } else if store.startsInNewWorktree {
                            Text(
                                "A fresh checkout of the workspace's repository. Empty fields use a generated worktree/ branch off HEAD."
                            )
                        } else {
                            Text(
                                "Run the agent in a clean checkout instead of the workspace itself."
                            )
                        }
                    }
                }

                Section {
                    switch store.agentDiscoveryState {
                    case _ where store.isStartingTemplate:
                        HStack {
                            ProgressView()
                            if let name = store.selectedTemplate?.name {
                                Text("Starting \(name)…")
                            } else {
                                Text("Starting the Template…")
                            }
                        }
                    case .idle:
                        Text("Select a Host to detect installed Agents.")
                            .foregroundStyle(.secondary)
                    case .loading:
                        HStack {
                            ProgressView()
                            Text("Detecting installed Agents…")
                        }
                    case .loaded where store.availableAgentKinds.isEmpty && store.availableTemplates.isEmpty:
                        ContentUnavailableView(
                            "No Agents Found",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "Install a supported Agent CLI on this Host, then try again."))
                        Button("Detect Again", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    case .loaded:
                        agentPicker
                        if !store.selectedAgentPresets.isEmpty {
                            Picker("Preset", selection: $store.selectedPresetID) {
                                Text("None").tag(LaunchPreset.ID?.none)
                                ForEach(store.selectedAgentPresets) { @Sendable preset in
                                    AgentKindMenuLabel(preset.name, kind: preset.kind)
                                        .tag(LaunchPreset.ID?.some(preset.id))
                                }
                            }
                            .accessibilityIdentifier("startAgent.preset")
                            if let preset = store.selectedPreset {
                                LaunchPresetSummary(preset: preset)
                            }
                        }
                        Button("Detect Again", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if !store.availableTemplates.isEmpty {
                            agentPicker
                        }
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    if let template = store.selectedTemplate {
                        VStack(alignment: .leading) {
                            if !template.description.isEmpty {
                                Text(template.description)
                            }
                            Text("Its first start can take up to 35 seconds.")
                        }
                    } else {
                        Text(store.discoversThroughUserShell
                            ? String(localized: "Agents your own shell on this Host can run. Launch Presets live in Settings › Agents & Accounts.")
                            : String(localized: "Agents installed and launchable from this Host's PATH. Launch Presets live in Settings › Agents & Accounts."))
                    }
                }

                Section {
                    TextField("Agent name (optional)", text: $store.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Agent Name")
                } footer: {
                    if let message = store.nameErrorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else if let defaultName = store.defaultAgentName {
                        Text("Empty names the agent \(Text(defaultName).monospaced()).")
                    } else {
                        Text("Empty names the agent after its kind.")
                    }
                }

                if store.offersWorkspaceAndTabNames {
                    Section {
                        TextField("Tab name (optional)", text: $store.tabLabel)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Tab Name")
                    } footer: {
                        Text("Empty lets herdr or a title plugin name the tab.")
                    }
                }

                if store.offersArguments {
                    Section {
                        AgentArgumentsField(
                            text: $store.arguments,
                            placeholder: String(localized: "Arguments (optional)"))
                    } header: {
                        Text("Arguments")
                    } footer: {
                        if let message = store.argumentErrorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        } else {
                            Text(
                                "Quotes and backslash escapes are supported.\ne.g. \(Text(#"--model "gpt 5" --continue"#).monospaced())"
                            )
                        }
                    }
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            // The last footer ends clear of the sheet's rounded corners
            // when the form fits it.
            .contentMargins(.bottom, 20, for: .scrollContent)
            // The form grows as a Host adds its Agent and argument rows; a
            // fixed form cut them off under a scroll.
            .consoleSheetPage()
            .task(id: store.selectedHostID) {
                if let hostID = store.selectedHostID { await console.checkNewAgentOffers(on: hostID) }
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(!store.canDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.state == .starting {
                        ProgressView()
                    } else {
                        Button("Start") {
                            Task { await store.submit() }
                        }
                        .disabled(!store.canSubmit)
                    }
                }
            }
            .onChange(of: store.state) {
                if case .started(let id) = store.state {
                    dismiss()
                    onStarted(id)
                } else if store.state == .startedAsTerminal {
                    dismiss()
                }
            }
            .task(id: store.selectedHostID) {
                await store.discoverAgents()
            }
            // The presented item also supplies the content, so the first
            // presentation cannot capture an empty browser from an older view.
            .sheet(item: $directoryBrowser) { browser in
                RemoteDirectoryBrowserView(browser: browser) { path in
                    store.applyBrowsedDirectory(path)
                    directoryBrowser = nil
                }
            }
            .interactiveDismissDisabled(!store.canDismiss)
        }
    }

    private var agentPicker: some View {
        @Bindable var store = self.store
        return Picker("Agent", selection: $store.selectedAgent) {
            ForEach(store.availableAgentKinds) { @Sendable kind in
                AgentKindMenuLabel(kind.displayName, kind: kind)
                    .tag(StartAgentStore.AgentChoice?.some(.kind(kind)))
            }
            if !store.availablePresets.isEmpty {
                Section("Launch Presets") {
                    ForEach(store.availablePresets) { @Sendable preset in
                        AgentKindMenuLabel(
                            "\(preset.name) · \(preset.kind.displayName)", kind: preset.kind)
                            .tag(StartAgentStore.AgentChoice?.some(.preset(preset.id)))
                    }
                }
            }
            if !store.availableTemplates.isEmpty {
                Section("Templates") {
                    ForEach(store.availableTemplates) { @Sendable template in
                        Text(template.name)
                            .tag(StartAgentStore.AgentChoice?.some(.template(template)))
                    }
                }
            }
        }
        .accessibilityIdentifier("startAgent.agent")
    }

    private func openDirectoryBrowser() {
        guard let hostID = store.selectedHostID else { return }
        directoryBrowser = RemoteDirectoryBrowser(
            resolveHome: { try await console.remoteHomeDirectory(on: hostID) },
            list: { try await console.listRemoteDirectories(at: $0, on: hostID) })
    }
}

/// Picks a Host by its name alone, and adds a Server picker only when that
/// Host offers more than one Server here.
struct StartHostPickers: View {
    let hosts: [LaunchHostChoice]
    @Binding var selectedHost: HostMachine.Connection?
    let servers: [Host]
    let offersServerChoice: Bool
    @Binding var selectedServerID: Host.ID?

    var body: some View {
        Picker("Host", selection: $selectedHost) {
            if selectedHost == nil {
                Text("Select a Host").tag(HostMachine.Connection?.none)
            }
            ForEach(hosts) { @Sendable host in
                Text(host.name).tag(HostMachine.Connection?.some(host.id))
            }
        }
        if offersServerChoice {
            Picker("Server", selection: $selectedServerID) {
                ForEach(servers) { @Sendable server in
                    Text(LaunchHostChoice.serverLabel(for: server))
                        .tag(Host.ID?.some(server.id))
                }
            }
        }
    }
}

/// Keeps the latest browsed directory as the final menu option, even when an
/// existing Workspace is selected. Browsing only updates the launch draft.
struct StartWorkspacePicker: View {
    private enum Selection: Hashable {
        case existing(String)
        case newWorkspace
        /// New Workspace: opens the directory browser, never selected.
        case browse
    }

    let workspaces: [ConsoleWorkspace]
    let selectedWorkspaceID: String?
    let newDirectory: String?
    let isNewWorkspaceSelected: Bool
    let canBrowse: Bool
    let onSelect: (String) -> Void
    let onSelectNewWorkspace: () -> Void
    let onNewWorkspace: () -> Void

    private var directoryName: String {
        newDirectory.map { RemoteHostPath.lastComponent(of: $0) } ?? "/"
    }

    private var selection: Binding<Selection?> {
        Binding(
            get: {
                isNewWorkspaceSelected ? .newWorkspace : selectedWorkspaceID.map(Selection.existing)
            },
            set: { value in
                switch value {
                case .existing(let id): onSelect(id)
                case .newWorkspace: onSelectNewWorkspace()
                case .browse: onNewWorkspace()
                case nil: break
                }
            })
    }

    /// A menu picker, as the Host row above it is: the whole row opens it,
    /// from the value at its trailing edge. New Workspace is its last
    /// option, which browses instead of becoming the selection. It must be
    /// the row itself: wrapped, the form draws it as a bare button.
    var body: some View {
        Picker(selection: selection) {
            if selectedWorkspaceID == nil && !isNewWorkspaceSelected {
                Text("None reported").tag(Selection?.none)
            }
            ForEach(workspaces) { @Sendable workspace in
                Text(workspace.label).tag(Selection?.some(.existing(workspace.id)))
            }
            if newDirectory != nil {
                Text(directoryName).tag(Selection?.some(.newWorkspace))
            } else if isNewWorkspaceSelected {
                Text("Home").tag(Selection?.some(.newWorkspace))
            }
            Divider()
            Label("New Workspace", systemImage: "folder.badge.plus")
                .tag(Selection?.some(.browse))
                .accessibilityIdentifier("new-workspace")
        } label: {
            Text("Workspace")
            // The browsed directory in full, under the row's title.
            if isNewWorkspaceSelected, let newDirectory {
                Text(newDirectory)
            }
        }
        // The form's own picker style, not `.menu`, which draws a bare
        // accent-colored value that only it opens.
        .menuOrder(.fixed)
        .disabled(!canBrowse)
        .accessibilityIdentifier("start-workspace-picker")
    }
}

/// Makes the form's store the first time the form asks for it.
@MainActor
private final class LazyStore {
    private let make: () -> StartAgentStore
    private(set) lazy var store = make()

    init(make: @escaping () -> StartAgentStore) {
        self.make = make
    }
}
