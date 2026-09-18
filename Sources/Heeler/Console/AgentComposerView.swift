import SwiftUI
import UIKit

enum AgentComposerKeyboardPresentation: Equatable {
    case hidden
    case system
    case tools

    /// The tools dock follows the Keys dock's responder policy; see
    /// `TerminalKeyboardMode.controlsReleaseFirstResponder`.
    @MainActor static var toolsDockReleasesFocus: Bool {
        TerminalKeyboardMode.controlsReleaseFirstResponder
    }
}

struct AgentComposerKeyboardLayout: Equatable {
    /// Used only when `lastPresentedHeight` is still zero. Any positive
    /// measurement is the tools footprint as-is, even when it is shorter
    /// than this value.
    static let minimumToolsHeight: CGFloat = 260

    let contentInset: CGFloat
    let availableToolsHeight: CGFloat

    /// `softwareKeyboardDismissed` releases the `.system` pin once the
    /// software keyboard really left while focus stayed (a hardware keyboard
    /// attached); see ``TerminalKeyboardInset/isSoftwareKeyboardDismissed``.
    init(
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat,
        presentation: AgentComposerKeyboardPresentation,
        softwareKeyboardDismissed: Bool = false
    ) {
        switch presentation {
        case .hidden:
            availableToolsHeight = lastPresentedHeight
            contentInset = currentHeight
        case .system:
            availableToolsHeight = lastPresentedHeight
            // The pin bridges transient dips (Tools→iOS pre-show, input-view
            // swaps), never a confirmed dismissal.
            contentInset =
                softwareKeyboardDismissed
                ? currentHeight : max(currentHeight, lastPresentedHeight)
        case .tools:
            // Only the unmeasured path may invent a height. A positive
            // measurement, including compact landscape footprints below
            // `minimumToolsHeight`, is the tools dock's exact size.
            let toolsHeight =
                lastPresentedHeight > 0
                ? lastPresentedHeight : Self.minimumToolsHeight
            availableToolsHeight = toolsHeight
            contentInset = toolsHeight
        }
    }
}

struct AgentComposerActions {
    let canBegin: Bool
    let attachLinkCount: Int
    let addImage: () -> Void
    let addFile: () -> Void
    let showAttachLinks: () -> Void
    let openTerminal: (() -> Void)?
    let isOpeningTerminal: Bool
    let startAgent: () -> Void
    let manageSnippets: () -> Void
    /// Opens the explicit Skill picker. Nil for agent kinds without a skills
    /// source catalog, which hides the More-menu entry entirely rather than
    /// offering a dead button.
    let showSkills: (() -> Void)?
    let showWorktreeDetails: (() -> Void)?
    let renameAgent: () -> Void
    let renameWorkspace: () -> Void
    let closeAgent: () -> Void
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
/// stays on device; Send emits one `agent.prompt` request except when Agent
/// Status is Blocked, in which case it inserts the draft into Attach without
/// Enter and presents the tools keyboard. Explicit tool-keyboard controls
/// send terminal sequences through Attach.
struct AgentComposerView: View {
    let store: AgentComposerStore
    let status: AgentStatus
    /// Read-only projection of the Host's own connection telemetry; nil
    /// whenever there is nothing proven to show.
    let hostTelemetry: HostTelemetryPresentation?
    /// The terminal theme's luminance, not the system appearance. The status
    /// row sits directly on the themed terminal surface, so hierarchical
    /// styles and the status inks must resolve against that background — a
    /// dark theme under a light system otherwise renders light-mode grays
    /// into near-black and the row disappears.
    let chromeColorScheme: ColorScheme
    let switcher: TerminalAgentSwitcher
    let keyboardHandoff: TerminalKeyboardHandoff
    /// False for the placeholder Agent detail builds before its retained
    /// terminal is prepared: that instance is torn down a moment later, and
    /// spending the one-shot handoff there would leave the real screen
    /// without it. See `AgentDetailView.prepareRetainedAgent`.
    var inheritsKeyboardHandoff = true
    let keyboardHeight: CGFloat
    let actions: AgentComposerActions
    /// Anchors the Attach Links list to the link chip that opens it.
    let attachLinksPopover: AttachLinksPopover
    /// The screen's one Skills store, shared with the tools keyboard and the
    /// explicit picker. Nil for kinds without a skills source catalog, which
    /// disables inline suggestions.
    let skills: SkillsPaneStore?
    @Binding var keyboardPresentation: AgentComposerKeyboardPresentation
    let prepareKeyboardPresentation: (AgentComposerKeyboardPresentation) -> Void
    /// Optional Hide Composer control on the switcher trail.
    var modeControl: TerminalAgentSwitcherModeControl? = nil
    var keyboardHandoffID: UUID?
    var isKeyboardHandoffCurrent: (UUID) -> Bool = { _ in false }
    var onFirstResponderRequest: (UUID, Bool) -> Void = { _, _ in }
    var onKeyboardHandoffSettled: (UUID) -> Void = { _ in }
    /// Drop is Composer-only. Defaults to Composer so existing call sites stay
    /// a drop target; Direct Input must pass `.direct` to keep this inert.
    var inputMode: AgentInputMode = .composer
    @State private var isInputFocused = false
    /// An explicit dismissal hides suggestions for the current trigger token;
    /// removing the token arms them again.
    @State private var isSuggestionsDismissed = false
    @State private var isDropTargeted = false

    private var isToolsKeyboardPresented: Bool {
        keyboardPresentation == .tools
    }

    private var toolsDockReleasesFocus: Bool {
        AgentComposerKeyboardPresentation.toolsDockReleasesFocus
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                AgentDetailStatusChrome(
                    status: status,
                    hostTelemetry: hostTelemetry,
                    chromeColorScheme: chromeColorScheme)

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let skills, let trigger = suggestionTrigger,
                            isInputFocused, !isSuggestionsDismissed
                        {
                            AgentComposerSkillSuggestions(
                                skills: skills,
                                trigger: trigger,
                                onSelect: { skill in
                                    store.replaceTrailingToken(
                                        trigger.token, with: skill.insertionText)
                                },
                                onDismiss: { isSuggestionsDismissed = true })
                        }
                        ZStack(alignment: .topLeading) {
                            AgentComposerTextEditor(
                                text: store.draft,
                                selectedRange: store.draftSelection,
                                onEdit: { store.applyEditorDraft($0, selection: $1) },
                                isFocused: $isInputFocused,
                                keyboardPresentation: keyboardPresentation,
                                keyboardHandoffID: keyboardHandoffID,
                                isKeyboardHandoffCurrent: isKeyboardHandoffCurrent,
                                onFirstResponderRequest: onFirstResponderRequest,
                                onKeyboardHandoffSettled: onKeyboardHandoffSettled)
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
                                        Task { await deliverDraft { await store.retry(failure.id) } }
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
                                AgentActionMenuContent(
                                    actions: actions,
                                    sections: AgentActionMenuPolicy.composerAddSections)
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
                                AgentActionMenuContent(
                                    actions: actions,
                                    sections: AgentActionMenuPolicy.composerMoreSections)
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
                                .modifier(attachLinksPopover)
                            }

                            Spacer(minLength: 0)
                            if store.hasPendingDroppedImages {
                                Text(store.sendAccessibilityHint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .accessibilityHidden(true)
                            }
                            AgentComposerSendButton(
                                isEnabled: store.canSend,
                                accessibilityHint: store.sendAccessibilityHint
                            ) {
                                Task { await deliverDraft { await store.send() } }
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
                        switchKeyboard: keyboardSwitchAction,
                        modeControl: modeControl)
                }
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.accentColor.opacity(dropHighlight.fillOpacity))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(composerCardStroke, lineWidth: dropHighlight.strokeWidth)
                }
                .composerDropDestination(
                    isEnabled: ComposerDropPolicy.acceptsDrops(in: inputMode),
                    isTargeted: $isDropTargeted,
                    accept: { store.acceptDrop($0) }
                )
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)

        }
        .modifier(ConsoleComposerCommandRegistration(
            agentID: switcher.selectedID,
            isFocused: isInputFocused,
            hasDraft: { store.canSend },
            send: { await deliverDraft { await store.send() } }))
        .onAppear {
            guard inheritsKeyboardHandoff,
                  let selectedID = switcher.selectedID,
                  keyboardHandoff.consume(selectedID)
            else { return }
            setKeyboardPresentation(.system)
            isInputFocused = true
        }
        .onChange(of: isInputFocused) { _, isFocused in
            if isFocused {
                // A tap into the text while the iPad tools dock is up asks
                // for the system keyboard; on iPhone the dock keeps the caret.
                if keyboardPresentation != .tools || toolsDockReleasesFocus {
                    setKeyboardPresentation(.system)
                }
            } else if !(toolsDockReleasesFocus && keyboardPresentation == .tools) {
                setKeyboardPresentation(.hidden)
            }
        }
        .onChange(of: store.draft) { _, _ in
            guard let skills else { return }
            if suggestionTrigger == nil {
                isSuggestionsDismissed = false
            } else if !isSuggestionsDismissed {
                // Typing the prefix is the pane-selection moment: load once,
                // then reuse (the ConsoleStore caches underneath).
                Task { await skills.loadIfNeeded() }
            }
        }
    }

    /// The invocation token at the end of the draft, when this agent has
    /// skill sources at all. Prefixes ride the skills and their catalog, not
    /// the Composer.
    private var suggestionTrigger: SkillSuggestionTrigger? {
        guard let skills else { return nil }
        return SkillSuggestionTrigger.detect(
            draft: store.draft, prefixes: skills.triggerPrefixes)
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
            isInputFocused = expectsSystemKeyboard || !toolsDockReleasesFocus
        }
    }

    private func setKeyboardPresentation(_ presentation: AgentComposerKeyboardPresentation) {
        guard presentation != keyboardPresentation else { return }
        prepareKeyboardPresentation(presentation)
        keyboardPresentation = presentation
    }

    /// Blocked delivery types into Attach without Enter; the tools keyboard
    /// is what submits or cancels.
    private func deliverDraft(
        _ deliver: () async -> AgentComposerStore.SendResult
    ) async {
        let result = await deliver()
        guard result == .deliveredViaAttach else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            setKeyboardPresentation(.tools)
            isInputFocused = !toolsDockReleasesFocus
        }
    }

    private var focusPreservingSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: switcher.items,
            selectedID: switcher.selectedID,
            onSelect: { id in
                if isInputFocused {
                    keyboardHandoff.arm(for: id)
                }
                switcher.onSelect(id)
            },
            onTogglePin: switcher.onTogglePin)
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

    private var dropHighlight: ComposerDropHighlight {
        ComposerDropHighlight(isTargeted: isDropTargeted)
    }

    private var composerCardStroke: Color {
        dropHighlight.usesAccentStroke
            ? Color.accentColor.opacity(0.72)
            : Color.secondary.opacity(0.16)
    }

}

/// The inline suggestion menu above the Composer's text area: the Skills the
/// typed trigger token matches, or the load in progress behind them. Selecting
/// a row swaps the token for the full invocation in the draft — nothing is
/// sent. Renders nothing when a loaded catalogue has no match, so prose that
/// happens to contain a prefix is not nagged.
private struct AgentComposerSkillSuggestions: View {
    let skills: SkillsPaneStore
    let trigger: SkillSuggestionTrigger
    let onSelect: (AgentSkill) -> Void
    let onDismiss: () -> Void
    /// The suggestion list's measured content height. The scroll view is
    /// sized to it so one match does not reserve the full cap of empty
    /// space; the cap only bounds long lists.
    @State private var listHeight: CGFloat = Self.maximumListHeight

    private static let maximumListHeight: CGFloat = 176

    var body: some View {
        switch skills.phase {
        case .idle, .loading:
            header {
                ProgressView()
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                header {
                    Button("Retry") { Task { await skills.refresh() } }
                        .font(.caption)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .loaded:
            let matches = trigger.matches(in: skills.skills)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header { EmptyView() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { skill in
                                row(for: skill)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            listHeight = height
                        }
                    }
                    .frame(height: min(listHeight, Self.maximumListHeight))
                    .scrollBounceBehavior(.basedOnSize)
                    Divider()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Skill Suggestions")
            }
        }
    }

    private func header(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text("Skills")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            trailing()
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Skill Suggestions")
        }
    }

    private func row(for skill: AgentSkill) -> some View {
        Button {
            onSelect(skill)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.command)
                    .font(.subheadline.weight(.medium))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let description = skill.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skill.name)
        .accessibilityHint("Inserts \(skill.command) without sending it")
    }
}

struct AgentComposerSendButton: View {
    let isEnabled: Bool
    var accessibilityHint: String = "Delivers the complete draft to the Agent"
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
        .accessibilityHint(accessibilityHint)
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
    let text: String
    let selectedRange: NSRange
    let onEdit: (String, NSRange) -> Void
    @Binding var isFocused: Bool
    let keyboardPresentation: AgentComposerKeyboardPresentation
    let keyboardHandoffID: UUID?
    let isKeyboardHandoffCurrent: (UUID) -> Bool
    let onFirstResponderRequest: (UUID, Bool) -> Void
    let onKeyboardHandoffSettled: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, isFocused: $isFocused)
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
        textView.onKeyboardHandoffSettled = onKeyboardHandoffSettled
        return textView
    }

    func updateUIView(_ textView: AgentComposerUITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        if textView.text != text {
            textView.text = text
        }
        if textView.selectedRange != selectedRange {
            textView.selectedRange = selectedRange
        }
        textView.updateKeyboard(presentation: keyboardPresentation)
        textView.onKeyboardHandoffSettled = onKeyboardHandoffSettled
        let shouldFocus = isFocused
        let coordinator = context.coordinator
        coordinator.wantsFocus = shouldFocus
        guard shouldFocus != textView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if shouldFocus {
                if let keyboardHandoffID {
                    guard textView.window != nil,
                          isKeyboardHandoffCurrent(keyboardHandoffID)
                    else {
                        onFirstResponderRequest(keyboardHandoffID, false)
                        return
                    }
                    onFirstResponderRequest(
                        keyboardHandoffID,
                        textView.requestKeyboardHandoff(id: keyboardHandoffID))
                } else {
                    textView.becomeFirstResponder()
                }
            } else {
                // UIKit can flush a pending update from inside
                // `becomeFirstResponder`, after the view is first responder
                // but before `textViewDidBeginEditing` records it. That
                // update's stale `false` must not undo the focus it raced.
                guard !coordinator.wantsFocus else { return }
                _ = textView.resignFirstResponder()
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
        var onEdit: (String, NSRange) -> Void
        /// The latest focus intent, from either SwiftUI or UIKit, so a
        /// deferred focus change can recheck it before acting.
        var wantsFocus = false
        private var isFocused: Binding<Bool>

        init(onEdit: @escaping (String, NSRange) -> Void, isFocused: Binding<Bool>) {
            self.onEdit = onEdit
            self.isFocused = isFocused
        }

        func textViewDidChange(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
        }

        func textViewDidBeginEditing(_: UITextView) {
            wantsFocus = true
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_: UITextView) {
            wantsFocus = false
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
    static var toolsDockReleasesFocus: Bool {
        AgentComposerKeyboardPresentation.toolsDockReleasesFocus
    }

    private lazy var suppressedSoftKeyboard = TerminalSuppressedSoftKeyboardView()
    private var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    var onKeyboardHandoffSettled: ((UUID) -> Void)?
    private var activeKeyboardHandoffID: UUID?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        installKeyboardObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installKeyboardObservers()
    }

    private func installKeyboardObservers() {
        for name: Notification.Name in [
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardFrameDidSettle(_:)),
                name: name,
                object: nil)
        }
    }

    @objc private func keyboardFrameDidSettle(_ notification: Notification) {
        guard isFirstResponder, let window, window.isKeyWindow,
              let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect,
              let guideFrame = TerminalKeyboardInset.keyboardLayoutGuideFrame(in: window)
        else { return }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        guard TerminalKeyboardInset.keyboardFrame(
            frameInWindow,
            matches: guideFrame,
            in: window)
        else { return }
        guard let activeKeyboardHandoffID else { return }
        self.activeKeyboardHandoffID = nil
        onKeyboardHandoffSettled?(activeKeyboardHandoffID)
    }

    @discardableResult
    func requestKeyboardHandoff(id: UUID) -> Bool {
        guard window != nil else { return false }
        activeKeyboardHandoffID = id
        let accepted = becomeFirstResponder()
        if !accepted {
            activeKeyboardHandoffID = nil
        }
        return accepted
    }

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
        // On iPad the tools dock resigns instead (see `toolsDockReleasesFocus`);
        // reloading here would flash the suppressed keyboard's toolbar first.
        if presentation == .tools, Self.toolsDockReleasesFocus { return }
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }
}

struct AgentToolsKeyboard: View {
    /// The screen routes authored text according to the active input mode.
    let insertText: (String) -> Void
    let context: TerminalKeysContext
    let keyboardControl: TerminalKeyboardControl
    let inputMode: AgentInputMode
    let height: CGFloat
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void
    @State private var selectedTab: TerminalKeysTab = .controls

    private var tabs: [TerminalKeysTab] {
        context.tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    if inputMode == .direct {
                        TerminalFullKeyboard(
                            isEnabled: quickKeysEnabled,
                            keyboardControl: keyboardControl,
                            send: sendQuickKey)
                    } else {
                        AgentControlKeyboard(
                            isEnabled: quickKeysEnabled,
                            keyboardControl: keyboardControl,
                            send: sendQuickKey)
                    }
                case .skills:
                    if let skills = context.skills {
                        SkillsKeyboardPane(
                            store: skills.store,
                            onInsert: { skill in
                                insertText(skill.insertionText)
                                selectedTab = .controls
                            },
                            onViewContent: skills.viewContent)
                    }
                case .snippets:
                    SnippetsKeyboardPane(
                        store: context.settings.snippets,
                        onSend: { snippet in
                            insertText(snippet.body)
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
        .clipped()
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
        .onChange(of: selectedTab) { _, tab in
            guard tab == .skills, let skills = context.skills else { return }
            Task { await skills.store.loadIfNeeded() }
        }
    }
}
