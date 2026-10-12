import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent detail surface settings")
struct AgentDetailSurfaceSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-detail-surface-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToTheTerminal() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(AgentDetailSurfaceSettings(defaults: defaults).preferred == .terminal)
    }

    @Test func chosenSurfaceIsRememberedAcrossLaunches() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentDetailSurfaceSettings(defaults: defaults)

        settings.select(.chat)

        #expect(settings.preferred == .chat)
        #expect(AgentDetailSurfaceSettings(defaults: defaults).preferred == .chat)

        settings.select(.terminal)

        #expect(AgentDetailSurfaceSettings(defaults: defaults).preferred == .terminal)
    }

    @Test func unknownStoredSurfaceFallsBackToTheTerminal() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("timeline", forKey: "agent.detail-surface")

        #expect(AgentDetailSurfaceSettings(defaults: defaults).preferred == .terminal)
    }

    @Test func reselectingTheCurrentSurfaceWritesNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentDetailSurfaceSettings(defaults: defaults)

        settings.select(.terminal)

        #expect(defaults.object(forKey: "agent.detail-surface") == nil)
    }
}

@Suite("Agent Chat availability")
struct AgentChatAvailabilityTests {
    private func agent(kind: String) -> Agent {
        Agent(AgentInfo.fixture(paneID: "w1:p1", kind: kind))
    }

    @Test(arguments: [("claude", ChatProgram.claude), ("codex", .codex)])
    func claudeAndCodexOfferChatOnPOSIXHosts(kind: String, program: ChatProgram) {
        #expect(AgentChatAvailability.program(for: agent(kind: kind), platform: .posix) == program)
        #expect(AgentChatAvailability.mayOfferChat(for: agent(kind: kind)))
    }

    @Test(arguments: ["pi", "gemini", "cursor", "droid", "opencode", "Claude", ""])
    func otherProgramsNeverOfferChat(kind: String) {
        #expect(AgentChatAvailability.program(for: agent(kind: kind), platform: .posix) == nil)
        #expect(!AgentChatAvailability.mayOfferChat(for: agent(kind: kind)))
    }

    /// Unknown is not POSIX: the entry stays hidden until the Host says.
    @Test(arguments: [HostPlatform?.none, .some(.nativeWindows)])
    func chatNeedsAHostKnownToBePOSIX(platform: HostPlatform?) {
        #expect(AgentChatAvailability.program(for: agent(kind: "claude"), platform: platform) == nil)
        #expect(AgentChatAvailability.program(for: agent(kind: "codex"), platform: platform) == nil)
    }
}
