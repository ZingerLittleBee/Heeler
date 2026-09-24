import SwiftUI

/// The Terminals tab's New Terminal sheet (#316). On success the sheet
/// dismisses and hands the new shell to `onCreated`, which opens it.
struct NewTerminalView: View {
    @State private var store: NewTerminalStore
    @State private var directoryBrowser: RemoteDirectoryBrowser?
    private let console: ConsoleStore
    private let onCreated: (ConsoleTerminal) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        hosts: [Host], console: ConsoleStore, initialHostID: Host.ID? = nil,
        onCreated: @escaping (ConsoleTerminal) -> Void
    ) {
        self.console = console
        self.onCreated = onCreated
        _store = State(
            initialValue: NewTerminalStore(
                hosts: hosts,
                initialHostID: initialHostID,
                workspaces: { console.workspaces(for: $0) },
                directory: { hostID, workspaceID in
                    TerminalListProjection(hosts: hosts, console: console)
                        .workspaces(filteredHostID: hostID)
                        .first { $0.workspaceID == workspaceID }?
                        .directory
                },
                remoteHome: { try await console.remoteHomeDirectory(on: $0) },
                create: { destination, hostID in
                    switch destination {
                    case .existing(let request):
                        try await console.createShellTerminal(request, on: hostID)
                    case .newWorkspace(let workspace, let tabLabel):
                        try await console.createShellWorkspace(
                            workspace, tabLabel: tabLabel, on: hostID)
                    }
                },
                awaitTerminal: { await console.waitForTerminal($0, on: $1) }))
    }

    private var selectedWorkspaceTitle: String? {
        store.workspaces.first { $0.id == store.selectedWorkspaceID }?.label
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    Picker("Host", selection: $store.selectedHostID) {
                        if store.selectedHostID == nil {
                            Text("Select a Host").tag(Host.ID?.none)
                        }
                        ForEach(store.hosts) { host in
                            Text(host.displayName).tag(Host.ID?.some(host.id))
                        }
                    }
                }

                Section {
                    StartWorkspacePicker(
                        workspaces: store.workspaces,
                        selectedWorkspaceID: store.target == .existingWorkspace
                            ? store.selectedWorkspaceID : nil,
                        newDirectory: store.newWorkspaceDirectory.isEmpty
                            ? nil : store.newWorkspaceDirectory,
                        isNewWorkspaceSelected: store.target == .newWorkspace,
                        canBrowse: store.selectedHostID != nil,
                        onSelect: store.selectExistingWorkspace,
                        onSelectNewWorkspace: store.selectNewWorkspace,
                        onNewWorkspace: openDirectoryBrowser)
                    if store.target == .newWorkspace {
                        TextField("Workspace name (optional)", text: $store.newWorkspaceLabel)
                            .autocorrectionDisabled()
                        if store.newWorkspaceDirectory.isEmpty {
                            Label("Directory: the Host's home directory", systemImage: "house")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("Browse Directory…", systemImage: "folder.badge.plus") {
                            openDirectoryBrowser()
                        }
                    }
                } header: {
                    Text("Workspace")
                } footer: {
                    if store.target == .newWorkspace {
                        Text("Creates a fresh Workspace on the Host. An empty name uses the directory's name.")
                    } else if let selectedWorkspaceTitle {
                        Text("Opens a new shell tab in \(selectedWorkspaceTitle). Choose New Workspace in the menu to start somewhere else.")
                    }
                }

                Section {
                    TextField("Tab name (optional)", text: $store.tabLabel)
                        .autocorrectionDisabled()
                } header: {
                    Text("Tab")
                } footer: {
                    Text("Empty keeps herdr's numbered tab name.")
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(!store.canDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.state == .creating {
                        ProgressView()
                    } else {
                        Button("Open") {
                            Task { await store.submit() }
                        }
                        .disabled(!store.canSubmit)
                    }
                }
            }
            .onChange(of: store.state) {
                guard case .created(let id) = store.state,
                    let terminal = console.terminals.first(where: { $0.id == id })
                else { return }
                dismiss()
                onCreated(terminal)
            }
            .sheet(item: $directoryBrowser) { browser in
                RemoteDirectoryBrowserView(browser: browser) { path in
                    store.applyBrowsedDirectory(path)
                    directoryBrowser = nil
                }
            }
            .interactiveDismissDisabled(!store.canDismiss)
        }
    }

    private func openDirectoryBrowser() {
        guard let hostID = store.selectedHostID else { return }
        directoryBrowser = RemoteDirectoryBrowser(
            resolveHome: { try await console.remoteHomeDirectory(on: hostID) },
            list: { try await console.listRemoteDirectories(at: $0, on: hostID) })
    }
}
