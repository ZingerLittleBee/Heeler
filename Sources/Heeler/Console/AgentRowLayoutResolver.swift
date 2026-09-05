/// Every source replaces the entire layout, including per-kind rows and gap.
/// Heeler's default is the silent last resort: it is never shown as a
/// choice and the user never edits it.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?
    ) -> AgentRowLayout {
        hostLayout ?? pluginSnapshot?.layout ?? .heelerDefault
    }
}
