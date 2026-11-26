import Foundation

/// A picture or video a description shows, as GitHub's rendered HTML
/// (`bodyHTML`) gives it to a browser (ADR 0065): an upload at an address
/// GitHub signed for a few minutes, another site's image through GitHub's
/// image proxy, or an image on GitHub itself. The phone loads only these,
/// with no token, and never another site directly.
struct GitHubMedia: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case image
        case video
    }

    let kind: Kind
    /// Where the phone loads it.
    let url: URL
    /// What the Markdown may have written for it, most stable first: the
    /// upload's id (`upload:<uuid>`), then the addresses it stands for
    /// (`url:<address>`).
    let keys: [String]
    /// The size its tag gives, in CSS pixels, as the uploader writes it.
    let width: Int?
    let height: Int?

    /// The same picture across reads, whose signed addresses differ.
    var id: String { keys.first ?? Self.addressKey(url) }

    /// When the address's signature ends; nil for one that does not.
    var expiresAt: Date? { Self.signatureExpiry(of: url) }

    /// Whether the address still loads for a while: a request started now
    /// should finish before the signature ends.
    func isFresh(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 20
    }
}

// MARK: - Reading the rendered HTML

extension GitHubMedia {
    /// The pictures and videos of a body's rendered HTML, in reading order.
    /// GitHub's emoji images are left out: no Markdown image writes them.
    static func media(inHTML html: String) -> [GitHubMedia] {
        html.matches(of: /<(img|video)\b([^>]*)>/.ignoresCase()).compactMap { match in
            let attributes = attributes(in: String(match.output.2))
            if attributes["class"]?.split(separator: " ").contains("emoji") == true { return nil }
            guard let source = attributes["src"], let url = webURL(source) else { return nil }
            let canonical = attributes["data-canonical-src"].flatMap(webURL)
            var keys: [String] = []
            for candidate in [url, canonical].compactMap(\.self) {
                if let upload = uploadID(in: candidate) { keys.append(uploadKey(upload)) }
            }
            for candidate in [canonical, url].compactMap(\.self) {
                keys.append(addressKey(candidate))
            }
            return GitHubMedia(
                kind: match.output.1.lowercased() == "video" ? .video : .image,
                url: url, keys: keys.uniqued(),
                width: attributes["width"].flatMap(pixels), height: attributes["height"].flatMap(pixels))
        }
    }

    /// The keys a picture or video written as `address` matches: its upload
    /// id when it is an upload, and the address.
    static func keys(written address: String) -> [String] {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let unbracketed = trimmed.hasPrefix("<") && trimmed.hasSuffix(">") ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard let url = webURL(unbracketed) else { return [] }
        return ([uploadID(in: url).map(uploadKey)] + [addressKey(url)]).compactMap(\.self)
    }

    /// A tag's attributes by lowercased name, their entities decoded.
    static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in tag.matches(of: /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/) {
            let name = match.output.1.lowercased()
            guard result[name] == nil else { continue }
            result[name] = htmlUnescaped(String(match.output.2 ?? match.output.3 ?? ""))
        }
        return result
    }

    /// The text of HTML with its character references decoded.
    static func htmlUnescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});/) { match in
            let name = match.output.1
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                    ?? String(match.output.0)
            }
            if name.hasPrefix("#") {
                return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.output.0)
            }
            return namedReferences[String(name)] ?? String(match.output.0)
        }
    }

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{00A9}",
    ]

    /// An upload's id: the UUID GitHub names an uploaded file by, on
    /// GitHub's own hosts only.
    static func uploadID(in url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path()
        let isUpload =
            host.hasSuffix(".githubusercontent.com")
            || (host == "github.com" && (path.hasPrefix("/user-attachments/") || path.contains("/assets/")))
        guard isUpload,
            let match = url.lastPathComponent.firstMatch(
                of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)
        else { return nil }
        return match.output.lowercased()
    }

    private static func uploadKey(_ id: String) -> String { "upload:\(id)" }

    private static func addressKey(_ url: URL) -> String { "url:\(url.absoluteString)" }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.host()?.isEmpty == false
        else { return nil }
        return url
    }

    private static func pixels(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The end of the signature GitHub puts on an upload's address, from
    /// the `exp` of its `jwt` query item. GitHub signs for five minutes.
    static func signatureExpiry(of url: URL) -> Date? {
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "jwt" })?.value
        else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let expiry = claims["exp"] as? NSNumber
        else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
