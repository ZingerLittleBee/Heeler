import GhosttyTerminal
import UIKit

private enum TerminalEscapeSequences {
    static let newLine: [UInt8] = [0x0A]
    static let escape: [UInt8] = [0x1B]
    static let tab: [UInt8] = [0x09]
    static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A]
    static let homeNormal: [UInt8] = [0x1B, 0x5B, 0x48]
    static let homeApplication: [UInt8] = [0x1B, 0x4F, 0x48]
    static let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E]
    static let upNormal: [UInt8] = [0x1B, 0x5B, 0x41]
    static let upApplication: [UInt8] = [0x1B, 0x4F, 0x41]
    static let pageDown: [UInt8] = [0x1B, 0x5B, 0x36, 0x7E]
    static let endNormal: [UInt8] = [0x1B, 0x5B, 0x46]
    static let endApplication: [UInt8] = [0x1B, 0x4F, 0x46]
    static let backspace: [UInt8] = [0x7F]
    static let insert: [UInt8] = [0x1B, 0x5B, 0x32, 0x7E]
    static let forwardDelete: [UInt8] = [0x1B, 0x5B, 0x33, 0x7E]
    static let functionKeys: [[UInt8]] = [
        [0x1B, 0x4F, 0x50], [0x1B, 0x4F, 0x51],
        [0x1B, 0x4F, 0x52], [0x1B, 0x4F, 0x53],
        [0x1B, 0x5B, 0x31, 0x35, 0x7E], [0x1B, 0x5B, 0x31, 0x37, 0x7E],
        [0x1B, 0x5B, 0x31, 0x38, 0x7E], [0x1B, 0x5B, 0x31, 0x39, 0x7E],
        [0x1B, 0x5B, 0x32, 0x30, 0x7E], [0x1B, 0x5B, 0x32, 0x31, 0x7E],
        [0x1B, 0x5B, 0x32, 0x33, 0x7E], [0x1B, 0x5B, 0x32, 0x34, 0x7E],
    ]
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

/// The small set of terminal controls exposed by Composer's tools keyboard.
/// These are explicit actions rather than authored text, so they bypass the
/// draft while the Ghostty surface itself remains display-only.
enum AgentQuickKey: CaseIterable, Hashable {
    case escape
    case tab
    case shiftTab
    case shiftEnter
    case left
    case up
    case down
    case right
    case enter
    case backspace

    var title: String? {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .shiftTab: "⇧Tab"
        case .shiftEnter: "⇧Enter"
        case .enter: "Enter"
        case .backspace: "Backspace"
        case .left, .up, .down, .right: nil
        }
    }

    var systemImageName: String? {
        switch self {
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        case .escape, .tab, .shiftTab, .shiftEnter, .enter, .backspace: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shiftTab: "Shift Tab"
        case .shiftEnter: "Shift Enter"
        case .left: "Left Arrow"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .right: "Right Arrow"
        case .enter: "Enter"
        case .backspace: "Backspace"
        }
    }

    var ghosttyInput: (key: TerminalKey, modifiers: TerminalInputModifiers) {
        switch self {
        case .escape: (.escape, [])
        case .tab: (.tab, [])
        case .shiftTab: (.tab, [.shift])
        // Ctrl-J preserves the established LF multiline action.
        case .shiftEnter: (.j, [.ctrl])
        case .left: (.arrowLeft, [])
        case .up: (.arrowUp, [])
        case .down: (.arrowDown, [])
        case .right: (.arrowRight, [])
        case .enter: (.enter, [])
        case .backspace: (.backspace, [])
        }
    }

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .escape: TerminalControlKey.escape.bytes(applicationCursor: applicationCursor)
        case .tab: TerminalControlKey.tab.bytes(applicationCursor: applicationCursor)
        case .shiftTab: TerminalEscapeSequences.shiftTab
        // LF / Ctrl-J keeps the multiline action distinct from Enter's CR
        // without depending on a negotiated enhanced-keyboard protocol.
        case .shiftEnter: TerminalEscapeSequences.newLine
        case .left: TerminalControlKey.left.bytes(applicationCursor: applicationCursor)
        case .up: TerminalControlKey.up.bytes(applicationCursor: applicationCursor)
        case .down: TerminalControlKey.down.bytes(applicationCursor: applicationCursor)
        case .right: TerminalControlKey.right.bytes(applicationCursor: applicationCursor)
        case .enter: TerminalControlKey.enter.bytes(applicationCursor: applicationCursor)
        case .backspace:
            TerminalControlKey.backspace.bytes(applicationCursor: applicationCursor)
        }
    }
}

enum TerminalModifier: CaseIterable, Hashable {
    case control
    case option

    var title: String {
        switch self {
        case .control: "Ctrl"
        case .option: "⌥"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        }
    }

    var ghosttyModifier: TerminalPublicStickyModifier {
        switch self {
        case .control: .ctrl
        case .option: .alt
        }
    }
}

enum TerminalControlPadItem: Hashable {
    case key(TerminalControlKey)
    case modifier(TerminalModifier)
    case functionPage

    var title: String? {
        switch self {
        case .key(let key): key.title
        case .modifier(let modifier): modifier.title
        case .functionPage: "F1–F12"
        }
    }

    var systemImageName: String? {
        if case .key(let key) = self { key.systemImageName } else { nil }
    }

    var accessibilityLabel: String {
        switch self {
        case .key(let key): key.accessibilityLabel
        case .modifier(let modifier): modifier.accessibilityLabel
        case .functionPage: "Function Keys"
        }
    }

    var repeats: Bool {
        if case .key(let key) = self { key.repeats } else { false }
    }
}

enum TerminalControlKey: Equatable, CaseIterable, Hashable {
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
    case insert
    case forwardDelete
    case left
    case down
    case right
    case enter
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    static let primaryRows: [[TerminalControlPadItem]] = [
        [.key(.escape), .key(.tab), .modifier(.control), .modifier(.option), .key(.backspace)],
        [.key(.controlC), .key(.controlD), .key(.controlZ), .key(.insert), .key(.forwardDelete)],
        [.key(.home), .key(.pageUp), .key(.up), .key(.pageDown), .key(.end)],
        [.functionPage, .key(.left), .key(.down), .key(.right), .key(.enter)],
    ]

    static let functionRows: [[TerminalControlPadItem]] = [
        [.key(.f1), .key(.f2), .key(.f3), .key(.f4)],
        [.key(.f5), .key(.f6), .key(.f7), .key(.f8)],
        [.key(.f9), .key(.f10), .key(.f11), .key(.f12)],
        [.functionPage],
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
        case .insert: "Ins"
        case .forwardDelete: "Del"
        case .f1: "F1"
        case .f2: "F2"
        case .f3: "F3"
        case .f4: "F4"
        case .f5: "F5"
        case .f6: "F6"
        case .f7: "F7"
        case .f8: "F8"
        case .f9: "F9"
        case .f10: "F10"
        case .f11: "F11"
        case .f12: "F12"
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
        case .insert: "Insert"
        case .forwardDelete: "Forward Delete"
        case .left: "Left Arrow"
        case .down: "Down Arrow"
        case .right: "Right Arrow"
        case .enter: "Enter"
        case .f1: "F1"
        case .f2: "F2"
        case .f3: "F3"
        case .f4: "F4"
        case .f5: "F5"
        case .f6: "F6"
        case .f7: "F7"
        case .f8: "F8"
        case .f9: "F9"
        case .f10: "F10"
        case .f11: "F11"
        case .f12: "F12"
        }
    }

    var repeats: Bool {
        switch self {
        case .home, .pageUp, .up, .pageDown, .end, .backspace, .insert,
             .forwardDelete, .left, .down, .right:
            true
        case .escape, .tab, .controlC, .controlD, .controlZ, .enter,
             .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            false
        }
    }

    var ghosttyKey: TerminalKey? {
        switch self {
        case .controlC, .controlD, .controlZ: nil
        case .escape: .escape
        case .tab: .tab
        case .home: .home
        case .pageUp: .pageUp
        case .up: .arrowUp
        case .pageDown: .pageDown
        case .end: .end
        case .backspace: .backspace
        case .insert: .insert
        case .forwardDelete: .delete
        case .left: .arrowLeft
        case .down: .arrowDown
        case .right: .arrowRight
        case .enter: .enter
        case .f1: .f1
        case .f2: .f2
        case .f3: .f3
        case .f4: .f4
        case .f5: .f5
        case .f6: .f6
        case .f7: .f7
        case .f8: .f8
        case .f9: .f9
        case .f10: .f10
        case .f11: .f11
        case .f12: .f12
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
        case .insert: TerminalEscapeSequences.insert
        case .forwardDelete: TerminalEscapeSequences.forwardDelete
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
        case .f1: TerminalEscapeSequences.functionKeys[0]
        case .f2: TerminalEscapeSequences.functionKeys[1]
        case .f3: TerminalEscapeSequences.functionKeys[2]
        case .f4: TerminalEscapeSequences.functionKeys[3]
        case .f5: TerminalEscapeSequences.functionKeys[4]
        case .f6: TerminalEscapeSequences.functionKeys[5]
        case .f7: TerminalEscapeSequences.functionKeys[6]
        case .f8: TerminalEscapeSequences.functionKeys[7]
        case .f9: TerminalEscapeSequences.functionKeys[8]
        case .f10: TerminalEscapeSequences.functionKeys[9]
        case .f11: TerminalEscapeSequences.functionKeys[10]
        case .f12: TerminalEscapeSequences.functionKeys[11]
        }
    }
}

/// Suppresses the software keyboard while the terminal keeps first responder:
/// a zero-height input view replaces the system keyboard without resigning,
/// so the IME session — and its candidate row on return — survives the switch.
/// Shared with the Composer, whose tools mode pioneered the arrangement.
final class TerminalSuppressedSoftKeyboardView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 0)
    }
}

/// The control-key pane of the Keys dock. It fills whatever space the dock's
/// tab container gives it. Driven by a closure rather than the terminal view
/// so the app-side dock can outlive any one terminal surface.
final class TerminalControlPadView: UIView {
    private enum Page { case primary, functions }

    private let send: (TerminalControlKey) -> Void
    private let toggleModifier: (TerminalModifier) -> Void
    private let rows = UIStackView()
    private var page = Page.primary
    private var activeModifiers: Set<TerminalModifier> = []
    private var modifierButtons: [TerminalModifier: TerminalKeyButton] = [:]

    init(
        send: @escaping (TerminalControlKey) -> Void,
        toggleModifier: @escaping (TerminalModifier) -> Void = { _ in }
    ) {
        self.send = send
        self.toggleModifier = toggleModifier
        super.init(frame: .zero)
        configureKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setActiveModifiers(_ modifiers: Set<TerminalModifier>) {
        guard activeModifiers != modifiers else { return }
        activeModifiers = modifiers
        updateModifierButtons()
    }

    private func configureKeys() {
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 8
        addSubview(rows)
        show(.primary)

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func show(_ page: Page) {
        self.page = page
        modifierButtons.removeAll()
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let pageRows = page == .primary
            ? TerminalControlKey.primaryRows : TerminalControlKey.functionRows
        for items in pageRows {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            for item in items {
                row.addArrangedSubview(makeButton(for: item))
            }
            rows.addArrangedSubview(row)
        }
        updateModifierButtons()
    }

    private func makeButton(for item: TerminalControlPadItem) -> TerminalKeyButton {
        var configuration = Self.configuration(for: item, page: page, selected: false)
        let button = TerminalKeyButton(configuration: configuration, repeats: item.repeats) {
            [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            switch item {
            case .key(let key):
                send(key)
            case .modifier(let modifier):
                toggleModifier(modifier)
            case .functionPage:
                show(page == .primary ? .functions : .primary)
            }
        }
        button.accessibilityLabel = item == .functionPage
            ? (page == .primary ? "Function Keys" : "Standard Keys")
            : item.accessibilityLabel
        if case .modifier(let modifier) = item {
            modifierButtons[modifier] = button
        }
        return button
    }

    private func updateModifierButtons() {
        for (modifier, button) in modifierButtons {
            let selected = activeModifiers.contains(modifier)
            button.configuration = Self.configuration(
                for: .modifier(modifier), page: page, selected: selected)
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            button.accessibilityValue = selected ? "Selected" : nil
        }
    }

    private static func configuration(
        for item: TerminalControlPadItem,
        page: Page,
        selected: Bool
    ) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.title = item == .functionPage
            ? (page == .primary ? "F1–F12" : "Standard Keys") : item.title
        configuration.image = item.systemImageName.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(
                textStyle: .body, scale: .medium))
        }
        configuration.baseForegroundColor = selected ? .white : .label
        configuration.baseBackgroundColor = selected ? .systemBlue : .secondarySystemFill
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .body)
            return outgoing
        }
        return configuration
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
    private var wasCancelled = false
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
        wasCancelled = false
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
        if !didRepeat, !wasCancelled {
            keyAction()
        }
        cancelTimers()
    }

    /// The finger left the key — dragged off it, or taken by the pager. Either
    /// way the key was not pressed.
    @objc private func abandoned() {
        wasCancelled = true
        cancelTimers()
    }

    private func cancelTimers() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

extension HeelerTerminalView {
    /// Read from the installed input view, so the mode can never disagree
    /// with what UIKit is actually presenting.
    var keyboardMode: TerminalKeyboardMode {
        inputView is TerminalSuppressedSoftKeyboardView ? .controls : .text
    }

    /// Hooks the terminal into the keyboard's lifecycle, observed through
    /// `notificationCenter`.
    ///
    /// Production observes the process-wide default: UIKit posts keyboard
    /// notifications there, and there is no per-window center to move to.
    /// What keeps one window's keyboard from ending another window's handoff
    /// is the receiving end — a terminal heeds a transition event only for
    /// its own keyboard (see `textKeyboardFrameDidChange`) — because on iPad
    /// two of the app's windows can each hold a live terminal (#157). Tests
    /// pass a center of their own, the same seam `TerminalKeyboardInset`
    /// takes, so a keyboard settling in a neighbouring test cannot reach this
    /// terminal at all.
    /// There is nothing to balance: the center drops an observer that
    /// deallocates.
    func installKeyboardSwitcher(notificationCenter: NotificationCenter = .default) {
        installInputAssistantStyle()
        notificationCenter.addObserver(
            self, selector: #selector(textKeyboardFrameDidChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    /// Switches between the system keyboard and the Keys dock the way the
    /// Composer does: the first responder never changes, and Keys mode only
    /// suppresses the software keyboard with a zero-height input view while
    /// the app-side dock occupies the measured keyboard footprint behind it.
    /// Replacing the keyboard with a real input view was tried first and cost
    /// the switch its stability: UIKit removes the candidate row before the
    /// swap lands, everything riding the keyboard dips, and the IME's
    /// candidate row never comes back for a composition still in flight.
    func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        guard mode != keyboardMode else { return }

        switch mode {
        case .text:
            setTerminalInputView(nil)
        case .controls:
            setTerminalInputView(TerminalSuppressedSoftKeyboardView())
        }
        guard isFirstResponder else { return }
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }

    func toggleModifier(_ modifier: TerminalModifier) {
        guard isLocalInputEnabled else { return }
        toggleStickyModifier(modifier.ghosttyModifier)
    }

    func resetModifiers() {
        resetStickyModifiers()
    }

    func sendControlKey(_ key: TerminalControlKey) {
        guard isLocalInputEnabled else { return }
        switch key {
        case .controlC:
            sendFixedControlCharacter("c")
        case .controlD:
            sendFixedControlCharacter("d")
        case .controlZ:
            sendFixedControlCharacter("z")
        default:
            guard let ghosttyKey = key.ghosttyKey else { return }
            sendKey(ghosttyKey)
        }
    }

    private func sendFixedControlCharacter(_ character: String) {
        if stickyActivation(for: .ctrl) == .inactive {
            toggleStickyModifier(.ctrl)
        }
        insertText(character)
    }

    /// Composer quick keys are explicit terminal actions. They remain usable
    /// while ordinary local terminal input is disabled.
    func sendQuickKey(_ key: AgentQuickKey) {
        resetStickyModifiers()
        let input = key.ghosttyInput
        if !sendKey(input.key, modifiers: input.modifiers) {
            terminalSession.sendInput(
                Data(key.bytes(applicationCursor: usesApplicationCursorKeys)))
        }
    }

    func sendNewLine() {
        guard isLocalInputEnabled else { return }
        resetStickyModifiers()
        terminalSession.sendInput(Data(TerminalEscapeSequences.newLine))
    }

    @objc private func textKeyboardFrameDidChange(_ notification: Notification) {
        if notificationSettlesOwnKeyboard(notification) {
            keyboardFrameDidSettle()
        }
    }

    /// Whether a keyboard frame event is this terminal's own settle signal.
    /// Keyboard notifications are process-wide, and on iPad a second window
    /// of the app can hold a live terminal of its own (#157): the event
    /// belongs to this terminal's keyboard only while this terminal is first
    /// responder, and only when the reported end frame leaves the keyboard
    /// covering this terminal's window. A frame on its way out belongs to a
    /// different transition — the other window's, say — and must not end
    /// this terminal's handoff. A post carrying no frame cannot establish
    /// ownership and is ignored.
    private func notificationSettlesOwnKeyboard(_ notification: Notification) -> Bool {
        guard isFirstResponder, let window, window.isKeyWindow else { return false }
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect
        else { return false }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        return TerminalKeyboardInset.keyboardFrame(
            frameInWindow,
            matches: keyboardLayoutFrameProvider?(window)
                ?? window.keyboardLayoutGuide.layoutFrame,
            in: window)
    }
}
