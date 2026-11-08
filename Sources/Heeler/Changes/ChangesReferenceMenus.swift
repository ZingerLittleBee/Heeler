import SwiftUI

/// One file's immutable action availability, shared by all its diff rows.
/// Only construction observes the store. Line/hunk lookup waits until an
/// action runs, so building a row never scans or observes the loaded patch.
@MainActor
struct ChangesReferenceActions {
    enum PathAvailability: Equatable {
        case unavailable
        case copy
        case copyAndInsert
    }

    let pathAvailability: PathAvailability
    private let store: ChangesStore
    private let file: ChangedFile?

    init(store: ChangesStore) {
        self.init(store: store, file: nil, path: store.diffPathReference)
    }

    fileprivate init(store: ChangesStore, file: ChangedFile) {
        self.init(store: store, file: file, path: store.pathReference(for: file))
    }

    private init(store: ChangesStore, file: ChangedFile?, path: String?) {
        self.store = store
        self.file = file
        if let path {
            pathAvailability = store.insertReference != nil && ChangesReference.insertion(path) != nil
                ? .copyAndInsert : .copy
        } else {
            pathAvailability = .unavailable
        }
    }

    func copyPath() {
        if let file { store.copyPath(file) } else { store.copyDiffPath() }
    }

    func insertPath() {
        if let file { store.insert(file: file) } else { store.insertDiffPath() }
    }

    func copyLine(_ id: DiffLine.ID) { store.copyLine(id) }
    func copyHunk(_ id: DiffHunk.ID) { store.copyHunk(id) }
    func copyHunk(containingLine id: DiffLine.ID) { store.copyHunk(containingLine: id) }
    func insertLine(_ id: DiffLine.ID) { store.insert(line: id) }
}

extension EnvironmentValues {
    @Entry var changesReferenceActions: ChangesReferenceActions? = nil
}

extension View {
    @MainActor
    func changedFileReferenceMenu(_ file: ChangedFile, store: ChangesStore) -> some View {
        modifier(ChangedFileReferenceMenu(actions: ChangesReferenceActions(store: store, file: file)))
    }

    /// Every section of an edited rename references the opened status path.
    func diffFileReferenceMenu(_ file: DiffFile) -> some View {
        modifier(DiffFileReferenceMenu())
    }

    func diffHunkReferenceMenu(_ hunk: DiffHunk) -> some View {
        modifier(DiffHunkReferenceMenu(hunkID: hunk.id))
    }

    func diffLineContextMenu(_ line: DiffLine) -> some View {
        modifier(DiffLineContextMenu(lineID: line.id))
    }

    func diffLineAccessibilityActions(_ line: DiffLine, qualifier: DiffLineActionQualifier? = nil) -> some View {
        modifier(DiffLineAccessibilityActions(lineID: line.id, qualifier: qualifier))
    }
}

/// Which line of a changed side-by-side pair an accessibility action
/// targets, as "Copy Removed Line".
enum DiffLineActionQualifier: Sendable {
    case removed
    case added
}

private struct ChangedFileReferenceMenu: ViewModifier {
    let actions: ChangesReferenceActions

    @ViewBuilder func body(content: Content) -> some View {
        if actions.pathAvailability != .unavailable {
            content
                .contextMenu { ReferencePathCommands(actions: actions) }
                .accessibilityActions { ReferencePathCommands(actions: actions) }
        } else {
            content
        }
    }
}

private struct DiffFileReferenceMenu: ViewModifier {
    @Environment(\.changesReferenceActions) private var actions

    @ViewBuilder func body(content: Content) -> some View {
        if let actions, actions.pathAvailability != .unavailable {
            content
                .contextMenu { ReferencePathCommands(actions: actions) }
                .accessibilityActions { ReferencePathCommands(actions: actions) }
        } else {
            content
        }
    }
}

private struct ReferencePathCommands: View {
    let actions: ChangesReferenceActions

    var body: some View {
        if actions.pathAvailability != .unavailable {
            Button("Copy Path", systemImage: "doc.on.doc") { actions.copyPath() }
        }
        if actions.pathAvailability == .copyAndInsert {
            Button("Insert Path", systemImage: "text.insert") { actions.insertPath() }
        }
    }
}

private struct DiffHunkReferenceMenu: ViewModifier {
    let hunkID: DiffHunk.ID
    @Environment(\.changesReferenceActions) private var actions

    @ViewBuilder func body(content: Content) -> some View {
        if let actions {
            content
                .contextMenu {
                    Button("Copy Hunk", systemImage: "doc.on.doc") { actions.copyHunk(hunkID) }
                }
                .accessibilityAction(named: "Copy Hunk") { actions.copyHunk(hunkID) }
        } else {
            content
        }
    }
}

private struct DiffLineContextMenu: ViewModifier {
    let lineID: DiffLine.ID
    @Environment(\.changesReferenceActions) private var actions

    @ViewBuilder func body(content: Content) -> some View {
        if let actions {
            content.contextMenu {
                Button("Copy Line", systemImage: "doc.on.doc") { actions.copyLine(lineID) }
                Button("Copy Hunk", systemImage: "doc.on.doc") { actions.copyHunk(containingLine: lineID) }
                if actions.pathAvailability != .unavailable {
                    Button("Copy Path", systemImage: "doc.on.doc") { actions.copyPath() }
                }
                if actions.pathAvailability == .copyAndInsert {
                    Button("Insert Line Reference", systemImage: "text.insert") { actions.insertLine(lineID) }
                }
            }
        } else {
            // A standalone diff has no owner for actions. Even an empty
            // contextMenu installs interaction machinery on every lazy row.
            content
        }
    }
}

private struct DiffLineAccessibilityActions: ViewModifier {
    let lineID: DiffLine.ID
    let qualifier: DiffLineActionQualifier?
    @Environment(\.changesReferenceActions) private var actions

    private enum Action {
        case copyLine
        case copyHunk
        case copyPath
        case insertLineReference
    }

    @ViewBuilder func body(content: Content) -> some View {
        if let actions {
            // One file-level choice, with a flat chain of accessibility
            // attachments in each branch, instead of a modifier per action.
            switch actions.pathAvailability {
            case .copyAndInsert:
                content
                    .accessibilityAction(named: name(.copyLine)) { actions.copyLine(lineID) }
                    .accessibilityAction(named: name(.copyHunk)) { actions.copyHunk(containingLine: lineID) }
                    .accessibilityAction(named: name(.copyPath)) { actions.copyPath() }
                    .accessibilityAction(named: name(.insertLineReference)) { actions.insertLine(lineID) }
            case .copy:
                content
                    .accessibilityAction(named: name(.copyLine)) { actions.copyLine(lineID) }
                    .accessibilityAction(named: name(.copyHunk)) { actions.copyHunk(containingLine: lineID) }
                    .accessibilityAction(named: name(.copyPath)) { actions.copyPath() }
            case .unavailable:
                content
                    .accessibilityAction(named: name(.copyLine)) { actions.copyLine(lineID) }
                    .accessibilityAction(named: name(.copyHunk)) { actions.copyHunk(containingLine: lineID) }
            }
        } else {
            content
        }
    }

    /// One whole name per action and side, so each reads naturally once
    /// translated.
    private func name(_ action: Action) -> Text {
        switch (action, qualifier) {
        case (.copyLine, nil): Text("Copy Line")
        case (.copyLine, .removed?): Text("Copy Removed Line")
        case (.copyLine, .added?): Text("Copy Added Line")
        case (.copyHunk, nil): Text("Copy Hunk")
        case (.copyHunk, .removed?): Text("Copy Removed Hunk")
        case (.copyHunk, .added?): Text("Copy Added Hunk")
        case (.copyPath, nil): Text("Copy Path")
        case (.copyPath, .removed?): Text("Copy Removed Path")
        case (.copyPath, .added?): Text("Copy Added Path")
        case (.insertLineReference, nil): Text("Insert Line Reference")
        case (.insertLineReference, .removed?): Text("Insert Removed Line Reference")
        case (.insertLineReference, .added?): Text("Insert Added Line Reference")
        }
    }
}
