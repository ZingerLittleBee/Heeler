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

struct AgentComposerActions {
    let canBegin: Bool
    let attachLinkCount: Int
    let addImage: () -> Void
    let addFile: () -> Void
    let showAttachLinks: () -> Void
    let startAgent: () -> Void
    let manageSnippets: () -> Void
    let renameAgent: () -> Void
    let renameWorkspace: () -> Void
    let closeAgent: () -> Void
    /// Opens the Files surface for this Agent's project root; nil when the
    /// workspace carries no directory identity (no checkout, empty cwd), in
    /// which case the menu simply omits the entry.
    let browseFiles: (() -> Void)?
}

struct AgentComposerLinkPresentation: Equatable {
    let count: Int

    init?(count: Int) {
        guard count > 0 else { return nil }
        self.count = count
    }

    var accessibilityValue: String {
        count == 1 ? "1 distinct link" : "\(count) distinct links"
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
    let keyboardHeight: CGFloat
    let actions: AgentComposerActions
    @Binding var keyboardPresentation: AgentComposerKeyboardPresentation
    let prepareKeyboardPresentation: (AgentComposerKeyboardPresentation) -> Void
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
                                keyboardPresentation: keyboardPresentation)
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

                        HStack(spacing: 8) {
                            Menu {
                                Button("Add Image", systemImage: "photo") {
                                    actions.addImage()
                                }
                                .disabled(!actions.canBegin)
                                Button("Add File", systemImage: "doc") {
                                    actions.addFile()
                                }
                                .disabled(!actions.canBegin)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 18, height: 18)
                                    .accessibilityLabel("Add")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .tint(secondaryActionTint)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityHint("Adds an image or file to the draft")

                            Menu {
                                Section {
                                    Button("New Agent", systemImage: "plus") {
                                        actions.startAgent()
                                    }
                                    Button("Snippets", systemImage: "quote.bubble") {
                                        actions.manageSnippets()
                                    }
                                }
                                Section {
                                    if let browseFiles = actions.browseFiles {
                                        Button("Project Files", systemImage: "folder") {
                                            browseFiles()
                                        }
                                    }
                                }
                                Section {
                                    Button("Rename Agent", systemImage: "pencil") {
                                        actions.renameAgent()
                                    }
                                    Button("Rename Workspace", systemImage: "pencil.line") {
                                        actions.renameWorkspace()
                                    }
                                    Button(
                                        "Close Agent",
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        actions.closeAgent()
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 18, height: 18)
                                    .accessibilityLabel("More")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .tint(secondaryActionTint)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityHint("Opens Agent actions")

                            if let links = linkPresentation {
                                Button {
                                    actions.showAttachLinks()
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "link")
                                        Text("\(links.count)")
                                            .monospacedDigit()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(secondaryActionTint)
                                .font(.footnote.weight(.semibold))
                                .frame(minHeight: 44)
                                .accessibilityLabel("Attach Links")
                                .accessibilityValue(links.accessibilityValue)
                            }

                            Spacer(minLength: 0)
                            AgentComposerSendButton(isEnabled: store.canSend) {
                                Task { await store.send() }
                            }
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
            setKeyboardPresentation(.system)
            isInputFocused = true
        }
        .onChange(of: isInputFocused) { _, isFocused in
            if isFocused {
                if keyboardPresentation != .tools {
                    setKeyboardPresentation(.system)
                }
            } else {
                setKeyboardPresentation(.hidden)
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
            setKeyboardPresentation(.hidden)
            isInputFocused = false
        } else {
            if isInputFocused {
                setKeyboardPresentation(.hidden)
                isInputFocused = false
            } else {
                setKeyboardPresentation(.system)
                isInputFocused = true
            }
        }
    }

    private func switchKeyboard() {
        let expectsSystemKeyboard = isToolsKeyboardPresented
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            setKeyboardPresentation(expectsSystemKeyboard ? .system : .tools)
            isInputFocused = true
        }
    }

    private func setKeyboardPresentation(_ presentation: AgentComposerKeyboardPresentation) {
        guard presentation != keyboardPresentation else { return }
        prepareKeyboardPresentation(presentation)
        keyboardPresentation = presentation
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

    private var linkPresentation: AgentComposerLinkPresentation? {
        AgentComposerLinkPresentation(count: actions.attachLinkCount)
    }

    private var secondaryActionTint: Color {
        Color(uiColor: .label).opacity(0.72)
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

struct AgentComposerSendButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(AgentComposerSendButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Send")
        .accessibilityHint("Delivers the complete draft to the Agent")
    }
}

private struct AgentComposerSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                Color(uiColor: isEnabled ? .systemBackground : .secondaryLabel))
            .frame(width: 32, height: 32)
            .background(
                isEnabled
                    ? Color(uiColor: .label)
                    : Color(uiColor: .label).opacity(0.12),
                in: Circle())
            .frame(width: 44, height: 44)
            .opacity(configuration.isPressed && isEnabled ? 0.72 : 1)
            .contentShape(.circle)
    }
}

private struct AgentComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let keyboardPresentation: AgentComposerKeyboardPresentation

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
        textView.updateKeyboard(presentation: keyboardPresentation)
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

/// Keeps the Composer first-responder while switching between the system
/// keyboard and an app-owned tools dock. Tools mode suppresses UIKit's soft
/// keyboard with a zero-height input view; the dock already occupies the
/// measured keyboard footprint behind it, so removing the candidate row never
/// exposes an intermediate gap.
final class AgentComposerUITextView: UITextView {
    private lazy var suppressedSoftKeyboard = AgentSuppressedSoftKeyboardView()
    private var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden

    func updateKeyboard(presentation: AgentComposerKeyboardPresentation) {
        guard presentation != keyboardPresentation else { return }
        keyboardPresentation = presentation
        let previousInputView = inputView
        switch presentation {
        case .hidden, .tools:
            inputView = suppressedSoftKeyboard
        case .system:
            inputView = nil
        }
        guard isFirstResponder, inputView !== previousInputView else { return }
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }
}

final class AgentSuppressedSoftKeyboardView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 0)
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
