import Testing

@testable import Heeler

@Suite("Agent row layout resolver")
struct AgentRowLayoutResolverTests {
    @Test func precedenceReplacesTheWholeLayoutAtEveryLevel() {
        let host = AgentRowLayout(rows: [[.init(.pane)]], rowGap: 3)
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.workspace)]], rowGap: 1,
            rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]]), agentPanelSort: .priority)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: host, pluginSnapshot: plugin) == host)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin) == plugin.layout)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: nil) == .heelerDefault)
        // An empty override is still a whole-layout choice, not inheritance.
        #expect(AgentRowLayoutResolver.resolve(hostLayout: AgentRowLayout(rows: []), pluginSnapshot: plugin).rows.isEmpty)
    }
}
