import Foundation
import Testing

@testable import Heeler

/// The shared agent-name rule (server rule, verified live: 0.7.5 rejects
/// violations with `invalid_agent_name`), consumed by both the new-agent
/// form (#12) and the rename sheet (#98).
@Suite("Agent name rule")
struct AgentNameTests {
    @Test(arguments: [
        "reviewer", "a", "a1", "agent-2", "agent_2", "x1234567890",
        String(repeating: "a", count: 32),
    ])
    func validAgentNamesPassTheServerRule(name: String) {
        #expect(AgentName.validationError(name) == nil)
    }

    @Test(arguments: [
        "", "Agent", "1agent", "-agent", "_agent", "agent name", "拆解任务",
        "café", String(repeating: "a", count: 33),
    ])
    func invalidAgentNamesFailTheServerRule(name: String) {
        #expect(AgentName.validationError(name) != nil)
    }
}
