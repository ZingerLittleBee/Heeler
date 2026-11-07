import SwiftUI
import UIKit

extension View {
    /// Points an iPad sidebar's navigation bar at the list on show, and
    /// starts each list with the bar's search field tucked away.
    ///
    /// The sidebar keeps both lists built (see `sidebarLists(showing:)`),
    /// and a bar follows the first scroll view it finds: without this,
    /// scrolling the Terminals list would neither put the field away nor
    /// pull it back into view. The field shows while the followed list
    /// rests at its top, so each list that can scroll is scrolled past it
    /// the first time it shows there, as `searchDrawerStartsTucked()` does
    /// on an iPhone.
    /// `shownList` only prompts a new look once the switch has changed.
    func sidebarSearchDrawer(following shownList: ConsoleTab) -> some View {
        background { SidebarSearchDrawerBridge(shownList: shownList) }
    }
}

private struct SidebarSearchDrawerBridge: UIViewRepresentable {
    let shownList: ConsoleTab

    func makeUIView(context: Context) -> BridgeView { BridgeView() }

    func updateUIView(_ view: BridgeView, context: Context) {
        // After the switch lays the lists out anew.
        DispatchQueue.main.async { view.follow() }
    }

    final class BridgeView: UIView {
        /// Lists already tucked. Once per list: one the user pulled down,
        /// shown again after a switch, keeps its field in view.
        private let tuckedLists = NSHashTable<UIScrollView>.weakObjects()
        private var retries = 0
        private static let maximumRetries = 20

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            follow()
        }

        func follow() {
            guard window != nil, let controller = searchingController() else { return }
            guard let list = shownList(in: controller.view) else { return followLater() }
            if controller.contentScrollView(for: .top) !== list {
                controller.setContentScrollView(list, for: .top)
                retries = 0
            }
            if tuck(list, in: controller) {
                retries = 0
            } else {
                followLater()
            }
        }

        /// Tries again shortly: at launch the lists join the column after
        /// this view does, and a list first built out of sight has no rows
        /// or field to measure until a pass later. Bounded, as an empty list
        /// never has any.
        private func followLater() {
            guard retries < Self.maximumRetries else { return }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.follow()
            }
        }

        /// Tucks a list's field once, returning false while there is not
        /// yet anything to measure.
        private func tuck(_ list: UIScrollView, in controller: UIViewController) -> Bool {
            guard !tuckedLists.contains(list) else { return true }
            guard let searchController = controller.navigationItem.searchController
            else { return true }
            let field = searchController.searchBar.frame.height
            guard field > 0, list.contentSize.height > 0 else { return false }
            tuckedLists.add(list)
            // A list first shown mid-search keeps its field in view.
            guard !searchController.isActive else { return true }
            let top = -list.adjustedContentInset.top
            // Only from the top: a list already scrolled has hidden it.
            guard list.contentOffset.y <= top + 1 else { return true }
            // Rows that fit leave no room to scroll the field away: it stays
            // in view, and the scroll would only park the first row under it.
            let bottom = list.contentSize.height + list.adjustedContentInset.bottom
                - list.bounds.height
            guard bottom >= top + field else { return true }
            // Animated, so the bar follows the scroll; see
            // `searchDrawerStartsTucked()`.
            list.setContentOffset(
                CGPoint(x: list.contentOffset.x, y: top + field), animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.settle(list, below: searchController.searchBar)
            }
            return true
        }

        /// Puts a tucked list back at its top once the field has gone. The
        /// bar losing the field moves the list's top edge while the scroll
        /// that hid it is still settling, which can leave the first rows
        /// under the bar.
        private func settle(_ list: UIScrollView, below field: UISearchBar, attempt: Int = 0) {
            guard !list.isTracking, !list.isDecelerating else { return }
            guard field.frame.height < 1 else {
                if attempt < Self.maximumRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.settle(list, below: field, attempt: attempt + 1)
                    }
                }
                return
            }
            let top = -list.adjustedContentInset.top
            guard list.contentOffset.y > top + 1 else { return }
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: top), animated: true)
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

        /// The list scroll view that is neither hidden nor out of reach; the
        /// other list is kept invisible and untouchable.
        private func shownList(in root: UIView) -> UIScrollView? {
            var queue = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if view.isHidden || view.alpha < 0.01 || !view.isUserInteractionEnabled {
                    continue
                }
                if let list = view as? UICollectionView { return list }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
