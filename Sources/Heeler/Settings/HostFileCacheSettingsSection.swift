import SwiftUI

/// Settings' Files section: how much the Host files Files and Chat's
/// previews kept take, and Clear. A change to `remeasuring` measures again,
/// as after Clear Chat Cache, which empties it too.
struct HostFileCacheSettingsSection: View {
    @State private var model: CacheSettingsModel
    @State private var confirmsClear = false
    private let remeasuring: Int

    init(cache: HostFileCache, remeasuring: Int = 0) {
        _model = State(initialValue: CacheSettingsModel(cache: cache))
        self.remeasuring = remeasuring
    }

    var body: some View {
        Section {
            LabeledContent("Downloaded Files") {
                switch model.state {
                case .measured(let bytes):
                    Text(bytes.formatted(.byteCount(style: .file)))
                case .measuring, .clearing:
                    ProgressView()
                }
            }
            .accessibilityIdentifier("settings.files.cacheSize")
            Button("Clear Downloaded Files", role: .destructive) {
                confirmsClear = true
            }
            .disabled(!model.canClear)
            .accessibilityIdentifier("settings.files.clearCache")
            .confirmationDialog(
                "Clear downloaded files?", isPresented: $confirmsClear, titleVisibility: .visible
            ) {
                Button("Clear Downloaded Files", role: .destructive) {
                    Task { await model.clear() }
                }
            } message: {
                Text("Files and Chat download a file from its Host again the next time you open it.")
            }
        } header: {
            Text("Files")
        } footer: {
            Text(
                "Files you open from a Host, in Files or from Chat, stay on this device for up to 7 days, within 500 MB, so they open again without downloading. A file changed on the Host downloads again. Closing an Agent or removing its saved Chat deletes the copies only it opened, removing a Host deletes the copies kept from it, and Clear Chat Cache deletes them all.")
        }
        .task(id: remeasuring) { await model.refresh() }
    }
}
