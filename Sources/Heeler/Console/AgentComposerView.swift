import SwiftUI
import UIKit

enum AgentComposerKeyboardPresentation: Equatable {
    case hidden
    case system
    case tools
}

struct AgentComposerKeyboardLayout: Equatable {
    let contentInset: CGFloat
    let availableToolsHeight: CGFloat

    init(
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat,
        presentation: AgentComposerKeyboardPresentation
    ) {
        availableToolsHeight = lastPresentedHeight
        switch presentation {
        case .hidden:
            contentInset = currentHeight
        case .system:
            contentInset = max(currentHeight, lastPresentedHeight)
        case .tools:
            contentInset = lastPresentedHeight
        }
    }
}

/// The native, local-first input surface beneath the live terminal. Drafting
/// stays on device; Send emits one `agent.prompt` request, while explicit
/// tool-keyboard controls send terminal sequences through Attach.
struct AgentComposerView: View {
    let store: AgentComposerStore
    let status: AgentStatus
    let switcher: TerminalAgentSwitcher
    let keyboardHandoff: TerminalKeyboardHandoff
    let keysContext: TerminalKeysContext
    let keyboardHeight: CGFloat
    @Binding var keyboardPresentation: AgentComposerKeyboardPresentation
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void
    @State private var isInputFocused = false

    private var isToolsKeyboardPresented: Bool {
        keyboardPresentation == .tools
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                statusLabel
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            AgentComposerTextEditor(
                                text: Binding(
                                    get: { store.draft },
                                    set: { store.replaceDraft(with: $0) }),
                                isFocused: $isInputFocused,
                                keyboardPresentation: keyboardPresentation,
                                keyboardHeight: keyboardHeight,
                                store: store,
                                context: keysContext,
                                quickKeysEnabled: quickKeysEnabled,
                                sendQuickKey: sendQuickKey)
                            if store.draft.isEmpty {
                                Text("Message Agent")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(minHeight: 36, alignment: .topLeading)
                        .accessibilityElement(children: .contain)

                        if let failure = latestFailure {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(failure.detail, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Button("Retry") {
                                        Task { await store.retry(failure.id) }
                                    }
                                    Button("Edit Draft") {
                                        store.withdrawToDraft(failure.id)
                                        isInputFocused = true
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Button("Send", systemImage: "arrow.up") {
                                Task { await store.send() }
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(!store.canSend)
                            .accessibilityHint("Delivers the complete draft to the Agent")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    TerminalAgentSwitcherRow(
                        switcher: focusPreservingSwitcher,
                        isKeyboardUp: isKeyboardPresented,
                        toggleKeyboard: dismissOrPresentKeyboard,
                        isToolsKeyboardPresented: isToolsKeyboardPresented,
                        switchKeyboard: keyboardSwitchAction)
                }
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.secondary.opacity(0.16), lineWidth: 1)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)

        }
        .onAppear {
            guard let selectedID = switcher.selectedID,
                  keyboardHandoff.consume(selectedID)
            else { return }
            keyboardPresentation = .system
            isInputFocused = true
        }
        .onChange(of: isInputFocused) { _, isFocused in
            if isFocused {
                if keyboardPresentation != .tools {
                    keyboardPresentation = .system
                }
            } else {
                keyboardPresentation = .hidden
            }
        }
    }

    private var isKeyboardPresented: Bool {
        isInputFocused || isToolsKeyboardPresented
    }

    private var keyboardSwitchAction: (() -> Void)? {
        guard keyboardHeight > 0 else { return nil }
        return { switchKeyboard() }
    }

    private func dismissOrPresentKeyboard() {
        if isToolsKeyboardPresented {
            keyboardPresentation = .hidden
            isInputFocused = false
        } else {
            isInputFocused.toggle()
        }
    }

    private func switchKeyboard() {
        let expectsSystemKeyboard = isToolsKeyboardPresented
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if expectsSystemKeyboard {
                keyboardPresentation = .system
            } else {
                keyboardPresentation = .tools
            }
            isInputFocused = true
        }
    }

    private var focusPreservingSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: switcher.items,
            selectedID: switcher.selectedID
        ) { id in
            if isInputFocused {
                keyboardHandoff.arm(for: id)
            }
            switcher.onSelect(id)
        }
    }

    private var latestFailure: (id: AgentComposerStore.Message.ID, detail: String)? {
        guard let message = store.messages.last,
              case .failed(let detail) = message.state
        else { return nil }
        return (message.id, detail)
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(status.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(status.rawValue.capitalized)
    }
}

private struct AgentComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let keyboardPresentation: AgentComposerKeyboardPresentation
    let keyboardHeight: CGFloat
    let store: AgentComposerStore
    let context: TerminalKeysContext
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> AgentComposerUITextView {
        let textView = AgentComposerUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = "Message the Agent"
        return textView
    }

    func updateUIView(_ textView: AgentComposerUITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.updateKeyboard(
            presentation: keyboardPresentation,
            // `TerminalKeyboardInset` excludes the Home Indicator from its
            // overlap. A custom input view owns that safe area too, so add it
            // back to match UIKit's complete keyboard window footprint.
            height: keyboardHeight + (textView.window?.safeAreaInsets.bottom ?? 0),
            store: store,
            context: self.context,
            quickKeysEnabled: quickKeysEnabled,
            sendQuickKey: sendQuickKey)
        let shouldFocus = isFocused
        guard shouldFocus != textView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if shouldFocus {
                textView.becomeFirstResponder()
            } else {
                textView.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AgentComposerUITextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maximumHeight = lineHeight * 5
            + uiView.textContainerInset.top
            + uiView.textContainerInset.bottom
        let height = min(max(36, measured.height), maximumHeight)
        uiView.isScrollEnabled = measured.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_: UITextView) {
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_: UITextView) {
            isFocused.wrappedValue = false
        }
    }
}

/// Owns both keyboard implementations. `reloadInputViews()` replaces them in
/// UIKit's keyboard window without resigning first responder, so neither the
/// Composer nor Ghostty participates in a keyboard hide/show layout cycle.
final class AgentComposerUITextView: UITextView {
    private var toolsInputView: AgentToolsInputView?
    private var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    private lazy var systemKeyboardAccessory = AgentComposerKeyboardAccessory(target: self)

    func updateKeyboard(
        presentation: AgentComposerKeyboardPresentation,
        height: CGFloat,
        store: AgentComposerStore,
        context: TerminalKeysContext,
        quickKeysEnabled: Bool,
        sendQuickKey: @escaping (AgentQuickKey) -> Void
    ) {
        guard presentation != keyboardPresentation else {
            toolsInputView?.update(
                height: height,
                store: store,
                context: context,
                quickKeysEnabled: quickKeysEnabled,
                sendQuickKey: sendQuickKey)
            return
        }
        keyboardPresentation = presentation
        switch presentation {
        case .tools:
            let toolsInputView = AgentToolsInputView(
                height: height,
                store: store,
                context: context,
                quickKeysEnabled: quickKeysEnabled,
                sendQuickKey: sendQuickKey)
            self.toolsInputView = toolsInputView
            inputView = toolsInputView
            inputAccessoryView = nil
        case .hidden, .system:
            toolsInputView = nil
            inputView = nil
            inputAccessoryView = systemKeyboardAccessory
        }
        guard isFirstResponder else { return }
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }
}

/// Keeps the iOS keyboard at its complete paste-row height even when the
/// pasteboard has no compatible item. The tools keyboard replaces this row as
/// part of its single full-height input view, so the two heights do not stack.
final class AgentComposerKeyboardAccessory: UIInputView {
    static let preferredHeight: CGFloat = 48
    private static let surface = UIColor.secondarySystemBackground
    private weak var target: AgentComposerUITextView?
    private(set) lazy var pasteControl: UIPasteControl = {
        var configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Self.surface
        configuration.baseForegroundColor = .label
        let control = UIPasteControl(configuration: configuration)
        control.target = target
        control.accessibilityLabel = "Paste"
        return control
    }()

    init(target: AgentComposerUITextView) {
        self.target = target
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.preferredHeight),
            inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = Self.surface

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pasteControl)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(
                equalToConstant: 1 / max(traitCollection.displayScale, 1)),
            pasteControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pasteControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            pasteControl.widthAnchor.constraint(equalToConstant: 44),
            pasteControl.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }
}

/// The tools surface presented as the Composer's custom keyboard.
final class AgentToolsInputView: UIInputView {
    private var keyboardHeight: CGFloat
    private let host: UIHostingController<AgentToolsKeyboard>

    init(
        height: CGFloat,
        store: AgentComposerStore,
        context: TerminalKeysContext,
        quickKeysEnabled: Bool,
        sendQuickKey: @escaping (AgentQuickKey) -> Void
    ) {
        keyboardHeight = height
        host = UIHostingController(
            rootView: AgentToolsKeyboard(
                store: store,
                context: context,
                height: height,
                quickKeysEnabled: quickKeysEnabled,
                sendQuickKey: sendQuickKey))
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: height),
            inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .systemBackground
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight)
    }

    func update(
        height: CGFloat,
        store: AgentComposerStore,
        context: TerminalKeysContext,
        quickKeysEnabled: Bool,
        sendQuickKey: @escaping (AgentQuickKey) -> Void
    ) {
        let heightChanged = height != keyboardHeight
        keyboardHeight = height
        host.rootView = AgentToolsKeyboard(
            store: store,
            context: context,
            height: height,
            quickKeysEnabled: quickKeysEnabled,
            sendQuickKey: sendQuickKey)
        if heightChanged {
            invalidateIntrinsicContentSize()
        }
    }
}

struct AgentToolsKeyboard: View {
    let store: AgentComposerStore
    let context: TerminalKeysContext
    let height: CGFloat
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void
    @State private var selectedTab: TerminalKeysTab = .controls

    private var tabs: [TerminalKeysTab] {
        TerminalKeysTab.allCases.filter {
            $0 != .skills || context.skills != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    AgentQuickKeyPad(
                        isEnabled: quickKeysEnabled,
                        send: sendQuickKey)
                case .skills:
                    if let skills = context.skills {
                        SkillsKeyboardPane(
                            store: skills.store,
                            onInsert: { skill in
                                store.insertIntoDraft(skill.insertionText)
                                selectedTab = .controls
                            },
                            onViewContent: skills.viewContent)
                    }
                case .snippets:
                    SnippetsKeyboardPane(
                        store: context.settings.snippets,
                        onSend: { snippet in
                            store.insertIntoDraft(snippet.body)
                            selectedTab = .controls
                        },
                        onManage: context.manageSnippets)
                case .appearance:
                    TerminalAppearancePane(
                        themes: context.settings.themes,
                        zoom: context.settings.zoom,
                        fonts: context.settings.fonts)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Image(systemName: tab.systemImageName)
                            .font(.body)
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                selectedTab == tab ? Color(uiColor: .secondarySystemFill) : .clear,
                                in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.accessibilityLabel)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
        .frame(height: height)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
        .onChange(of: selectedTab) { _, tab in
            guard tab == .skills, let skills = context.skills else { return }
            Task { await skills.store.loadIfNeeded() }
        }
    }
}

private struct AgentQuickKeyPad: View {
    let isEnabled: Bool
    let send: (AgentQuickKey) -> Void

    private static let rows: [[AgentQuickKey]] = [
        [.escape, .tab, .shiftTab],
        [.left, .up, .right],
        [.backspace, .down, .enter],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 8) {
                    ForEach(Self.rows[rowIndex], id: \.self) { key in
                        Button {
                            send(key)
                        } label: {
                            keyLabel(for: key)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .background(
                            Color(uiColor: .secondarySystemFill),
                            in: .rect(cornerRadius: 8))
                        .disabled(!isEnabled)
                        .opacity(isEnabled ? 1 : 0.45)
                        .accessibilityLabel(key.accessibilityLabel)
                        .accessibilityHint("Sends this key directly to the Agent")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func keyLabel(for key: AgentQuickKey) -> some View {
        if let systemImageName = key.systemImageName {
            Image(systemName: systemImageName)
                .font(.system(size: 13, weight: .medium))
        } else if let title = key.title {
            Text(title)
                .font(.caption.weight(.medium))
        }
    }
}
