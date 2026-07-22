import SwiftTerm
import UIKit

enum TerminalKeyboardMode: Int {
    case text
    case controls
}

enum TerminalControlKey: Equatable {
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

    static let rows: [[Self]] = [
        [.escape, .tab, .controlC, .controlD, .controlZ],
        [.home, .pageUp, .up, .pageDown, .end],
        [.backspace, .left, .down, .right, .enter],
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
        case .escape: EscapeSequences.cmdEsc
        case .tab: EscapeSequences.cmdTab
        case .controlC: [0x03]
        case .controlD: [0x04]
        case .controlZ: [0x1A]
        case .home:
            applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal
        case .pageUp: EscapeSequences.cmdPageUp
        case .up:
            applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .pageDown: EscapeSequences.cmdPageDown
        case .end:
            applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal
        case .backspace: EscapeSequences.cmdDel
        case .left:
            applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .down:
            applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .right:
            applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        case .enter: EscapeSequences.cmdRet
        }
    }
}

final class TerminalKeyboardAccessory: UIInputView {
    private weak var terminalView: SizeReportingTerminalView?
    private let modeControl = UISegmentedControl(items: ["Text", "Keys"])

    init(frame: CGRect, terminalView: SizeReportingTerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground
        configureModeControl()
        configureDismissButton()
        update(mode: terminalView.keyboardMode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
    }

    func update(mode: TerminalKeyboardMode) {
        modeControl.selectedSegmentIndex = mode.rawValue
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

    private func configureDismissButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "keyboard.chevron.compact.down")
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
        _ = terminalView?.resignFirstResponder()
    }
}

final class TerminalControlKeyboardView: UIInputView, UIInputViewAudioFeedback {
    private weak var terminalView: SizeReportingTerminalView?

    var enableInputClicksWhenVisible: Bool { true }

    init(frame: CGRect, terminalView: SizeReportingTerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .systemBackground
        configureKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 224)
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
            rows.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
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

extension SizeReportingTerminalView {
    var keyboardMode: TerminalKeyboardMode {
        inputView is TerminalControlKeyboardView ? .controls : .text
    }

    func installKeyboardSwitcher() {
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        inputAccessoryView = TerminalKeyboardAccessory(
            frame: CGRect(x: 0, y: 0, width: bounds.width, height: 48), terminalView: self)
    }

    func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        guard mode != keyboardMode else { return }

        switch mode {
        case .text:
            inputView = nil
        case .controls:
            inputView = TerminalControlKeyboardView(
                frame: CGRect(x: 0, y: 0, width: bounds.width, height: 224), terminalView: self)
        }
        (inputAccessoryView as? TerminalKeyboardAccessory)?.update(mode: mode)
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }

    func sendControlKey(_ key: TerminalControlKey) {
        send(key.bytes(applicationCursor: getTerminal().applicationCursor))
    }
}
