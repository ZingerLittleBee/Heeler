/// Every source replaces the entire layout, including per-kind rows and gap.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        globalLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?
    ) -> AgentRowLayout {
        hostLayout ?? globalLayout ?? pluginSnapshot?.layout ?? .heelerDefault
    }
}
