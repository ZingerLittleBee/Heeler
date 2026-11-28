import Foundation
import Testing

@testable import Heeler

/// The fixture owns one disposable Unix socket. Only its SSH connection crosses the cut proxy.
/// Its independent observer reads both terminal screens after each attempted stale input.
@Suite("Rex SSH recovery", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct RexRecoveryLiveTests {
    private struct Row: Decodable {
        let session: String
        let block: String
        let label: String
        let pid: Int
        let program: String
        let containsMarker: Bool

        var paneID: String { RexPaneAddress(sessionID: session, blockID: block).paneID }
    }

    private struct Observation: Decodable {
        let rexSocket: String
        let instance: String
        let host: String
        let loginShell: String?
        let rows: [Row]
    }

    private struct Lab: Decodable {
        let port: Int
        let controller: Int
        let token: String
        let user: String
        let seed: String
        let fingerprint: String
        let marker: String
        let initial: Observation

        func phase<T: Decodable>(_ action: String, as type: T.Type) async throws -> T {
            let url = try #require(URL(string: "http://127.0.0.1:\(controller)/\(action)"))
            var request = URLRequest(url: url, timeoutInterval: 40)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try #require((response as? HTTPURLResponse)?.statusCode == 200, "Fixture phase \(action)")
            return try JSONDecoder().decode(type, from: data)
        }
    }

    private func wait(_ description: String, until predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while await !predicate() {
            try #require(ContinuousClock.now < deadline, "\(description)")
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func followsRestoredTerminalsAndRefusesInputFromTheirPreviousForeground() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_REX_RECOVERY_LAB"])
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(lab.initial.rexSocket.hasPrefix("/tmp/heeler-lab-recovery-"))
        try #require(lab.marker.hasPrefix("HEELER_LAB_STALE_"))
        let original = try #require(lab.initial.rows.first { $0.label == "heeler-lab-recovery-target" })
        let peer = try #require(lab.initial.rows.first { $0.label == "heeler-lab-recovery-peer" })
        try #require(original.program == "claude" && peer.program == "bash")
        let originalPanes = Set([original.paneID, peer.paneID])
        let socket = try #require(RexSocket(path: lab.initial.rexSocket))
        let settings = SSHTransportSettings(
            host: "127.0.0.1", port: lab.port, username: lab.user,
            credentials: .ed25519(try RealSSHFixture.deviceKey(seed: lab.seed)),
            hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) { $0.fingerprint.displayString == lab.fingerprint },
            socket: .defaultSession)
        let host = Host(name: "heeler-lab-recovery", address: "127.0.0.1", port: lab.port,
                        username: lab.user, serverKind: .rex, rexSocket: socket)
        let session = RexHostSession(storedSocket: socket) { stored, previous in
            try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: settings),
                                              socket: stored, resuming: previous)
        }
        let suite = "heeler-lab-recovery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = PinnedAgentsStore(defaults: defaults)
        let projection = RexConsoleProjection(host: host, session: session, memory: .init(defaults: defaults),
                                              pins: pins, onChange: {})
        projection.start(isActive: true)
        defer { projection.end() }
        try await wait("Both original terminals and the known foreground") {
            Set(projection.terminalsByPane.keys) == originalPanes
                && projection.agentsByPane[original.paneID]?.agent.kind == "claude"
                && projection.server?.instanceID == lab.initial.instance
        }
        let core = try #require(projection.inventoryCore)
        let pin = TerminalCorePin(joined: core)
        pins.togglePin(hostID: host.id, paneID: original.paneID)
        let typing = try projection.chatTyping(at: original.paneID)
        let oldScreen = typing.blockedScreen
        let initialScreen = try await oldScreen.readScreen()
        try #require(initialScreen.rows.contains { $0.text.trimmingCharacters(in: .whitespaces) == "heeler-lab-agent-ready" })
        let generation = projection.transportGeneration

        struct Cut: Decodable { let cutConnections: Int }
        let cut = try await lab.phase("cut", as: Cut.self)
        try #require(cut.cutConnections >= 1)
        try await wait("A fresh SSH transport listed the same Rex instance and foreground") {
            projection.transportGeneration > generation && projection.status == .connected
                && projection.server?.instanceID == lab.initial.instance
                && projection.agentsByPane[original.paneID]?.agent.kind == "claude"
        }
        #expect(projection.inventoryCore == core)
        #expect(projection.admits(pin))
        #expect(pins.isPinned(hostID: host.id, paneID: original.paneID))

        func awaitSnapshot(_ observation: Observation) async throws {
            try await wait("The projection listed both foregrounds of the observed instance") {
                // A dial can find the socket between stop and start. Retry that standing failure.
                if case .failed = projection.status { await projection.revalidate() }
                return projection.server?.instanceID == observation.instance && projection.status == .connected
                    && !projection.isAwaitingSnapshot && projection.panesAwaitingForeground.isEmpty
                    && Set(projection.terminalsByPane.keys) == Set(observation.rows.map(\.paneID))
                    && projection.agentsByPane.isEmpty
            }
        }

        func staleInputRefusal() async throws -> String {
            do {
                try await oldScreen.type(.paste(lab.marker), whileShowing: { _ in true })
                Issue.record("Input from the original foreground was accepted")
                return ""
            } catch let refusal as RexChatTyping.Refusal {
                return refusal.message
            }
        }

        let restored = try await lab.phase("restored", as: Observation.self)
        try #require(restored.instance != lab.initial.instance && restored.host == lab.initial.host)
        try #require(Set(restored.rows.map(\.paneID)) == originalPanes)
        let loginShell = restored.loginShell ?? "bash" // Older Linux fixture manifests name Bash implicitly.
        try #require(!loginShell.isEmpty && restored.rows.allSatisfy { $0.program == loginShell }
                     && restored.rows.first { $0.paneID == original.paneID }?.pid != original.pid)
        try await awaitSnapshot(restored)
        #expect(projection.inventoryCore == core)
        #expect(projection.admits(pin))
        #expect(pins.isPinned(hostID: host.id, paneID: original.paneID))
        let restoredRefusal = try await staleInputRefusal()
        #expect(restoredRefusal == String(localized: "The Agent no longer holds this terminal, so Heeler pressed nothing."))
        let restoredScreens = try await lab.phase("inspect-restored", as: Observation.self)
        #expect(restoredScreens.instance == restored.instance && restoredScreens.rows.allSatisfy { !$0.containsMarker })

        let fresh = try await lab.phase("fresh", as: Observation.self)
        try #require(fresh.instance != restored.instance && fresh.host == restored.host)
        try #require(Set(fresh.rows.map(\.label)) == Set(restored.rows.map(\.label)))
        try #require(Set(fresh.rows.map(\.paneID)).isDisjoint(with: originalPanes))
        try await awaitSnapshot(fresh)
        #expect(projection.inventoryCore != core)
        #expect(!projection.admits(pin))
        #expect(!pins.isPinned(hostID: host.id, paneID: original.paneID))
        let freshRefusal = try await staleInputRefusal()
        #expect(freshRefusal == TransportError.rexServerGone.presentation.message)
        let freshScreens = try await lab.phase("inspect-fresh", as: Observation.self)
        #expect(freshScreens.instance == fresh.instance && freshScreens.rows.allSatisfy { !$0.containsMarker })
        withExtendedLifetime(typing) {}
    }
}
