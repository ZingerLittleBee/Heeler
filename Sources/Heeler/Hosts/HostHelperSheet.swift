import SwiftUI

/// The Host Helper's install sheet: its status, the linger offer, every file an
/// install writes, and removal.
struct HostHelperSheet: View {
    let store: HostHelperStore
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                lingerSection
                filesSection
                failureSection
                actionsSection
            }
            .navigationTitle("Host Helper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove the Host Helper?", isPresented: $isConfirmingRemoval, titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) { Task { await store.remove() } }
            } message: {
                Text(store.removalMessage)
            }
        }
    }

    private static let removalDeletes =
        String(localized: "This stops its service and deletes its files, its Pi and Oh My Pi extensions and this Host's notification registrations, and undoes the OpenCode edit this device made. ")
    static let removalMessage = removalDeletes + String(localized: "Systemd linger and the Grok Build setting stay as they are.")
    static let macOSRemovalMessage = removalDeletes + String(localized: "The Grok Build setting stays as it is.")

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                if store.reading == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Text(store.rowValue)
                }
            }
            .accessibilityIdentifier("hosts.helper.status")
        } footer: {
            if let detail = store.detail { Text(detail) }
        }
    }

    @ViewBuilder
    private var lingerSection: some View {
        if store.offersLinger {
            Section {
                Button("Turn On Linger") { Task { await store.turnOnLinger() } }
                    .disabled(store.running != nil)
                    .accessibilityIdentifier("hosts.helper.linger")
            } header: {
                Text("Systemd Linger")
            } footer: {
                Text("Linger keeps the Host Helper running while nobody is logged in to this Host.")
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        if let plan = store.plan {
            Section("Files This Writes") {
                ForEach(plan.files, id: \.self) { @Sendable path in
                    MainActorContent {
                        Text(path)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if let failure = store.failure {
            Section {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("hosts.helper.failure")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if store.installAction != nil || store.offersRemoval {
            Section {
                if let action = store.installAction {
                    Button {
                        Task { await store.install() }
                    } label: {
                        HStack {
                            Text(action.title)
                            if store.running == .install {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(store.running != nil)
                    .accessibilityIdentifier("hosts.helper.install")
                }
                if store.offersRemoval {
                    Button("Remove", role: .destructive) { isConfirmingRemoval = true }
                        .disabled(store.running != nil)
                        .accessibilityIdentifier("hosts.helper.remove")
                }
            }
        }
    }
}
