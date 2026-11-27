import Foundation

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
    static let entries = originalEntries + [CommandHookEntry(event: "Notification", matcher: "permission_prompt|elicitation_dialog"),
                                             CommandHookEntry(event: "PostToolUse", matcher: nil)]
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
            try await placeFile(contents, at: script) { $0.starts(with: Data("# Heeler Droid Chat hook\n".utf8)) }
            try await placeFile(launchSettings(script: script), at: launch) { $0 == launchSettings(script: script, using: originalEntries) }
        }
        if action != .launch {
            let settings = RemoteFilePath.join(config, "settings.json")
            let edit = HarnessConfigEdit(id: "droid.chat-hook", harness: "Droid", path: settings,
                transform: action == .register ? adding(script: script) : removing)
            switch try await editor.propose(edit) {
            case .alreadyApplied: break
            case .change(let change): _ = try await editor.apply(change)
            case .refused(_, let reason, _): throw TransportError.malformedResponse(reason)
            }
        }
        return launch
    }
}
