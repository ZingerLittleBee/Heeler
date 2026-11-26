import CryptoKit
import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Amp Chat on a live Herdr TUI Host")
struct AmpChatLiveTests {
    /// The fixture owns both private Amp threads, an isolated config directory
    /// and a disposable loopback sshd. Its operator reloads the missing plugin
    /// in the first pane once this test has installed it.
    @Test
    func installReadAndSendThroughLocalHerdr() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_AMP_CHAT_LAB"])
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let seed = try #require(Data(base64Encoded: lab.seed))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let settings = SSHTransportSettings(host: "127.0.0.1", port: lab.port, username: lab.user,
            credentials: .ed25519(key), hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) {
                $0.fingerprint.displayString == lab.fingerprint
            }, socket: .absolutePath(lab.socket))
        let host = Host(name: "Amp Lab", address: "127.0.0.1", port: lab.port, username: lab.user)
        let session = EventsSession(subscriptions: [], connect: {
            try await HeelerSSHTransport.connect(settings: settings)
        }, keepalive: nil)
        await session.resume()
        let projection = HostConsoleProjection(host: host, session: session, snapshotRetryDelay: .milliseconds(50), onChange: {})
        do {
            try await exercise(lab, projection: projection)
        } catch {
            await session.end()
            throw error
        }
        await session.end()
    }

    private func exercise(_ lab: Lab, projection: HostConsoleProjection) async throws {
        let first = AmpChatConnection(pane: lab.first) { projection }
        let second = AmpChatConnection(pane: lab.second) { projection }
        let available = try await second.evidence()
        try #require(available == .bound(sessionID: lab.secondThread, transcriptRoot: nil, directory: nil))
        let other = try #require(second.current)
        let initial = try await first.evidence()
        if lab.alreadyInstalled == true {
            try #require(initial == .bound(sessionID: lab.firstThread, transcriptRoot: nil, directory: nil))
        } else {
            try #require(initial == .unavailable(.amp(.missing)))
        }
        let place = try #require(first.location)
        try #require(place.directory == lab.directory)
        try await first.install(place)
        try await first.install(place)
        let deadline = ContinuousClock.now + .seconds(60)
        while first.current == nil, ContinuousClock.now < deadline {
            _ = try await first.evidence()
            if first.current == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        let target = try #require(first.current)
        try #require(target.binding.thread == lab.firstThread && target.binding.thread != other.binding.thread)
        var files = projection.chatHostFiles()
        files.amp = first
        var source = AmpRecordSource(thread: lab.firstThread)
        var reducer = AmpTranscriptReducer()
        reducer.append(try #require(try await source.open(files)))
        try #require(reducer.transcript(.init()).recordedPrompts.contains { $0.text.contains("HEELER_AMP_A_OK") })
        let nonce = "HEELER_AMP_IOS_" + UUID().uuidString.prefix(8)
        let text = "Reply with only \(nonce). Do not use tools."
        let composer = AgentComposerStore(target: lab.first) { _ in
            Issue.record("Amp Chat typed a terminal prompt")
            throw AmpChatProblem.changed
        }
        var policy = ComposerDeliveryPolicy.chat(rules: .init(program: .amp, commands: []), activity: { .idle },
            readScreen: { try await projection.readAgentScreen(lab.first) })
        policy.verify = nil
        policy.submitChat = { await first.send(id: $0, text: $1, target: other) }
        composer.replaceDraft(with: text)
        #expect(await composer.send(policy: policy) == .refused(.inputNotReady(AmpChatProblem.changed.explanation)))
        #expect(composer.draft == text)
        policy.submitChat = { await first.send(id: $0, text: $1, target: target) }
        try #require(await composer.send(policy: policy) == .deliveredViaPrompt)
        let id = try #require(composer.messages.last?.id)
        try #require(await first.send(id: id, text: text, target: target) == .submitted)
        let wait = ContinuousClock.now + .seconds(45)
        var replied = false
        while !replied, ContinuousClock.now < wait {
            switch try await source.poll(files) {
            case .appended(let lines): reducer.append(lines)
            case .reset(let lines, _): reducer = .init(); reducer.append(lines)
            default: break
            }
            replied = reducer.transcript(.init()).entries.contains {
                if case .assistant(let message) = $0.content { return message.text.contains(nonce) }
                return false
            }
            if !replied { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(replied)
        #expect(reducer.transcript(.init()).recordedPrompts.filter { $0.text == text }.count == 1)
        let (_, page) = try await second.page(thread: lab.secondThread, expected: other, offset: nil, limit: 20)
        #expect(!page.rows.flatMap(\.blocks).contains { $0.text?.contains(nonce) == true })
    }

    private struct Lab: Decodable {
        let port: Int
        let user, seed, fingerprint, socket, first, second, directory, firstThread, secondThread: String
        let alreadyInstalled: Bool?
    }
}
