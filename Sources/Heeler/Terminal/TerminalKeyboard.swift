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
    static let leftNormal: [UInt8] = [0x1B, 0x5B, 0x44]
    static let leftApplication: [UInt8] = [0x1B, 0x4F, 0x44]
    static let downNormal: [UInt8] = [0x1B, 0x5B, 0x42]
    static let downApplication: [UInt8] = [0x1B, 0x4F, 0x42]
    static let rightNormal: [UInt8] = [0x1B, 0x5B, 0x43]
    static let rightApplication: [UInt8] = [0x1B, 0x4F, 0x43]
    static let enter: [UInt8] = [0x0D]
}
/// One-shot sticky modifiers for the terminal key surfaces (issue #270).
/// Standard iOS terminal behavior (Blink/Termius): tapping ⌃ or ⌥ arms the
/// modifier for the next key only; firing any key consumes and clears it.
/// There is deliberately no lock mode.
struct TerminalKeyModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    /// Ctrl: xterm modifier parameter 5 (1 + 4).
    static let control = Self(rawValue: 1 << 0)
    /// Option/Alt: xterm modifier parameter 3 (1 + 2).
    static let option = Self(rawValue: 1 << 1)
}

/// Tells the shared modifier encoding how a key's bare bytes accept modifiers.
enum TerminalKeyModifierShape: Sendable {
    /// Arrows, Home/End, PgUp/PgDn, Shift-Tab: xterm CSI `1;<m><final>`
    /// (or `<params>;<m><final>` for `~`-terminated sequences).
    case csiSuffixed
    /// Tab/Enter/Esc/Backspace, Shift-Enter, dedicated ⌃C/⌃D/⌃Z: an armed
    /// Option prefixes ESC; an armed Ctrl is a no-op because the bare byte
    /// is already a control character (Tab is Ctrl-I, Enter is Ctrl-M,
    /// LF is Ctrl-J, ⌃C/⌃D/⌃Z are control bytes by definition).
    case escPrefixed
}

extension TerminalKeyModifiers {
    /// Pure shared encoding used by both key enums: maps a key's bare bytes
    /// plus its modifier shape to the bytes to send. Empty modifiers return
    /// the bare bytes unchanged.
    func applied(to bare: [UInt8], shape: TerminalKeyModifierShape) -> [UInt8] {
        guard !isEmpty else { return bare }
        switch shape {
        case .escPrefixed:
            guard contains(.option) else { return bare }
            return TerminalEscapeSequences.escape + bare
        case .csiSuffixed:
            return Self.csiWithModifiers(bare: bare, modifiers: self)
        }
    }

    /// xterm modifier parameter: 5 for Ctrl, 3 for Alt/Option, 7 for both
    /// (1 + shift(1) + alt(2) + ctrl(4), with shift never set here).
    /// Returned as the ASCII digit byte for direct CSI emission.
    private var xtermParameterByte: UInt8 {
        var parameter: UInt8 = 1
        if contains(.option) { parameter += 2 }
        if contains(.control) { parameter += 4 }
        return UInt8(ascii: "0") + parameter
    }

    private static func csiWithModifiers(
        bare: [UInt8], modifiers: TerminalKeyModifiers
    ) -> [UInt8] {
        let parameter = modifiers.xtermParameterByte
        // Application-cursor SS3 (`ESC O <final>`) always falls back to the
        // CSI form when modifiers are present, matching xterm behavior.
        if bare.count == 3, bare[0] == 0x1B, bare[1] == 0x4F {
            return [0x1B, 0x5B, UInt8(ascii: "1"), UInt8(ascii: ";"), parameter, bare[2]]
        }
        // CSI form: insert `;<m>` before the final byte, defaulting empty
        // params to `1` (`ESC[H` -> `ESC[1;5H`, `ESC[5~` -> `ESC[5;5~`).
        guard bare.count >= 3, bare[0] == 0x1B, bare[1] == 0x5B else { return bare }
        let final = bare[bare.count - 1]
        var encoded = Array(bare.dropLast())
        if bare.count == 3 {
            encoded.append(UInt8(ascii: "1"))
        }
        encoded.append(UInt8(ascii: ";"))
        encoded.append(parameter)
        encoded.append(final)
        return encoded
    }
}

enum TerminalKeyboardMode: Int {
    case text
    case controls
}

/// PC-style function keys in the terminal's existing xterm encoding.
enum TerminalFunctionKey: Int, CaseIterable, Hashable {
    case f1 = 1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var title: String { "F\(rawValue)" }

    func bytes(modifiers: TerminalKeyModifiers) -> [UInt8] {
        let bare: [UInt8]
        switch self {
        case .f1: bare = Array("\u{1B}OP".utf8)
        case .f2: bare = Array("\u{1B}OQ".utf8)
        case .f3: bare = Array("\u{1B}OR".utf8)
        case .f4: bare = Array("\u{1B}OS".utf8)
        case .f5: bare = Array("\u{1B}[15~".utf8)
        case .f6: bare = Array("\u{1B}[17~".utf8)
        case .f7: bare = Array("\u{1B}[18~".utf8)
        case .f8: bare = Array("\u{1B}[19~".utf8)
        case .f9: bare = Array("\u{1B}[20~".utf8)
        case .f10: bare = Array("\u{1B}[21~".utf8)
        case .f11: bare = Array("\u{1B}[23~".utf8)
        case .f12: bare = Array("\u{1B}[24~".utf8)
        }
        return modifiers.applied(to: bare, shape: .csiSuffixed)
    }
}

/// The small set of terminal controls exposed by Composer's tools keyboard.
/// These are explicit actions rather than authored text, so they bypass the
/// draft while the Ghostty surface itself remains display-only.
enum AgentQuickKey: Hashable {
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

    case controlC
    case controlA
    case controlE
    case home
    case end
    case insert
    case forwardDelete
    case function(TerminalFunctionKey)

    var title: String? {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .shiftTab: "⇧Tab"
        case .shiftEnter: "⇧Enter"
        case .enter: "Enter"
        case .backspace: "Backspace"
        case .controlC: "Ctrl+C"
        case .controlA: "Ctrl+A"
        case .controlE: "Ctrl+E"
        case .home: "Home"
        case .end: "End"
        case .insert: "Insert"
        case .forwardDelete: "Forward Delete"
        case .function(let key): key.title
        case .left, .up, .down, .right: nil
        }
    }

    var systemImageName: String? {
        switch self {
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        default: nil
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
        case .controlC: "Control C"
        case .controlA: "Control A"
        case .controlE: "Control E"
        case .home: "Home"
        case .end: "End"
        case .insert: "Insert"
        case .forwardDelete: "Forward Delete"
        case .function(let key): key.title
        }
    }

    func bytes(applicationCursor: Bool) -> [UInt8] {
        bytes(applicationCursor: applicationCursor, modifiers: [])
    }

    /// Modifier-aware overload for the one-shot sticky ⌃/⌥ keys (#270).
    /// Delegates to the matching `TerminalControlKey` encoding so both
    /// surfaces share one xterm mapping; only Shift-Tab/Shift-Enter encode
    /// directly (CSI `1;<m>Z`, ESC-prefixed LF).
    func bytes(applicationCursor: Bool, modifiers: TerminalKeyModifiers) -> [UInt8] {
        switch self {
        case .escape: TerminalControlKey.escape.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .tab: TerminalControlKey.tab.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .shiftTab: modifiers.applied(
            to: TerminalEscapeSequences.shiftTab, shape: .csiSuffixed)
        // LF / Ctrl-J keeps the multiline action distinct from Enter's CR
        // without depending on a negotiated enhanced-keyboard protocol.
        case .shiftEnter: modifiers.applied(
            to: TerminalEscapeSequences.newLine, shape: .escPrefixed)
        case .left: TerminalControlKey.left.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .up: TerminalControlKey.up.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .down: TerminalControlKey.down.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .right: TerminalControlKey.right.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .enter: TerminalControlKey.enter.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .backspace:
            TerminalControlKey.backspace.bytes(
                applicationCursor: applicationCursor, modifiers: modifiers)
        case .controlC: modifiers.applied(to: [0x03], shape: .escPrefixed)
        case .controlA: modifiers.applied(to: [0x01], shape: .escPrefixed)
        case .controlE: modifiers.applied(to: [0x05], shape: .escPrefixed)
        case .home: TerminalControlKey.home.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .end: TerminalControlKey.end.bytes(
            applicationCursor: applicationCursor, modifiers: modifiers)
        case .insert: modifiers.applied(
            to: Array("\u{1B}[2~".utf8), shape: .csiSuffixed)
        case .forwardDelete: modifiers.applied(
            to: Array("\u{1B}[3~".utf8), shape: .csiSuffixed)
        case .function(let key): key.bytes(modifiers: modifiers)
        }
    }
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
        bytes(applicationCursor: applicationCursor, modifiers: [])
    }

    /// Modifier-aware overload for the one-shot sticky ⌃/⌥ keys (#270).
    /// Ctrl+arrows/Home/End/PgUp/PgDn emit CSI `1;5X`, Option+those emit
    /// CSI `1;3X`; Option+Tab/Enter/Esc/Backspace prefix ESC; Ctrl on keys
    /// whose bare byte is already a control character is byte-identical.
    func bytes(applicationCursor: Bool, modifiers: TerminalKeyModifiers) -> [UInt8] {
        let bare: [UInt8] = switch self {
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
        return modifiers.applied(to: bare, shape: modifierShape)
    }

    private var modifierShape: TerminalKeyModifierShape {
        switch self {
        case .home, .pageUp, .up, .pageDown, .end, .left, .down, .right:
            .csiSuffixed
        case .escape, .tab, .controlC, .controlD, .controlZ, .backspace, .enter:
            .escPrefixed
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
    private let send: (TerminalControlKey) -> Void
    private let toggleModifier: (TerminalKeyModifiers) -> Void
    private var modifierButtons: [TerminalKeyModifiers: UIButton] = [:]

    /// Mirrors `TerminalKeyboardControl.pendingModifiers`, pushed from
    /// `TerminalControlPadRepresentable.updateUIView` so the ⌃/⌥ caps stay
    /// highlighted while armed, including arms set from another surface.
    var armedModifiers = TerminalKeyModifiers() {
        didSet { guard armedModifiers != oldValue else { return }; refreshModifierButtons() }
    }

    init(
        send: @escaping (TerminalControlKey) -> Void,
        toggleModifier: @escaping (TerminalKeyModifiers) -> Void = { _ in }
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

    private func configureKeys() {
        let rows = UIStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 8
        addSubview(rows)

        rows.addArrangedSubview(makeModifierRow())
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

    /// One-shot sticky modifiers: tap ⌃ or ⌥ to arm it for the next key only;
    /// tapping the armed cap again disarms. Firing any key consumes the arm.
    private func makeModifierRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for modifier in [TerminalKeyModifiers.control, .option] {
            let button = makeModifierButton(for: modifier)
            modifierButtons[modifier] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    private func makeModifierButton(for modifier: TerminalKeyModifiers) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = modifierConfiguration(armed: false, modifier: modifier)
        button.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.toggleModifier(modifier)
        }, for: .touchUpInside)
        button.accessibilityLabel =
            modifier == .control ? "Control modifier" : "Option modifier"
        button.accessibilityValue = "Not armed"
        return button
    }

    private func refreshModifierButtons() {
        for (modifier, button) in modifierButtons {
            let armed = armedModifiers.contains(modifier)
            button.configuration = modifierConfiguration(armed: armed, modifier: modifier)
            button.accessibilityValue = armed ? "Armed" : "Not armed"
        }
    }

    private func modifierConfiguration(
        armed: Bool, modifier: TerminalKeyModifiers
    ) -> UIButton.Configuration {
        var configuration = armed ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.title = modifier == .control ? "⌃" : "⌥"
        configuration.baseForegroundColor = .label
        if !armed {
            configuration.baseBackgroundColor = .secondarySystemFill
        }
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .body)
            return outgoing
        }
        return configuration
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
            [send] in
            UIDevice.current.playInputClick()
            send(key)
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

    func sendControlKey(_ key: TerminalControlKey) {
        sendControlKey(key, modifiers: [])
    }

    /// Modifier-aware overload for the one-shot sticky ⌃/⌥ keys (#270).
    /// Returns whether the bytes were actually sent so the caller can
    /// consume the armed modifiers only on a real send: a send dropped by
    /// the local-input gate must leave the armed state untouched.
    @discardableResult
    func sendControlKey(_ key: TerminalControlKey, modifiers: TerminalKeyModifiers) -> Bool {
        guard isLocalInputEnabled else { return false }
        terminalSession.sendInput(
            Data(key.bytes(
                applicationCursor: usesApplicationCursorKeys, modifiers: modifiers)))
        return true
    }

    /// Composer quick keys are explicit terminal actions. They remain usable
    /// while ordinary local terminal input is disabled.
    func sendQuickKey(_ key: AgentQuickKey) {
        sendQuickKey(key, modifiers: [])
    }

    /// Modifier-aware overload for the one-shot sticky ⌃/⌥ keys (#270).
    func sendQuickKey(_ key: AgentQuickKey, modifiers: TerminalKeyModifiers) {
        terminalSession.sendInput(
            Data(key.bytes(
                applicationCursor: usesApplicationCursorKeys, modifiers: modifiers)))
    }

    func sendNewLine() {
        guard isLocalInputEnabled else { return }
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
