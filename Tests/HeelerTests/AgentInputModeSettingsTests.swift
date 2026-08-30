import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent input mode settings")
struct AgentInputModeSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-input-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToComposer() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let settings = AgentInputModeSettings(defaults: defaults)

        #expect(settings.mode == .composer)
        #expect(!settings.isDirect)
    }

    @Test func selectionPersistsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentInputModeSettings(defaults: defaults)

        settings.select(.direct)

        #expect(AgentInputModeSettings(defaults: defaults).mode == .direct)
        #expect(AgentInputModeSettings(defaults: defaults).isDirect)
    }

    @Test func unknownStoredOptionFallsBackToComposer() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("keys-mode", forKey: "agent-input-mode")

        #expect(AgentInputModeSettings(defaults: defaults).mode == .composer)
    }

    @Test func everyModeIsOfferedInAStableOrder() {
        #expect(AgentInputMode.allCases == [.composer, .direct])
        #expect(AgentInputMode.allCases.map(\.segmentTitle) == ["Composer", "Keyboard"])
    }
}
