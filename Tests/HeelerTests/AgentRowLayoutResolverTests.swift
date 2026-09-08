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
        let resolvedPlugin = AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin)
        #expect(resolvedPlugin == plugin.layout.normalizedForConsole())
        #expect(resolvedPlugin.rows == plugin.layout.rows && resolvedPlugin.rowGap == 1)
        #expect(resolvedPlugin.rowsByAgent.isEmpty)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: nil) == .consoleDefault)
        // An empty override is still a whole-layout choice, not inheritance.
        #expect(AgentRowLayoutResolver.resolve(hostLayout: AgentRowLayout(rows: []), pluginSnapshot: plugin).rows.isEmpty)
    }
}
