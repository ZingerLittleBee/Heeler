import UIKit

/// Reads where the keyboard is on screen during its own animation.
///
/// Keyboard notifications only give the end frame, and the curve they name
/// has no public equivalent to animate along. A view pinned to the keyboard
/// layout guide moves inside UIKit's keyboard animation, so its presentation
/// layer is the keyboard's position, whatever the curve and on any OS.
@MainActor
final class KeyboardMotionTracker: NSObject {
    /// How long to wait for a keyboard that was announced but has not moved:
    /// a hardware keyboard means nothing will.
    private static let idleTimeout: CFTimeInterval = 0.5
    /// A motion longer than this is not one animation; give up on following.
    private static let motionTimeout: CFTimeInterval = 1.5

    private let marker = UIView()
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var hasMoved = false
    private var lastTop: CGFloat?
    /// The keyboard's top edge in window coordinates, each frame, then nil
    /// once it comes to rest.
    private let onChange: (CGFloat?) -> Void

    init(onChange: @escaping (CGFloat?) -> Void) {
        self.onChange = onChange
        super.init()
        marker.isUserInteractionEnabled = false
        marker.backgroundColor = .clear
        marker.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Pins the marker to `rootView`'s guide; a window's own guide is never
    /// laid out (see `TerminalKeyboardInset.keyboardLayoutGuideFrame(in:)`).
    func install(in rootView: UIView) {
        guard marker.superview !== rootView else { return }
        stop()
        marker.removeFromSuperview()
        rootView.addSubview(marker)
        NSLayoutConstraint.activate([
            marker.topAnchor.constraint(equalTo: rootView.keyboardLayoutGuide.topAnchor),
            marker.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 1),
            marker.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// Follows the keyboard until it rests. Safe to call again mid-motion:
    /// a presentation often publishes several frames.
    func start() {
        guard marker.window != nil else { return }
        startedAt = CACurrentMediaTime()
        hasMoved = false
        lastTop = nil
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        tick()
    }

    func stop() {
        guard let displayLink else { return }
        displayLink.invalidate()
        self.displayLink = nil
        onChange(nil)
    }

    @objc private func tick() {
        guard let window = marker.window, let superview = marker.superview else {
            stop()
            return
        }
        let layer = marker.layer
        let current = (layer.presentation() ?? layer).frame.minY
        let top = superview.convert(CGPoint(x: 0, y: current), to: window).y
        if let lastTop, abs(top - lastTop) > 0.25 { hasMoved = true }
        lastTop = top

        let isAnimating = !(layer.animationKeys() ?? []).isEmpty
        if isAnimating { hasMoved = true }
        let isAtRest = !isAnimating && abs(current - layer.frame.minY) < 0.5
        let elapsed = CACurrentMediaTime() - startedAt
        if (isAtRest && (hasMoved || elapsed > Self.idleTimeout)) || elapsed > Self.motionTimeout {
            stop()
        } else {
            onChange(top)
        }
    }
}
