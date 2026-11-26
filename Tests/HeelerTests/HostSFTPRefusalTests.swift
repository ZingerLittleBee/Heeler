import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// A Host whose SSH server refuses SFTP is asked once: each ask costs its
/// connection, so Chat left open on one replaced it every few seconds (#596).
@Suite("Host SFTP refusal")
struct HostSFTPRefusalTests {
    /// The connection that met the refusal is replaced along with it, so the
    /// Host's next connection, for whichever Server, has to know.
    @Test func aRefusalStandsForTheHostsNextConnection() async throws {
        let refusals = HostSFTPRefusals()
        let first = try #require(Self.settings(Self.host(), refusals).sftpRefusal)
        let next = try #require(Self.settings(Self.host(serverKind: .tmux), refusals).sftpRefusal)
        let host = Asked()

        await #expect(throws: SSHError.sftpUnavailable) { try await first.asking { try await host.refuses() } }
        await #expect(throws: SSHError.sftpUnavailable) { try await next.asking { await host.answers() } }
        #expect(await host.asks == 1)

        // Another Host answers for itself.
        let other = try #require(Self.settings(Self.host(address: "other.example"), refusals).sftpRefusal)
        _ = try await other.asking { await host.answers() }
        #expect(await host.asks == 2)
    }

    @Test func theUserAskingAgainReachesTheHost() async throws {
        let refusal = HostSFTPRefusal()
        let host = Asked()
        await #expect(throws: SSHError.sftpUnavailable) { try await refusal.asking { try await host.refuses() } }

        // Asked again, a Host that still refuses is asked once, not once a
        // read.
        refusal.forget()
        await #expect(throws: SSHError.sftpUnavailable) { try await refusal.asking { try await host.refuses() } }
        await #expect(throws: SSHError.sftpUnavailable) { try await refusal.asking { try await host.refuses() } }
        #expect(await host.asks == 2)

        // A file the user attaches asks whatever the Host said before, and a
        // Host that now offers SFTP is asked from then on.
        _ = try await refusal.asking(again: true) { await host.answers() }
        _ = try await refusal.asking { await host.answers() }
        #expect(await host.asks == 4)
    }

    /// The three places the user asks again, through the Console's own
    /// wiring.
    @MainActor
    @Test func retryCheckAgainAndReconnectAskTheHostAgain() async {
        let host = Self.host(address: "\(UUID().uuidString.lowercased()).example")
        let refusal = HostSFTPRefusals.shared.refusal(for: HostMachine.Connection(host))
        let console = ConsoleStore(makeSession: { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "no Host here") },
                keepalive: nil)
        })
        console.setHosts([host])
        let files = console.chatHostFiles(for: host.id)

        await Self.refuse(refusal)
        let agent = Agent(
            terminalID: "term-1", kind: "grok", title: "", status: .idle, workspaceID: "w1", tabID: "t1",
            paneID: "w1:p1", cwd: "/home/dev", revision: 1)
        let chat = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"), agent: agent, program: .grok,
            source: AgentChatSource(
                hostID: host.id, socketLocation: .defaultSession, files: files, agentInfo: { agent },
                cache: VolatileChatTranscriptCache(), adapter: .grok))
        chat.retry()
        #expect(!refusal.stands)

        await Self.refuse(refusal)
        let browser = HostFilesBrowser(
            files: files, hostID: host.id, openedBy: "t1", cache: console.hostFileCache,
            agentDirectory: "/home/dev", isHostConnected: true)
        browser.folder(at: "/home/dev").checkAgain()
        #expect(!refusal.stands)

        await Self.refuse(refusal)
        await console.reconnect(
            HostMachine(id: HostMachine.Connection(host), members: [host]), leases: HostRouteLeases())
        #expect(!refusal.stands)
    }

    // MARK: Helpers

    private static func host(address: String = "mac.example", serverKind: ServerKind = .herdrTUI) -> Host {
        Host(address: address, username: "dev", serverKind: serverKind)
    }

    private static func settings(_ host: Host, _ refusals: HostSFTPRefusals) -> SSHTransportSettings {
        SSHTransportSettings(
            host: host, credentials: .password("secret"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            sftpRefusals: refusals)
    }

    private static func refuse(_ refusal: HostSFTPRefusal) async {
        _ = try? await refusal.asking(again: true) { () async throws -> Int in throw SSHError.sftpUnavailable }
        #expect(refusal.stands)
    }
}

/// What a Host was asked, and how often.
private actor Asked {
    private(set) var asks = 0

    func refuses() throws -> Int {
        asks += 1
        throw SSHError.sftpUnavailable
    }

    func answers() -> Int {
        asks += 1
        return asks
    }
}
