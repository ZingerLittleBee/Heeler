import SwiftUI

/// How much a cache keeps on this device, and the way to drop it.
@MainActor
@Observable
final class CacheSettingsModel {
    enum State: Equatable {
        case measuring
        case measured(Int64)
        case clearing
    }

    private(set) var state: State = .measuring
    @ObservationIgnored private let cache: any DeviceCache

    init(cache: any DeviceCache) {
        self.cache = cache
    }

    func refresh() async {
        let usage = await cache.diskUsage()
        guard state != .clearing else { return }
        state = .measured(usage)
    }

    func clear() async {
        state = .clearing
        await cache.removeAll()
        state = .measured(await cache.diskUsage())
    }

    var canClear: Bool {
        if case .measured(let bytes) = state { return bytes > 0 }
        return false
    }
}

/// Settings' Chat section: the cache size and Clear. Chat's font, text
/// size and Fold Finished Turns are under Appearance.
struct ChatCacheSettingsSection: View {
    @State private var model: CacheSettingsModel
    @State private var confirmsClear = false

    init(cache: any ChatTranscriptCache) {
        _model = State(initialValue: CacheSettingsModel(cache: cache))
    }

    var body: some View {
        Section {
            LabeledContent("Cached Messages") {
                switch model.state {
                case .measured(let bytes):
                    Text(bytes.formatted(.byteCount(style: .file)))
                case .measuring, .clearing:
                    ProgressView()
                }
            }
            .accessibilityIdentifier("settings.chat.cacheSize")
            Button("Clear Chat Cache", role: .destructive) {
                confirmsClear = true
            }
            .disabled(!model.canClear)
            .accessibilityIdentifier("settings.chat.clearCache")
            .confirmationDialog(
                "Clear Chat cache?", isPresented: $confirmsClear, titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    Task { await model.clear() }
                }
            } message: {
                Text("Chat reloads messages from each Host the next time you open it.")
            }
        } header: {
            Text("Chat")
        } footer: {
            Text(
                String(localized: "Recent Chat messages stay on this device for up to 30 days, within 300 MB. Removing a Host deletes its messages."))
        }
        .task { await model.refresh() }
    }
}
