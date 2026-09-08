/// Every source replaces the entire layout, including per-kind rows and gap.
/// Heeler's default is the silent last resort: it is never shown as a
/// choice and the user never edits it. Whatever the source, the Console
/// receives the three-slot shape without `state_icon`.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?
    ) -> AgentRowLayout {
        (hostLayout ?? pluginSnapshot?.layout ?? .heelerDefault).normalizedForConsole()
    }
}
