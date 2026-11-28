import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Select one backend when a private fixture only contains that backend's Panes.
enum LiveChatLabSelection {
    private static var selectedName: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["HEELER_LIVE_CHAT_BACKEND"] ?? environment["HEELER_CHAT_LAB_BACKEND"]
    }

    static func backend(for fixture: ServerKind? = nil) throws -> ServerKind {
        guard let name = selectedName else { return fixture ?? .herdrTUI }
        let selected = try #require(ServerKind(rawValue: name), "Unknown live Chat backend: \(name)")
        if let fixture { try #require(fixture == selected, "The lab fixture belongs to a different backend.") }
        return selected
    }

    static func cases(_ defaults: [ServerKind]) -> [ServerKind] {
        guard let name = selectedName else { return defaults }
        return defaults.filter { $0.rawValue == name }
    }
}

/// A loopback SSH fixture, pinned to its host key and private server addresses.
protocol LiveChatBackendLab: Sendable {
    var port: Int { get }
    var user: String { get }
    var seed: String { get }
    var fingerprint: String { get }
    var coreName: String { get }
    var tmuxSocket: String { get }
    var tmuxExecutable: String { get }
    var rexSocket: String { get }
    var rexSession: String { get }
    var rexBlock: String { get }
    var herdrSocket: String? { get }
    var panes: [String: String] { get }
}

@MainActor
extension LiveChatBackendLab {
    func connection(_ kind: ServerKind) throws -> (any ConsoleHostProjection, String) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: #require(Data(base64Encoded: self.seed)))
        var ssh = SSHTransportSettings(host: "127.0.0.1", port: self.port, username: self.user,
            credentials: .ed25519(key), hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) {
                $0.fingerprint.displayString == self.fingerprint
            }, socket: self.herdrSocket.map { .absolutePath($0) } ?? .defaultSession)
        ssh.serverKind = kind
        let settings = ssh
        let host = Host(name: "Chat Lab", address: "127.0.0.1", port: self.port, username: self.user, serverKind: kind)
        let projection: any ConsoleHostProjection
        let pane: String
        switch kind {
        case .herdrCore:
            let session = HerdrCoreHostSession(connect: {
                try await HerdrCoreSSHTransport(connection: HeelerSSHTransport.connect(settings: settings), session: self.coreName)
            })
            projection = HerdrCoreConsoleProjection(host: host, session: session, memory: .init(), pins: .init(),
                gitGate: .init(), herdrAppRename: false, isNativeWindows: { false }, onChange: {})
            pane = try #require(self.panes[kind.rawValue])
        case .tmux:
            let paths = try #require(TmuxPaths(executable: self.tmuxExecutable, socket: self.tmuxSocket))
            let socketName = URL(fileURLWithPath: self.tmuxSocket).lastPathComponent
            let session = TmuxHostSession(storedPaths: paths, connect: { saved in
                try await TmuxSSHTransport(connection: HeelerSSHTransport.connect(settings: settings),
                                           socketName: socketName, storedPaths: saved)
            })
            projection = TmuxConsoleProjection(host: host, session: session, memory: .init(), pins: .init(),
                                               gitGate: .init(), onPathsResolved: { _ in }, onChange: {})
            pane = try #require(self.panes[kind.rawValue])
        case .rex:
            let socket = try #require(RexSocket(path: self.rexSocket))
            let session = RexHostSession(storedSocket: socket) { stored, previous in
                try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: settings),
                                                  socket: stored, resuming: previous)
            }
            projection = RexConsoleProjection(host: host, session: session, pins: .init(), onChange: {})
            pane = RexPaneAddress(sessionID: self.rexSession, blockID: self.rexBlock).paneID
        case .herdrTUI:
            let link = EventsSession(subscriptions: [], connect: { try await HeelerSSHTransport.connect(settings: settings) }, keepalive: nil)
            projection = HostConsoleProjection(host: host, session: link, snapshotRetryDelay: .milliseconds(50), onChange: {})
            pane = try #require(self.panes[kind.rawValue])
        case .unconfirmed: throw TransportError.cancelled
        }
        return (projection, pane)
    }
}
