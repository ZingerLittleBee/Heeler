import Foundation

/// Why Chat may not show the conversation open in the Agent's terminal, read
/// from how its program was launched rather than from the conversation.
enum ChatLaunchNotice: String, Codable, Equatable, Sendable {
    /// Codex runs on its shared background server, whose hooks carry the
    /// environment of whichever terminal started that server. herdr's
    /// integration can then report this Agent's conversation to another
    /// pane, or another Agent's to this one, and Heeler can't tell which
    /// (docs/agents/herdr-compatibility.md).
    case codexSharedServer

    /// `--no-daemon` with non-breaking hyphens, so text that wraps keeps
    /// the flag on one line.
    static let unbrokenNoDaemon = "\u{2011}\u{2011}no\u{2011}daemon"

    /// The shared server can outlive the Codex that started it and keep the
    /// conversation loaded, and Codex then won't resume it without the
    /// server ("This conversation is open in another app", codex-cli
    /// 0.165.0 on a 0.166.0 daemon, until `codex app-server daemon stop`).
    /// Also seen with codex-cli 0.169.0 and a 0.169.0 daemon on 2026-11-18,
    /// from a `codex --no-daemon resume`. The Composer's hold over that
    /// screen says the same in fewer words (`InputBoxStateDetector`).
    static let stopSharedServer =
        String(localized: "If Codex says the conversation is open in another app, run codex app\u{2011}server daemon stop, which also ends any other Codex on that server, then resume again.")

    /// The user guide's section for the notice.
    var guideURL: URL? {
        guideURL()
    }

    func guideURL(localization: String = Bundle.main.preferredLocalizations.first ?? "en") -> URL? {
        switch self {
        case .codexSharedServer:
            ChatTroubleshootingGuide.url(for: .codexSharedServer, localization: localization)
        }
    }
}

/// Remembers which live Agent terminal instances have had their launch notice
/// banner dismissed, so the banner stays hidden across app restarts while the
/// same terminal keeps running, and drops entries once the notice clears, the
/// terminal disappears, or the Host is removed.
@MainActor
final class ChatLaunchNoticeDismissalStore {
    struct Entry: Codable, Equatable, Sendable {
        let hostID: Host.ID
        let terminalID: String
        let notice: ChatLaunchNotice
    }

    private struct Key: Hashable {
        let hostID: Host.ID
        let terminalID: String
    }

    static let defaultsKey = "chat.dismissed-launch-notices"
    static let maxEntries = 64

    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    private nonisolated(unsafe) let defaults: UserDefaults?
    /// Most-recently dismissed first, capped at `maxEntries`.
    private var entries: [Entry]
    /// O(1) lookup by `(hostID, terminalID)`.
    private var noticeByTerminal: [Key: ChatLaunchNotice] = [:]
    /// Counts per Host so `hasEntries(for:)` is O(1).
    private var countByHost: [Host.ID: Int] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let defaults,
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        {
            self.entries = Array(decoded.prefix(Self.maxEntries))
        } else {
            self.entries = []
        }
        rebuildIndexes()
    }

    var isEmpty: Bool { entries.isEmpty }

    func hasEntries(for hostID: Host.ID) -> Bool {
        (countByHost[hostID] ?? 0) > 0
    }

    func dismissedNotice(hostID: Host.ID, terminalID: String) -> ChatLaunchNotice? {
        noticeByTerminal[Key(hostID: hostID, terminalID: terminalID)]
    }

    func dismiss(_ notice: ChatLaunchNotice, hostID: Host.ID, terminalID: String) {
        let key = Key(hostID: hostID, terminalID: terminalID)
        if noticeByTerminal[key] == notice { return }
        entries.removeAll { $0.hostID == hostID && $0.terminalID == terminalID }
        entries.insert(Entry(hostID: hostID, terminalID: terminalID, notice: notice), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        rebuildIndexes()
        persist()
    }

    func clear(hostID: Host.ID, terminalID: String) {
        guard noticeByTerminal[Key(hostID: hostID, terminalID: terminalID)] != nil else { return }
        entries.removeAll { $0.hostID == hostID && $0.terminalID == terminalID }
        rebuildIndexes()
        persist()
    }

    func removeHost(_ hostID: Host.ID) {
        guard hasEntries(for: hostID) else { return }
        entries.removeAll { $0.hostID == hostID }
        rebuildIndexes()
        persist()
    }

    func retainHosts(_ hostIDs: Set<Host.ID>) {
        guard entries.contains(where: { !hostIDs.contains($0.hostID) }) else { return }
        entries.removeAll { !hostIDs.contains($0.hostID) }
        rebuildIndexes()
        persist()
    }

    func retainTerminals(hostID: Host.ID, terminalIDs: Set<String>) {
        guard hasEntries(for: hostID),
            entries.contains(where: { $0.hostID == hostID && !terminalIDs.contains($0.terminalID) })
        else { return }
        entries.removeAll { $0.hostID == hostID && !terminalIDs.contains($0.terminalID) }
        rebuildIndexes()
        persist()
    }

    private func rebuildIndexes() {
        var notices: [Key: ChatLaunchNotice] = [:]
        var counts: [Host.ID: Int] = [:]
        for entry in entries {
            let key = Key(hostID: entry.hostID, terminalID: entry.terminalID)
            if notices[key] == nil {
                notices[key] = entry.notice
                counts[entry.hostID, default: 0] += 1
            }
        }
        noticeByTerminal = notices
        countByHost = counts
    }

    private func persist() {
        guard let defaults else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Whether a Codex in the Agent's pane runs on Codex's shared background
/// server, from the arguments of its foreground processes and the server's
/// control socket (Codex 0.164.0, `tui/src/daemon_startup.rs`).
enum CodexLaunch {
    /// Long options that keep the terminal's Codex off the shared server:
    /// `--no-daemon`, and launch settings a shared server can't adopt.
    /// `--config` counts even for the feature toggles Codex lets through,
    /// so a launch Chat can't place shows no notice.
    static let ownServerOptions: Set<String> = [
        "--no-daemon", "--oss", "--profile", "--strict-config", "--dangerously-bypass-hook-trust",
        "--config", "--search", "--approve-for-me", "--not-so-yolo",
    ]

    /// The short spellings of `--config` and `--profile`.
    static let ownServerShortOptions: Set<Character> = ["c", "p"]

    /// Subcommands that never open the terminal UI, which alone uses the
    /// shared server (`cli/src/main.rs`). `resume`, `fork` and `agents` do.
    static let nonInteractiveSubcommands: Set<String> = [
        "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "app",
        "completion", "update", "doctor", "sandbox", "debug", "execpolicy", "apply", "a", "queue", "archive",
        "delete", "migrate-rollouts", "migrate-nfs-db", "unarchive", "cloud", "cloud-tasks",
        "responses-api-proxy", "stdio-to-uds", "exec-server", "features", "tcp-tunnel",
    ]

    /// The shared server's control socket under the default `CODEX_HOME`,
    /// which Chat reads Codex from. It exists only while a server runs.
    static func controlSocketPath(home: String) -> String {
        RemoteFilePath.join(home, ".codex", "app-server-control", "app-server-control.sock")
    }

    /// The control socket under the `CODEX_HOME` of a Codex whose environment
    /// Heeler has read (ADR 0034).
    static func controlSocketPath(codexHome: String) -> String {
        RemoteFilePath.join(codexHome, "app-server-control", "app-server-control.sock")
    }

    /// `launchesOnSharedServer(_:)` for a herdr-core Terminal's foreground, which may
    /// be what started Codex rather than Codex: a Template's `sh -c` line, the desktop
    /// app's wrapper, or the Node that runs npm's launcher (ADR 0032). The Agent rule
    /// reads those, so what the Console calls Codex is judged by Codex's own arguments.
    static func launchesOnSharedServer(foreground: HerdrCoreForeground?) -> Bool? {
        guard let foreground else { return nil }
        let argv =
            HerdrCoreAgentRule.arguments(of: foreground, runningKind: ChatProgram.codex.rawValue)
            .map { [ChatProgram.codex.rawValue] + $0 } ?? foreground.argv
        return launchesOnSharedServer(
            PaneProcessInfo(
                paneID: "",
                foregroundProcesses: [
                    PaneProcessInfoProcess(
                        name: foreground.name, pid: foreground.pid ?? 0, argv: argv.isEmpty ? nil : argv)
                ]))
    }

    /// True when the pane's foreground job runs Codex's terminal UI and no
    /// Codex process in it was launched with an option that keeps it off the
    /// shared server; nil when no process there is Codex with known
    /// arguments, or one runs a subcommand without the UI. Codex before the
    /// shared server has no such option either, so this alone doesn't say a
    /// server is in use.
    static func launchesOnSharedServer(_ info: PaneProcessInfo) -> Bool? {
        let arguments = (info.foregroundProcesses ?? []).filter(isCodex).compactMap(\.argv).filter { !$0.isEmpty }
        guard !arguments.isEmpty,
            !arguments.contains(where: { $0.dropFirst().first.map(nonInteractiveSubcommands.contains) == true })
        else { return nil }
        return !arguments.contains { keepsOwnServer($0.dropFirst(), addressesHidden: false) }
    }

    /// The words of a Codex's own command line that decide the shared server,
    /// for a read of its argument vector that keeps only these, in order, where
    /// nothing else names that command line (a Rex terminal). Every other word
    /// reads as a placeholder and never leaves the Host (`HostProcessReader`).
    static let launchWords: [String] = ownServerOptions
        .union(["--remote", "--"])
        .union(ownServerShortOptions.map { "-\($0)" })
        .union(nonInteractiveSubcommands)
        .sorted()

    /// `launchesOnSharedServer(_:)` for a Codex whose own argument vector was read
    /// keeping only `launchWords`. A `--remote` address is never among them, and
    /// the shared server's own socket may be what it names, so a `--remote` counts
    /// as reaching that server here: a Codex there holds no conversation of its
    /// own either. Nil when the read did not answer.
    static func launchesOnSharedServer(orderedArguments reading: HostProcessReader.Reading<[String]>) -> Bool? {
        guard case .value(let arguments) = reading, !arguments.isEmpty,
            arguments.dropFirst().first.map(nonInteractiveSubcommands.contains) != true
        else { return nil }
        return !keepsOwnServer(arguments.dropFirst(), addressesHidden: true)
    }

    /// The native binary rather than a launcher such as npm's Node script,
    /// which passes it the same arguments. On Linux herdr reports no argv0
    /// and a name cut to 15 bytes, so argv[0] names it there.
    private static func isCodex(_ process: PaneProcessInfoProcess) -> Bool {
        process.name == "codex" || process.argv0.map(lastComponent) == "codex"
            || process.argv?.first.map(lastComponent) == "codex"
    }

    private static func keepsOwnServer(_ arguments: ArraySlice<String>, addressesHidden: Bool) -> Bool {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if argument == "--" { return false }
            if argument.hasPrefix("--") {
                let name = String(argument.prefix { $0 != "=" })
                if ownServerOptions.contains(name) { return true }
                if name == "--remote" {
                    let value: String? =
                        name.count < argument.count ? String(argument.dropFirst(name.count + 1)) : remaining.popFirst()
                    if !addressesHidden, let value, !namesSharedServer(value) { return true }
                }
            } else if argument.hasPrefix("-"), argument.count > 1 {
                let option = argument[argument.index(after: argument.startIndex)]
                if ownServerShortOptions.contains(option) { return true }
            }
        }
        return false
    }

    /// `--remote unix://` and the control socket's own path reach the shared
    /// server too (`tui/src/lib.rs` `resolve_remote_addr`).
    private static func namesSharedServer(_ address: String) -> Bool {
        address == "unix://" || address.hasSuffix("/.codex/app-server-control/app-server-control.sock")
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
