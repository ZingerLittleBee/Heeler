import Foundation

/// `heeler://agent` deep links into the app. Heeler's own Live Activity names
/// the Host by its local id: `heeler://agent/<hostID>/<paneID>` opens that
/// Agent's detail and `heeler://agent/<hostID>` the Console. Pane ids contain
/// `:` and are percent-encoded as a path component.
///
/// Another app cannot know that id, so it names the Host the way it reaches
/// it, and the app looks the Host up among the saved ones:
/// `heeler://agent?host=<address or name>&session=<name>&pane=<paneID>`.
/// `session` is the herdr session, left out for the default one; without
/// `pane` the link opens the Console. Other query items are ignored. The
/// scheme is registered in the app's Info.plist so other apps can open it.
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
        let host: HostReference
        /// Absent for Console-level links.
        let paneID: String?
    }

    /// How a link names its Host.
    enum HostReference: Equatable, Sendable {
        /// The Host's local id, as Heeler's own links carry it.
        case id(UUID)
        /// A saved Host's address or name, as another app knows it, and the
        /// herdr session it reaches; nil for the default session.
        case lookup(String, session: String?)
    }

    static func target(from url: URL) -> Target? {
        guard url.scheme == scheme, url.host() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.isEmpty ? lookupTarget(from: url) : idTarget(from: parts)
    }

    private static func idTarget(from parts: [String]) -> Target? {
        guard let first = parts.first, let hostID = UUID(uuidString: first),
            parts.count <= 2
        else { return nil }
        let pane = parts.count == 2 ? parts[1] : nil
        guard pane?.isEmpty != true else { return nil }
        return Target(host: .id(hostID), paneID: pane)
    }

    private static let lookupItems: Set<String> = ["host", "session", "pane"]
    /// herdr lists its default session under this name, and
    /// `--session default` selects it, so a named session never has it.
    private static let defaultSessionName = "default"

    private static func lookupTarget(from url: URL) -> Target? {
        var values: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        where lookupItems.contains(item.name) {
            // The same item twice names two things; the link names neither.
            guard values[item.name] == nil else { return nil }
            values[item.name] = item.value ?? ""
        }
        guard let hostValue = values["host"], !hostValue.isEmpty else { return nil }
        let session = values["session"].flatMap {
            $0.isEmpty || $0 == defaultSessionName ? nil : $0
        }
        let pane = values["pane"].flatMap { $0.isEmpty ? nil : $0 }
        return Target(host: .lookup(hostValue, session: session), paneID: pane)
    }
}

extension CharacterSet {
    /// `urlPathAllowed` keeps `:` verbatim, which reads back fine but makes
    /// the encoding asymmetric; strict encoding round-trips byte-for-byte.
    fileprivate static let urlPathAllowedStrict =
        CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/"))
}
