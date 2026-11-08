import SwiftUI

/// The Host Helper's install sheet: its status and the action it offers first,
/// the linger offer, the places an install writes to (each browsed one folder
/// at a time), and removal.
struct HostHelperSheet: View {
    let store: HostHelperStore
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        NavigationStack {
            List {
                summarySection
                lingerSection
                failureSection
                filesSection
                removalSection
            }
            .navigationTitle("Host Helper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneButton }
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
        "This stops its service and deletes its files, its Pi and Oh My Pi extensions "
        + "and this Host's notification registrations, and undoes the OpenCode edit this device made. "
    static let removalMessage = removalDeletes + "Systemd linger and the Grok Build setting stay as they are."
    static let macOSRemovalMessage = removalDeletes + "The Grok Build setting stays as it is."

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 6) {
                statusBadge
                Text("Host Helper")
                    .font(.title2.bold())
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                if let detail = store.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let action = store.installAction {
                    installButton(action)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if store.reading == .checking {
            ProgressView()
                .controlSize(.small)
                .frame(height: 22)
                .accessibilityIdentifier("hosts.helper.status")
        } else {
            Text(store.rowValue)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(store.needsAttention ? Color.orange : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
                .accessibilityLabel("Status")
                .accessibilityValue(store.rowValue)
                .accessibilityIdentifier("hosts.helper.status")
        }
    }

    private func installButton(_ action: HostHelperInstallAction) -> some View {
        Button {
            Task { await store.install() }
        } label: {
            HStack(spacing: 8) {
                Text(action.title)
                if store.running == .install {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(store.running != nil)
        .accessibilityIdentifier("hosts.helper.install")
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
    private var filesSection: some View {
        if let plan = store.plan {
            Section("Files This Writes") {
                ForEach(plan.locations) { @Sendable location in
                    MainActorContent { locationRow(location) }
                }
            }
        }
    }

    private func locationRow(_ location: HostHelperFileLocation) -> some View {
        let folder = location.folder
        return NavigationLink {
            HostHelperFolderView(title: location.title, folder: folder) { dismiss() }
        } label: {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.title)
                        Text(location.summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: location.symbolName)
                }
                Spacer(minLength: 8)
                Text(HostHelperFolderView.count(folder.fileCount))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var removalSection: some View {
        if store.offersRemoval {
            Section {
                Button("Remove", role: .destructive) { isConfirmingRemoval = true }
                    .disabled(store.running != nil)
                    .accessibilityIdentifier("hosts.helper.remove")
            }
        }
    }
}

extension HostHelperFileLocation {
    fileprivate var symbolName: String {
        switch kind {
        case .helper: "folder"
        case .service: "gearshape"
        case .extensions: "puzzlepiece.extension"
        }
    }
}

/// One folder of what an install writes: its folders first, then its files,
/// the way Files lists a folder.
struct HostHelperFolderView: View {
    let title: String
    let folder: HostHelperFileFolder
    let close: @MainActor () -> Void

    var body: some View {
        List {
            Section {
                ForEach(folder.folders) { @Sendable child in
                    MainActorContent { folderRow(child) }
                }
                ForEach(folder.files, id: \.self) { @Sendable name in
                    MainActorContent {
                        Label {
                            Text(name).font(.body.monospaced())
                        } icon: {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            } footer: {
                Text(folder.displayPath)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { close() }
            }
        }
    }

    private func folderRow(_ child: HostHelperFileFolder) -> some View {
        NavigationLink {
            HostHelperFolderView(title: child.name, folder: child, close: close)
        } label: {
            HStack {
                Label {
                    Text(child.name).font(.body.monospaced())
                } icon: {
                    Image(systemName: "folder.fill")
                }
                Spacer(minLength: 8)
                Text("\(child.fileCount)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func count(_ files: Int) -> String {
        files == 1 ? "1 file" : "\(files) files"
    }
}
