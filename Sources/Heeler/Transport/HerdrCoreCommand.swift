import Foundation

/// Core is an explicit Host backend. Never try it after a legacy socket
/// failure: two servers on the same account can own different terminals.
enum HerdrCoreCommand {
    static let streamMarker = "__HEELER_CORE_STREAM__"

    static let executableMarker = "__HEELER_CORE_EXECUTABLE__="

    /// Resolve an actual executable before terminal.run, whose bare argv[0]
    /// otherwise names a user template before it names a program on PATH.
    static func executableProbe(for kind: SupportedAgentKind) -> String {
        "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "executable=$(command -v \"$1\") || exit 127; "
            + "printf \"\(executableMarker)%s\\n\" \"$executable\"' heeler-core-executable "
            + GitProbe.singleQuoted(kind.executable)
    }

    static func connect(session: String) throws -> String {
        try command(session: session, arguments: ["connect"], stream: true)
    }

    static func attach(session: String, request: TerminalAttachRequest) throws -> String {
        try validateTarget(request.target.identifier)
        guard (1...Int(UInt16.max)).contains(request.cols),
              (1...Int(UInt16.max)).contains(request.rows) else {
            throw TransportError.channelFailed(detail: "Invalid herdr-core terminal geometry")
        }
        // Core supports concurrent viewers; there is no legacy takeover flag.
        return try command(session: session, arguments: ["attach", request.target.identifier], stream: false)
    }

    static func validateTarget(_ target: String) throws {
        // A federated terminal's cwd and files belong to another machine.
        // Only inventory on this authenticated Host can use its SSH services.
        guard !target.isEmpty, !target.contains("/"), !target.hasPrefix("-"),
              target.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
            throw TransportError.hostFeatureUnavailable(feature: "Connect directly to the Host that owns this herdr-core terminal")
        }
    }

    private static func command(session: String, arguments: [String], stream: Bool) throws -> String {
        guard HerdrSessionName.isValid(session) else {
            throw TransportError.channelFailed(detail: "Invalid herdr-core session name")
        }
        let body = HerdrHostPath.pathExport
            + "; export HC_SESSION=\"$1\"; shift; unset HC_SOCKET HC_TERMINAL_ID; "
            + "if command -v hc >/dev/null 2>&1; then core=$(command -v hc); "
            + "elif command -v herdr-core >/dev/null 2>&1; then core=$(command -v herdr-core); "
            + "else printf \"Install herdr-core on this Host.\\n\" >&2; exit 127; fi; "
            + (stream ? "printf \"\(streamMarker)\\n\"; " : "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; ")
            + "exec \"$core\" \"$@\""
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "/bin/sh -c \(quote(body)) heeler-core " + ([session] + arguments).map(quote).joined(separator: " ")
    }
}
