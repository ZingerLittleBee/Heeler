import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: the configuration names disposable test Agents, never
/// the focused pane. See docs/prototypes/title-rename/README.md for the contract.
@MainActor
@Suite("Native title rename over real SSH", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["HEELER_TITLE_RENAME_CONFIG"]?.isEmpty == false))
struct AgentTitleRenameLiveTests {
    struct Configuration: Decodable {
        var port: Int
        var username: String
        var deviceKeySeed: String
        var fingerprint: String
        var socketPath: String
        var allowTitleMutations: Bool
        var agents: [Target]
    }

    struct Target: Decodable {
        var paneID: String
        var terminalID: String
        var session: AgentSessionInfo
        var generates: Bool
        var generationMayFail: Bool
    }

    @Test func savesAndGeneratesOnExplicitTestAgents() async throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["HEELER_TITLE_RENAME_CONFIG"])
        let data = try #require(Data(base64Encoded: encoded))
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        try #require(config.allowTitleMutations && !config.agents.isEmpty)
        let key = try RealSSHFixture.deviceKey(seed: config.deviceKeySeed)
        let settings = SSHTransportSettings(
            host: "127.0.0.1", port: config.port, username: config.username,
            credentials: .ed25519(key),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) {
                $0.fingerprint.displayString == config.fingerprint
            }, socket: .absolutePath(config.socketPath))
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        do {
            for target in config.agents {
                let agent = try await transport.agentInfo(AgentTarget(target: target.paneID))
                try #require(agent.terminalID == target.terminalID && agent.agentSession == target.session)
                let program = try #require(ChatProgram(rawValue: agent.kind))
                let io = AgentTitleRenameIO(
                    agent: { try await transport.agentInfo(AgentTarget(target: target.paneID)) },
                    screen: {
                        let result = try await transport.readAgent(AgentReadParams(
                            source: .visible, target: target.paneID, format: .ansi, stripANSI: false))
                        return ANSIScreenDecoder.decode(result.text)
                    },
                    prompt: { _ = try await transport.promptAgent(AgentPromptParams(target: target.paneID, text: $0)) },
                    keys: { try await transport.sendAgentKeys(AgentSendKeysParams(keys: $0, target: target.paneID)) },
                    paste: { try await transport.sendPaneInput(PaneSendInputParams(paneID: target.paneID, text: $0)) },
                    refresh: { _ = try? await transport.sessionSnapshot() })
                let store = AgentTitleRenameStore(agent: agent, program: program, io: io)
                store.input = "Heeler title QA " + String(UUID().uuidString.prefix(8))
                await store.save()
                print("Native title QA \(program.rawValue) manual: \(store.state)")
                #expect(store.state == .renamed, "\(program.rawValue) manual rename: \(store.state)")
                guard store.state == .renamed else { continue }
                let saved = try await transport.agentInfo(AgentTarget(target: target.paneID))
                #expect(AgentTitleNaming.matches(saved, program: program, title: store.input))
                if target.generates {
                    let generator = AgentTitleRenameStore(agent: saved, program: program, io: io)
                    await generator.generate()
                    print("Native title QA \(program.rawValue) generation: \(generator.state)")
                    if target.generationMayFail, case .failed(let message) = generator.state {
                        #expect(message.contains("could not generate"), "Unexpected failure: \(message)")
                        let after = try await transport.agentInfo(AgentTarget(target: target.paneID))
                        #expect(after.title == saved.title)
                    } else {
                        #expect(generator.state == .renamed, "\(program.rawValue) generation: \(generator.state)")
                    }
                }
            }
            try await transport.close()
        } catch {
            try? await transport.close()
            throw error
        }
    }
}
