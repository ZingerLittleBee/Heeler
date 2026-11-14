import Foundation

/// What `tmux -V` printed, and whether Heeler can use that tmux (ADR 0044).
struct TmuxVersion: Equatable, Sendable {
    /// The oldest tmux Heeler drives, as the user reads it.
    static let minimum = "3.3"
    private static let minimumNumber = (major: 3, minor: 3)
    private static let bracketedPasteNumber = (major: 3, minor: 7)

    /// The version as tmux names it: `3.7b`, `next-3.8`, `master`.
    let text: String
    private let major: Int?
    private let minor: Int?

    /// Nil when the line is not tmux's: `tmux`, a space, and a version.
    init?(versionLine: String) {
        let line = versionLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("tmux ") else { return nil }
        let text = line.dropFirst("tmux ".count).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        self.text = text
        // A development build names the release it leads to: `next-3.8`.
        let release = text.hasPrefix("next-") ? text.dropFirst("next-".count) : Substring(text)
        let parts = release.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let major = parts.first.flatMap { Int($0) }
        let minor = parts.count > 1 ? Int(parts[1].prefix { $0.isASCII && $0.isNumber }) : nil
        self.major = major
        self.minor = major == nil ? nil : minor
    }

    /// A version that does not read as numbers, such as `master`, is a build the
    /// user made, and is taken as new enough.
    var isSupported: Bool {
        guard let major, let minor else { return true }
        return (major, minor) >= Self.minimumNumber
    }

    /// tmux 3.7 added `#{bracket_paste_flag}`.
    var reportsBracketedPaste: Bool {
        guard let major, let minor else { return true }
        return (major, minor) >= Self.bracketedPasteNumber
    }
}

/// One run of a tmux server (ADR 0044): its pid and when it started. A server
/// that restarted is another instance, whatever its socket.
struct TmuxServerInstance: Hashable, Sendable {
    let pid: Int
    let startTime: Int
}
