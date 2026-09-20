import Foundation

/// The UDP endpoint and session key `mosh-server new` prints at startup.
///
/// Over a plain (PTY-less) SSH exec, `mosh-server new` prints one banner
/// line — `MOSH CONNECT <udp-port> <22-char-key>` — amid its startup
/// chatter, then detaches: the server stays alive on the Host with its UDP
/// socket bound and the wrapped command running under its own PTY, while
/// the SSH channel closes. These two values are everything `mosh_main`
/// needs to reach that socket; the IP is the SSH host the bootstrap ran
/// on, which the transport fills in.
struct MoshBootstrap: Equatable, Sendable {
    let host: String
    let udpPort: String
    let key: String

    /// Banner layout enforced byte-for-byte after the marker: digits, one
    /// space, the 22-character unpadded base64 key. Anything before the
    /// line or after it (chatter) is ignored; a line that deviates from the
    /// exact format is not the banner.
    static let marker = "MOSH CONNECT "
    static let keyLength = 22

    /// Parses the banner out of `mosh-server` output. nil when no line
    /// matches — the transport surfaces that as a failed bootstrap and the
    /// Console falls back to the SSH attach.
    static func parse(_ output: Data, host: String = "") -> MoshBootstrap? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Leading whitespace and a trailing CR (in case the output ever
            // crosses a PTY) are tolerated; everything else in the line is
            // exact.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(marker) else { continue }
            let rest = line.dropFirst(marker.count)
            guard let separator = rest.firstIndex(of: " ") else { continue }
            let port = rest[..<separator]
            guard !port.isEmpty, port.allSatisfy({ ("0"..."9").contains($0) }) else { continue }
            let keyAndNoise = rest[rest.index(after: separator)...]
            guard keyAndNoise.count >= keyLength else { continue }
            let key = keyAndNoise.prefix(keyLength)
            guard key.allSatisfy(isUnpaddedBase64(_:)) else { continue }
            // The banner ends after the key; anything else on the line would
            // make the format ambiguous, so refuse it.
            guard keyAndNoise.dropFirst(keyLength).allSatisfy({ $0 == " " || $0 == "\t" })
            else { continue }
            return MoshBootstrap(host: host, udpPort: String(port), key: String(key))
        }
        return nil
    }

    /// Base64 alphabet without padding — exactly what mosh-server's
    /// 16-byte AES-128 key encodes to.
    private static func isUnpaddedBase64(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return ("a"..."z").contains(character)
            || ("A"..."Z").contains(character)
            || ("0"..."9").contains(character)
            || character == "+"
            || character == "/"
    }
}

/// The pure mosh-vs-SSH decision for one interactive attach. Phase 1
/// deliberately keeps ordinary shell terminals on SSH: mosh wraps only the
/// Agent terminal (`herdr agent attach`), the surface with the round-trip
/// latency problem.
enum MoshTransportChoice: Equatable, Sendable {
    case mosh
    case ssh

    static func select(
        availability: Bool, target: TerminalAttachTarget
    ) -> MoshTransportChoice {
        guard availability else { return .ssh }
        switch target {
        case .agentPane:
            return .mosh
        case .terminal:
            return .ssh
        }
    }
}
