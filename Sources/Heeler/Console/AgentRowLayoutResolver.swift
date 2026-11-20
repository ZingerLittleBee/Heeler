/// Saved Host layouts take precedence. Otherwise, import herdr's first two
/// rows when a plugin snapshot is available, keeping Heeler's third row empty.
/// A Host that does not follow a plugin, or has no plugin snapshot, starts
/// from Heeler's two-row default (`terminal_title_stripped` with `host` on the
/// right, then `workspace` with `changes` on the right). Whatever the source,
/// the Console receives the three-slot shape without `state_icon`.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?,
        followsPlugin: Bool = true,
        withoutPlugin: AgentRowLayout = .hostWithoutPluginDefault
    ) -> AgentRowLayout {
        if let hostLayout { return hostLayout.normalizedForConsole() }
        guard followsPlugin else { return withoutPlugin }
        guard let pluginSnapshot else { return .consoleDefault }
        return pluginSnapshot.layout.withHeelerRow()
    }
}
