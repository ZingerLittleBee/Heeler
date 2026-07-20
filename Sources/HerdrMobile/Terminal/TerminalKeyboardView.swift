import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class TerminalKeyboardSession {
    private(set) var state = TerminalKeyboardState()
    var onModeChanged: ((TerminalKeyboardMode) -> Void)?
    var onClose: (() -> Void)?
    var onKey: ((TerminalKey, Set<TerminalModifier>) -> Void)?

    private var lastShiftTapUptime: TimeInterval?
    private var repeatTask: Task<Void, Never>?

    func selectMode(_ mode: TerminalKeyboardMode) {
        guard state.mode != mode else { return }
        cancelRepeat()
        lastShiftTapUptime = nil
        state.selectMode(mode)
        onModeChanged?(mode)
    }

    func selectPage(_ page: TerminalKeyboardPage) {
        state.selectPage(page)
    }

    func movePage(by offset: Int) {
        let rawValue = min(
            TerminalKeyboardPage.allCases.count - 1,
            max(0, state.page.rawValue + offset))
        guard let page = TerminalKeyboardPage(rawValue: rawValue) else { return }
        selectPage(page)
    }

    func tapModifier(_ modifier: TerminalModifier) {
        let now = ProcessInfo.processInfo.systemUptime
        let locks = modifier == .shift
            && state.phase(of: .shift) == .armed
            && lastShiftTapUptime.map { now - $0 <= 0.35 } == true

        state.toggle(modifier, locks: locks)
        lastShiftTapUptime = modifier == .shift && !locks ? now : nil
    }

    func press(_ key: TerminalKey) {
        cancelRepeat()
        lastShiftTapUptime = nil
        let modifiers = state.activeModifiers
        onKey?(key, modifiers)
        state.consumeOneShotModifiers()
    }

    func beginRepeating(_ key: TerminalKey) {
        guard key.isRepeatable else {
            press(key)
            return
        }
        cancelRepeat()
        lastShiftTapUptime = nil
        let modifiers = state.activeModifiers
        onKey?(key, modifiers)
        state.consumeOneShotModifiers()

        repeatTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                while !Task.isCancelled {
                    guard let self else { return }
                    self.onKey?(key, modifiers)
                    try await Task.sleep(for: .milliseconds(80))
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func endRepeating() {
        cancelRepeat()
    }

    func close() {
        cancelRepeat()
        lastShiftTapUptime = nil
        state.clearModifiers()
        onClose?()
    }

    private func cancelRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

@MainActor
final class TerminalKeyboardHost {
    let session: TerminalKeyboardSession
    private let accessoryView: TerminalKeyboardHostingView
    private let keyboardView: TerminalKeyboardHostingView

    init(terminalView: SizeReportingTerminalView) {
        let session = TerminalKeyboardSession()
        self.session = session

        let accessoryView = TerminalKeyboardHostingView(
            role: .accessory,
            rootView: AnyView(TerminalKeyboardAccessory(session: session)))
        let keyboardView = TerminalKeyboardHostingView(
            role: .keyboard,
            rootView: AnyView(TerminalKeyboardView(session: session)))
        self.accessoryView = accessoryView
        self.keyboardView = keyboardView

        terminalView.inputAccessoryView = accessoryView
        terminalView.inputView = nil

        session.onModeChanged = { [weak terminalView, weak keyboardView] mode in
            guard let terminalView else { return }
            terminalView.unmarkText()
            terminalView.inputView = mode == .terminal ? keyboardView : nil
            UIView.performWithoutAnimation {
                terminalView.reloadInputViews()
            }
        }
        session.onClose = { [weak terminalView] in
            guard let terminalView else { return }
            terminalView.unmarkText()
            _ = terminalView.resignFirstResponder()
        }
        session.onKey = { [weak terminalView, weak keyboardView] key, modifiers in
            guard let terminalView else { return }
            keyboardView?.playClick()
            terminalView.sendTerminalKey(key, modifiers: modifiers)
        }
    }
}

@MainActor
private final class TerminalKeyboardHostingView: UIInputView, UIInputViewAudioFeedback {
    enum Role {
        case accessory
        case keyboard
    }

    private let role: Role
    private let hostingController: UIHostingController<AnyView>

    init(role: Role, rootView: AnyView) {
        self.role = role
        hostingController = UIHostingController(rootView: rootView)
        super.init(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 0,
                height: Self.initialHeight(for: role)),
            inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear

        let hostedView = hostingController.view
        hostedView?.backgroundColor = .clear
        if let hostedView {
            addSubview(hostedView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostingController.view.frame = bounds
    }

    func playClick() {
        UIDevice.current.playInputClick()
    }

    private var preferredHeight: CGFloat {
        switch role {
        case .accessory:
            return UIDevice.current.userInterfaceIdiom == .pad ? 56 : 50
        case .keyboard:
            return UIDevice.current.userInterfaceIdiom == .pad ? 360 : 244
        }
    }

    private static func initialHeight(for role: Role) -> CGFloat {
        switch role {
        case .accessory:
            UIDevice.current.userInterfaceIdiom == .pad ? 56 : 50
        case .keyboard:
            UIDevice.current.userInterfaceIdiom == .pad ? 360 : 244
        }
    }
}

private struct TerminalKeyboardAccessory: View {
    @Bindable var session: TerminalKeyboardSession

    var body: some View {
        HStack(spacing: 12) {
            Picker(
                "Keyboard Mode",
                selection: Binding(
                    get: { session.state.mode },
                    set: { session.selectMode($0) })
            ) {
                Text("Input Method").tag(TerminalKeyboardMode.inputMethod)
                Text("Terminal Keyboard").tag(TerminalKeyboardMode.terminal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                session.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Keyboard")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }
}

private struct TerminalKeyboardView: View {
    @Bindable var session: TerminalKeyboardSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            controlRow

            TabView(
                selection: Binding(
                    get: { session.state.page },
                    set: { session.selectPage($0) })
            ) {
                ForEach(TerminalKeyboardPage.allCases, id: \.self) { page in
                    TerminalKeyboardPageView(page: page, session: session)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let translation = value.translation
                        guard abs(translation.width) > abs(translation.height) else { return }

                        let projectedWidth = value.predictedEndTranslation.width
                        guard abs(projectedWidth) >= 80 else { return }
                        session.movePage(by: projectedWidth < 0 ? 1 : -1)
                    })
            .accessibilityLabel("Terminal keyboard pages")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    session.movePage(by: 1)
                case .decrement:
                    session.movePage(by: -1)
                @unknown default:
                    break
                }
            }

            HStack(spacing: 8) {
                ForEach(TerminalKeyboardPage.allCases, id: \.self) { page in
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            session.selectPage(page)
                        }
                    } label: {
                        Circle()
                            .fill(
                                session.state.page == page
                                    ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                            .frame(width: 44, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        page == .typing ? "Typing keyboard page" : "Navigation keyboard page")
                    .accessibilityAddTraits(
                        session.state.page == page ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color(uiColor: .systemGray6))
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            ForEach(TerminalModifier.allCases, id: \.self) { modifier in
                TerminalModifierButton(modifier: modifier, session: session)
            }
            TerminalKeyButton(key: .escape, session: session)
            TerminalKeyButton(key: .tab, session: session)
        }
        .frame(maxHeight: 42)
    }
}

private struct TerminalKeyboardPageView: View {
    let page: TerminalKeyboardPage
    let session: TerminalKeyboardSession

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(page.rows.enumerated()), id: \.offset) { _, row in
                TerminalKeyboardRow(keys: row, session: session)
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
    }
}

private struct TerminalKeyboardRow: View {
    let keys: [TerminalKey]
    let session: TerminalKeyboardSession

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 5
            let totalWeight = keys.reduce(0) { $0 + $1.width }
            let usableWidth = geometry.size.width - spacing * CGFloat(max(0, keys.count - 1))

            HStack(spacing: spacing) {
                ForEach(keys, id: \.id) { key in
                    TerminalKeyButton(key: key, session: session)
                        .frame(width: usableWidth * key.width / totalWeight)
                }
            }
        }
    }
}

private struct TerminalModifierButton: View {
    let modifier: TerminalModifier
    let session: TerminalKeyboardSession

    var body: some View {
        Button {
            session.tapModifier(modifier)
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if phase == .locked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                }
            }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(TerminalKeyButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(phase == .inactive ? [] : .isSelected)
    }

    private var phase: TerminalModifierPhase {
        session.state.phase(of: modifier)
    }

    private var label: String {
        switch modifier {
        case .control: "Ctrl"
        case .shift: "Shift"
        case .alt: "Alt"
        }
    }

    private var background: Color {
        switch phase {
        case .inactive: Color(uiColor: .tertiarySystemBackground)
        case .armed: Color.accentColor.opacity(0.65)
        case .locked: Color.accentColor
        }
    }

    private var accessibilityValue: String {
        switch phase {
        case .inactive: "Off"
        case .armed: "Applies to the next key"
        case .locked: "Locked"
        }
    }
}

private struct TerminalKeyButton: View {
    let key: TerminalKey
    let session: TerminalKeyboardSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    var body: some View {
        if key.isRepeatable {
            keyCap
                .brightness(isPressed ? -0.08 : 0)
                .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.08),
                    value: isPressed)
                .contentShape(Rectangle())
                .onLongPressGesture(
                    minimumDuration: .infinity,
                    maximumDistance: 20,
                    pressing: { isPressing in
                        isPressed = isPressing
                        if isPressing {
                            session.beginRepeating(key)
                        } else {
                            session.endRepeating()
                        }
                    },
                    perform: {})
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { session.press(key) }
        } else {
            Button {
                session.press(key)
            } label: {
                keyCap
            }
            .buttonStyle(TerminalKeyButtonStyle())
        }
    }

    private var keyCap: some View {
        keyLabel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(uiColor: .tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var keyLabel: some View {
        switch key {
        case .character(let base, let shifted):
            if base == " " {
                Text("Space")
                    .font(.callout)
            } else if base.isLetter {
                Text(String(base).uppercased())
                    .font(.title3)
            } else {
                HStack(spacing: 2) {
                    Text(String(base))
                    Text(String(shifted))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .minimumScaleFactor(0.65)
            }
        case .backspace:
            Image(systemName: "delete.left")
        case .up:
            Image(systemName: "arrow.up")
        case .down:
            Image(systemName: "arrow.down")
        case .left:
            Image(systemName: "arrow.left")
        case .right:
            Image(systemName: "arrow.right")
        default:
            Text(textLabel)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var textLabel: String {
        switch key {
        case .escape: "Esc"
        case .tab: "Tab"
        case .enter: "Enter"
        case .insert: "Insert"
        case .delete: "Delete"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .function(let function): "F\(function.rawValue)"
        case .character, .backspace, .up, .down, .left, .right: ""
        }
    }

    private var accessibilityLabel: String {
        switch key {
        case .character(let base, _):
            base == " " ? "Space" : String(base)
        case .backspace: "Backspace"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        default: textLabel
        }
    }
}

private struct TerminalKeyButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed)
    }
}

private extension Character {
    var isLetter: Bool {
        unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }
}

extension SizeReportingTerminalView {
    func installTerminalKeyboard() {
        guard terminalKeyboardHost == nil else { return }
        terminalKeyboardHost = TerminalKeyboardHost(terminalView: self)
    }

    fileprivate func sendTerminalKey(
        _ key: TerminalKey,
        modifiers: Set<TerminalModifier>
    ) {
        let terminal = getTerminal()
        let context = TerminalKeyEncodingContext(
            kittyFlags: terminal.keyboardEnhancementFlags,
            applicationCursor: terminal.applicationCursor,
            backspaceSendsControlH: backspaceSendsControlH)
        let data = TerminalKeyEncoder.encode(key, modifiers: modifiers, context: context)
        onTerminalKeyboardSend?(data)
    }
}
