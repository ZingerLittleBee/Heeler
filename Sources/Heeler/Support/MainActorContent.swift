import SwiftUI

/// Builds its content in `body`, which SwiftUI runs on the main actor.
///
/// SwiftUI can call `ForEach` content on its async render thread
/// (FB20692404), where a content closure isolated to the main actor traps on
/// entry (#471). Content closures are `@Sendable` instead, and content that
/// needs the main actor, such as a view's own row builders or state, goes
/// through this view.
struct MainActorContent<Content: View>: View {
    @ViewBuilder let content: @MainActor () -> Content

    var body: some View {
        content()
    }
}
