import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Backspace has an explicit hold delay shared by every keyboard surface.
struct TerminalBackspaceButton: UIViewRepresentable {
    var usesSymbol = false
    var isToolbar = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> TerminalRepeatingBackspaceButton {
        TerminalRepeatingBackspaceButton(usesSymbol: usesSymbol, isToolbar: isToolbar, action: action)
    }

    func updateUIView(_ view: TerminalRepeatingBackspaceButton, context: Context) {
        view.keyAction = action
        view.isEnabled = isEnabled
        view.reduceMotion = reduceMotion
    }

    static func dismantleUIView(_ view: TerminalRepeatingBackspaceButton, coordinator: ()) {
        view.cancelHold()
    }
}

/// Observe touches before ancestor gestures can delay UIButton's control events.
/// Release after a repeated or cancelled hold sends no additional key.
final class TerminalRepeatingBackspaceButton: UIButton {
    var keyAction: () -> Void
    var reduceMotion = false
    private enum HoldState { case idle, pressed, repeating, cancelled }
    private var holdState = HoldState.idle
    private var holdTimer: Timer?

    init(usesSymbol: Bool = false, isToolbar: Bool = false, action: @escaping () -> Void) {
        keyAction = action
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        if usesSymbol {
            configuration.image = UIImage(systemName: "delete.left")
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 13, weight: .medium)
        } else {
            configuration.title = "Backspace"
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .systemFont(ofSize: isToolbar ? 12 : 13, weight: .medium)
            return result
        }
        configuration.contentInsets = .zero
        configuration.background.cornerRadius = 7
        configuration.background.backgroundInsets = isToolbar
            ? NSDirectionalEdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0) : .zero
        self.configuration = configuration
        configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.baseForegroundColor = .label
            configuration?.background.backgroundColor = button.isHighlighted ? .systemGray3 : .secondarySystemFill
            button.configuration = configuration
        }
        accessibilityLabel = "Backspace"
        accessibilityHint = "Tap to delete once; hold to keep deleting"
        isExclusiveTouch = true
        let touchObserver = TerminalBackspaceTouchRecognizer()
        touchObserver.button = self
        touchObserver.cancelsTouchesInView = false
        touchObserver.delaysTouchesBegan = false
        touchObserver.delaysTouchesEnded = false
        addGestureRecognizer(touchObserver)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet { if !isEnabled { cancelHold() } }
    }

    override var isHighlighted: Bool {
        didSet {
            let transform = isHighlighted && !reduceMotion
                ? CATransform3DMakeScale(0.97, 0.97, 1) : CATransform3DIdentity
            // Transform only the painted contents. Scaling the UIButton itself
            // shrinks its hit area and drops touches along all four edges.
            let previous = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
            layer.removeAnimation(forKey: "keyPressFeedback")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = transform
            CATransaction.commit()
            if !isHighlighted && !reduceMotion {
                let animation = CABasicAnimation(keyPath: "sublayerTransform")
                animation.fromValue = NSValue(caTransform3D: previous)
                animation.toValue = NSValue(caTransform3D: transform)
                animation.duration = 0.1
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "keyPressFeedback")
            }
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only an existing hold gets drift tolerance; initial touches must
        // still land inside this key so neighbouring keys keep their hit areas.
        let isHolding = holdState == .pressed || holdState == .repeating
        let hitBounds = isHolding ? bounds.insetBy(dx: -8, dy: -8) : bounds
        return hitBounds.contains(point)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelHold() }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        cancelHold()
        keyAction()
        return true
    }

    fileprivate func pressed() {
        cancelHold()
        guard isEnabled else { return }
        holdState = .pressed
        isHighlighted = true
        schedule(after: 0.3)
    }

    private func schedule(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatKey() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func repeatKey() {
        holdTimer = nil
        guard isEnabled, window != nil,
              holdState == .pressed || holdState == .repeating else { return }
        holdState = .repeating
        keyAction()
        // The action may disable or remove this key, so recheck before arming.
        if holdState == .repeating, isEnabled, window != nil { schedule(after: 0.075) }
    }

    fileprivate func released() {
        let shouldSend = isEnabled && holdState == .pressed
        cancelHold()
        holdState = .idle
        if shouldSend { keyAction() }
    }

    func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdState = .cancelled
        isHighlighted = false
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        cancelHold()
    }
}

/// A passive observer never claims the gesture, leaving paging and scrolling
/// available. Its touch callbacks precede delayed UIView/control delivery.
private final class TerminalBackspaceTouchRecognizer: UIGestureRecognizer {
    weak var button: TerminalRepeatingBackspaceButton?
    private var finger: UITouch?
    private var origin = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard finger == nil, touches.count == 1, let touch = touches.first,
              let button, button.isEnabled,
              button.bounds.contains(touch.location(in: button)) else {
            cancel()
            return
        }
        finger = touch
        origin = touch.location(in: button)
        button.pressed()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger), let button else { return }
        let point = finger.location(in: button)
        // Match the pager's drag threshold, including swipes within a large key.
        guard button.isEnabled, button.point(inside: point, with: event),
              abs(point.x - origin.x) < 16, abs(point.y - origin.y) < 16 else {
            cancel()
            return
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger), let button else { return }
        if button.point(inside: finger.location(in: button), with: event) {
            button.released()
        } else {
            button.cancelHold()
        }
        self.finger = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancel()
    }

    override func reset() {
        super.reset()
        finger = nil
        button?.cancelHold()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Native scroll views cancel holds as soon as their pan takes over.
        // SwiftUI paging also cancels through the button's isEnabled gate.
        preventingGestureRecognizer is UIPanGestureRecognizer
    }

    private func cancel() {
        finger = nil
        button?.cancelHold()
        state = .failed
    }
}
