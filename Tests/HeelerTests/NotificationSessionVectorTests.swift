import Foundation
import Testing

@testable import Heeler

/// The app side of session-scoped Notification Registration (#412), driven by
/// the shared vectors in `plugin/test-vectors/notification-session-v1.json`,
/// the same file the Node plugin tests consume. The plugin derives a hook's
/// session from its socket path and delivers entries by it; these tests pin
/// that the session a Host writes, the name rule, and the entries the app
/// keeps line up with that derivation and delivery.
@Suite("Notification session vectors")
struct NotificationSessionVectorTests {
    private static let vectors = NotificationSessionVectorFile.shared
    /// The home directory the vector's socket paths are written under.
    private static let home = "/home/ada"
    private static let deviceToken = APNSDeviceToken(hex: "a1b2c3", environment: .production)
    private static let ownKey = Data(repeating: 0xEE, count: 32)
    /// A valid launcher for endpoint Hosts; only the socket varies.
    private static let launcher = "/opt/example/bin/herdr"
    /// The derivation vectors whose socket path a Pairing Code v2 endpoint
    /// accepts: absolute, quotable, in herdr's layout, and short enough.
    private static let endpointDerivations = vectors.derivation.filter { vector in
        vector.socketPath.flatMap { HerdrEndpoint(socketPath: $0, executablePath: launcher) } != nil
    }

    /// Guards against silently loading an empty or truncated vector file;
    /// mirrors the same assertion in the Node suite.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.names.contains { $0.valid })
        #expect(Self.vectors.names.contains { !$0.valid })
        #expect(Self.vectors.derivation.count >= 20)
        #expect(Self.vectors.delivery.count >= 8)
        #expect(Set(Self.vectors.derivation.map(\.name)).count == Self.vectors.derivation.count)
        #expect(Set(Self.vectors.delivery.map(\.name)).count == Self.vectors.delivery.count)
        #expect(Self.vectors.derivation.contains { $0.session == nil })
        #expect(Self.vectors.delivery.contains { $0.ownSession == nil })
        #expect(Self.endpointDerivations.contains { $0.session == "" })
        #expect(Self.endpointDerivations.contains { $0.session?.isEmpty == false })
    }

    @Test(arguments: vectors.names)
    func sessionNameRuleMatchesHerdr(vector: NotificationSessionVectorFile.Name) {
        #expect(HerdrSessionName.isValid(vector.name) == vector.valid)
    }

    /// A Host targeting the derived session writes exactly the value a hook
    /// in that session derives, and where the vector path follows the app's
    /// home-relative layout the Host's socket is that path.
    @Test(arguments: vectors.derivation.filter { $0.session != nil })
    func hostSessionValueMatchesTheHookDerivation(
        vector: NotificationSessionVectorFile.Derivation
    ) throws {
        let session = try #require(vector.session)
        let host = Host(address: "studio.local", username: "ada", sessionName: session)

        #expect(host.notificationSession == session)
        #expect(session.isEmpty || HerdrSessionName.isValid(session))
        if let socketPath = vector.socketPath, socketPath.hasPrefix("\(Self.home)/.config/herdr/") {
            #expect(host.socketLocation.path(homeDirectory: Self.home) == socketPath)
        }
    }

    /// No Host reaches a session a hook cannot name: a session-shaped socket
    /// path the plugin reads as unknown carries a name the app refuses.
    @Test(arguments: vectors.derivation.filter { $0.session == nil })
    func unknownSessionSocketsCarryNamesTheAppRefuses(
        vector: NotificationSessionVectorFile.Derivation
    ) throws {
        let socketPath = try #require(vector.socketPath)
        let prefix = "\(Self.home)/.config/herdr/sessions/"
        let suffix = "/herdr.sock"
        guard socketPath.hasPrefix(prefix), socketPath.hasSuffix(suffix),
            socketPath.count >= prefix.count + suffix.count
        else { return }
        let name = String(socketPath.dropFirst(prefix.count).dropLast(suffix.count))

        #expect(!HerdrSessionName.isValid(name))
    }

    /// The app's port of the plugin's derivation reads every socket path the
    /// way the plugin does.
    @Test(arguments: vectors.derivation)
    func endpointSessionDerivationMatchesThePlugin(
        vector: NotificationSessionVectorFile.Derivation
    ) {
        #expect(HerdrEndpoint.session(fromSocketPath: vector.socketPath) == vector.session)
    }

    /// An endpoint Host registers in the session its hooks derive from the
    /// endpoint's socket, whatever its stored session name, and connects to
    /// that socket.
    @Test(arguments: endpointDerivations)
    func endpointHostSessionValueMatchesTheHookDerivation(
        vector: NotificationSessionVectorFile.Derivation
    ) throws {
        let socketPath = try #require(vector.socketPath)
        let endpoint = try #require(
            HerdrEndpoint(socketPath: socketPath, executablePath: Self.launcher))
        let host = Host(
            address: "studio.local", username: "ada", sessionName: "elsewhere",
            herdrEndpoint: endpoint)

        #expect(host.notificationSession == vector.session)
        #expect(host.socketLocation == .absolutePath(socketPath))
    }

    /// No endpoint carries a socket whose session a hook cannot name.
    @Test(arguments: vectors.derivation.filter { $0.session == nil })
    func unknownSessionSocketsNeverMakeAnEndpoint(
        vector: NotificationSessionVectorFile.Derivation
    ) {
        let endpoint = vector.socketPath.flatMap {
            HerdrEndpoint(socketPath: $0, executablePath: Self.launcher)
        }

        #expect(endpoint == nil)
    }

    /// The app reads an entry as legacy exactly when the plugin does: its
    /// `session` is not a JSON string.
    @Test(arguments: vectors.delivery)
    func deliveryIndexesFollowTheAppsReadingOfSession(
        vector: NotificationSessionVectorFile.Delivery
    ) {
        let delivered = vector.entries.indices.filter {
            Self.delivers(vector.entries[$0], toHookIn: vector.ownSession)
        }

        #expect(delivered == vector.delivered)
    }

    /// After a Host registers in the hook's session, that hook reaches the
    /// Host's entry and no other session-scoped entry of this device, and no
    /// other session's hook reaches it.
    @Test(arguments: vectors.delivery.filter { $0.ownSession != nil })
    func aRegisteredHostIsReachedOnlyByItsSessionsHook(
        vector: NotificationSessionVectorFile.Delivery
    ) throws {
        let session = try #require(vector.ownSession)
        let entry = NotificationDeviceEntry(
            token: Self.deviceToken, key: Self.ownKey, session: session,
            notify: NotificationTriggerPreferences())
        let registered = try Self.file(entries: vector.entries).registering(entry)

        for hookSession in Self.hookSessions(for: vector) {
            let reached = registered.devices.filter {
                Self.delivers($0, toHookIn: hookSession) && $0["session"]?.stringValue != nil
            }
            let ownReached = reached.filter { Self.isOwn($0, key: Self.ownKey) }
            if hookSession == session {
                #expect(reached.count == 1, "hook in \(hookSession.debugDescription)")
                #expect(ownReached.count == 1, "hook in \(hookSession.debugDescription)")
            } else {
                #expect(ownReached.isEmpty, "hook in \(hookSession.debugDescription)")
            }
        }
    }

    /// A legacy entry (every session's hook reaches it) moves into its Host's
    /// session on normalization, or is dropped when another Host holds that
    /// slot, so afterwards only the Host's own session reaches it and that
    /// session reaches one entry of this device.
    @Test(arguments: vectors.delivery.filter { $0.ownSession != nil })
    func aLegacyEntryMovesIntoItsHostsSession(
        vector: NotificationSessionVectorFile.Delivery
    ) throws {
        let session = try #require(vector.ownSession)
        let file = try Self.file(entries: vector.entries)

        for index in vector.entries.indices where vector.entries[index]["session"]?.stringValue == nil {
            let key = Self.key(at: index)
            let owner = NotificationRegistrationOwner(
                deviceToken: Self.deviceToken.hex, key: key, session: session)
            let normalized = file.normalized(for: owner)
            let own = normalized.devices.filter { Self.isOwn($0, key: key) }

            #expect(own.count <= 1, "entry \(index)")
            if let entry = own.first {
                #expect(entry["session"] == .string(session), "entry \(index)")
            }
            let reached = normalized.devices.filter {
                Self.delivers($0, toHookIn: session) && $0["session"]?.stringValue != nil
            }
            #expect(reached.count <= 1, "entry \(index)")
        }
    }

    /// The plugin's delivery rule, in terms of the app's reading of an
    /// entry: legacy entries reach every hook; others only the exact session.
    private static func delivers(_ entry: JSONValue, toHookIn session: String?) -> Bool {
        guard let entrySession = entry["session"]?.stringValue else { return true }
        return entrySession == session
    }

    private static func isOwn(_ entry: JSONValue, key: Data) -> Bool {
        entry["token"]?.stringValue == deviceToken.hex
            && entry["key"]?.stringValue == key.base64URLEncodedString()
    }

    /// Every session the vector names, plus the default session.
    private static func hookSessions(for vector: NotificationSessionVectorFile.Delivery) -> Set<String> {
        var sessions: Set<String> = [""]
        sessions.formUnion(vectors.delivery.compactMap(\.ownSession))
        sessions.formUnion(vector.entries.compactMap { $0["session"]?.stringValue })
        return sessions
    }

    /// A distinct Notification Key per vector entry: each entry belongs to a
    /// different Host of this device.
    private static func key(at index: Int) -> Data {
        Data(repeating: UInt8(index + 1), count: 32)
    }

    /// A registration file of this device holding the vector's entries, each
    /// with its own Host key and the vector's `session` field as written.
    private static func file(entries: [JSONValue]) throws -> NotificationRegistrationFile {
        let devices = entries.enumerated().map { index, entry -> JSONValue in
            guard case .object(var fields) = entry else { return entry }
            fields["token"] = .string(deviceToken.hex)
            fields["key"] = .string(key(at: index).base64URLEncodedString())
            fields["env"] = .string(deviceToken.environment.rawValue)
            fields["notify"] = .object(["blocked": .bool(true), "done": .bool(true)])
            return .object(fields)
        }
        // `v` is written by hand: JSONValue carries numbers as Double.
        let data = Data(#"{"v":1,"devices":"#.utf8)
            + (try JSONEncoder().encode(JSONValue.array(devices))) + Data("}".utf8)
        let file = try NotificationRegistrationFile.decode(data)
        #expect(file.devices.count == entries.count)
        return file
    }
}
