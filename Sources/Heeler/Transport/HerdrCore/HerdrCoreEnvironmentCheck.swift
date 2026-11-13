import Foundation

/// Which of the variables that break session records or Program Status the
/// core's Terminals start with (ADR 0034). A Terminal inherits the environment
/// of the `herdr-core hold` it runs under, which can differ from the core's
/// own, so the check reads the core and every hold `server.status` names.
/// Names only: the request asks for no value, and the script prints none, so
/// none can reach the app.
///
/// Anything but a whole answer reads as nothing found, process by process: an
/// unreadable environment, or a macOS read that could not be confirmed, adds no
/// name, and output that does not read as the script's names none at all.
enum HerdrCoreEnvironmentCheck {
    // `NO_COLOR` is not one of them: it changes how a program draws, not a
    // session record or Program Status, and agy's screen readers read its
    // colorless screens.
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
    /// Holds past this many processes are not read, which keeps the Windows
    /// command well under its limit.
    static let processCap = 16

    /// The core first, then its holds, each once and only as a pid the reader
    /// takes, so one it would refuse cannot refuse the others.
    static func processIDs(core: Int, holders: [Int]) -> [Int] {
        var pids: [Int] = []
        for pid in [core] + holders
        where pids.count < processCap && HostProcessReader.isProcessID(String(pid)) && !pids.contains(pid) {
            pids.append(pid)
        }
        return pids
    }

    static func request(pids: [Int]) -> HostProcessReader.Request {
        HostProcessReader.Request(pids: pids.map(String.init), namesOf: names, namesWithPrefix: prefixes)
    }

    static func script(
        pids: [Int], nonce: String, platform: HostProcessReader.Platform = .hostKernel
    ) throws -> Data {
        try HostProcessReader.script(request(pids: pids), nonce: nonce, platform: platform)
    }

    /// The same names on a native Windows Host, from the block in each process's
    /// own memory. No value leaves the Host there either. It ran on Windows build
    /// 26200 with herdr-core 0.1.16 (`docs/agents/herdr-compatibility.md`).
    static func windowsCommand(pids: [Int], nonce: String) throws -> String {
        try HostProcessReader.windowsCommand(request(pids: pids), nonce: nonce)
    }

    /// Every name any of `pids` holds.
    static func leakedNames(stdout: Data, nonce: String, pids: [Int]) -> Set<String> {
        guard let facts = try? HostProcessReader.parse(stdout: stdout, nonce: nonce, request: request(pids: pids))
        else { return [] }
        var found: Set<String> = []
        for pid in pids {
            if case .value(let names)? = facts[String(pid)]?.nonEmptyNames { found.formUnion(names) }
        }
        return found
    }
}
