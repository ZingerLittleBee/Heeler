import SwiftUI

/// The Files surface for one Agent's project: the browser rooted at the
/// project root, with the editor pushed on file selection. One column, its
/// own `NavigationStack` — on iPad it sits beside the live terminal, on
/// iPhone it fills a sheet, and both get identical behavior for free.
struct ProjectFilesColumn: View {
    /// The workspace's project root (`skillsProjectRoot`): the worktree
    /// checkout when the workspace has one, else the agent's launch cwd.
    let root: String
    let hostName: String
    let access: RemoteFileAccess
    let fontFamily: String?
    let palette: TerminalThemePalette?

    /// Owned here, not in the browser view: the cached tree must survive the
    /// editor push/pop and SwiftUI redraws of the column.
    @State private var store: ProjectFilesStore?
    @State private var openFile: OpenFile?

    /// `navigationDestination(item:)` needs Identifiable + Hashable; a bare
    /// String would collapse distinct pushes of the same path.
    private struct OpenFile: Identifiable, Hashable {
        let path: String
        var id: String { path }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    ProjectFilesView(store: store)
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(item: $openFile) { file in
                RemoteFileEditorView(
                    path: file.path,
                    access: access,
                    fontFamily: fontFamily,
                    palette: palette)
            }
        }
        .task {
            guard store == nil else { return }
            let created = ProjectFilesStore(root: root, hostName: hostName, access: access)
            created.onOpenFile = { path in
                openFile = OpenFile(path: path)
            }
            store = created
        }
    }
}
