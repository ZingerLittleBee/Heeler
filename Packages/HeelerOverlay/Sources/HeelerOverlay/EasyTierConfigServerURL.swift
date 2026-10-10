import Foundation

/// Normalizes what a user types as an EasyTier config server: a bare user
/// name for the official server, or a full URL. Mirrors the native check
/// (heeler-easytier `check_url`), so anything accepted here connects.
enum EasyTierConfigServerURL {
    static let officialHost = "config-server.easytier.cn"
    static let officialPort = 22020

    /// Characters a user name keeps verbatim in the URL path; everything else
    /// (including `/`, `%`, `?` and `#`) is percent-encoded.
    private static let tokenAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        guard trimmed.contains("://") else { return userName(trimmed) }
        return url(trimmed)
    }

    /// `scheme://host[:port]/…` for what a user typed, without the token (the
    /// path), user info, query or fragment, for messages and logs; nil when it
    /// has no scheme and host (a bare user name is a token too).
    static func redacted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://"),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed)\(port)/…"
    }

    private static func userName(_ name: String) -> String? {
        guard let token = name.addingPercentEncoding(withAllowedCharacters: tokenAllowed) else { return nil }
        return "udp://\(officialHost):\(officialPort)/\(token)"
    }

    private static func url(_ text: String) -> String? {
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        switch scheme {
        case "udp", "tcp":
            guard components.port != nil else { return nil }
        case "ws", "wss":
            break
        default:
            return nil
        }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        // The token is the last path segment, as EasyTier reads it.
        guard let last = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).last,
              let token = String(last).removingPercentEncoding, !token.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host
        return components.string
    }
}
