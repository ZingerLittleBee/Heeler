import Foundation
import CryptoKit

/// The only Droid files a Rex connection can place. New Agent on other
/// backends requests runtime settings; only the Chat install action registers
/// the hook in the SSH account's Factory settings.
protocol DroidChatHookHost: Sendable {
    func prepareDroidChatHook(_ action: DroidChatHook.Action) async throws -> String
}

extension DroidChatHookHost {
    func prepareDroidChatHook(_ action: DroidChatHook.Action) async throws -> String {
        throw TransportError.hostFeatureUnavailable(feature: String(localized: "Droid Chat hooks"))
    }
}

enum DroidChatHook: CommandHookSettings {
    enum Action: Sendable {
        case launch, register, removeRegistration
    }

    static let fileName = "heeler-droid.py"
    static let marker = "/.factory/hooks/" + fileName
    private static let originalEntries = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"].map {
        CommandHookEntry(event: $0, matcher: nil)
    }
    private static func notificationEntries(matcher: String) -> [CommandHookEntry] {
        originalEntries + [CommandHookEntry(event: "Notification", matcher: matcher),
                           CommandHookEntry(event: "PostToolUse", matcher: nil)]
    }
    static let entries = notificationEntries(matcher: "permission_prompt|elicitation_dialog")
    private static let previousNotification = Entry(event: "Notification", matcher: "permission_prompt")
    /// Exact bundled revisions that can be upgraded in place.
    private static let previousScripts: Set<String> = [
        "647104cd52e4bda85a4ab9d765976c1a2863f70476cd2c16268b710f5481d996",
        "6f8751aef298f82ce629757cfaa2610fcd799b3ae4c3eb03e78dcbd4706e9107",
        "f4ebe67d5f79e808b7b8b233bb4b036b0986ba5223cb82caff4e42a43f299014",
    ]
    static let mixedFormReason = String(localized: "Droid's settings contain a hooks entry Heeler couldn't update.")

    static func disabled(in data: Data) -> Bool {
        guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks["hooksDisabled"] as? Bool == true
    }

    static func command(script: String) -> String {
        let path = HostHelperScript.quote(script)
        return "if [ -r \(path) ]; then exec python3 \(path); fi"
    }

    private static func owns(_ handler: JSONTextTree.Value, in group: JSONTextTree.Value, entry: Entry,
                             script: String, tree: JSONTextTree) -> Bool {
        guard case .object(let groupFields, _) = group, groupFields.map(\.key).sorted() == (entry.matcher == nil ? ["hooks"] : ["hooks", "matcher"]),
              case .object(let fields, _) = handler, fields.map(\.key).sorted() == ["command", "timeout", "type"],
              case .string("command", _) = fields.first(where: { $0.key == "type" })?.value,
              case .string(let text, _) = fields.first(where: { $0.key == "command" })?.value, text == command(script: script),
              let duration = fields.first(where: { $0.key == "timeout" }), tree.text(in: duration.value.span) == String(timeout)
        else { return false }
        if let matcher = entry.matcher {
            guard case .string(matcher, _) = groupFields.first(where: { $0.key == "matcher" })?.value else { return false }
        }
        return true
    }

    static func includes(_ event: JSONTextTree.Value, entry: Entry, script: String, tree: JSONTextTree) -> Bool {
        guard case .array(let groups, _) = event else { return false }
        return groups.contains { group in
            guard case .object(let fields, _) = group,
                  case .array(let handlers, _) = fields.first(where: { $0.key == "hooks" })?.value else { return false }
            return handlers.contains { owns($0, in: group, entry: entry, script: script, tree: tree) }
        }
    }

    static func hasRelatedHandler(in event: JSONTextTree.Member, script: String, tree: JSONTextTree) -> Bool {
        (entries + [previousNotification]).contains {
            $0.event == event.key && includes(event.value, entry: $0, script: script, tree: tree)
        }
    }

    static func registration(script: String, remove: Bool, settings: Data?) -> HarnessConfigEdit.Transform {
        let removable = remove ? entries + [previousNotification] : [previousNotification]
        let cleaned = removing(from: settings) { event, group, handler, tree in
            removable.contains { $0.event == event && owns(handler, in: group, entry: $0, script: script, tree: tree) }
        }
        if remove { return cleaned }
        switch cleaned {
        case .refused: return cleaned
        case .alreadyApplied: return adding(script: script)(settings)
        case .change(let data):
            let addition = adding(script: script)(data)
            if case .alreadyApplied = addition { return cleaned }
            return addition
        }
    }

    static func offersLaunchSettings(kind: String, arguments: [String], kernel: String?) -> Bool {
        kind == SupportedAgentKind.droid.rawValue && (kernel == HerdrCoreLocator.macOSKernel || kernel == HerdrCoreLocator.linuxKernel)
            && !arguments.contains { $0 == "--settings" || $0.hasPrefix("--settings=") }
    }

    static func place(
        on host: any HostServices, action: Action, createFolder: @Sendable (String) async throws -> Void
    ) async throws -> String {
        let home = try await host.hostHomeDirectory()
        guard RemoteFilePath.isAcceptable(home) else { throw TransportError.invalidDirectoryPath(path: home) }
        let config = RemoteFilePath.join(home, ".factory")
        let folder = RemoteFilePath.join(config, "hooks")
        let script = RemoteFilePath.join(folder, fileName)
        let launch = RemoteFilePath.join(folder, "heeler-droid.json")
        guard let url = Bundle.main.url(forResource: "heeler-droid", withExtension: "py", subdirectory: "droid")
        else { throw HostHelperBundle.LoadError.unreadable(fileName) }
        let contents = try Data(contentsOf: url)
        let editor = HarnessConfigEditor(files: host)

        func placeFile(_ bytes: Data, at path: String, mayReplace: (Data) -> Bool) async throws {
            let previous = try await editor.read(path)
            if previous == bytes { return }
            if let previous, !mayReplace(previous) { throw HostTextFileError.changedSinceRead }
            do {
                try await host.replaceHostTextFile(path: path, expected: previous, contents: bytes)
            } catch HostTextFileError.changedSinceRead {
                // Two New Agent launches can prepare identical files concurrently.
                guard try await editor.read(path) == bytes else { throw HostTextFileError.changedSinceRead }
            }
        }

        if action != .removeRegistration {
            try await createFolder(config)
            try await createFolder(folder)
            try await placeFile(contents, at: script) {
                previousScripts.contains(SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined())
            }
            try await placeFile(launchSettings(script: script), at: launch) { previous in
                // Only replace complete launch files emitted by earlier Heeler builds.
                [originalEntries, notificationEntries(matcher: "permission_prompt")].contains {
                    previous == launchSettings(script: script, using: $0)
                }
            }
        }
        if action != .launch {
            let settings = RemoteFilePath.join(config, "settings.json")
            let edit = HarnessConfigEdit(id: "droid.chat-hook", harness: "Droid", path: settings,
                transform: { registration(script: script, remove: action == .removeRegistration, settings: $0) })
            switch try await editor.propose(edit) {
            case .alreadyApplied: break
            case .change(let change): _ = try await editor.apply(change)
            case .refused(_, let reason, _): throw TransportError.malformedResponse(reason)
            }
        }
        return launch
    }
}
