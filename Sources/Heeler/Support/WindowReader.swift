import SwiftUI
import UIKit

/// Reports the `UIWindow` the modified SwiftUI subtree is mounted in.
///
/// With more than one window on iPad, "the key window of the first
/// foreground scene" is some window, not necessarily this one. Anything
/// window-scoped — safe-area insets, keyboard geometry, scene activation —
/// has to ask the view's own window instead, and SwiftUI does not expose it.
/// The callback runs synchronously from `didMoveToWindow`, before the first
/// frame is committed, so it must not mutate SwiftUI state; hand the window
/// to a reference type such as ``WindowReference`` instead.
struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void
    /// Also reports the reader's own view, for geometry that depends on where
    /// the subtree sits in its window rather than on the window alone.
    var onView: ((UIWindow, UIView) -> Void)? = nil

    func makeUIView(context: Context) -> WindowReaderView {
        WindowReaderView(onWindow: onWindow, onView: onView)
    }

    func updateUIView(_ view: WindowReaderView, context: Context) {
        view.onWindow = onWindow
        view.onView = onView
        if let window = view.window {
            onWindow(window)
            onView?(window, view)
        }
    }
}

final class WindowReaderView: UIView {
    var onWindow: (UIWindow) -> Void
    var onView: ((UIWindow, UIView) -> Void)?

    init(onWindow: @escaping (UIWindow) -> Void, onView: ((UIWindow, UIView) -> Void)? = nil) {
        self.onWindow = onWindow
        self.onView = onView
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
        if let window {
            onWindow(window)
            onView?(window, self)
        }
    }
}

/// A weak, observable handle on one window. Views read `window` in `body`
/// the way they would read any other observable value, so a subtree that
/// renders before its window attaches renders again once it has.
@MainActor
@Observable
final class WindowReference {
    @ObservationIgnored private weak var storage: UIWindow?
    private var attachments: UInt64 = 0

    init() {}

    var window: UIWindow? {
        _ = attachments
        return storage
    }

    /// Idempotent: re-attaching the same window changes nothing.
    func attach(_ window: UIWindow) {
        guard storage !== window else { return }
        storage = window
        attachments &+= 1
        installInteractionRecognizer()
    }

    /// Calls `handler` whenever the user touches, clicks, or types in this
    /// window, through a passive ``WindowInteractionRecognizer`` installed on
    /// it — now if the window is attached, otherwise once it attaches. One
    /// handler per reference; a later call replaces it.
    func observeInteraction(_ handler: @escaping @MainActor () -> Void) {
        interactionHandler = handler
        installInteractionRecognizer()
    }

    @ObservationIgnored private var interactionHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var interactionRecognizer: WindowInteractionRecognizer?

    /// Keeps exactly one recognizer, on the attached window. It reaches the
    /// handler through this reference weakly, so the window never retains
    /// what the handler captures beyond this reference's own lifetime.
    private func installInteractionRecognizer() {
        guard interactionHandler != nil, let window = storage else { return }
        if let interactionRecognizer, interactionRecognizer.view === window { return }
        if let interactionRecognizer {
            interactionRecognizer.view?.removeGestureRecognizer(interactionRecognizer)
        }
        let recognizer = WindowInteractionRecognizer { [weak self] in
            self?.interactionHandler?()
        }
        window.addGestureRecognizer(recognizer)
        interactionRecognizer = recognizer
    }
}

extension WindowReference: AgentSceneWindow {
    var sceneWindowState: AgentSceneWindowState {
        AgentSceneWindowState.resolve(
            hasAttached: attachments > 0,
            activationState: storage?.windowScene?.activationState)
    }
}

extension EnvironmentValues {
    /// The window of the scene this view belongs to, provided by the scene's
    /// root view. Nil outside a scene root (previews, hosted test views).
    @Entry var sceneWindow: WindowReference? = nil
}

extension View {
    /// Reports how far down this view's top-leading corner the window's own
    /// controls reach. iPadOS draws a windowed app's close and resize
    /// controls over its content, outside the safe area, so a screen with no
    /// navigation bar of its own has to clear them itself. Zero before
    /// iOS 26 and on iPhone.
    func onWindowControlsHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        modifier(WindowControlsHeightReader(action: action))
    }
}

private struct WindowControlsHeightReader: ViewModifier {
    let action: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.onGeometryChange(
                for: CGFloat.self, of: { $0.containerCornerInsets.topLeading.height },
                action: action)
        } else {
            content
        }
    }
}
