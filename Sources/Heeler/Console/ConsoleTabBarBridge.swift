import SwiftUI
import UIKit

/// What the Console's regular-width tab bar needs from UIKit, which SwiftUI
/// offers no handle for. An iPad beside its sidebar hides the bar, which
/// leaves a wide iPhone's. Lives in a list tab's content, so the
/// tab bar controller it reaches is the Console's own.
///
/// A compact Agent push hides the bar as well. SwiftUI's own hide reaches
/// the pushed detail's bottom safe area only once the push settles, so the
/// detail would lay its input chrome out a bar's height too high and then
/// drop it. Hiding the bar as soon as it is asked keeps that inset out of
/// the detail's first layout.
///
/// A bridge in a tab off screen gets no updates, and one that kept its own
/// last request hid the bar of a list that needs it: a window narrowing
/// from beside the sidebar brought back a tab whose bridge last saw the
/// sidebar. Every bridge reads the latest request from one shared
/// `Request`, and holds the bar to it in both directions.
///
/// A tab shown for the first time after launch is laid out with the
/// floating bar inside its top safe area: its split view starts a bar's
/// height too low, until a later visit or a rotation recomputes it. A change
/// of the bar's visibility recomputes it at once.
///
/// The bar's glass also ignores `toolbarColorScheme(_:for: .tabBar)`, so
/// over a dark terminal it renders a light glass on near-black: a flat gray
/// pill with dark labels. The bar takes the terminal's chrome scheme here
/// instead, as the status bar above it does, and gives it back when the
/// list tab leaves the screen.
struct ConsoleTabBarBridge: UIViewRepresentable {
    /// The scheme the floating bar renders in; nil follows the app.
    let chromeScheme: ColorScheme?
    /// Whether the bar should be hidden.
    let hidesBar: Bool
    /// Shared by the bridges of every tab of one Console.
    let request: Request

    /// What the Console last asked of its bar.
    @MainActor
    final class Request {
        fileprivate var chromeScheme: ColorScheme?
        fileprivate var hidesBar = false
    }

    func makeUIView(context: Context) -> BridgeView {
        BridgeView(request: request)
    }

    func updateUIView(_ view: BridgeView, context: Context) {
        request.hidesBar = hidesBar
        request.chromeScheme = chromeScheme
        view.applyRequest()
    }

    final class BridgeView: UIView {
        /// The bridge that last styled each tab bar controller's chrome. A
        /// tab switch can bring the arriving tab's bridge into the window
        /// before the leaving one goes; only the owner resets the style.
        private static let owners =
            NSMapTable<UITabBarController, BridgeView>.weakToWeakObjects()

        private let request: Request
        private var hasSettledSafeArea = false
        private weak var styledController: UITabBarController?

        init(request: Request) {
            self.request = request
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Leaving for Hosts or Settings, whose bar follows the app.
            guard window != nil else { return resetChromeScheme() }
            // A bar hidden after the first layout leaves its height in the
            // split view columns' top insets until the window resizes.
            // Hidden now, it never adds it.
            applyVisibility()
            applyChromeScheme()
            // The floating bar is regular width's; a compact bar sits at the
            // bottom, outside the safe area in question.
            guard !hasSettledSafeArea, traitCollection.horizontalSizeClass == .regular
            else { return }
            hasSettledSafeArea = true
            // After the layout pass that attached this tab; toggling during
            // it leaves the stale inset in place.
            Task { @MainActor [weak self] in self?.settleSafeArea() }
        }

        func applyRequest() {
            applyVisibility()
            applyChromeScheme()
        }

        /// Without animation either way: hidden at once for the reasons
        /// above, and shown as SwiftUI shows it.
        private func applyVisibility() {
            guard window != nil, let controller = tabBarController,
                controller.isTabBarHidden != request.hidesBar
            else { return }
            controller.setTabBarHidden(request.hidesBar, animated: false)
        }

        /// The bar's views can be rebuilt by a rotation or size change.
        override func layoutSubviews() {
            super.layoutSubviews()
            applyChromeScheme()
        }

        private var tabBarController: UITabBarController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UITabBarController { return controller }
                responder = current.next
            }
            return nil
        }

        /// Hides and shows the bar within one turn of the run loop, so
        /// nothing renders in between and the visibility ends where it was.
        private func settleSafeArea() {
            guard window != nil, let controller = tabBarController else { return }
            let isHidden = controller.isTabBarHidden
            controller.setTabBarHidden(!isHidden, animated: false)
            controller.setTabBarHidden(isHidden, animated: false)
        }

        /// Every view of the tab bar controller except the one holding the
        /// selected tab's content (this view's own ancestor) is bar chrome.
        /// Only the tab on screen may style it; the others are out of the
        /// window.
        private func applyChromeScheme() {
            guard window != nil, let controller = tabBarController else { return }
            let style: UIUserInterfaceStyle =
                switch request.chromeScheme {
                case .dark: .dark
                case .light: .light
                default: .unspecified
                }
            for chrome in controller.view.subviews where !isDescendant(of: chrome) {
                if chrome.overrideUserInterfaceStyle != style {
                    chrome.overrideUserInterfaceStyle = style
                }
            }
            styledController = controller
            Self.owners.setObject(self, forKey: controller)
        }

        private func resetChromeScheme() {
            guard let controller = styledController,
                Self.owners.object(forKey: controller) === self
            else { return }
            for chrome in controller.view.subviews
            where chrome.overrideUserInterfaceStyle != .unspecified {
                chrome.overrideUserInterfaceStyle = .unspecified
            }
            Self.owners.removeObject(forKey: controller)
            styledController = nil
        }
    }
}
