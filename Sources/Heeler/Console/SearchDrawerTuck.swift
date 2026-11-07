import SwiftUI
import UIKit

extension View {
    /// Starts a list with its navigation-bar search field tucked under the
    /// title, revealed by pulling the list down. SwiftUI's drawer shows the
    /// field whenever the list rests at its top and offers no way to start
    /// hidden, so this scrolls the list by the field's height once, the
    /// state a short upward scroll leaves it in.
    ///
    /// Only an iPhone's list starts tucked, and not beside a detail. The
    /// tuck assumes the iPhone's collapsing drawer: an iPad's field stays
    /// put at every width, where the tuck would only scroll the first row
    /// under the field, and a sidebar keeps its field in view or, on an
    /// iPad, tucks it with `sidebarSearchDrawer(following:)`. A narrow iPad
    /// window's list starts on its large title instead, which UIKit lays out
    /// collapsed when a tab switch first shows the list.
    func searchDrawerStartsTucked() -> some View {
        modifier(SearchDrawerTuck())
    }
}

private struct SearchDrawerTuck: ViewModifier {
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        content.background {
            if !isSidebarColumn {
                SearchDrawerTucker(tucksField: UIDevice.current.userInterfaceIdiom == .phone)
            }
        }
    }
}

private struct SearchDrawerTucker: UIViewRepresentable {
    /// Tucks the field; otherwise only puts back a collapsed large title.
    let tucksField: Bool

    func makeUIView(context: Context) -> TuckerView { TuckerView(tucksField: tucksField) }
    func updateUIView(_ view: TuckerView, context: Context) {}

    final class TuckerView: UIView {
        private let tucksField: Bool

        init(tucksField: Bool) {
            self.tucksField = tucksField
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        /// Search fields already tucked. Once per field, not per list: a
        /// list rebuilt later (a search ending, a presentation switch) must
        /// not hide a field the user pulled down, nor scroll against the
        /// bar's own animation.
        private static let tuckedFields = NSHashTable<UISearchController>.weakObjects()
        private var hasTucked = false
        /// Whether a tuck waits for the navigation transition under way.
        private var awaitsTransition = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if window != nil, !hasTucked { tuck() }
        }

        private func tuck() {
            guard let controller = searchingController(),
                let searchController = controller.navigationItem.searchController,
                let scrollView = Self.firstScrollView(in: controller.view)
            else { return }
            // Never inside a navigation transition. A relaunch that restores
            // an Agent detail first lays the list out inside that push; a
            // scroll then leaves an offset the bar cannot settle on, and
            // Back hangs the app: through the pop the bar collapses and
            // restores its large title on every layout pass. The tuck waits
            // for the transition to end, and for the list's next showing
            // when that transition took it off screen.
            if let coordinator = controller.transitionCoordinator {
                guard !awaitsTransition else { return }
                awaitsTransition = coordinator.animate(alongsideTransition: nil) {
                    [weak self] _ in
                    self?.awaitsTransition = false
                    self?.setNeedsLayout()
                }
                return
            }
            hasTucked = true
            guard !Self.tuckedFields.contains(searchController) else { return }
            Self.tuckedFields.add(searchController)
            // A list first shown mid-search keeps its field in view.
            guard !searchController.isActive else { return }
            let top = -scrollView.adjustedContentInset.top
            // Only from the top: a list already scrolled has hidden it.
            guard scrollView.contentOffset.y <= top + 1 else { return }
            guard tucksField else {
                // Resting at its top, the list shows its large title, which
                // is the bar's fitting size; a tab switch that first shows it
                // leaves the bar inline until the list is pulled down.
                controller.navigationController?.navigationBar.sizeToFit()
                controller.navigationController?.view.setNeedsLayout()
                return
            }
            // Animated, so the bar follows the scroll: a jump past the field
            // reads as a scroll past the title and collapses both.
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: top + searchController.searchBar.frame.height),
                animated: true)
        }

        /// The view controller whose navigation item carries the search.
        private func searchingController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController {
                    var candidate: UIViewController? = controller
                    while let current = candidate {
                        if current.navigationItem.searchController != nil { return current }
                        candidate = current.parent
                    }
                    return nil
                }
                responder = next
            }
            return nil
        }

        private static func firstScrollView(in root: UIView) -> UIScrollView? {
            var queue = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let scrollView = view as? UIScrollView { return scrollView }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
