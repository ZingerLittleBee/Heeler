import SwiftUI
import UIKit

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

/// UIKit tracking cancels a hold when a scroll view or the keyboard pager
/// takes the touch. Release after a repeated or cancelled hold sends no key.
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
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(self, action: #selector(released), for: .touchUpInside)
        addTarget(self, action: #selector(cancelHold), for: [.touchUpOutside, .touchCancel, .touchDragExit])
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

    @objc private func pressed() {
        cancelHold()
        guard isEnabled else { return }
        holdState = .pressed
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

    @objc private func released() {
        let shouldSend = isEnabled && (holdState == .idle || holdState == .pressed)
        cancelHold()
        holdState = .idle
        if shouldSend { keyAction() }
    }

    @objc func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdState = .cancelled
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        cancelHold()
    }
}
