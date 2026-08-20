import SwiftUI

/// The Host-level Files destination: the whole remote machine from the
/// Host's home directory, not one Agent's project. On a regular-width iPad
/// the detail column becomes a working split — tree on the left, editor
/// filling the rest — while compact width falls back to the push-per-file
/// column the Agent surface uses.
///
/// The browse root is resolved over the live connection (`$HOME`, cached by
/// the transport) rather than guessed, so a Host whose home is not
/// `/Users/<name>` still opens where its files actually are.
struct HostFilesView: View {
    let hostName: String
    let access: RemoteFileAccess
    /// Resolves the browse root over the live connection; retried on tap
    /// after a failure, so a Host that reconnects does not strand this view.
    let resolveRoot: () async throws -> String
    let fontFamily: String?
    let palette: TerminalThemePalette?

    private enum RootState {
        case resolving
        case failed(message: String)
        case resolved(String)
    }

    @State private var rootState: RootState = .resolving
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        switch rootState {
        case .resolving:
            ProgressView("Connecting to \(hostName)…")
                .task { await resolve() }
        case .failed(let message):
            ContentUnavailableView {
                Label("Files Unavailable", systemImage: "folder.badge.questionmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    rootState = .resolving
                }
                .buttonStyle(.borderedProminent)
            }
        case .resolved(let root):
            if horizontalSizeClass == .regular {
                HostFilesSplit(
                    root: root,
                    hostName: hostName,
                    access: access,
                    fontFamily: fontFamily,
                    palette: palette)
            } else {
                ProjectFilesColumn(
                    root: root,
                    hostName: hostName,
                    access: access,
                    fontFamily: fontFamily,
                    palette: palette)
            }
        }
    }

    private func resolve() async {
        do {
            let root = try await resolveRoot()
            rootState = .resolved(root)
        } catch is CancellationError {
            // A cancelled resolution belongs to a disappearing view; the next
            // appearance starts over from `.resolving`.
        } catch let error as TransportError {
            rootState = .failed(message: error.connectionGuidance)
        } catch {
            rootState = .failed(message: "The Host's home directory could not be resolved.")
        }
    }
}

/// The iPad working layout: browser tree at sidebar width, editor filling
/// the remainder. Selection is store-driven, so tapping a file swaps the
/// editor pane in place instead of pushing over the tree.
private struct HostFilesSplit: View {
    let root: String
    let hostName: String
    let access: RemoteFileAccess
    let fontFamily: String?
    let palette: TerminalThemePalette?

    /// Owned here so the cached tree survives editor swaps and redraws.
    @State private var store: ProjectFilesStore?
    @State private var openFilePath: String?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let store {
                    NavigationStack {
                        ProjectFilesView(store: store)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(width: 320)

            Divider()

            Group {
                if let openFilePath {
                    NavigationStack {
                        RemoteFileEditorView(
                            path: openFilePath,
                            access: access,
                            fontFamily: fontFamily,
                            palette: palette)
                    }
                    // A different file is a different editing session; reuse
                    // would carry one file's draft into another's baseline.
                    .id(openFilePath)
                } else {
                    ContentUnavailableView(
                        "No File Open", systemImage: "doc.text",
                        description: Text("Choose a file to edit it here."))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task {
            guard store == nil else { return }
            let created = ProjectFilesStore(root: root, hostName: hostName, access: access)
            created.onOpenFile = { path in
                openFilePath = path
            }
            store = created
        }
    }
}
