import SwiftUI

/// The new-agent sheet (#12, User Story 8): pick a Host and workspace, type a
/// installed Agent and its native arguments, and dispatch it through the
/// Transport launch flow. The started agent appears in the Console through the
/// store's normal snapshot/delta machinery, so this screen dismisses on
/// success rather than navigating anywhere itself.
struct StartAgentView: View {
    @State private var store: StartAgentStore
    @Environment(\.dismiss) private var dismiss

    init(hosts: [Host], console: ConsoleStore) {
        _store = State(
            initialValue: StartAgentStore(
                hosts: hosts,
                workspaces: { console.workspaces(for: $0) },
                discoverAgentKinds: { try await console.availableAgentKinds(on: $0) },
                start: { params, worktree, hostID in
                    if let worktree {
                        try await console.startAgentInNewWorktree(
                            params, worktree: worktree, on: hostID)
                    } else {
                        try await console.startAgent(params, on: hostID)
                    }
                }))
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
                    Picker("Workspace", selection: $store.selectedWorkspaceID) {
                        if store.workspaces.isEmpty {
                            Text("None reported").tag(String?.none)
                        }
                        ForEach(store.workspaces) { workspace in
                            Text(workspace.label).tag(String?.some(workspace.id))
                        }
                    }
                    .disabled(store.selectedHostID == nil || store.workspaces.isEmpty)
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("Where the agent runs. Defaults to the one you last started an agent in.")
                }

                Section {
                    Toggle("Start in a new worktree", isOn: $store.startsInNewWorktree)
                        .disabled(store.selectedWorkspaceID == nil)
                    if store.startsInNewWorktree {
                        TextField("Branch (optional)", text: $store.worktreeBranch)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Base (optional)", text: $store.worktreeBase)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Worktree")
                } footer: {
                    if let message = store.worktreeBranchErrorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else if store.startsInNewWorktree {
                        Text(
                            "A fresh checkout of the workspace's repository. Empty fields use a generated worktree/ branch off HEAD."
                        )
                    } else {
                        Text("Run the agent in a clean checkout instead of the workspace itself.")
                    }
                }

                Section {
                    TextField("e.g. reviewer", text: $store.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Agent Name")
                } footer: {
                    Text("A unique name for this running agent on the Host.")
                }

                Section {
                    switch store.agentDiscoveryState {
                    case .idle:
                        Text("Select a Host to detect installed Agents.")
                            .foregroundStyle(.secondary)
                    case .loading:
                        HStack {
                            ProgressView()
                            Text("Detecting installed Agents…")
                        }
                    case .loaded where store.availableAgentKinds.isEmpty:
                        ContentUnavailableView(
                            "No Agents Found",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "Install a supported Agent CLI on this Host, then try again."))
                        Button("Detect Again", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    case .loaded:
                        Picker("Agent", selection: $store.selectedAgentKind) {
                            ForEach(store.availableAgentKinds) { kind in
                                Text("\(kind.displayName) (\(kind.executable))")
                                    .tag(SupportedAgentKind?.some(kind))
                            }
                        }
                        Button("Detect Again", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Agents installed and launchable from this Host's PATH.")
                }

                Section {
                    TextField(
                        #"e.g. --model "gpt 5" --continue"#,
                        text: $store.arguments,
                        axis: .vertical)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Arguments")
                } footer: {
                    if let message = store.argumentErrorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else {
                        Text("Optional. Quotes and backslash escapes are supported.")
                    }
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
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
                if store.state == .started { dismiss() }
            }
            .task(id: store.selectedHostID) {
                await store.discoverAgents()
            }
            .interactiveDismissDisabled(!store.canDismiss)
        }
    }
}
