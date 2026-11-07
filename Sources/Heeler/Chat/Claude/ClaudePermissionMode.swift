import Foundation

/// Launch opt-in is a menu hint, not Claude Code's runtime permission policy.
/// Policies can revoke bypass after launch; only the live footer confirms a switch.
enum ClaudePermissionMode {
    struct ProcessIdentity: Equatable, Sendable {
        let pid: String
        let start: String
    }

    struct Launch: Equatable, Sendable {
        let process: ProcessIdentity
        let optsIntoBypass: Bool

        init?(pid: String, facts: HostProcessReader.Facts) {
            guard case .value(let start) = facts.start else { return nil }
            process = ProcessIdentity(pid: pid, start: start)
            if case .value(let argv) = facts.argumentVector {
                optsIntoBypass = ClaudePermissionMode.optsIntoBypass(argv: argv)
            } else {
                optsIntoBypass = false
            }
        }
    }

    /// Read only an unambiguous native Claude process in the foreground job.
    /// Shell commands and launcher arguments are not the running Agent's argv.
    static func processID(in info: PaneProcessInfo) -> String? {
        let matches = (info.foregroundProcesses ?? []).filter { process in
            process.pid > 0 && (process.name == "claude"
                || process.name.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil
                || process.argv0?.split(separator: "/").last == "claude"
                || process.argv?.first?.split(separator: "/").last == "claude")
        }
        return matches.count == 1 ? matches.first.map { String($0.pid) } : nil
    }

    // Claude Code 2.1.319's CLI. Only names and permission-mode values leave the
    // Host. Keeping value positions prevents a prompt quoting a flag from opting in.
    private static let valued: Set<String> = [
        "--agent", "--agents", "--append-system-prompt", "--autocompact", "--debug-file", "--effort",
        "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd",
        "--model", "-n", "--name", "--output-format", "--permission-mode", "--permission-prompts",
        "--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix", "--session-id",
        "--setting-sources", "--settings", "--system-prompt", "--system-prompt-snapshot",
    ]
    private static let optionalOrVariadic: Set<String> = [
        "--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--cloud", "-d", "--debug",
        "--disallowedTools", "--disallowed-tools", "--file", "--from-pr", "--mcp-config",
        "--prompt-suggestions", "--remote-control", "-r", "--resume", "--teleport", "--tools", "-w", "--worktree",
    ]
    private static let flags: Set<String> = [
        "--allow-dangerously-skip-permissions", "--dangerously-skip-permissions", "--restricted",
        "--ax-screen-reader", "--bg", "--background", "--bare", "--brief", "--chrome", "-c", "--continue",
        "--desktop", "--disable-slash-commands", "--exclude-dynamic-system-prompt-sections",
        "--fork-session", "--forward-subagent-text", "-h", "--help", "--ide", "--include-hook-events",
        "--include-partial-messages", "--no-chrome", "--no-session-persistence", "-p", "--print",
        "--replay-user-messages", "--safe-mode", "--strict-mcp-config", "--tmux", "--verbose", "-v", "--version",
    ]
    static let argumentWords: [String] = {
        let modes = ["default", "manual", "acceptEdits", "auto", "bypassPermissions", "dontAsk", "plan"]
        return (valued.union(optionalOrVariadic).union(flags).union(["--"]).union(modes)
            .union(modes.map { "--permission-mode=\($0)" })).sorted()
    }()

    static func request(pid: String) -> HostProcessReader.Request {
        .init(pids: [pid], readsStart: true, argumentsAmong: argumentWords, preservesArgumentOrder: true)
    }

    /// Unknown option syntax fails closed. `--`, required option values and
    /// repeated permission-mode options retain their CLI meaning after redaction.
    static func optsIntoBypass(argv: [String]) -> Bool {
        var remaining = argv.dropFirst()
        var allowed = false
        var initialMode: String?
        while let argument = remaining.popFirst() {
            if argument == "--" { break }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let option = parts.first.map(String.init) ?? ""
            if option == "--restricted" { return false }
            if option == "--allow-dangerously-skip-permissions" || option == "--dangerously-skip-permissions" {
                guard parts.count == 1 else { return false }
                allowed = true
            } else if valued.contains(option) {
                guard let value = parts.count == 2 ? String(parts[1]) : remaining.popFirst() else { return false }
                if option == "--permission-mode" { initialMode = value }
            } else if optionalOrVariadic.contains(option) {
                while let next = remaining.first, !next.hasPrefix("-") { remaining.removeFirst() }
            } else if !flags.contains(option) || parts.count != 1 {
                return false
            }
        }
        return allowed || initialMode == "bypassPermissions"
    }

    struct SwitchResult: Equatable {
        var mode: String?
        var reachedTarget = false
        var completedCycle = false
        var feedbackTimedOut = false
    }

    /// One key at a time, waiting for a changed footer before the next. Returning
    /// to the starting mode without the target proves it is absent from this cycle.
    /// A stale frame, unreadable screen or interrupted action proves no such thing.
    @MainActor static func switchTo(
        _ target: String,
        readScreen: () async throws -> ANSIScreen,
        press: (_ whileShowing: String) async throws -> Void,
        mayContinue: () -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async -> SwitchResult {
        var result = SwitchResult()
        do {
            guard mayContinue(), !Task.isCancelled else { return result }
            var screen = try await readScreen()
            guard PreSendGate.check(screen, program: .claude, activity: .idle) == .send else { return result }
            guard let initial = AgentSessionSettings.permissionMode(onScreen: screen) else { return result }
            result.mode = initial
            var visited: Set<String> = [initial]
            for _ in 0..<8 {
                guard let before = AgentSessionSettings.permissionMode(onScreen: screen) else { return result }
                if before == target { result.reachedTarget = true; return result }
                guard mayContinue(), !Task.isCancelled else { return result }
                try await press(before)
                var changed = false
                for _ in 0..<20 {
                    try await pause()
                    guard mayContinue(), !Task.isCancelled else { return result }
                    screen = try await readScreen()
                    guard PreSendGate.check(screen, program: .claude, activity: .idle) == .send else { continue }
                    guard let after = AgentSessionSettings.permissionMode(onScreen: screen) else { continue }
                    result.mode = after
                    if after != before { changed = true; break }
                }
                guard changed else { result.feedbackTimedOut = true; return result }
                guard let after = AgentSessionSettings.permissionMode(onScreen: screen) else { return result }
                if after == target { result.reachedTarget = true; return result }
                if after == initial { result.completedCycle = true; return result }
                if !visited.insert(after).inserted { return result }
            }
        } catch {
            // The view's checked typing records uncertain delivery; never retry it.
        }
        return result
    }
}
