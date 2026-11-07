import Foundation

/// The user's confirmed start of a Linux Host's own core session (ADR 0031).
/// Pure: it builds what a caller runs in one bounded exec and judges what comes
/// back. Nothing else in the app runs this command.
enum HerdrCoreStart {
    enum Outcome: Equatable, Sendable {
        case started
        /// The core's uptime predates the Start, which changed nothing, so this
        /// core has whatever environment its first start gave it.
        case alreadyRunning
        case failed(detail: String?)
    }

    /// A script for `/bin/sh`. The user's interactive login shell runs the core,
    /// so the core and every Terminal it starts get the environment of the
    /// user's own terminal. `HC_SESSION` is set inside the command, after the
    /// startup files, so none of them can send the start to another session.
    /// `exec` leaves no shell behind to run logout files after the core's last line.
    static func script(executablePath: String, session: String) throws -> Data {
        guard HerdrCoreSessionName.isValid(session) else {
            throw HerdrCoreLocator.SessionRefused(session: session)
        }
        let name = HerdrCoreSessionName.normalized(session)
        let command =
            "HC_SESSION=\(HerdrCoreLocator.quoted(name)) "
            + "exec \(HerdrCoreLocator.quoted(executablePath)) server start"
        return Data("\"$SHELL\" -lic \(HerdrCoreLocator.quoted(command))".utf8)
    }

    /// `herdr-core update` by the probed path, for a terminal on a Unix Host.
    static func updateCommand(executablePath: String) -> String {
        // A command line, not UI copy: it must stay identical in every locale.
        "\(shellWord(executablePath)) update"
    }

    /// What to run in a terminal on a machine where the app starts no core.
    static func manualCommand(executablePath: String, session: String) -> String {
        let name = HerdrCoreSessionName.normalized(session)
        return "HC_SESSION=\(shellWord(name)) \(shellWord(executablePath)) server start"
    }

    /// What to run in a PowerShell window of the user's desktop session on a native
    /// Windows Host. `HC_SESSION` is how `server start` takes a session there too.
    static func windowsManualCommand(executablePath: String, session: String) -> String {
        let name = HerdrCoreSessionName.normalized(session)
        // A command line, not UI copy: it must stay identical in every locale.
        let run = "\(windowsProgramWord(executablePath)) server start"
        return name == "default" ? run : "$env:HC_SESSION=\(PowerShellCommand.literal(name)); \(run)"
    }

    /// `herdr-core update` by the probed path, for the same window.
    static func windowsUpdateCommand(executablePath: String) -> String {
        // A command line, not UI copy: it must stay identical in every locale.
        "\(windowsProgramWord(executablePath)) update"
    }

    /// A path that needs quoting needs `&` to run: PowerShell reads a bare quoted
    /// word as a string. An account name can hold what PowerShell reads as syntax,
    /// so only a path of plain characters goes bare.
    private static func windowsProgramWord(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: #"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\:._-"#)
        return path.unicodeScalars.allSatisfy(plain.contains) ? path : "& \(PowerShellCommand.literal(path))"
    }

    /// Judges by exit status and by the uptime the core prints as its last line.
    /// An interactive shell without a terminal writes job-control warnings and
    /// the user's startup files may print anything, in any encoding, before it.
    ///
    /// `elapsed` runs from before the exec was sent, and a core started by this
    /// exec has been up for less than that, so a longer uptime predates the Start.
    static func outcome(stdout: Data, stderr: Data, exitStatus: Int32, elapsed: Duration) -> Outcome {
        guard exitStatus == 0 else {
            return .failed(detail: lastLine(of: stderr).map(failureDetail) ?? lastLine(of: stdout))
        }
        guard let line = lastLine(of: stdout) else { return .failed(detail: nil) }
        guard let uptime = uptimeMilliseconds(in: line) else { return .failed(detail: line) }
        let (seconds, attoseconds) = elapsed.components
        let elapsedMilliseconds = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return uptime > elapsedMilliseconds ? .alreadyRunning : .started
    }

    /// Only the last line is decoded, so noise above it cannot spoil it.
    private static func lastLine(of output: Data) -> String? {
        output.split(separator: UInt8(ascii: "\n"))
            .lazy
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }

    /// A startup file's output without a newline, such as a terminal title, ends
    /// up on the same line as the core's, so each `{` may be where its JSON starts.
    private static func uptimeMilliseconds(in line: String) -> Int64? {
        struct Status: Decodable {
            let uptime_ms: Int64
        }
        for start in line.indices where line[start] == "{" {
            if let status = try? JSONDecoder().decode(Status.self, from: Data(line[start...].utf8)) {
                return status.uptime_ms
            }
        }
        return nil
    }

    /// A piped `herdr-core` reports a failure as one JSON line on stderr; any
    /// other line, such as the shell's own error, stands as it is.
    private static func failureDetail(_ line: String) -> String {
        struct Failure: Decodable {
            struct Body: Decodable {
                let message: String
            }
            let error: Body
        }
        return (try? JSONDecoder().decode(Failure.self, from: Data(line.utf8)))?.error.message ?? line
    }

    private static func shellWord(_ value: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        return value.unicodeScalars.allSatisfy(plain.contains) ? value : HerdrCoreLocator.quoted(value)
    }
}
