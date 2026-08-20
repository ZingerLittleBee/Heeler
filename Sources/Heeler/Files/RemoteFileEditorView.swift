import Foundation
import SwiftUI

/// The one-file editor surface. It keeps conflict resolution at the point of
/// save so a user can compare the current remote file before deciding whether
/// their local draft should win.
struct RemoteFileEditorView: View {
    @State private var store: RemoteFileEditorStore
    private let fontFamily: String?
    private let palette: TerminalThemePalette?

    init(
        path: String,
        access: RemoteFileAccess,
        fontFamily: String? = nil,
        palette: TerminalThemePalette? = nil
    ) {
        _store = State(initialValue: RemoteFileEditorStore(path: path, access: access))
        self.fontFamily = fontFamily
        self.palette = palette
    }

    var body: some View {
        Group {
            switch store.state {
            case .loading:
                ProgressView("Loading File…")
            case .binary(let notice):
                ContentUnavailableView {
                    Label("Binary File", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(notice)
                }
            case .tooLarge(let sizeBytes, let limit):
                ContentUnavailableView {
                    Label("File Too Large", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: sizeBytes), countStyle: .file)) "
                            + "exceeds this editor's \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit.")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Open File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await store.retryLoad() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .editing, .conflict:
                CodeEditorView(
                    text: Binding(
                        get: { store.text },
                        set: { store.text = $0 }),
                    path: store.path,
                    isEditable: !store.isSaving,
                    fontFamily: fontFamily,
                    palette: palette,
                    onSave: {
                        Task { await store.save() }
                    })
            }
        }
        .navigationTitle(breadcrumb)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if store.isDirty {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .accessibilityLabel("Unsaved changes")
                    }
                    Button("Save", systemImage: "square.and.arrow.down") {
                        Task { await store.save() }
                    }
                    .disabled(!store.isDirty || store.isSaving || hasConflict)
                }
            }
        }
        .task {
            await store.load()
        }
        .alert(
            "File Changed on Server",
            isPresented: Binding(
                get: { hasConflict },
                set: { _ in }),
            actions: {
                Button("Overwrite", role: .destructive) {
                    Task { await store.resolveConflict(.overwrite) }
                }
                Button("Reload") {
                    Task { await store.resolveConflict(.reload) }
                }
            },
            message: {
                Text("The file was modified after it was opened. Overwrite it or reload the remote version.")
            })
        .alert(
            "Couldn't Save File",
            isPresented: Binding(
                get: { store.saveErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { store.dismissSaveError() }
                }),
            actions: {
                Button("OK", role: .cancel) { store.dismissSaveError() }
            },
            message: {
                Text(store.saveErrorMessage ?? "")
            })
    }

    private var hasConflict: Bool {
        if case .conflict = store.state { return true }
        return false
    }

    private var breadcrumb: String {
        let components = store.path.split(separator: "/").map(String.init)
        return components.isEmpty ? "/" : components.joined(separator: " › ")
    }
}
