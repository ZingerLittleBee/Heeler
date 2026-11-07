import Foundation
import SwiftUI

/// Heeler's session extension on a native Windows core Host, which has no Host Helper
/// to bring it (ADR 0033). The app writes the one file into the folders Pi and Oh My
/// Pi load extensions from, through the core's `file.write`, only when the user asks,
/// and after showing which folders. These folders load for every session on the Host.
enum HerdrCoreWindowsExtensions {
    static let fileName = "heeler-session.js"
    static let bundlePath = "extensions/\(fileName)"

    /// The folders under `home` and the Oh My Pi profiles found there, in the form the
    /// core takes: the rule `plugin/helper/extensions/extension-folders.js` follows.
    static func folders(home: String, profiles: [String]) -> [String] {
        let home = home.hasSuffix("\\") ? String(home.dropLast()) : home
        return [#"\.pi\agent\extensions"#, #"\.omp\agent\extensions"#].map { home + $0 }
            + profiles.sorted().map { home + #"\.omp\profiles\"# + $0 + #"\agent\extensions"# }
    }

    static func isProfileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9._-]{0,63}/) != nil && !name.hasSuffix(".") && name != "default"
    }

    /// What `file.write` takes for one folder.
    static func writeParams(folder: String, contents: Data) -> JSONValue {
        .object([
            "path": .string(folder + #"\"# + fileName),
            "data": .string(contents.base64EncodedString()),
        ])
    }
}

/// The confirmation's state: which folders, then the writes.
@MainActor
@Observable
final class HerdrCoreWindowsExtensionFlow: Identifiable {
    enum Phase: Equatable {
        case locating
        case ready(folders: [String])
        case writing(folders: [String])
        case written(folders: [String])
        case failed(String)
    }

    private(set) var phase = Phase.locating
    private let locate: @MainActor () async throws -> [String]
    private let write: @MainActor ([String]) async throws -> Void

    init(
        locate: @escaping @MainActor () async throws -> [String],
        write: @escaping @MainActor ([String]) async throws -> Void
    ) {
        self.locate = locate
        self.write = write
    }

    func load() async {
        phase = .locating
        do {
            phase = .ready(folders: try await locate())
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func confirm() async {
        guard case .ready(let folders) = phase else { return }
        phase = .writing(folders: folders)
        do {
            try await write(folders)
            phase = .written(folders: folders)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? TransportError)?.presentation.message ?? String(localized: "Heeler couldn't add the extension. Nothing more was written.")
    }
}

/// Names each folder before anything is written.
struct HerdrCoreWindowsExtensionSheet: View {
    @State private var flow: HerdrCoreWindowsExtensionFlow
    @Environment(\.dismiss) private var dismiss

    init(flow: HerdrCoreWindowsExtensionFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            List { content }
                .task { await flow.load() }
                .navigationTitle("Add Heeler's Extension")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(ConsoleStatusSheetPresentationModifier.formBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .locating:
            ProgressView()
        case .ready(let folders):
            folderSection(
                folders,
                footer: String(localized: "Expect Pi and Oh My Pi to load what is in these folders for every session on this Host. The extension only tells Chat which conversation a session is in."))
            Section {
                Button("Add to \(folders.count) Folders") {
                    Task { await flow.confirm() }
                }
                .accessibilityIdentifier("chat.windowsExtension.confirm")
            }
        case .writing(let folders):
            folderSection(folders, footer: nil)
            ProgressView()
        case .written(let folders):
            folderSection(folders, footer: String(localized: "Added. Start the Agent again to load it, and Chat follows its conversation."))
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("chat.windowsExtension.failure")
        }
    }

    private func folderSection(_ folders: [String], footer: String?) -> some View {
        Section {
            ForEach(folders, id: \.self) { folder in
                Text(folder)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        } footer: {
            if let footer { Text(footer) }
        }
    }
}
