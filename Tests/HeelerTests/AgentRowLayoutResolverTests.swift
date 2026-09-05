import Testing

@testable import Heeler

@Suite("Agent row layout resolver")
struct AgentRowLayoutResolverTests {
    @Test func precedenceReplacesTheWholeLayoutAtEveryLevel() {
        let host = AgentRowLayout(rows: [[.init(.pane)]], rowGap: 3)
        let global = AgentRowLayout(rows: [[.init(.terminalTitle)]], rowGap: 2)
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.workspace)]], rowGap: 1,
            rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]]), agentPanelSort: .priority)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: host, globalLayout: global, pluginSnapshot: plugin) == host)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, globalLayout: global, pluginSnapshot: plugin) == global)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, globalLayout: nil, pluginSnapshot: plugin) == plugin.layout)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, globalLayout: nil, pluginSnapshot: nil) == .heelerDefault)
        // An empty override is still a whole-layout choice, not inheritance.
        #expect(AgentRowLayoutResolver.resolve(hostLayout: AgentRowLayout(rows: []),
                                              globalLayout: global, pluginSnapshot: plugin).rows.isEmpty)
    }
}
