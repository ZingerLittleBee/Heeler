import UIKit

private enum TerminalEscapeSequences {
    static let newLine: [UInt8] = [0x0A]
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

    /// Backspace takes the top row's right edge, where the iOS keyboard puts it
    /// and where a thumb finds it without looking. It trades places with ⌃Z
    /// rather than crowding in, so the rows stay evenly sized.
    static let rows: [[Self]] = [
        [.escape, .tab, .controlC, .controlD, .backspace],
        [.home, .pageUp, .up, .pageDown, .end],
        [.controlZ, .left, .down, .right, .enter],
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

/// The keyboard's own row: paste, new line, and the Text/Keys mode control.
/// The Agent switcher and the keyboard toggle are deliberately not here — both
/// outlive the keyboard, so they ride the terminal instead. See
/// ``TerminalAgentSwitcherRow``.
final class TerminalKeyboardAccessory: UIInputView {
    /// Paste, new line, and the mode control.
    static let inputRowHeight: CGFloat = 48
    static let preferredHeight: CGFloat = inputRowHeight
    /// The accessory's own background, reused as the paste control's fill.
    private static let surface = UIColor.secondarySystemBackground
    /// `UIPasteControl` draws its glyph at a fixed 12 pt (measured; the size
    /// is not configurable). The dismiss button matches it, or the row reads
    /// as two icons borrowed from different sets.
    private static let glyphPointSize: CGFloat = 12

    private weak var terminalView: HerdrTerminalView?
    private(set) var toolbarContentView = UIView()
    private let modeControl = UISegmentedControl(items: ["Text", "Keys"])
    /// Holds the input row's controls so their layout stays independent of
    /// the switcher above them.
    private let inputRow = UIView()
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
    private(set) lazy var newLineButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        let symbol = UIImage.SymbolConfiguration(
            pointSize: Self.glyphPointSize, weight: .regular, scale: .medium)
        configuration.image = UIImage(systemName: "text.append", withConfiguration: symbol)
        configuration.preferredSymbolConfigurationForImage = symbol
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Insert New Line"
        button.accessibilityHint = "Adds a line break without submitting"
        button.addTarget(self, action: #selector(insertNewLine), for: .touchUpInside)
        return button
    }()

    init(frame: CGRect, terminalView: HerdrTerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        configureContentView()
        configureInputRow()
        configureModeControl()
        configurePasteControl()
        configureNewLineButton()
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

    func setInputEnabled(_ isEnabled: Bool) {
        pasteControl.isEnabled = isEnabled
        newLineButton.isEnabled = isEnabled
    }

    func animateDismissal(
        duration: TimeInterval = 0.25,
        options: UIView.AnimationOptions = .curveEaseInOut
    ) {
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [options, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.toolbarContentView.alpha = 0
            self.toolbarContentView.transform = CGAffineTransform(
                translationX: 0, y: Self.preferredHeight)
        }
    }

    func resetDismissalAppearance() {
        toolbarContentView.layer.removeAllAnimations()
        toolbarContentView.alpha = 1
        toolbarContentView.transform = .identity
    }

    private func configureContentView() {
        toolbarContentView.translatesAutoresizingMaskIntoConstraints = false
        toolbarContentView.backgroundColor = Self.surface
        addSubview(toolbarContentView)

        NSLayoutConstraint.activate([
            toolbarContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarContentView.topAnchor.constraint(equalTo: topAnchor),
            toolbarContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureInputRow() {
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        toolbarContentView.addSubview(inputRow)

        // Fences the keyboard's row off from the Agent strip resting above it;
        // both carry the same fill and would otherwise read as one slab.
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        toolbarContentView.addSubview(separator)

        NSLayoutConstraint.activate([
            inputRow.leadingAnchor.constraint(equalTo: toolbarContentView.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: toolbarContentView.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: toolbarContentView.topAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: Self.inputRowHeight),

            separator.leadingAnchor.constraint(equalTo: toolbarContentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: toolbarContentView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: toolbarContentView.topAnchor),
            separator.heightAnchor.constraint(
                equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
    }

    private func configureModeControl() {
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentTintColor = .tertiarySystemBackground
        modeControl.setTitleTextAttributes(
            [.font: UIFont.preferredFont(forTextStyle: .subheadline)], for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.accessibilityLabel = "Terminal keyboard mode"
        inputRow.addSubview(modeControl)

        let preferredWidth = modeControl.widthAnchor.constraint(equalToConstant: 184)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            modeControl.centerXAnchor.constraint(equalTo: inputRow.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            modeControl.trailingAnchor.constraint(
                lessThanOrEqualTo: inputRow.trailingAnchor, constant: -8),
            preferredWidth,
            modeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            modeControl.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func configurePasteControl() {
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addSubview(pasteControl)

        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: 8),
            pasteControl.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            pasteControl.widthAnchor.constraint(equalToConstant: 44),
            pasteControl.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureNewLineButton() {
        newLineButton.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addSubview(newLineButton)

        NSLayoutConstraint.activate([
            newLineButton.trailingAnchor.constraint(
                equalTo: inputRow.trailingAnchor, constant: -8),
            newLineButton.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            newLineButton.widthAnchor.constraint(equalToConstant: 44),
            newLineButton.heightAnchor.constraint(equalToConstant: 44),
            modeControl.trailingAnchor.constraint(
                lessThanOrEqualTo: newLineButton.leadingAnchor, constant: -4),
            pasteControl.trailingAnchor.constraint(
                lessThanOrEqualTo: modeControl.leadingAnchor, constant: -4),
        ])
    }

    @objc private func modeChanged() {
        guard let mode = TerminalKeyboardMode(rawValue: modeControl.selectedSegmentIndex) else {
            return
        }
        terminalView?.setKeyboardMode(mode)
    }

    @objc private func insertNewLine() {
        UIDevice.current.playInputClick()
        terminalView?.sendNewLine()
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

/// A key fires when the finger lifts, not when it lands: the pad sits inside
/// the pane pager, and a swipe that starts on a key must switch panes without
/// also sending an Esc down the wire. Holding still repeats, so the arrows go
/// on behaving like arrows.
private final class TerminalKeyButton: UIButton {
    private let keyAction: () -> Void
    private let repeats: Bool
    private var repeatDelayTimer: Timer?
    private var repeatTimer: Timer?
    /// A hold that has begun repeating already sent the key; letting go of it
    /// must not send one more.
    private var didRepeat = false

    init(configuration: UIButton.Configuration, repeats: Bool, action: @escaping () -> Void) {
        self.keyAction = action
        self.repeats = repeats
        super.init(frame: .zero)
        self.configuration = configuration
        isExclusiveTouch = true
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(self, action: #selector(released), for: .touchUpInside)
        addTarget(
            self, action: #selector(abandoned),
            for: [.touchUpOutside, .touchCancel, .touchDragExit])
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
        didRepeat = false
        guard repeats else { return }

        let timer = Timer(timeInterval: 0.45, target: self, selector: #selector(beginRepeating),
                          userInfo: nil, repeats: false)
        repeatDelayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func beginRepeating() {
        repeatDelayTimer = nil
        didRepeat = true
        keyAction()
        let timer = Timer(timeInterval: 0.075, target: self, selector: #selector(repeatKey),
                          userInfo: nil, repeats: true)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func repeatKey() {
        keyAction()
    }

    @objc private func released() {
        if !didRepeat {
            keyAction()
        }
        cancelTimers()
    }

    /// The finger left the key — dragged off it, or taken by the pager. Either
    /// way the key was not pressed.
    @objc private func abandoned() {
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDismissalWillBegin(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardTransitionDidFinish(_:)),
            name: UIResponder.keyboardDidHideNotification, object: nil)
        // The other end of a transition: a terminal that inherited the
        // keyboard keeps its grid frozen until the keyboard has settled.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardTransitionDidFinish(_:)),
            name: UIResponder.keyboardDidShowNotification, object: nil)
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

    func sendNewLine() {
        guard isLocalInputEnabled else { return }
        terminalSession.sendInput(Data(TerminalEscapeSequences.newLine))
    }

    func recordTextKeyboardHeight(totalHeight: CGFloat, accessoryHeight: CGFloat) {
        let inputViewHeight = totalHeight - accessoryHeight
        guard inputViewHeight >= 100 else { return }
        controlKeyboardHeight = inputViewHeight.rounded(.up)
    }

    @objc private func keyboardDismissalWillBegin(_ notification: Notification) {
        if let isLocal = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey]
            as? NSNumber,
            !isLocal.boolValue
        {
            return
        }
        let duration =
            (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                as? NSNumber)?.doubleValue ?? 0.25
        let curve =
            (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey]
                as? NSNumber)?.uintValue ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        (inputAccessoryView as? TerminalKeyboardAccessory)?.animateDismissal(
            duration: duration,
            options: options)
    }

    @objc private func textKeyboardFrameDidChange(_ notification: Notification) {
        keyboardFrameDidSettle()
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
