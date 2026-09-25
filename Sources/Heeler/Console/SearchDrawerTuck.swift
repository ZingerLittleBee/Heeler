import SwiftUI
import UIKit

extension View {
    /// Starts a list with its navigation-bar search field tucked under the
    /// title, revealed by pulling the list down. SwiftUI's drawer shows the
    /// field whenever the list rests at its top and offers no way to start
    /// hidden, so this scrolls the list by the field's height once, the
    /// state a short upward scroll leaves it in.
    func searchDrawerStartsTucked() -> some View {
        background(SearchDrawerTucker())
    }
}

private struct SearchDrawerTucker: UIViewRepresentable {
    func makeUIView(context: Context) -> TuckerView { TuckerView() }
    func updateUIView(_ view: TuckerView, context: Context) {}

    final class TuckerView: UIView {
        private var hasTucked = false

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
            hasTucked = true
            // A list rebuilt mid-search keeps its field in view.
            guard !searchController.isActive else { return }
            let top = -scrollView.adjustedContentInset.top
            // Only from the top: a list already scrolled has hidden it.
            guard scrollView.contentOffset.y <= top + 1 else { return }
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
