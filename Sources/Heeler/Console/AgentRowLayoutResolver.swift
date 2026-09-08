/// Saved Host layouts take precedence. Otherwise, import herdr's first two
/// rows and initialize Heeler's third row with the directory.
/// Heeler's default is the silent last resort: it is never shown as a
/// choice and the user never edits it. Whatever the source, the Console
/// receives the three-slot shape without `state_icon`.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?
    ) -> AgentRowLayout {
        if let hostLayout { return hostLayout.normalizedForConsole() }
        return (pluginSnapshot?.layout ?? .heelerDefault).withHeelerRow()
    }
}
