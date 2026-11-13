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

/// Content its parent builds in a closure, rebuilt only when `key` changes.
///
/// SwiftUI cannot compare a closure, so content handed over as one is rebuilt
/// by every pass of the body that made it: a list that read one changed Agent
/// rebuilt every row. `key` names what that body passes in. What the content
/// reads from an observable store or from state still updates it on its own.
///
/// The closure a skipped pass leaves in place captured its builder as it was
/// then, environment values included, so the key must also change whenever
/// the builder itself is rebuilt. `ContentPass` is that part of a key.
///
/// A List's row is used as it is: the List compares it with `==`, while it
/// takes an `EquatableView` for one opaque row and misses the separator,
/// insets and swipe actions the content sets on itself. Anywhere else the
/// site adds `.equatable()`.
///
/// What the content's own initializers read counts as read here: a detail
/// whose initializer looked through every Agent was rebuilt with each one's
/// status change, whatever its key said.
struct KeyedContent<Key: Equatable & Sendable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: @MainActor () -> Content

    var body: some View {
        content()
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }
}

/// Counts a view's body passes, as the part of a `KeyedContent` key that
/// says the view which built the content has not been rebuilt since.
@MainActor
final class ContentPass {
    private(set) var number = 0

    /// Called from the view's `body`.
    func advance() {
        number &+= 1
    }
}
