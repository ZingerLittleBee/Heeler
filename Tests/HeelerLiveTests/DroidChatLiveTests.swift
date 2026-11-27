import CryptoKit
import Foundation
import Testing
import SwiftUI
import UIKit

@testable import Heeler

@MainActor
@Suite("Droid Chat on a live Herdr TUI Host")
struct DroidChatLiveTests {
    struct Scenario: Decodable {
        let pane, directory: String
    }

    struct Lab: Decodable {
        let port: Int
        let user, seed, fingerprint, socket, pane, session: String
        var scenarios: [String: Scenario]?
        var evidenceDirectory: String?
    }

    /// The fixture owns a disposable Droid pane on the specified local server.
    /// Send one plain-text prompt only after checking that pane's session UUID.
    @Test func readsAndRepliesInTheReportedSession() async throws {
        try await withLab { try await exercise($0, host: $1, projection: $2) }
    }

    func withLab(_ body: (Lab, Host, HostConsoleProjection) async throws -> Void) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_DROID_CHAT_LAB"])
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let seed = try #require(Data(base64Encoded: lab.seed))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let settings = SSHTransportSettings(host: "127.0.0.1", port: lab.port, username: lab.user,
            credentials: .ed25519(key), hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) {
                $0.fingerprint.displayString == lab.fingerprint
            }, socket: .absolutePath(lab.socket))
        let link = EventsSession(subscriptions: [], connect: {
            try await HeelerSSHTransport.connect(settings: settings)
        }, keepalive: nil)
        await link.resume()
        do {
            let host = Host(name: "Droid Lab", address: "127.0.0.1", port: lab.port, username: lab.user)
            let projection = HostConsoleProjection(host: host, session: link, snapshotRetryDelay: .milliseconds(50), onChange: {})
            try await body(lab, host, projection)
        } catch {
            await link.end()
            throw error
        }
        await link.end()
    }

    private func exercise(_ lab: Lab, host: Host, projection: HostConsoleProjection) async throws {
        let agent = try await projection.agentInfo(paneID: lab.pane)
        let program = try #require(AgentChatAvailability.program(for: agent, platform: .posix))
        try #require(program == .droid)
        let expected = ConversationReference(program: .droid, sessionID: lab.session)
        try #require(ConversationReference.resolve(agent.agentSession) == .bound(expected))
        var source = AgentChatSource(
            hostID: host.id, socketLocation: .absolutePath(lab.socket), files: projection.chatHostFiles(),
            agentInfo: { try await projection.agentInfo(paneID: lab.pane) }, cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: program)))
        source.screen.droidTarget = { try await projection.droidDialogTarget(paneID: lab.pane) }
        source.sessionEvidence = { try await projection.droidSessionEvidence(paneID: lab.pane) }
        let chat = AgentChatStore(agentID: .init(hostID: host.id, paneID: lab.pane), agent: agent, program: program, source: source)
        defer { chat.end() }
        await chat.step()
        guard case .following(let file) = chat.conversation.phase else {
            Issue.record("Droid Chat did not open the live transcript")
            return
        }
        try #require(file.hasSuffix("/" + lab.session + ".jsonl"))
        let answer = "HEELER_DROID_" + UUID().uuidString.prefix(8)
        let prompt = "Reply with exactly \(answer). Do not use tools."
        let composer = AgentComposerStore(target: lab.pane) { try await projection.promptAgent($0) }
        composer.bindDroidDraft(to: chat.droidSessionID)
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: program, commands: []),
            activity: { ChatAgentActivity(chat.agent.status) }, readScreen: { try await projection.readAgentScreen(lab.pane) },
            droidTarget: chat.droidScreen.droidTarget, displayedDroidTarget: { chat.displayedDroidTarget }, confirmSession: { await chat.confirmSessionBeforeSend() })
        composer.replaceDraft(with: prompt)
        chat.draftDidChange(to: prompt)
        try #require(await composer.send(policy: policy) == .deliveredViaPrompt)
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            await chat.step()
            let transcript = chat.conversation.transcript
            if transcript.entries.contains(where: { $0.content == .assistant(.init(text: answer)) }) {
                #expect(transcript.recordedPrompts.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt }.count == 1)
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("The reply did not reach the Chat timeline")
    }
}
