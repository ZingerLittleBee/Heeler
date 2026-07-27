import SwiftUI

/// The new-agent sheet (#12, User Story 8): pick a Host and workspace, type a
/// command, and dispatch it through the Transport launch flow. The started
/// agent appears in the Console through the store's normal snapshot/delta
/// machinery, so this screen dismisses on success rather than navigating
/// anywhere itself.
struct StartAgentView: View {
    @State private var store: StartAgentStore
    @Environment(\.dismiss) private var dismiss

    init(hosts: [Host], console: ConsoleStore) {
        _store = State(
            initialValue: StartAgentStore(
                hosts: hosts,
                workspaces: { console.workspaces(for: $0) },
                start: { params, hostID in try await console.startAgent(params, on: hostID) }))
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
                    TextField("e.g. reviewer", text: $store.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Agent Name")
                } footer: {
                    Text("A unique name for this running agent on the Host.")
                }

                Section {
                    TextField("e.g. claude --continue", text: $store.command, axis: .vertical)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Command")
                } footer: {
                    Text("The agent command to run, split on spaces.")
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
            .interactiveDismissDisabled(!store.canDismiss)
        }
    }
}
