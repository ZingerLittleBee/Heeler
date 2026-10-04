import SwiftUI
import UIKit

extension View {
    /// Lets the system's back swipes pop this screen, following the finger as
    /// they do anywhere else, though the screen hides the system Back button:
    /// UIKit turns those swipes off along with the button.
    func interactivePopGestureEnabled(_ isEnabled: Bool) -> some View {
        background {
            if isEnabled {
                InteractivePopEnabler()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Stands in as the back swipes' delegate while its screen is in a window,
/// and hands them back as the screen leaves.
private struct InteractivePopEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {}

    static func dismantleUIView(_ probe: Probe, coordinator: ()) {
        probe.detach()
    }

    final class Probe: UIView {
        private var gates: [PopGate] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detach()
            } else {
                // After the push that brought this screen in has updated
                // its navigation controller's stack.
                DispatchQueue.main.async { [weak self] in self?.attach() }
            }
        }

        private func attach() {
            guard window != nil, gates.isEmpty,
                  let screen = owningViewController,
                  let navigation = Self.navigation(above: screen)
            else { return }
            var swipes = [navigation.interactivePopGestureRecognizer].compactMap(\.self)
            if #available(iOS 26, *),
               let content = navigation.interactiveContentPopGestureRecognizer {
                swipes.append(content)
            }
            gates = swipes.map { PopGate(swipe: $0, navigation: navigation, screen: screen) }
        }

        func detach() {
            gates.forEach { $0.restore() }
            gates = []
        }

        /// The nearest navigation controller with something to go back to.
        /// A detail's own stack can have this screen as its root, while the
        /// one that pushed the detail over the list sits above it.
        private static func navigation(above screen: UIViewController) -> UINavigationController? {
            var candidate = screen.navigationController
            while let navigation = candidate, navigation.viewControllers.count < 2 {
                candidate = navigation.navigationController
            }
            return candidate
        }

        private var owningViewController: UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }
    }
}

/// Lets one back swipe begin on the screen that hid its Back button, and
/// leaves other screens, and how the swipe meets other gestures, to the
/// delegate it replaced.
private final class PopGate: NSObject, UIGestureRecognizerDelegate {
    private weak var swipe: UIGestureRecognizer?
    private weak var navigation: UINavigationController?
    private weak var screen: UIViewController?
    private weak var original: UIGestureRecognizerDelegate?

    init(swipe: UIGestureRecognizer, navigation: UINavigationController, screen: UIViewController) {
        self.swipe = swipe
        self.navigation = navigation
        self.screen = screen
        original = swipe.delegate
        super.init()
        swipe.delegate = self
    }

    func restore() {
        if let swipe, swipe.delegate === self {
            swipe.delegate = original
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.topViewController === screen else {
            return original?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
        }
        guard navigation.viewControllers.count > 1 else { return false }
        // The edge swipe only runs one way. The content swipe starts
        // anywhere, so it takes only a mostly horizontal drag back toward
        // the previous screen, leaving other drags to the terminal.
        guard gestureRecognizer !== navigation.interactivePopGestureRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return true }
        let velocity = pan.velocity(in: pan.view)
        let backward = navigation.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? -velocity.x : velocity.x
        return backward > abs(velocity.y)
    }

    // The rest of what the replaced delegate decides still applies. Not
    // forwarded wholesale: it also turns away every touch on this screen.

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: other)
            ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other) ?? false
    }
}
