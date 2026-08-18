import Foundation

/// Where `herdr` actually lives on Hosts that install it via Homebrew,
/// linuxbrew, cargo, or a user-local prefix.
///
/// SSH exec is not a login shell: sshd's default `PATH` is typically
/// `/usr/bin:/bin`, so a Host that can run `herdr` interactively still
/// answers `exec: herdr: not found` (exit 127) on Attach. The API socket
/// path does not need the binary — that is why the Console can list Agents
/// while the PTY Attach dies (#206).
///
/// Extra prefixes are appended after the session `PATH` so an existing
/// `herdr` keeps priority. There is no separate discovery probe: those
/// prefixes already cover the same directories, and a probe would add a
/// round trip inside attach/wake/session-list deadlines.
///
/// Two ways the prefixes get onto a command, pick by how `herdr` is spelled:
/// - ``wrappingBareHerdr(_:)`` at the exec site when the command *word* is
///   still an unpathed `herdr` (session list, plugin list, and those
///   overrides).
/// - Bake ``pathExport`` into an existing `/bin/sh -c` body when `herdr`
///   lives inside that body (the default plugin config-dir probe uses
///   command substitution). Wrapping looks only at the command word, so it
///   cannot see that inner `herdr`.
enum HerdrHostPath: Sendable {
    /// Directories appended to `PATH` on herdr CLI execs. `$HOME` is
    /// expanded by the remote `/bin/sh`, not by Swift.
    static let extraPATH =
        "$HOME/.local/bin:$HOME/.linuxbrew/bin:$HOME/.cargo/bin:"
        + "/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"

    static var pathAssignment: String {
        "PATH=\"$PATH:\(extraPATH)\""
    }

    static var pathExport: String {
        "export \(pathAssignment)"
    }

    /// True when `command` invokes an unpathed `herdr` as its command word.
    /// Leading `NAME=value` assignments are skipped, so `HERDR_X=1 herdr …`
    /// still counts. Quoted literals (`'herdr: not json'`), `ENV=herdr` in
    /// front of another command, and absolute injectables (`/opt/herdr-wake`,
    /// `/nonexistent/herdr`) stay false.
    static func isBareHerdrCommand(_ command: String) -> Bool {
        commandWord(in: command) == "herdr"
    }

    /// Wraps a still-bare `herdr …` in `/bin/sh` so the extra prefixes are
    /// visible even when the account shell is fish (`$PATH` is a list there).
    /// The wrap therefore runs under POSIX sh, not the login shell: a `herdr`
    /// that exists only as a shell function or alias is not visible.
    /// Injectable commands whose command word is not `herdr` are unchanged.
    /// Embedded single quotes are escaped with `'\''` so a per-Host override
    /// such as `herdr --config '/x/y' session list` still gets the PATH fix.
    static func wrappingBareHerdr(_ command: String) -> String {
        guard isBareHerdrCommand(command) else { return command }
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "/bin/sh -c '\(pathExport); exec \(escaped)'"
    }

    /// Exit 127 from a still-bare `herdr` is the PATH miss (#206). Any other
    /// status, or an injectable command, is left for the caller.
    static func missingBinaryError(
        exitStatus: Int32, command: String
    ) -> TransportError? {
        guard exitStatus == 127, isBareHerdrCommand(command) else { return nil }
        return .herdrBinaryNotFound
    }

    private static func commandWord(in command: String) -> Substring? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: \.isWhitespace)
            .first { !isEnvironmentAssignment($0) }
    }

    /// POSIX `NAME=value` words a shell would consume before the command.
    private static func isEnvironmentAssignment(_ word: Substring) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator > word.startIndex else {
            return false
        }
        let name = word[..<separator]
        guard let first = name.first, first.isASCII else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "_")
        }
    }
}
