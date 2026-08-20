import Foundation
import SwiftUI

/// A remote project browser that renders only the portions of the cached tree
/// the user has disclosed. The store, rather than the view hierarchy, owns the
/// cache so a SwiftUI redraw never turns into another SFTP listing.
struct ProjectFilesView: View {
    let store: ProjectFilesStore

    init(store: ProjectFilesStore) {
        self.store = store
    }

    var body: some View {
        List {
            ProjectDirectoryContents(store: store, node: store.rootNode)
        }
        .navigationTitle(store.hostName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("File Display", systemImage: "ellipsis.circle") {
                    Toggle(
                        "Show Hidden Files",
                        isOn: Binding(
                            get: { store.showsHiddenFiles },
                            set: { store.showsHiddenFiles = $0 }))
                }
            }
        }
        .refreshable {
            await store.refresh()
        }
        .task {
            await store.load()
        }
    }
}

private struct ProjectDirectoryContents: View {
    let store: ProjectFilesStore
    let node: ProjectFilesStore.Node

    var body: some View {
        switch node.state {
        case .unloaded, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading \(node.entry.name)…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading \(node.entry.name)")
        case .loaded:
            let children = store.visibleChildren(of: node.entry.path)
            if children.isEmpty {
                ContentUnavailableView(
                    "No Visible Files",
                    systemImage: "folder",
                    description: Text("Show hidden files to include dotfiles."))
            } else {
                ForEach(children) { child in
                    ProjectFileTreeRow(store: store, node: child)
                }
            }
        case .failed(let message):
            Button {
                Task {
                    await store.retryDirectory(at: node.entry.path)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Couldn't Load \(node.entry.name)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Retry")
                        .font(.footnote.weight(.semibold))
                }
            }
            .accessibilityHint("Retries the directory listing")
        }
    }
}

private struct ProjectFileTreeRow: View {
    let store: ProjectFilesStore
    let node: ProjectFilesStore.Node

    var body: some View {
        if node.entry.kind == .directory {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { store.isDirectoryExpanded(node.entry.path) },
                    set: { expanded in
                        Task {
                            await store.setDirectoryExpanded(node.entry.path, isExpanded: expanded)
                        }
                    }))
            {
                ProjectDirectoryContents(store: store, node: node)
            } label: {
                ProjectFileRow(entry: node.entry)
            }
        } else {
            Button {
                store.openFile(at: node.entry.path)
            } label: {
                ProjectFileRow(entry: node.entry)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(node.entry.name) in the editor")
        }
    }
}

private struct ProjectFileRow: View {
    let entry: RemoteFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch entry.kind {
        case .directory: "folder"
        case .file: "doc.text"
        case .symlink: "link"
        case .other: "questionmark.square.dashed"
        }
    }

    private var secondaryText: String {
        var details: [String] = []
        if let sizeBytes = entry.sizeBytes {
            details.append(
                ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: sizeBytes),
                    countStyle: .file))
        }
        if let modified = entry.modified {
            let formatter = RelativeDateTimeFormatter()
            details.append(formatter.localizedString(for: modified, relativeTo: Date()))
        }
        return details.joined(separator: " · ")
    }
}
