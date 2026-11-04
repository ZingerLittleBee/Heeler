import Foundation

/// Why Chat may not show the conversation open in the Agent's terminal, read
/// from how its program was launched rather than from the conversation.
enum ChatLaunchNotice: Equatable, Sendable {
    /// Codex runs on its shared background server, whose hooks carry the
    /// environment of whichever terminal started that server. herdr's
    /// integration can then report this Agent's conversation to another
    /// pane, or another Agent's to this one, and Heeler can't tell which
    /// (docs/agents/herdr-compatibility.md).
    case codexSharedServer

    /// `--no-daemon` with non-breaking hyphens, so text that wraps keeps
    /// the flag on one line.
    static let unbrokenNoDaemon = "\u{2011}\u{2011}no\u{2011}daemon"

    /// The user guide's section for the notice.
    var guideURL: URL? {
        switch self {
        case .codexSharedServer:
            URL(string: "https://docs.heeler.bybee.dev/chat-troubleshooting#codex-started-without---no-daemon")
        }
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

    /// True when the pane's foreground job runs Codex's terminal UI and no
    /// Codex process in it was launched with an option that keeps it off the
    /// shared server; nil when no process there is Codex with known
    /// arguments, or one runs a subcommand without the UI. Codex before the
    /// shared server has no such option either, so this alone doesn't say a
    /// server is in use.
    static func launchesOnSharedServer(_ info: PaneProcessInfo) -> Bool? {
        let arguments = (info.foregroundProcesses ?? []).filter(isCodex).compactMap(\.argv)
        guard !arguments.isEmpty,
            !arguments.contains(where: { $0.dropFirst().first.map(nonInteractiveSubcommands.contains) == true })
        else { return nil }
        return !arguments.contains { keepsOwnServer($0.dropFirst()) }
    }

    /// The native binary rather than a launcher such as npm's Node script,
    /// which passes it the same arguments. On Linux herdr reports no argv0
    /// and a name cut to 15 bytes, so argv[0] names it there.
    private static func isCodex(_ process: PaneProcessInfoProcess) -> Bool {
        process.name == "codex" || process.argv0.map(lastComponent) == "codex"
            || process.argv?.first.map(lastComponent) == "codex"
    }

    private static func keepsOwnServer(_ arguments: ArraySlice<String>) -> Bool {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if argument == "--" { return false }
            if argument.hasPrefix("--") {
                let name = String(argument.prefix { $0 != "=" })
                if ownServerOptions.contains(name) { return true }
                if name == "--remote" {
                    let value: String? =
                        name.count < argument.count ? String(argument.dropFirst(name.count + 1)) : remaining.popFirst()
                    if let value, !namesSharedServer(value) { return true }
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
