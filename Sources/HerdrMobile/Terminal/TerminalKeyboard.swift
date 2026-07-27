import UIKit

private enum TerminalEscapeSequences {
    static let escape: [UInt8] = [0x1B]
    static let tab: [UInt8] = [0x09]
    static let homeNormal: [UInt8] = [0x1B, 0x5B, 0x48]
    static let homeApplication: [UInt8] = [0x1B, 0x4F, 0x48]
    static let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E]
    static let upNormal: [UInt8] = [0x1B, 0x5B, 0x41]
    static let upApplication: [UInt8] = [0x1B, 0x4F, 0x41]
    static let pageDown: [UInt8] = [0x1B, 0x5B, 0x36, 0x7E]
    static let endNormal: [UInt8] = [0x1B, 0x5B, 0x46]
    static let endApplication: [UInt8] = [0x1B, 0x4F, 0x46]
    static let backspace: [UInt8] = [0x7F]
    static let leftNormal: [UInt8] = [0x1B, 0x5B, 0x44]
    static let leftApplication: [UInt8] = [0x1B, 0x4F, 0x44]
    static let downNormal: [UInt8] = [0x1B, 0x5B, 0x42]
    static let downApplication: [UInt8] = [0x1B, 0x4F, 0x42]
    static let rightNormal: [UInt8] = [0x1B, 0x5B, 0x43]
    static let rightApplication: [UInt8] = [0x1B, 0x4F, 0x43]
    static let enter: [UInt8] = [0x0D]
}

enum TerminalKeyboardMode: Int {
    case text
    case controls
}

enum TerminalControlKey: Equatable, CaseIterable {
    case escape
    case tab
    case controlC
    case controlD
    case controlZ
    case home
    case pageUp
    case up
    case pageDown
    case end
    case backspace
    case left
    case down
    case right
    case enter

    /// Backspace rides the top row's right edge, where the iOS keyboard puts it
    /// and where a thumb finds it without looking. That leaves the bottom row
    /// to the arrows and Enter alone, which get wider keys out of the deal.
    static let rows: [[Self]] = [
        [.escape, .tab, .controlC, .controlD, .controlZ, .backspace],
        [.home, .pageUp, .up, .pageDown, .end],
        [.left, .down, .right, .enter],
    ]

    var title: String? {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .controlC: "⌃C"
        case .controlD: "⌃D"
        case .controlZ: "⌃Z"
        case .home: "Home"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .end: "End"
        case .up, .backspace, .left, .down, .right, .enter: nil
        }
    }

    var systemImageName: String? {
        switch self {
        case .up: "arrow.up"
        case .backspace: "delete.left"
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .right: "arrow.right"
        case .enter: "return"
        default: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .controlC: "Control C"
        case .controlD: "Control D"
        case .controlZ: "Control Z"
        case .home: "Home"
        case .pageUp: "Page Up"
        case .up: "Up Arrow"
        case .pageDown: "Page Down"
        case .end: "End"
        case .backspace: "Backspace"
        case .left: "Left Arrow"
        case .down: "Down Arrow"
        case .right: "Right Arrow"
        case .enter: "Enter"
        }
    }

    var repeats: Bool {
        switch self {
        case .home, .pageUp, .up, .pageDown, .end, .backspace, .left, .down, .right:
            true
        case .escape, .tab, .controlC, .controlD, .controlZ, .enter:
            false
        }
    }

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .escape: TerminalEscapeSequences.escape
        case .tab: TerminalEscapeSequences.tab
        case .controlC: [0x03]
        case .controlD: [0x04]
        case .controlZ: [0x1A]
        case .home:
            applicationCursor
                ? TerminalEscapeSequences.homeApplication : TerminalEscapeSequences.homeNormal
        case .pageUp: TerminalEscapeSequences.pageUp
        case .up:
            applicationCursor
                ? TerminalEscapeSequences.upApplication : TerminalEscapeSequences.upNormal
        case .pageDown: TerminalEscapeSequences.pageDown
        case .end:
            applicationCursor
                ? TerminalEscapeSequences.endApplication : TerminalEscapeSequences.endNormal
        case .backspace: TerminalEscapeSequences.backspace
        case .left:
            applicationCursor
                ? TerminalEscapeSequences.leftApplication : TerminalEscapeSequences.leftNormal
        case .down:
            applicationCursor
                ? TerminalEscapeSequences.downApplication : TerminalEscapeSequences.downNormal
        case .right:
            applicationCursor
                ? TerminalEscapeSequences.rightApplication : TerminalEscapeSequences.rightNormal
        case .enter: TerminalEscapeSequences.enter
        }
    }
}

final class TerminalKeyboardAccessory: UIInputView {
    static let preferredHeight: CGFloat = 48
    /// The accessory's own background, reused as the paste control's fill.
    private static let surface = UIColor.secondarySystemBackground
    /// `UIPasteControl` draws its glyph at a fixed 12 pt (measured; the size
    /// is not configurable). The dismiss button matches it, or the row reads
    /// as two icons borrowed from different sets.
    private static let glyphPointSize: CGFloat = 12

    private weak var terminalView: HerdrTerminalView?
    private let modeControl = UISegmentedControl(items: ["Text", "Keys"])
    private(set) lazy var pasteControl: UIPasteControl = {
        var configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        // The system default is a filled accent-tinted tile, which shouts next
        // to the mode control and the dismiss button. UIPasteControl refuses a
        // clear fill (it falls back to a tinted one), so paint the fill with
        // the accessory's own background instead: the glyph is left reading as
        // a bare icon, matching the dismiss button beside it.
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Self.surface
        configuration.baseForegroundColor = .label
        let control = UIPasteControl(configuration: configuration)
        control.target = terminalView
        control.accessibilityLabel = "Paste"
        return control
    }()

    init(frame: CGRect, terminalView: HerdrTerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = Self.surface
        configureModeControl()
        configurePasteControl()
        configureDismissButton()
        update(mode: terminalView.keyboardMode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    func update(mode: TerminalKeyboardMode) {
        modeControl.selectedSegmentIndex = mode.rawValue
    }

    func setPasteEnabled(_ isEnabled: Bool) {
        pasteControl.isEnabled = isEnabled
    }

    private func configureModeControl() {
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentTintColor = .tertiarySystemBackground
        modeControl.setTitleTextAttributes(
            [.font: UIFont.preferredFont(forTextStyle: .subheadline)], for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.accessibilityLabel = "Terminal keyboard mode"
        addSubview(modeControl)

        NSLayoutConstraint.activate([
            modeControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 184),
            modeControl.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func configurePasteControl() {
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pasteControl)

        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pasteControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            pasteControl.widthAnchor.constraint(equalToConstant: 44),
            pasteControl.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureDismissButton() {
        var configuration = UIButton.Configuration.plain()
        let symbol = UIImage.SymbolConfiguration(
            pointSize: Self.glyphPointSize, weight: .regular, scale: .medium)
        configuration.image = UIImage(
            systemName: "keyboard.chevron.compact.down", withConfiguration: symbol)
        configuration.preferredSymbolConfigurationForImage = symbol
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
        button.accessibilityLabel = "Dismiss keyboard"
        addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func modeChanged() {
        guard let mode = TerminalKeyboardMode(rawValue: modeControl.selectedSegmentIndex) else {
            return
        }
        terminalView?.setKeyboardMode(mode)
    }

    @objc private func dismissKeyboard() {
        if let terminalView, terminalView.isFirstResponder {
            terminalView.dismissKeyboard()
            return
        }
        // The accessory can outlive its terminal view's first-responder
        // status (a rebuilt terminal after a reconnect). Resigning through the
        // responder chain still takes the keyboard down, so the button is
        // never a dead control.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The control-key pane of the Keys keyboard. It fills whatever space the
/// keyboard's tab container gives it, which is now one tab bar shorter than
/// the whole keyboard.
final class TerminalControlPadView: UIView {
    private weak var terminalView: HerdrTerminalView?

    init(terminalView: HerdrTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        configureKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func configureKeys() {
        let rows = UIStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 8
        addSubview(rows)

        for keys in TerminalControlKey.rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            for key in keys {
                row.addArrangedSubview(makeButton(for: key))
            }
            rows.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func makeButton(for key: TerminalControlKey) -> TerminalKeyButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = key.title
        configuration.image = key.systemImageName.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(
                textStyle: .body, scale: .medium))
        }
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = .secondarySystemFill
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .body)
            return outgoing
        }

        let button = TerminalKeyButton(configuration: configuration, repeats: key.repeats) {
            [weak terminalView] in
            guard let terminalView else { return }
            UIDevice.current.playInputClick()
            terminalView.sendControlKey(key)
        }
        button.accessibilityLabel = key.accessibilityLabel
        return button
    }
}

private final class TerminalKeyButton: UIButton {
    private let keyAction: () -> Void
    private let repeats: Bool
    private var repeatDelayTimer: Timer?
    private var repeatTimer: Timer?

    init(configuration: UIButton.Configuration, repeats: Bool, action: @escaping () -> Void) {
        self.keyAction = action
        self.repeats = repeats
        super.init(frame: .zero)
        self.configuration = configuration
        isExclusiveTouch = true
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(
            self, action: #selector(released),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelTimers()
        }
    }

    @objc private func pressed() {
        keyAction()
        guard repeats else { return }

        let timer = Timer(timeInterval: 0.45, target: self, selector: #selector(beginRepeating),
                          userInfo: nil, repeats: false)
        repeatDelayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func beginRepeating() {
        repeatDelayTimer = nil
        let timer = Timer(timeInterval: 0.075, target: self, selector: #selector(repeatKey),
                          userInfo: nil, repeats: true)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func repeatKey() {
        keyAction()
    }

    @objc private func released() {
        cancelTimers()
    }

    private func cancelTimers() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

extension HerdrTerminalView {
    var keyboardMode: TerminalKeyboardMode {
        inputView is TerminalKeysKeyboardView ? .controls : .text
    }

    var keysKeyboard: TerminalKeysKeyboardView? {
        inputView as? TerminalKeysKeyboardView
    }

    func installKeyboardSwitcher() {
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        _ = inputAccessoryView
        NotificationCenter.default.addObserver(
            self, selector: #selector(textKeyboardFrameDidChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        guard mode != keyboardMode else { return }

        switch mode {
        case .text:
            setTerminalInputView(nil)
        case .controls:
            setTerminalInputView(
                TerminalKeysKeyboardView(
                    frame: CGRect(
                        x: 0, y: 0, width: bounds.width, height: controlKeyboardHeight),
                    keyboardHeight: controlKeyboardHeight,
                    terminalView: self,
                    context: keysContext))
        }
        keysKeyboard?.localInputEnabledDidChange()
        (inputAccessoryView as? TerminalKeyboardAccessory)?.update(mode: mode)
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }

    func sendControlKey(_ key: TerminalControlKey) {
        guard isLocalInputEnabled else { return }
        terminalSession.sendInput(
            Data(key.bytes(applicationCursor: usesApplicationCursorKeys)))
    }

    func recordTextKeyboardHeight(totalHeight: CGFloat, accessoryHeight: CGFloat) {
        let inputViewHeight = totalHeight - accessoryHeight
        guard inputViewHeight >= 100 else { return }
        controlKeyboardHeight = inputViewHeight.rounded(.up)
    }

    @objc private func textKeyboardFrameDidChange(_ notification: Notification) {
        guard keyboardMode == .text, isFirstResponder, let window,
              let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect
        else { return }

        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        let totalHeight = window.bounds.intersection(frameInWindow).height
        let accessoryHeight = max(
            inputAccessoryView?.bounds.height ?? 0,
            TerminalKeyboardAccessory.preferredHeight)
        recordTextKeyboardHeight(
            totalHeight: totalHeight, accessoryHeight: accessoryHeight)
    }
}
