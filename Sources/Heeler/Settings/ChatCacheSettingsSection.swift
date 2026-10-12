import SwiftUI

/// How much Chat keeps on this device, and the way to drop it.
@MainActor
@Observable
final class ChatCacheSettingsModel {
    enum State: Equatable {
        case measuring
        case measured(Int64)
        case clearing
    }

    private(set) var state: State = .measuring
    @ObservationIgnored private let cache: any ChatTranscriptCache

    init(cache: any ChatTranscriptCache) {
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

/// Where Fold Finished Turns is kept. On by default.
enum ChatFoldSettings {
    static let defaultsKey = "chat.fold-finished-turns"
}

/// Settings' Chat section: Fold Finished Turns, the cache size and Clear.
/// Four rows do not earn a navigation level.
struct ChatCacheSettingsSection: View {
    @State private var model: ChatCacheSettingsModel
    @State private var confirmsClear = false
    @AppStorage(ChatFoldSettings.defaultsKey) private var foldsFinishedTurns = true

    init(cache: any ChatTranscriptCache) {
        _model = State(initialValue: ChatCacheSettingsModel(cache: cache))
    }

    var body: some View {
        Section {
            Toggle("Fold Finished Turns", isOn: $foldsFinishedTurns)
                .accessibilityIdentifier("settings.chat.foldFinishedTurns")
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
                "A finished turn's steps fold behind one line above its answer; a turn stays open "
                    + "while it runs or while its background work does. "
                    + "Recent Chat messages stay on this device for up to 30 days, within 300 MB. "
                    + "Removing a Host deletes its messages.")
        }
        .task { await model.refresh() }
    }
}
