import Foundation

/// Every executable is resolved and identity-checked by the transport before
/// this builder binds it to an explicit core session. Never fall back to herdr.
enum HerdrCoreCommand {
    static let streamMarker = "__HEELER_CORE_STREAM__"
    static let executableMarker = "__HEELER_CORE_EXECUTABLE__="
    static let pathMarker = "__HEELER_CORE_PATH__="

    /// Runs under the transport's remote process-group watchdog. Probe each
    /// name separately so an unrelated or hanging hc cannot hide herdr-core.
    static func identityProbe(name: String) -> Data {
        Data((HerdrHostPath.pathExport + "; candidate=$(command -v " + quote(name) + ") || exit 127; "
            + "case \"$candidate\" in /*) ;; *) exit 126 ;; esac; "
            + "version=$(\"$candidate\" --version 2>/dev/null) || exit 126; "
            + "case \"$version\" in 'hc '[0-9]*|'herdr-core '[0-9]*) "
            + "printf '\(executableMarker)%s\\n' \"$candidate\" ;; *) exit 126 ;; esac").utf8)
    }

    /// The actual executable bypasses core templates. Its runtime PATH must
    /// travel with it because the already running daemon has another env.
    static func executableProbe(for kind: SupportedAgentKind) -> String {
        let body = HerdrHostPath.pathExport
            + "; executable=$(command -v \"$1\") || exit 127; "
            + "printf '\(executableMarker)%s\\n\(pathMarker)%s\\n' \"$executable\" \"$PATH\""
        return "/bin/sh -c " + quote(body) + " heeler-core-executable " + quote(kind.executable)
    }

    static func connect(session: String, executable: String) throws -> String {
        try command(session: session, executable: executable, arguments: ["connect"], stream: true)
    }

    static func attach(session: String, request: TerminalAttachRequest, executable: String) throws -> String {
        try validateTarget(request.target.identifier)
        guard (1...Int(UInt16.max)).contains(request.cols),
              (1...Int(UInt16.max)).contains(request.rows) else {
            throw TransportError.channelFailed(detail: "Invalid herdr-core terminal geometry")
        }
        return try command(session: session, executable: executable, arguments: ["attach", request.target.identifier], stream: false)
    }

    static func validateTarget(_ target: String) throws {
        guard !target.isEmpty, !target.contains("/"), !target.hasPrefix("-"),
              target.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
            throw TransportError.hostFeatureUnavailable(feature: "Connect directly to the Host that owns this herdr-core terminal")
        }
    }

    private static func command(session: String, executable: String, arguments: [String], stream: Bool) throws -> String {
        guard HerdrCoreSessionName.isValid(session), executable.hasPrefix("/"),
              !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransportError.channelFailed(detail: "Invalid herdr-core session or executable")
        }
        let body = HerdrHostPath.pathExport
            + "; export HC_SESSION=\"$1\"; shift; core=\"$1\"; shift; unset HC_SOCKET HC_TERMINAL_ID; "
            + (stream ? "printf \"\(streamMarker)\\n\"; " : "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; ")
            + "exec \"$core\" \"$@\"" + (stream ? " 2>&1" : "")
        return "/bin/sh -c " + quote(body) + " heeler-core "
            + ([HerdrCoreSessionName.normalized(session), executable] + arguments).map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String { GitProbe.singleQuoted(value) }
}
