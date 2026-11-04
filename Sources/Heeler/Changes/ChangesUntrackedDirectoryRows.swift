import SwiftUI

/// An untracked directory and, once expanded, the files inside it. Child
/// rows are the same file row as the rest of the list. A nested repository
/// is not a button: only a top-level directory expands.
struct ChangesUntrackedDirectoryRows: View {
    let directory: ChangedFile
    let store: ChangesStore
    @State private var toggleTasks: [Task<Void, Never>] = []

    var body: some View {
        directoryRow
        if let expansion {
            expanded(expansion)
        }
    }

    private var expansion: UntrackedDirectoryExpansions.Expansion? {
        store.untrackedDirectories.expansion(for: directory.path)
    }

    private var isExpanded: Bool { expansion != nil }

    private var directoryRow: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12)
                    .accessibilityHidden(true)
                ChangesFileRow(file: directory)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(directory.accessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Lists the files inside")
        .changedFileReferenceMenu(directory, store: store)
        .onDisappear {
            for task in toggleTasks { task.cancel() }
        }
    }

    private func toggle() {
        toggleTasks.append(Task { await store.toggleDirectory(directory) })
    }

    @ViewBuilder
    private func expanded(_ expansion: UntrackedDirectoryExpansions.Expansion) -> some View {
        switch expansion {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Listing \(directory.displayPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Listing \(directory.displayPath)")
            .padding(.leading, 18)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        case .loaded(let listing):
            if let notice = listing.repositoryNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            ForEach(listing.entries) { @Sendable entry in
                MainActorContent {
                    if entry.path.last == UInt8(ascii: "/") {
                        ChangesFileRow(file: entry)
                            .padding(.leading, 18)
                            .changedFileReferenceMenu(entry, store: store)
                    } else {
                        Button { store.openDiff(entry) } label: {
                            ChangesFileRow(file: entry)
                        }
                        .buttonStyle(.plain)
                        .changedFileReferenceMenu(entry, store: store)
                        .padding(.leading, 18)
                    }
                }
            }
            if let notice = listing.limitNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
    }
}
