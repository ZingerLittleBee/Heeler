import Testing

@testable import Heeler

@Suite("Agent row layout resolver")
struct AgentRowLayoutResolverTests {
    @Test func initializationImportsTwoPluginRowsAndKeepsThirdRowEmpty() {
        let first: AgentRow = [.init(.workspace, bold: true), .init(.custom("branch"))]
        let second: AgentRow = [.init(.terminalTitle, dim: true)]
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.stateIcon)] + first, second, [.init(.tab)]], rowGap: 2))
        let initial = AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin)
        #expect(initial.rows == [first, second, []])
        #expect(initial.rowGap == 2)

        // A customized third row stays as saved.
        let saved = AgentRowLayout(rows: [first, second, [.init(.directory)]])
        #expect(AgentRowLayoutResolver.resolve(hostLayout: saved, pluginSnapshot: plugin) == saved)
        let fallback = AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: nil)
        #expect(fallback.rows == [[.init(.terminalTitleStripped)], [.init(.workspace)]])
        #expect(fallback.effectiveTrailing == [[.init(.host)], [.init(.changes)], []])
    }

    @Test func savedLayoutsTakePrecedenceOverInitializedPluginRows() {
        let host = AgentRowLayout(rows: [[.init(.pane)]], rowGap: 3)
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.workspace)]], rowGap: 1,
            rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]]), agentPanelSort: .priority)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: host, pluginSnapshot: plugin) == host)
        let resolvedPlugin = AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin)
        #expect(resolvedPlugin == plugin.layout.withHeelerRow())
        #expect(resolvedPlugin.rows == [[.init(.workspace)], [], []] && resolvedPlugin.rowGap == 1)
        #expect(resolvedPlugin.rowsByAgent.isEmpty)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: nil) == .consoleDefault)
        // An empty override is still a whole-layout choice, not inheritance.
        #expect(AgentRowLayoutResolver.resolve(hostLayout: AgentRowLayout(rows: []), pluginSnapshot: plugin).rows.isEmpty)
    }
}
