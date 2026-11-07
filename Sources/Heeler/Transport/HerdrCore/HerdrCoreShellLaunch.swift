import Foundation

/// How Heeler reaches an agent through the user's own interactive shell on a
/// herdr-core Host (ADR 0032), so the agent gets the PATH and variables the
/// shell's startup files set, and no shell stays behind. Pure: it builds an argv
/// or a script and reads what the script prints.
///
/// `scripts/test-herdr-core-shell-launch.py` runs both through real shells.
enum HerdrCoreShellLaunch {
    /// The output was cut short or does not read as this script's.
    struct MalformedOutput: Error, Equatable {}

    struct Discovery: Equatable, Sendable {
        /// The asked-for programs the interactive shell can run.
        let executables: Set<String>
        /// The asked-for program's own words for its version, as it printed them.
        let version: String?
    }

    /// A native Windows launch goes through Windows PowerShell: always there, and
    /// the only form recorded on a Windows machine. PowerShell 7's profile is not read.
    static let windowsShell = "powershell.exe"

    /// The shell replaces itself with `program`. Each argument stays a separate
    /// argv entry, so nothing in one ever reaches the shell's command string.
    /// PowerShell does not replace itself, so there the agent is its child, each
    /// word a literal in `-Command`, and the Terminal ends when it exits.
    static func argv(shell: String, program: [String]) -> [String] {
        if shell == windowsShell {
            let words = program.map(PowerShellCommand.literal).joined(separator: " ")
            return [shell, "-Command", "& \(words); exit $LASTEXITCODE"]
        }
        return isFish(shell)
            ? [shell, "-ic", "exec $argv[2..]", "fish"] + program
            : [shell, "-ic", "exec \"$@\"", shell] + program
    }

    /// A script for `/bin/sh`, for one bounded exec: the interactive shell looks
    /// for each program and asks one for its version in that same run. The inner
    /// script parses under POSIX shells and fish alike. Its markers start their
    /// own lines after whatever the startup files print. A child `/bin/sh` does the
    /// looking, with the PATH the startup files set: it sees no alias or function
    /// of the shell's, which the launch's `exec` could not run either.
    static func discoveryScript(
        shell: String, executables: [String], versionOf versioned: String, nonce: String
    ) -> Data {
        let quoted = HerdrCoreLocator.quoted
        var lines = ["printf '\\n%s\\n' \(quoted(beginMarker(nonce)))"]
        func isOnPath(_ program: String) -> String {
            "/bin/sh -c 'command -v \"$1\"' sh \(quoted(program)) >/dev/null 2>&1"
        }
        for executable in executables {
            lines.append("\(isOnPath(executable)) && printf 'agent %s\\n' \(quoted(executable))")
        }
        lines += [
            "printf 'version '",
            "\(isOnPath(versioned)) && \(quoted(versioned)) --version </dev/null 2>/dev/null",
            "printf '\\n%s\\n' \(quoted(endMarker(nonce)))",
            "exit 0",
        ]
        return Data("\(quoted(shell)) -ic \(quoted(lines.joined(separator: "\n")))".utf8)
    }

    /// A script for `/bin/sh` that asks the program an Agent runs for its version,
    /// found as that Agent found it: with its own PATH, from its own directory, and
    /// no startup file in between, since a login shell's PATH can find another
    /// release (herdr compatibility, OpenCode on a signed-in Linux core). With no
    /// PATH it searches where `execvp` does, and with its directory gone it reads
    /// no version. Its output reads as discovery's, with the version alone.
    static func versionScript(program: String, path: String?, directory: String?, nonce: String) -> Data {
        let quoted = HerdrCoreLocator.quoted
        let end = "printf '\\n%s\\n' \(quoted(endMarker(nonce)))"
        var lines = [
            "printf '\\n%s\\n' \(quoted(beginMarker(nonce)))",
            "PATH=\(quoted(path ?? "/bin:/usr/bin")); export PATH",
        ]
        if let directory, !directory.isEmpty {
            lines.append("cd \(quoted(directory)) 2>/dev/null || { \(end); exit 0; }")
        }
        lines += [
            "printf 'version '",
            "command -v \(quoted(program)) >/dev/null 2>&1 && \(quoted(program)) --version </dev/null 2>/dev/null",
            end,
            "exit 0",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The same look through Windows PowerShell, a whole command line for one
    /// bounded exec. It loads the profile a launch's `-Command` loads, and counts every
    /// command type, since `&` runs them all. An exec can refuse a program a Terminal
    /// runs (herdr compatibility), so a version that does not come changes no listing.
    /// Nothing here has run on a Windows machine.
    static func windowsDiscoveryCommand(executables: [String], versionOf versioned: String, nonce: String) -> String {
        let literal = PowerShellCommand.literal
        let programs = executables.map(literal).joined(separator: ", ")
        return PowerShellCommand.encoded(
            """
            \(HerdrCoreLocator.windowsPrelude)
            say ''
            say \(literal(beginMarker(nonce)))
            foreach ($p in @(\(programs))) {
                if (Get-Command $p -ErrorAction SilentlyContinue) { say ('agent ' + $p) }
            }
            $v = $null
            if (Get-Command \(literal(versioned)) -ErrorAction SilentlyContinue) {
                try { $v = @($null | & \(literal(versioned)) --version 2>$null)[0] } catch { $v = $null }
            }
            say ('version ' + $v)
            say \(literal(endMarker(nonce)))
            exit 0
            """,
            loadingProfile: true)
    }

    /// Reads only what lies between the markers, which startup files never reach.
    static func parseDiscovery(stdout: Data, nonce: String) throws -> Discovery {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let begin = lines.firstIndex(of: beginMarker(nonce)),
            let end = lines.lastIndex(of: endMarker(nonce)), begin < end
        else { throw MalformedOutput() }
        var executables: Set<String> = []
        var version: String?
        for line in lines[(begin + 1)..<end] {
            if line.hasPrefix("agent ") {
                executables.insert(String(line.dropFirst("agent ".count)))
            } else if version == nil, line.hasPrefix("version ") {
                let text = line.dropFirst("version ".count).trimmingCharacters(in: .whitespaces)
                version = text.isEmpty ? nil : text
            }
        }
        return Discovery(executables: executables, version: version)
    }

    private static func isFish(_ shell: String) -> Bool {
        shell.split(separator: "/").last == "fish"
    }

    private static func beginMarker(_ nonce: String) -> String { "__HEELER_AGENTS_BEGIN_\(nonce)" }
    private static func endMarker(_ nonce: String) -> String { "__HEELER_AGENTS_END_\(nonce)" }
}
