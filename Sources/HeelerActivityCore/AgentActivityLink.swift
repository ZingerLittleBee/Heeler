import Foundation

/// Deep links from Live Activity taps into the app. A widget tap always
/// opens its own app, so the scheme needs no Info.plist registration; the
/// URL just has to survive the round trip. Pane ids contain `:` and are
/// percent-encoded as a path component.
enum AgentActivityLink {
    static let scheme = "heeler"
    static let host = "agent"

    /// A tap on one agent row: opens that agent's detail.
    static func agentURL(hostID: String, paneID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        guard
            let pane = paneID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowedStrict)
        else { return nil }
        components.percentEncodedPath = "/\(hostID)/\(pane)"
        return components.url
    }

    /// A tap outside any row (compact island, minimal, banner chrome):
    /// opens the Console.
    static func consoleURL(hostID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(hostID)"
        return components.url
    }

    struct Target: Equatable, Sendable {
        let hostID: UUID
        /// Absent for Console-level taps.
        let paneID: String?
    }

    static func target(from url: URL) -> Target? {
        guard url.scheme == scheme, url.host() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first, let hostID = UUID(uuidString: first),
            parts.count <= 2
        else { return nil }
        let pane = parts.count == 2 ? parts[1] : nil
        guard pane?.isEmpty != true else { return nil }
        return Target(hostID: hostID, paneID: pane)
    }
}

extension CharacterSet {
    /// `urlPathAllowed` keeps `:` verbatim, which reads back fine but makes
    /// the encoding asymmetric; strict encoding round-trips byte-for-byte.
    fileprivate static let urlPathAllowedStrict =
        CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/"))
}
