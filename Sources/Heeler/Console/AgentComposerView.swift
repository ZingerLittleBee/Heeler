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

/// Pulling the Composer's grabber down to hide the keyboard. The system's
/// interactive dismissal belongs to scroll views and starts only once the
/// finger reaches the keyboard, a whole card away from here. So the grabber
/// alone follows the finger, against growing resistance, and the keyboard
/// goes the moment the pull is long enough, without waiting for the release.
enum AgentComposerKeyboardPull {
    /// The grabber's touch area: it reaches this far above the card, into
    /// the gap under the status line, and stops short of the input's text.
    static let touchOverhang: CGFloat = 6
    static let touchHeight: CGFloat = 22
    /// Narrower than the card, clear of the screen edge's back gesture.
    static let touchWidth: CGFloat = 160

    private static let hidingDistance: CGFloat = 44
    private static let flickDistance: CGFloat = 120
    /// How far the grabber could go, however long the pull.
    private static let travel: CGFloat = 18
    /// `UIScrollView`'s rubber-band coefficient.
    private static let resistance: CGFloat = 0.55

    /// Downward only, each point of the finger moving the grabber less.
    static func grabberOffset(translation: CGFloat) -> CGFloat {
        let pull = max(0, translation)
        return (1 - 1 / (pull * resistance / travel + 1)) * travel
    }

    static func reachesHidingDistance(translation: CGFloat) -> Bool {
        translation >= hidingDistance
    }

    /// A release short of the distance that was still heading down fast.
    static func isFlickDown(translation: CGFloat, predictedTranslation: CGFloat) -> Bool {
        translation > 0 && predictedTranslation >= flickDistance
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
    /// Opens the Changes of the Checkout containing the Agent's directory.
    /// Nil when the Agent has no directory, which hides the entry; it is
    /// never gated on the Agent's worktree metadata.
    let showChanges: (() -> Void)?
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
    /// Leaves the Agent: back to the Console list, or out to the sidebar
    /// beside a regular-width detail column.
    let backToConsole: () -> Void
    /// Swaps the detail to Chat or back to the Agent terminal. Nil hides the
    /// entry: the surface already showing it, or an Agent without Chat.
    var showChat: (() -> Void)? = nil
    var showAgentTerminal: (() -> Void)? = nil
    /// Close Agent's confirmation, set only on the More menu that is on
    /// screen so the dialog has a single anchor.
    var closeConfirmation: AgentCloseConfirmation? = nil
}

/// Close Agent's confirmation, hung off the More button that asked for it:
/// on iOS 26 the dialog is a popover, and anchored to the whole Agent screen
/// its arrow pointed at nothing in the middle of the terminal.
struct AgentCloseConfirmation {
    let title: String
    let isPresented: Binding<Bool>
    let close: () -> Void
}

extension View {
    @ViewBuilder
    func agentCloseConfirmation(_ confirmation: AgentCloseConfirmation?) -> some View {
        if let confirmation {
            confirmationDialog(
                "Close \(confirmation.title)?",
                isPresented: confirmation.isPresented,
                titleVisibility: .visible
            ) {
                Button("Close Agent", role: .destructive) { confirmation.close() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This closes the pane on the Host and removes the agent everywhere. "
                        + "This can't be undone.")
            }
        } else {
            self
        }
    }
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
/// send terminal sequences through Attach. While the Agent is Working and
/// the draft is blank, Send becomes Stop (`AgentComposerStopStore`).
struct AgentComposerView: View {
    let store: AgentComposerStore
    let status: AgentStatus
    /// Read-only projection of the Host's own connection telemetry; nil
    /// whenever there is nothing proven to show.
    let hostTelemetry: HostTelemetryPresentation?
    /// The Agent's Checkout totals for the status row.
    var changes: AgentDetailChanges? = nil
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
    /// How Send, Retry and ⌘↩ deliver. Chat passes its own.
    var sendPolicy: ComposerDeliveryPolicy = .terminal
    /// Chat's `/` menu, in place of the inline Skill suggestions; nil
    /// outside Chat.
    var commandMenu: [ChatCommand]? = nil
    /// Offered beside a refusal the terminal can carry out.
    var openAgentTerminal: (() -> Void)? = nil
    /// Shown in the input's place, above the switcher: Chat's Blocked card.
    var inputReplacement: AnyView? = nil
    /// Bumped to put the caret in the input.
    var focusRequest = 0
    /// Chat folds the input to one line while the keyboard is down; see
    /// `AgentComposerCollapse`. The terminal keeps its height, since every
    /// fold would resize the PTY, so each surface says which it wants.
    let collapsesWithoutKeyboard: Bool
    /// Focus has left but the keyboard has not started down. The fold waits, so
    /// that it and the keyboard move the conversation as one motion.
    var keyboardIsLeaving = false
    /// What Stop presses in the Agent's program, its wait and its hint; nil
    /// keeps Send.
    var interrupt: AgentComposerInterrupt? = nil
    @State private var isInputFocused = false
    /// An explicit dismissal hides suggestions for the current trigger token;
    /// removing the token arms them again.
    @State private var isSuggestionsDismissed = false
    @State private var isDropTargeted = false
    /// The finger's travel from where it took the grabber.
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.35, bounce: 0.4)))
    private var keyboardPull: CGFloat = 0

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
                    changes: changes,
                    chromeColorScheme: chromeColorScheme)

                VStack(spacing: 0) {
                    inputArea
                        .modifier(ComposerInputReplacement(replacement: inputReplacement))
                        .padding(inputAreaInsets)

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
                .overlay(alignment: .top) { keyboardGrabber }
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
            send: { await deliverDraft { await store.send(policy: sendPolicy) } }))
        .onAppear {
            guard inheritsKeyboardHandoff,
                  let selectedID = switcher.selectedID,
                  keyboardHandoff.consume(selectedID)
            else { return }
            setKeyboardPresentation(.system)
            isInputFocused = true
        }
        .onChange(of: focusRequest) { _, _ in
            // A card still in the input's place keeps the keyboard down.
            if inputReplacement == nil { isInputFocused = true }
        }
        .onChange(of: isInputFocused) { _, isFocused in
            keyboardPresentationFollowsFocus(isFocused)
        }
        .onChange(of: store.draft) { _, _ in
            if commandMenu != nil {
                if commandSuggestions == nil { isSuggestionsDismissed = false }
                return
            }
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

    /// Pull down to hide the keyboard. It sits in the card's top inset, so
    /// showing it moves nothing, and shows only while there is a keyboard to
    /// hide. The Switcher row's keyboard button does the same for VoiceOver.
    private var keyboardGrabber: some View {
        Capsule()
            .fill(keyboardPull > 0 ? HierarchicalShapeStyle.secondary : .tertiary)
            .frame(width: 48, height: 5)
            .offset(y: AgentComposerKeyboardPull.grabberOffset(translation: keyboardPull))
            .padding(.top, 5 + AgentComposerKeyboardPull.touchOverhang)
            .frame(
                width: AgentComposerKeyboardPull.touchWidth,
                height: AgentComposerKeyboardPull.touchHeight,
                alignment: .top
            )
            .contentShape(Rectangle())
            .offset(y: -AgentComposerKeyboardPull.touchOverhang)
            .opacity(isKeyboardPresented ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isKeyboardPresented)
            .allowsHitTesting(isKeyboardPresented)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($keyboardPull) { value, pull, _ in
                        pull = value.translation.height
                    }
                    .onChanged { value in
                        guard AgentComposerKeyboardPull.reachesHidingDistance(translation: value.translation.height)
                        else { return }
                        hideKeyboardFromPull()
                    }
                    .onEnded { value in
                        guard
                            AgentComposerKeyboardPull.isFlickDown(
                                translation: value.translation.height,
                                predictedTranslation: value.predictedEndTranslation.height)
                        else { return }
                        hideKeyboardFromPull()
                    }
            )
            .accessibilityHidden(true)
    }

    /// The input with its suggestions, notices and actions; a card in its
    /// place replaces all of it.
    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            suggestions
            editorRow
            if isCollapsed, store.hasPendingDroppedImages {
                pendingDropHint
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let failure = latestFailure {
                failureRow(failure)
            }
            if let notice = store.notice, notice.route == sendPolicy.route, failureIsHidden {
                noticeRow(notice)
            }
            if status == .working, let stopNotice = store.stop.notice {
                noticeLabel(stopNotice)
                    .accessibilityIdentifier("composer.stop-notice")
            }
            if !isCollapsed {
                actionRow
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if let commands = commandSuggestions, isInputFocused, !isSuggestionsDismissed {
            ChatCommandSuggestions(
                commands: commands,
                onSelect: { command in
                    store.replaceDraft(with: "/\(command.name) ")
                },
                onDismiss: { isSuggestionsDismissed = true })
        } else if let skills, let trigger = suggestionTrigger,
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
    }

    /// The input, with Add and Send beside it while it is folded. The
    /// editor keeps its place in this row in both layouts: a new text view
    /// would drop the focus and any keyboard handoff in flight.
    private var editorRow: some View {
        HStack(spacing: 8) {
            if isCollapsed {
                addMenu
            }
            ZStack(alignment: .topLeading) {
                AgentComposerTextEditor(
                    text: store.draft,
                    selectedRange: store.draftSelection,
                    onEdit: { store.applyEditorDraft($0, selection: $1) },
                    isFocused: inputFocus,
                    keyboardPresentation: keyboardPresentation,
                    lineLimit: isCollapsed ? 1 : 5,
                    keyboardHandoffID: keyboardHandoffID,
                    isKeyboardHandoffCurrent: isKeyboardHandoffCurrent,
                    onFirstResponderRequest: onFirstResponderRequest,
                    onKeyboardHandoffSettled: onKeyboardHandoffSettled,
                    onHardwareReturn: sendDraft)
                if store.draft.isEmpty {
                    Text("Message Agent")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 36, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            if isCollapsed {
                primaryButton
            }
        }
    }

    private func failureRow(
        _ failure: (id: AgentComposerStore.Message.ID, detail: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.detail, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("Retry") {
                    Task {
                        await deliverDraft {
                            await store.retry(failure.id, policy: sendPolicy)
                        }
                    }
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

    private func noticeRow(_ notice: ComposerNotice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            noticeLabel(notice.refusal.message)
            if notice.refusal.suggestsTerminal, let openAgentTerminal {
                Button("Open in Terminal", action: openAgentTerminal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.notice")
    }

    /// Why a send was refused, or why Stop pressed nothing or the Agent
    /// still shows Working, then what to do. Six lines hold the longest
    /// notices whole on a phone at the default text size.
    private func noticeLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.bubble")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(6)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            addMenu

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
            .agentCloseConfirmation(actions.closeConfirmation)

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
                pendingDropHint
            }
            primaryButton
        }
    }

    /// Why Send waits; its VoiceOver hint already says so.
    private var pendingDropHint: some View {
        Text(store.sendAccessibilityHint)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private var addMenu: some View {
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
    }

    private func sendDraft() {
        Task { await deliverDraft { await store.send(policy: sendPolicy) } }
    }

    /// Send, or Stop while the Agent works and the draft is blank.
    @ViewBuilder
    private var primaryButton: some View {
        switch primaryControl {
        case .send:
            AgentComposerSendButton(
                isEnabled: store.canSend,
                accessibilityHint: store.sendAccessibilityHint
            ) {
                sendDraft()
            }
        case .stop:
            AgentComposerStopButton(
                isStopping: store.stop.isStopping,
                accessibilityHint: stopHint
            ) {
                guard let interrupt else { return }
                store.stop.stop(waiting: interrupt.wait, using: interrupt.perform)
            }
        }
    }

    private var stopHint: String {
        interrupt?.accessibilityHint ?? AgentComposerInterrupt.escapeHint
    }

    private var primaryControl: AgentComposerPrimaryControl {
        AgentComposerPrimaryControl(
            status: status, draft: store.draft,
            canStop: interrupt != nil && !store.stop.isHeldAfterSend)
    }

    private var inputAreaInsets: EdgeInsets {
        EdgeInsets(
            top: isCollapsed ? 6 : 12, leading: 12, bottom: isCollapsed ? 6 : 8, trailing: 12)
    }

    private var isCollapsed: Bool {
        AgentComposerCollapse.isCollapsed(
            isEnabled: collapsesWithoutKeyboard,
            isInputFocused: isInputFocused,
            keyboardPresentation: keyboardPresentation,
            inheritsKeyboard: inheritsPendingKeyboard,
            hasInputReplacement: inputReplacement != nil,
            keyboardIsLeaving: keyboardIsLeaving)
    }

    /// A keyboard handed over by the screen this one replaces, read without
    /// consuming it (`onAppear` does), so the first frame is already open.
    private var inheritsPendingKeyboard: Bool {
        guard inheritsKeyboardHandoff, let selectedID = switcher.selectedID else { return false }
        return keyboardHandoff.mode(for: selectedID) != nil
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
        if isKeyboardPresented {
            hideKeyboard()
        } else {
            setKeyboardPresentation(.system)
            isInputFocused = true
        }
    }

    private func hideKeyboard() {
        setKeyboardPresentation(.hidden)
        isInputFocused = false
    }

    /// Once per pull: the finger is often still moving after this.
    private func hideKeyboardFromPull() {
        guard isKeyboardPresented else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        hideKeyboard()
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

    /// The editor's focus, with the presentation changing in the same update
    /// so that the surface animates the fold as one change.
    private var inputFocus: Binding<Bool> {
        Binding {
            isInputFocused
        } set: { isFocused in
            keyboardPresentationFollowsFocus(isFocused)
            isInputFocused = isFocused
        }
    }

    private func keyboardPresentationFollowsFocus(_ isFocused: Bool) {
        if isFocused {
            // A tap into the text while the iPad tools dock is up asks for the
            // system keyboard; on iPhone the dock keeps the caret.
            if keyboardPresentation != .tools || toolsDockReleasesFocus {
                setKeyboardPresentation(.system)
            }
        } else if !(toolsDockReleasesFocus && keyboardPresentation == .tools) {
            setKeyboardPresentation(.hidden)
        }
    }

    private func setKeyboardPresentation(_ presentation: AgentComposerKeyboardPresentation) {
        guard presentation != keyboardPresentation else { return }
        prepareKeyboardPresentation(presentation)
        keyboardPresentation = presentation
    }

    /// The `/` menu's matches for the draft, while it is open.
    private var commandSuggestions: [ChatCommand]? {
        guard let commandMenu,
            let matches = ChatCommandMenu.suggestions(for: store.draft, in: commandMenu),
            !matches.isEmpty
        else { return nil }
        return matches
    }

    /// The notice gives way to a failure, which has its own row and Retry.
    private var failureIsHidden: Bool { latestFailure == nil }

    /// Blocked delivery types into Attach without Enter; the tools keyboard
    /// is what submits or cancels. A refusal stays as the store's notice and
    /// keeps the keyboard where it is.
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

    /// Only this surface's own messages: a failure from the other one is
    /// retried there, the way it was sent.
    private var latestFailure: (id: AgentComposerStore.Message.ID, detail: String)? {
        guard let message = store.messages.last(where: { $0.route == sendPolicy.route }),
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
                            ForEach(matches) { @Sendable skill in
                                MainActorContent { row(for: skill) }
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

/// Send's place while the Agent works on a blank draft: one press of the
/// surface's Stop keys per tap, then a spinner until Agent Status leaves
/// Working or the store's window passes.
struct AgentComposerStopButton: View {
    let isStopping: Bool
    var accessibilityHint = AgentComposerInterrupt.escapeHint
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isStopping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(AgentComposerStopButtonStyle())
        .disabled(isStopping)
        .accessibilityLabel("Stop")
        .accessibilityValue(isStopping ? "Stopping" : "")
        .accessibilityHint(accessibilityHint)
    }
}

/// Send's geometry in system red, which stays apart from Blocked's red in
/// `AgentStatusPalette`.
private struct AgentComposerStopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color(uiColor: .systemRed), in: Circle())
            .frame(width: 44, height: 44)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(.circle)
    }
}

/// Puts another view in the input's place. The draft lives in the store,
/// so it comes back with the input.
private struct ComposerInputReplacement: ViewModifier {
    let replacement: AnyView?

    func body(content: Content) -> some View {
        if let replacement { replacement } else { content }
    }
}

private struct AgentComposerTextEditor: UIViewRepresentable {
    let text: String
    let selectedRange: NSRange
    let onEdit: (String, NSRange) -> Void
    @Binding var isFocused: Bool
    let keyboardPresentation: AgentComposerKeyboardPresentation
    /// How many lines show before the draft scrolls; one folds it to its
    /// first line.
    let lineLimit: Int
    let keyboardHandoffID: UUID?
    let isKeyboardHandoffCurrent: (UUID) -> Bool
    let onFirstResponderRequest: (UUID, Bool) -> Void
    let onKeyboardHandoffSettled: (UUID) -> Void
    let onHardwareReturn: () -> Void

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
        textView.onHardwareReturn = onHardwareReturn
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
        textView.updateLineLimit(lineLimit)
        textView.updateKeyboard(presentation: keyboardPresentation)
        textView.onKeyboardHandoffSettled = onKeyboardHandoffSettled
        textView.onHardwareReturn = onHardwareReturn
        let shouldFocus = isFocused
        let coordinator = context.coordinator
        coordinator.wantsFocus = shouldFocus
        guard shouldFocus != textView.isFirstResponder else { return }
        // Focus asked for before the view has a window is a keyboard
        // inherited from the screen being replaced (see `onAppear`); it is
        // claimed as the view reaches the window, not a turn later.
        textView.claimsKeyboardWhenReady =
            shouldFocus && keyboardHandoffID == nil && textView.window == nil
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if shouldFocus {
                guard !textView.isFirstResponder else { return }
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
        let maximumHeight = uiView.draftLineHeight * CGFloat(lineLimit)
            + uiView.textContainerInset.top
            + uiView.textContainerInset.bottom
        let height = min(max(36, measured.height), maximumHeight)
        uiView.isScrollEnabled = lineLimit > 1 && measured.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String, NSRange) -> Void
        /// The latest focus intent, from either SwiftUI or UIKit, so a
        /// deferred focus change can recheck it before acting.
        var wantsFocus = false
        private var isFocused: Binding<Bool>
        private var foldedSelection: NSRange?

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

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn _: NSRange,
            replacementText text: String
        ) -> Bool {
            (textView as? AgentComposerUITextView)?.acceptsReplacement(text) ?? true
        }

        /// A tap into the folded input lands in the one line it shows; the
        /// caret goes back where the draft was left.
        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            foldedSelection = textView.textContainer.maximumNumberOfLines == 1
                ? textView.selectedRange : nil
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            wantsFocus = true
            isFocused.wrappedValue = true
            guard let selection = foldedSelection else { return }
            foldedSelection = nil
            // UIKit places a tap's caret after editing begins.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, textView.isFirstResponder,
                      NSMaxRange(selection) <= (textView.text as NSString).length
                else { return }
                textView.selectedRange = selection
                onEdit(textView.text, selection)
                textView.scrollRangeToVisible(selection)
            }
        }

        func textViewDidEndEditing(_: UITextView) {
            wantsFocus = false
            isFocused.wrappedValue = false
        }
    }
}

/// What a hardware Return does in the Composer.
enum ComposerHardwareReturn {
    /// Return and keypad Enter send. Any of Shift, Option, Control or Command
    /// leaves the press to UIKit: a new line, or ⌘↩'s scene command. So does
    /// text the input method is still composing, which Return commits.
    static func sends(
        keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags,
        hasMarkedText: Bool
    ) -> Bool {
        (keyCode == .keyboardReturnOrEnter || keyCode == .keypadEnter)
            && !hasMarkedText
            && modifierFlags.isDisjoint(with: [.shift, .alternate, .control, .command])
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
    private var isRequestingKeyboardHandoff = false
    /// Focus requested before the view is in a window. The keyboard is then
    /// taken over in the same pass the view is inserted — while the surface
    /// it inherits from is still first responder — so UIKit moves it between
    /// responders instead of hiding it when that surface leaves the window
    /// and presenting it again a turn later. `HeelerTerminalView` claims an
    /// inherited keyboard the same way from `didMoveToWindow`.
    var claimsKeyboardWhenReady = false
    private var laidOutHeight: CGFloat = 0
    /// Sends the draft for a hardware Return, the way the Send button does.
    var onHardwareReturn: (() -> Void)?
    /// Return presses taken for sending. Their releases stay here too, and
    /// UIKit's own new line for them is refused (see `acceptsReplacement`).
    private var sendingReturnPresses: Set<ObjectIdentifier> = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, claimsKeyboardWhenReady else { return }
        claimsKeyboardWhenReady = false
        _ = becomeFirstResponder()
    }

    /// A hardware Return sends and Shift-Return starts a new line. The
    /// software keyboard's Return arrives as text, not a press, so it keeps
    /// starting a new line.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var forwarded: Set<UIPress> = []
        for press in presses {
            if let key = press.key,
               ComposerHardwareReturn.sends(
                   keyCode: key.keyCode,
                   modifierFlags: key.modifierFlags,
                   hasMarkedText: markedTextRange != nil)
            {
                beginHardwareReturn(token: ObjectIdentifier(press))
            } else {
                forwarded.insert(press)
            }
        }
        guard !forwarded.isEmpty else { return }
        super.pressesBegan(forwarded, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = presses.filter { !endHardwareReturn(token: ObjectIdentifier($0)) }
        guard !forwarded.isEmpty else { return }
        super.pressesEnded(forwarded, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = presses.filter { !endHardwareReturn(token: ObjectIdentifier($0)) }
        guard !forwarded.isEmpty else { return }
        super.pressesCancelled(forwarded, with: event)
    }

    /// The consume path `pressesBegan` uses. Tests drive it directly because
    /// `UIPress` cannot be constructed in the suite.
    func beginHardwareReturn(token: ObjectIdentifier) {
        sendingReturnPresses.insert(token)
        onHardwareReturn?()
    }

    /// Whether the press was one taken for sending.
    @discardableResult
    func endHardwareReturn(token: ObjectIdentifier) -> Bool {
        sendingReturnPresses.remove(token) != nil
    }

    /// While a Return taken for sending is down, a new line UIKit types for it
    /// anyway is not the user's.
    func acceptsReplacement(_ text: String) -> Bool {
        sendingReturnPresses.isEmpty || text != "\n"
    }

    /// A press's release goes to whichever responder holds the keyboard then,
    /// so one taken for sending is forgotten here rather than left to refuse
    /// every later new line.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            sendingReturnPresses.removeAll()
        }
        return resigned
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        applyComposerInputTraits()
        installKeyboardObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyComposerInputTraits()
        installKeyboardObservers()
    }

    /// The draft is local text until Send, so it autocorrects and spell
    /// checks like any message field; the terminal never does, because its
    /// keystrokes reach the PTY at once. The candidate bar this adds changes
    /// the keyboard's height across the Direct Input handoff, which
    /// `TerminalKeyboardInset` settles. Smart punctuation and inline
    /// predictions stay off: prompts often carry code.
    private func applyComposerInputTraits() {
        autocorrectionType = .yes
        spellCheckingType = .yes
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
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
        guard isRequestingKeyboardHandoff else {
            onKeyboardHandoffSettled?(activeKeyboardHandoffID)
            return
        }
        // iOS 26 publishes the settled frame from inside
        // `becomeFirstResponder`, before the requester has learned the
        // request succeeded; reporting it now would be discarded as unknown
        // and leave the handoff to its fallback.
        DispatchQueue.main.async { [weak self] in
            self?.onKeyboardHandoffSettled?(activeKeyboardHandoffID)
        }
    }

    @discardableResult
    func requestKeyboardHandoff(id: UUID) -> Bool {
        guard window != nil else { return false }
        activeKeyboardHandoffID = id
        isRequestingKeyboardHandoff = true
        let accepted = becomeFirstResponder()
        isRequestingKeyboardHandoff = false
        if !accepted {
            activeKeyboardHandoffID = nil
        }
        return accepted
    }

    /// Folding scrolls the draft to its top, so a caret further down comes
    /// back into view as the open Composer grows the view.
    override func layoutSubviews() {
        super.layoutSubviews()
        updateEdgeFade()
        defer { laidOutHeight = bounds.height }
        guard laidOutHeight > 0, bounds.height > laidOutHeight, isFirstResponder,
              textContainer.maximumNumberOfLines == 0
        else { return }
        scrollRangeToVisible(selectedRange)
    }

    /// The height one line of the draft takes as laid out, in whichever
    /// script it is written: Chinese falls back to a taller face than the
    /// body font, so a limit counted in body lines cut its lines short.
    var draftLineHeight: CGFloat {
        guard let font else { return 20 }
        func pitch(_ sample: String) -> CGFloat {
            func height(_ text: String) -> CGFloat {
                NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                ).height
            }
            return height(sample + "\n" + sample) - height(sample)
        }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        return (max(font.lineHeight, pitch("Ag"), pitch("中")) * scale).rounded(.up) / scale
    }

    /// The caret keeps the inset's padding around it, so the line it is on
    /// never ends in the faded band at the editor's edge.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        let padding = UIEdgeInsets(
            top: -textContainerInset.top, left: 0, bottom: -textContainerInset.bottom, right: 0)
        super.scrollRectToVisible(rect.inset(by: padding), animated: animated)
    }

    private lazy var edgeFade = CAGradientLayer()

    /// A draft taller than the editor fades out across the inset at the
    /// edge it continues past, rather than a line cut off against the
    /// Composer's border.
    private func updateEdgeFade() {
        let overflow = contentSize.height - bounds.height
        let fadesTop = isScrollEnabled && overflow > 0.5 && contentOffset.y > 0.5
        let fadesBottom = isScrollEnabled && overflow > 0.5 && contentOffset.y < overflow - 0.5
        guard fadesTop || fadesBottom, bounds.height > 0 else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        // Clear through most of the inset, where only the next line's edge
        // shows, and opaque just past it, where a whole line starts.
        func stop(_ y: CGFloat) -> NSNumber { NSNumber(value: Double(min(1, max(0, y / bounds.height)))) }
        let top = textContainerInset.top
        let bottom = bounds.height - textContainerInset.bottom
        let clear = UIColor.clear.cgColor
        let opaque = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = bounds
        edgeFade.colors = [
            fadesTop ? clear : opaque, fadesTop ? clear : opaque, opaque,
            opaque, fadesBottom ? clear : opaque, fadesBottom ? clear : opaque,
        ]
        edgeFade.locations = [0, stop(top - 3), stop(top + 2), stop(bottom - 2), stop(bottom + 3), 1]
        layer.mask = edgeFade
        CATransaction.commit()
    }

    /// One line truncates the draft after its first line, shown from the
    /// top; more wraps it in full, as typing needs.
    func updateLineLimit(_ lineLimit: Int) {
        let maximumLines = lineLimit == 1 ? 1 : 0
        guard textContainer.maximumNumberOfLines != maximumLines else { return }
        textContainer.maximumNumberOfLines = maximumLines
        textContainer.lineBreakMode = maximumLines == 1 ? .byTruncatingTail : .byWordWrapping
        if maximumLines == 1 {
            setContentOffset(.zero, animated: false)
        }
        invalidateIntrinsicContentSize()
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

/// The tools dock's tab row: the terminal's dock and Chat's.
struct ToolsKeyboardTabBar: View {
    let tabs: [TerminalKeysTab]
    @Binding var selection: TerminalKeysTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { @Sendable tab in
                MainActorContent {
                    let isSelected = selection == tab
                    Button {
                        selection = tab
                    } label: {
                        Image(systemName: tab.systemImageName)
                            .font(.body)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                isSelected ? Color(uiColor: .secondarySystemFill) : .clear,
                                in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.accessibilityLabel)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
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
            ToolsKeyboardTabBar(tabs: tabs, selection: $selectedTab)
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
