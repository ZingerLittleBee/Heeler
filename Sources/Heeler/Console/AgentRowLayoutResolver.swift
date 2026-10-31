/// Saved Host layouts take precedence. Otherwise, import herdr's first two
/// rows and initialize Heeler's third row with the directory.
/// Heeler's default is the silent last resort: it is never shown as a
/// choice and the user never edits it. A Host that does not follow a plugin
/// starts from Heeler's own layout instead, whatever snapshot is around.
/// Whatever the source, the Console receives the three-slot shape without
/// `state_icon`.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?,
        followsPlugin: Bool = true
    ) -> AgentRowLayout {
        if let hostLayout { return hostLayout.normalizedForConsole() }
        guard followsPlugin else { return .hostWithoutPluginDefault }
        return (pluginSnapshot?.layout ?? .heelerDefault).withHeelerRow()
    }
}
