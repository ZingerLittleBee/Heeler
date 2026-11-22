import Foundation

/// A page a program serves on a Host's loopback interface, named the way the
/// preview loads it: always under `localhost`. However a link names the
/// interface, the page is one origin, with one set of cookies, and its
/// address is one the preview listens for on this device (ADR 0062).
struct PortPreviewTarget: Hashable, Sendable {
    /// The address to load, its host rewritten to `localhost`.
    let url: URL
    /// The port on the Host's loopback interface.
    let port: Int
    /// Whether the link named the loopback interface some other way, such as
    /// `127.0.0.1`, so the address to load differs from the one written.
    let isRewritten: Bool

    /// What a link means on the Host, or nil when it does not name the
    /// loopback interface over `http` or `https`.
    init?(link: URL) {
        guard var components = URLComponents(url: link, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              let name = Self.loopbackName(host)
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard Self.ports.contains(port) else { return nil }
        components.scheme = scheme
        components.host = "localhost"
        guard let url = components.url else { return nil }
        self.url = url
        self.port = port
        isRewritten = name != "localhost"
    }

    /// What a person means by typing a port (`4100`, `4100/docs`) or a
    /// loopback address with or without its scheme.
    init?(typed text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let rest = text.dropFirst(digits.count)
        let written: String
        if !digits.isEmpty, rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("?") || rest.hasPrefix("#") {
            written = "http://localhost:\(digits)\(rest.isEmpty ? "/" : String(rest))"
        } else if text.contains("://") {
            written = text
        } else {
            written = "http://\(text)"
        }
        guard let link = URL(string: written) else { return nil }
        self.init(link: link)
    }

    /// The root page of a port, as the Ports list opens it.
    init?(port: Int) {
        guard Self.ports.contains(port), let link = URL(string: "http://localhost:\(port)/") else { return nil }
        self.init(link: link)
    }

    /// The same page over TLS, or nil when it already is.
    var secured: PortPreviewTarget? {
        guard url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }
        components.scheme = "https"
        components.port = port
        return components.url.flatMap(PortPreviewTarget.init(link:))
    }

    /// The address as its capsule shows it: `localhost:4100`.
    var address: String {
        url.port.map { "localhost:\($0)" } ?? "localhost"
    }

    private static let ports = 1...65535

    /// The lowercased loopback name a host is, or nil. `0.0.0.0` and `::`
    /// are what servers print for "every interface", which includes loopback.
    /// A subdomain of `localhost` is not one of these: App Transport Security
    /// refuses to load it over `http`.
    private static func loopbackName(_ host: String) -> String? {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0", "::"].contains(name) ? name : nil
    }
}
