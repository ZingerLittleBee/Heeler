import Foundation

/// The Agent one Heeler window presents. It is the window's `WindowGroup`
/// value, the payload of the user activity a dragged Console row carries,
/// and what the window's scene storage keeps across relaunches. It wraps the
/// Console row identity the navigation path already uses; there is no second
/// way to name an Agent.
struct AgentRoute: Codable, Hashable, Sendable {
    let agentID: ConsoleAgent.ID

    /// The user activity a Console row vends while dragged; dropping it at
    /// the screen edge asks the system for a new window on that Agent.
    static let activityType = "com.otreva.heeler-manual.agent"

    init(agentID: ConsoleAgent.ID) {
        self.agentID = agentID
    }

    init(hostID: Host.ID, paneID: String) {
        agentID = ConsoleAgent.ID(hostID: hostID, paneID: paneID)
    }

    init(_ target: AgentNotificationTarget) {
        agentID = target.agentID
    }

    /// The deep-link target naming the same Agent.
    var target: AgentNotificationTarget {
        AgentNotificationTarget(hostID: agentID.hostID, paneID: agentID.paneID)
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case paneID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostID: try container.decode(Host.ID.self, forKey: .hostID),
            paneID: try container.decode(String.self, forKey: .paneID))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentID.hostID, forKey: .hostID)
        try container.encode(agentID.paneID, forKey: .paneID)
    }

    // MARK: Scene storage

    /// A stable string for `@SceneStorage`: sorted-key JSON, so the same
    /// route always encodes to the same bytes. Pane ids are opaque strings,
    /// which is why this is JSON rather than a delimiter-joined pair.
    var sceneStorageValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a UUID and a String into a keyed container cannot fail.
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Nil for an empty, corrupt, or foreign value: a window that cannot
    /// read its stored route falls back to the Console rather than failing.
    init?(sceneStorageValue: String) {
        guard !sceneStorageValue.isEmpty,
            let route = try? JSONDecoder().decode(
                AgentRoute.self, from: Data(sceneStorageValue.utf8))
        else { return nil }
        self = route
    }

    // MARK: User activity

    private static let hostIDKey = "hostID"
    private static let paneIDKey = "paneID"

    /// Property-list-safe payload for `NSUserActivity.userInfo`.
    var userActivityInfo: [String: String] {
        [Self.hostIDKey: agentID.hostID.uuidString, Self.paneIDKey: agentID.paneID]
    }

    /// Matched by a scene's external-event preferences. Deliberately not a
    /// `heeler://` URL, which existing windows prefer, so a dropped row gets
    /// the new window the user asked for.
    var targetContentIdentifier: String {
        "\(Self.activityType)/\(agentID.hostID.uuidString)/\(agentID.paneID)"
    }

    init?(activityType: String, userInfo: [AnyHashable: Any]?) {
        guard activityType == Self.activityType,
            let hostString = userInfo?[Self.hostIDKey] as? String,
            let hostID = UUID(uuidString: hostString),
            let paneID = userInfo?[Self.paneIDKey] as? String,
            !paneID.isEmpty
        else { return nil }
        self.init(hostID: hostID, paneID: paneID)
    }

    init?(userActivity: NSUserActivity) {
        self.init(activityType: userActivity.activityType, userInfo: userActivity.userInfo)
    }

    /// The activity a dragged Console row carries.
    func makeUserActivity(title: String?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = title
        activity.userInfo = userActivityInfo
        activity.targetContentIdentifier = targetContentIdentifier
        return activity
    }
}

/// Where a window's Agent came from when the window first appeared.
enum SceneRouteSource: Equatable, Sendable {
    case sceneStorage
    case windowValue
    case userActivity
}

/// The restoration precedence for one window, as a pure decision: what the
/// scene itself stored beats the value the window was opened with, which
/// beats an activity handed to the new scene. Scene storage is the most
/// specific record — it follows every navigation inside that window — while
/// the window value can be the one it was opened with and the activity only
/// ever names the Agent that was dragged.
struct SceneRouteRestoration: Equatable, Sendable {
    let route: AgentRoute
    let source: SceneRouteSource

    static func resolve(
        sceneStorage: String?,
        windowValue: AgentRoute?,
        userActivity: AgentRoute?
    ) -> SceneRouteRestoration? {
        if let sceneStorage, let route = AgentRoute(sceneStorageValue: sceneStorage) {
            return SceneRouteRestoration(route: route, source: .sceneStorage)
        }
        if let windowValue {
            return SceneRouteRestoration(route: windowValue, source: .windowValue)
        }
        if let userActivity {
            return SceneRouteRestoration(route: userActivity, source: .userActivity)
        }
        return nil
    }
}
