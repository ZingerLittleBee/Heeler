import Foundation

/// Which of the variables that break session records or Program Status a core
/// inherited from whoever started it (ADR 0034). Names only: the request asks
/// for no value, and the script prints none, so none can reach the app.
///
/// Anything but a whole answer reads as nothing found: an unreadable
/// environment, or a macOS read that could not be confirmed, shows no notice.
enum HerdrCoreEnvironmentCheck {
    static let names = [
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SKIP_PROMPT_HISTORY",
        "CLAUDECODE",
        "TMUX",
        "STY",
        "ZELLIJ",
        "CURSOR_TRACE_ID",
        "VSCODE_GIT_ASKPASS_MAIN",
        "CODEX_THREAD_ID",
        "OMPCODE",
        "PI_PROGRAM_STATUS",
    ]
    static let prefixes = ["HERDR_"]

    static func request(pid: Int) -> HostProcessReader.Request {
        HostProcessReader.Request(pids: [String(pid)], namesOf: names, namesWithPrefix: prefixes)
    }

    static func script(
        pid: Int, nonce: String, platform: HostProcessReader.Platform = .hostKernel
    ) throws -> Data {
        try HostProcessReader.script(request(pid: pid), nonce: nonce, platform: platform)
    }

    /// The same names on a native Windows Host, from the block in the core's own
    /// memory. No value leaves the Host there either. It has not run on Windows.
    static func windowsCommand(pid: Int, nonce: String) throws -> String {
        try HostProcessReader.windowsCommand(request(pid: pid), nonce: nonce)
    }

    static func leakedNames(stdout: Data, nonce: String, pid: Int) -> Set<String> {
        let request = request(pid: pid)
        guard let facts = try? HostProcessReader.parse(stdout: stdout, nonce: nonce, request: request),
            case .value(let names)? = facts[String(pid)]?.nonEmptyNames
        else { return [] }
        return names
    }
}
