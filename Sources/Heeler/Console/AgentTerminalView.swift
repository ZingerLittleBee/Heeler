import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Stable in-process seam for exercising Agent-detail behavior without relying
/// on hosted SwiftUI accessibility. iOS 26 does not materialize those elements
/// without an assistive client; button wiring remains UI-test coverage.
@MainActor
final class AgentTerminalInteractionProbe {
    private var selectInputModeAction: ((AgentInputMode) -> Void)?
    private var sendQuickKeyAction: ((AgentQuickKey) -> Void)?
    private var toggleDirectKeyboardAction: (() -> Void)?
    private var switchDirectKeyboardAction: (() -> Void)?
    private(set) var directInputChromeMountCount = 0

    var isConnected: Bool { selectInputModeAction != nil }

    @discardableResult
    func selectInputMode(_ mode: AgentInputMode) -> Bool {
        guard let selectInputModeAction else { return false }
        selectInputModeAction(mode)
        return true
    }

    @discardableResult
    func sendQuickKey(_ key: AgentQuickKey) -> Bool {
        guard let sendQuickKeyAction else { return false }
        sendQuickKeyAction(key)
        return true
    }

    @discardableResult
    func toggleDirectKeyboard() -> Bool {
        guard let toggleDirectKeyboardAction else { return false }
        toggleDirectKeyboardAction()
        return true
    }

    @discardableResult
    func switchDirectKeyboard() -> Bool {
        guard let switchDirectKeyboardAction else { return false }
        switchDirectKeyboardAction()
        return true
    }

    fileprivate func connect(selectInputMode: @escaping (AgentInputMode) -> Void) {
        selectInputModeAction = selectInputMode
    }

    fileprivate func directInputChromeDidAppear(
        sendQuickKey: @escaping (AgentQuickKey) -> Void,
        toggleDirectKeyboard: @escaping () -> Void,
        switchDirectKeyboard: (() -> Void)?
    ) {
        directInputChromeMountCount += 1
        sendQuickKeyAction = sendQuickKey
        toggleDirectKeyboardAction = toggleDirectKeyboard
        switchDirectKeyboardAction = switchDirectKeyboard
    }

    fileprivate func disconnect() {
        selectInputModeAction = nil
        sendQuickKeyAction = nil
        toggleDirectKeyboardAction = nil
        switchDirectKeyboardAction = nil
        directInputChromeMountCount = 0
    }

    fileprivate func directInputChromeDidDisappear() {
        directInputChromeMountCount = max(0, directInputChromeMountCount - 1)
        guard directInputChromeMountCount == 0 else { return }
        sendQuickKeyAction = nil
        toggleDirectKeyboardAction = nil
        switchDirectKeyboardAction = nil
    }

    fileprivate func updateSwitchDirectKeyboard(_ action: (() -> Void)?) {
        guard directInputChromeMountCount > 0 else { return }
        switchDirectKeyboardAction = action
    }
}

@MainActor
private final class WeakAgentTerminalInteractionProbe {
    weak var value: AgentTerminalInteractionProbe?

    init(_ value: AgentTerminalInteractionProbe) {
        self.value = value
    }
}

/// The live Ghostty surface used by Agent detail. Composer mode keeps the
/// terminal display-only and routes authored text through the local draft;
/// Direct Input (ADR 0016) enables Ghostty local input so the system keyboard
/// types the live Attach PTY while the Composer card stays hidden.
struct AgentTerminalView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let inputMode: AgentInputModeSettings
    /// Passed through to the new-agent sheet, which keeps its Host picker for
    /// the Console's own entry point even though this screen pre-selects one.
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    /// Keeps the keyboard up across the terminal rebuild an Agent switch
    /// forces; owned by the Console so it survives that rebuild.
    private let keyboardHandoff: TerminalKeyboardHandoff
    /// How much of the bottom edge the keyboard covers. Console-owned for the
    /// same reason as the handoff: a switch that inherits a raised keyboard
    /// must lay the terminal out at the right height on its first frame.
    private let keyboardInset: TerminalKeyboardInset
    /// Router truth used to distinguish a real navigation from SwiftUI's
    /// same-screen disappear/appear churn.
    private let isOnStage: () -> Bool
    /// Opens another Agent from the terminal's switcher strip. The owner moves
    /// the selection, exactly as a tap in the Agent list would.
    private let onSwitch: (ConsoleAgent.ID) -> Void
    /// Leaves the screen after a confirmed close. A callback rather than
    /// `dismiss`: as a split view's detail root this view has nothing to
    /// dismiss — the owner clears the sidebar selection instead, which also
    /// pops the collapsed stack on iPhone.
    private let onClosed: () -> Void
    private let canOpenTerminal: Bool
    private let isOpeningTerminal: Bool
    private let openTerminal: () -> Void
    private let composer: AgentComposerStore
    private let interactionProbe: WeakAgentTerminalInteractionProbe?
    @State private var attach: AgentAttachStore
    /// Nil for agent kinds without a skills source catalog; the Keys
    /// keyboard hides the Skills tab in that case.
    @State private var skills: SkillsPaneStore?
    @State private var keyboardControl = TerminalKeyboardControl()
    @State private var composerKeyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    /// Keeps Composer mounted while its visible system keyboard moves to the
    /// terminal. Direct Input becomes the rendered mode only after the
    /// terminal confirms first-responder ownership.
    @State private var composerToDirectHandoffID: UUID?
    /// Keeps Direct Input active while the newly mounted Composer takes over
    /// its visible software keyboard.
    @State private var directToComposerHandoffID: UUID?
    /// This view's handoff after the destination responder has accepted it but
    /// before that responder's own keyboard frame settles. The inset is shared
    /// by the Console, so ownership must never be inferred from its active ID.
    @State private var settlingKeyboardHandoffID: UUID?
    /// Direct Input's tools dock, separate from Composer focus presentation.
    @State private var usesDirectToolsKeyboard = false
    /// Keeps reverse-handoff preloading from adopting Composer's taller layout
    /// before Composer actually owns keyboard input.
    @State private var directInputChromeHeight: CGFloat?
    /// Holds `.system` presentation across the Tools→iOS coalesce window so
    /// the terminal does not expand then shrink while UIKit re-shows the
    /// software keyboard. Cleared once `keyboardInset.height` becomes positive
    /// (or on resign / mode change). Never set for bare first-responder /
    /// hardware.
    @State private var expectsDirectSystemKeyboard = false
    /// Survives same-screen terminal replacement so a raised Direct Input
    /// keyboard is reclaimed without raising one that was down.
    @State private var directKeyboardIntent = DirectInputKeyboardIntent()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSelectingPhoto = false
    @State private var isSelectingFile = false
    @State private var isConfirmingClose = false
    @State private var isStartingAgent = false
    @State private var isManagingSnippets = false
    @State private var isShowingSkillsPicker = false
    @State private var isRenamingAgent = false
    /// The skill whose full document is on screen; set from the Skills
    /// pane's long-press menu.
    @State private var viewingSkill: AgentSkill?
    @State private var isRenamingWorkspace = false
    @State private var isShowingWorktree = false
    @State private var worktreeStore: WorktreeDetailStore?
    @State private var isShowingAttachLinks = false
    @State private var closeErrorMessage: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isDirectInput: Bool { inputMode.isDirect }

    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        inputMode: AgentInputModeSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        isOnStage: @escaping () -> Bool,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        canOpenTerminal: Bool = false,
        isOpeningTerminal: Bool = false,
        openTerminal: @escaping () -> Void = {},
        composer: AgentComposerStore,
        attachStore: AgentAttachStore? = nil,
        interactionProbe: AgentTerminalInteractionProbe? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.inputMode = inputMode
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        self.isOnStage = isOnStage
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        self.canOpenTerminal = canOpenTerminal
        self.isOpeningTerminal = isOpeningTerminal
        self.openTerminal = openTerminal
        self.composer = composer
        self.interactionProbe = interactionProbe.map(WeakAgentTerminalInteractionProbe.init)
        _attach = State(
            initialValue: attachStore ?? AgentAttachStore(
                target: agent.agent.paneID,
                paneTitle: Self.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                isOnStage: isOnStage,
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID),
                stageFile: console.fileStager(for: agent.hostID),
                composer: composer
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            })
        _skills = State(initialValue: Self.makeSkillsStore(for: agent, console: console))
    }

    /// The Skills pane's store, or nil when this agent's kind has no skills
    /// source catalog. Captures launch-time context on purpose: the project
    /// root is the worktree checkout or launch cwd, never the live cwd.
    private static func makeSkillsStore(
        for agent: ConsoleAgent, console: ConsoleStore
    ) -> SkillsPaneStore? {
        guard let kind = SupportedAgentKind(rawValue: agent.agent.kind) else { return nil }
        let sources = SkillSourceCatalog.sources(for: kind)
        guard !sources.isEmpty else { return nil }
        let projectRoot = agent.skillsProjectRoot
        return SkillsPaneStore(
            commandPrefixes: sources.map(\.commandPrefix)
        ) { [console] forceRefresh in
            try await console.fetchSkills(
                kind: kind,
                projectRoot: projectRoot,
                on: agent.hostID,
                forceRefresh: forceRefresh)
        }
    }

    private var terminalScreen: TerminalScreenView {
        var screen = TerminalScreenView(feed: attach.terminalFeed)
        screen.onSizeChanged = { cols, rows in
            attach.viewDidResize(cols: cols, rows: rows)
        }
        screen.onViewportTextChanged = { text in
            attach.viewportTextDidChange(text)
        }
        screen.onSend = { keystrokes in attach.send(keystrokes) }
        screen.onScroll = { sequence, rows in
            attach.scroll(sequence, rows: rows)
        }
        screen.onPaste = { text, bracketed in
            attach.requestPaste(text, bracketedPaste: bracketed)
        }
        screen.keyboardControl = keyboardControl
        // Agent input is natural-language authored text in both Composer and
        // Direct Input. Matching traits lets UIKit retain one Apple keyboard
        // context across the responder transfer; Shell terminals keep the
        // command-oriented defaults.
        screen.textInputStyle = .naturalLanguage
        screen.isLocalInputEnabled = isDirectInput || composerToDirectHandoffID != nil
        screen.claimsKeyboard = {
            [
                keyboardHandoff,
                agent,
                inputMode,
                directKeyboardIntent,
                composerToDirectHandoffID,
            ] in
            if composerToDirectHandoffID != nil {
                return directKeyboardIntent.wantsKeyboard
            }
            guard inputMode.isDirect else { return false }
            if keyboardHandoff.consume(agent.id) {
                directKeyboardIntent.setWantsKeyboard(true)
                return true
            }
            // Same-screen pipeline replacement: reclaim only while Direct
            // Input still owns raised intent. Cold persisted Direct stays down.
            return directKeyboardIntent.wantsKeyboard
        }
        screen.keyboardHandoffID = composerToDirectHandoffID
        screen.isKeyboardHandoffCurrent = { id in
            isOnStage()
                && keyboardInset.activeResponderHandoffID == id
                && composerToDirectHandoffID == id
        }
        screen.onKeyboardHandoffResult = { id, succeeded in
            guard composerToDirectHandoffID == id else { return }
            if succeeded {
                settlingKeyboardHandoffID = id
                applyInputMode(.direct, preservingKeyboardHandoff: true)
            } else {
                cancelKeyboardHandoff(id)
            }
        }
        screen.onKeyboardHandoffSettled = { id in
            endKeyboardHandoff(id)
        }
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { fontSize in terminal.zoom.setFontSize(fontSize) }
        return screen
    }

    var body: some View {
        GeometryReader { proxy in
            lifecycleSurface
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .top)
        }
        // Keyboard avoidance is owned by `TerminalKeyboardInset`. The fixed
        // geometry reader must ignore UIKit's keyboard safe area itself;
        // otherwise replacing the system keyboard changes the proposal that
        // reaches Ghostty even when our explicit inset is unchanged.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task { composer.open() }
    }

    private var presentedSurface: some View {
        terminalSurface
        .photosPicker(
            isPresented: $isSelectingPhoto,
            selection: $selectedPhoto,
            matching: .images)
        .fileImporter(
            isPresented: $isSelectingFile,
            allowedContentTypes: [.data]
        ) { result in
            guard case .success(let url) = result else { return }
            attach.staging.begin(.file(url))
        }
        .popover(isPresented: $isShowingAttachLinks) {
            AttachLinksView(
                links: attach.attachLinks,
                open: { link in openAttachLink(link) },
                copy: { link in UIPasteboard.general.string = link.target })
            .presentationCompactAdaptation(.sheet)
        }
        .sheet(isPresented: $isStartingAgent) {
            // StartAgentView brings its own NavigationStack.
            StartAgentView(
                hosts: hosts,
                console: console,
                origin: StartAgentStore.LaunchOrigin(
                    hostID: agent.hostID,
                    workspaceID: agent.agent.workspaceID,
                    cwd: agent.agent.cwd),
                onStarted: { switchToAgent($0) })
        }
        // Presenting this takes the keyboard down and dismissing brings it
        // back; see `allowsKeyboardActivation` in HeelerTerminalView.
        .sheet(isPresented: $isManagingSnippets) {
            SnippetsManagementView(store: terminal.snippets)
        }
        // Same keyboard choreography as the Snippets sheet above. The picker
        // shares the tools keyboard's SkillsPaneStore, so both surfaces load
        // and fail together.
        .sheet(isPresented: $isShowingSkillsPicker) {
            if let skills {
                SkillsPickerView(
                    store: skills,
                    onInsert: { composer.insertIntoDraft($0.insertionText) },
                    readSkill: { [console, agent] skill in
                        try await console.readSkillFile(path: skill.path, on: agent.hostID)
                    })
            }
        }
        // Same keyboard choreography as the Snippets sheet above.
        .sheet(item: $viewingSkill) { skill in
            SkillContentSheet(skill: skill) { [console, agent] in
                try await console.readSkillFile(path: skill.path, on: agent.hostID)
            }
        }
        .sheet(isPresented: $isRenamingAgent) {
            RenameSheetView(
                title: "Rename Agent",
                store: RenameStore(
                    subject: .agent(detectedKind: agent.agent.kind),
                    currentValue: agent.agent.name ?? ""
                ) { [console, agent] name in
                    try await console.renameAgent(
                        agent.agent.paneID, name: name, on: agent.hostID)
                })
        }
        .sheet(isPresented: $isRenamingWorkspace) {
            RenameSheetView(
                title: "Rename Workspace",
                store: RenameStore.workspace(
                    currentLabel: agent.workspaceLabel ?? ""
                ) { [console, agent] label in
                    try await console.renameWorkspace(
                        agent.agent.workspaceID, label: label, on: agent.hostID)
                })
        }
        .sheet(isPresented: $isShowingWorktree) {
            if let worktreeStore {
                WorktreeDetailView(store: worktreeStore) { _ in
                    isShowingWorktree = false
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { attach.pendingPaste != nil },
                set: { if !$0 { attach.cancelPaste() } })
        ) {
            pasteReviewSheet
        }
        .confirmationDialog(
            "Close \(title)?", isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            Button("Close Agent", role: .destructive) {
                Task { await performClose() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This closes the pane on the Host and removes the agent everywhere. "
                    + "This can't be undone.")
        }
    }

    private var alertSurface: some View {
        presentedSurface
        .alert(
            "Couldn't Close Agent",
            isPresented: Binding(
                get: { closeErrorMessage != nil },
                set: { if !$0 { closeErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(closeErrorMessage ?? "")
        }
        .alert(
            "Paste Blocked",
            isPresented: Binding(
                get: { attach.pasteErrorMessage != nil },
                set: { if !$0 { attach.clearPasteError() } })
        ) {
            Button("OK", role: .cancel) {
                attach.clearPasteError()
            }
        } message: {
            Text(attach.pasteErrorMessage ?? "")
        }
        .alert(
            "Couldn't Open Link",
            isPresented: Binding(
                get: { attach.attachLinkOpenFailure != nil },
                set: { if !$0 { attach.dismissAttachLinkOpenFailure() } })
        ) {
            Button("Copy Link") {
                attach.copyFailedAttachLink {
                    UIPasteboard.general.string = $0
                }
            }
            Button("Cancel", role: .cancel) {
                attach.dismissAttachLinkOpenFailure()
            }
        } message: {
            Text(
                attach.attachLinkOpenFailure?.message
                    ?? "This link couldn't be opened.")
        }
    }

    private var lifecycleSurface: some View {
        alertSurface
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            attach.staging.begin(.photo(PhotosPickerImageSelection(item: item)))
        }
        // Follows the grace period, not the raw scene phase: a staging operation
        // is exactly the work worth finishing while the app is briefly out of
        // sight, and it is cancelled only once the app really suspends.
        .onChange(of: activity.phase) { _, phase in
            guard phase == .suspended else { return }
            attach.staging.didEnterBackground()
        }
        // Not the phase: a background→foreground round trip the grace period
        // absorbs never leaves `.active`, so the return that has to prove the
        // attach channel is exactly the one an `onChange` on the phase cannot
        // see (#141).
        // `initial` lets a replacement screen claim an activation that landed
        // after its predecessor disappeared but before this observer existed.
        .onChange(of: activity.activationCount, initial: true) { _, _ in
            handleActivation()
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            armDirectKeyboardClaimIfNeeded()
            attach.transportGenerationDidChange(generation)
        }
        // Paired with the leave below: SwiftUI hands out onDisappear for
        // removals the user never made, and the state that comes back is the
        // one that left. Rejoining is what makes that survivable — and both
        // calls must stay synchronous, because the spurious pair can land in
        // one transaction and rejoin() can only undo a leave it can see.
        .onAppear {
            interactionProbe?.value?.connect(selectInputMode: { mode in selectInputMode(mode) })
            composer.bindAttachInput(attach.input)
            // Arm before rejoin so a full pipeline replacement can claim the
            // keyboard while Direct Input still owns raised intent.
            armDirectKeyboardClaimIfNeeded()
            attach.rejoin()
        }
        .onDisappear {
            interactionProbe?.value?.disconnect()
            attach.leave()
            Task { @MainActor in
                await Task.yield()
                guard !isOnStage() else { return }
                cancelKeyboardHandoffs()
            }
        }
        .onChange(of: attach.terminalID) { _, _ in
            cancelKeyboardHandoffs()
            guard isDirectInput else { return }
            usesDirectToolsKeyboard = false
            expectsDirectSystemKeyboard = false
            keyboardControl.setKeyboardMode(.text)
            keyboardInset.resumeHeightCapture()
            // Do not re-arm TerminalKeyboardHandoff here: claimsKeyboard already
            // consumed any pre-armed token or reclaimed via same-screen intent.
            // Arming again leaves a stale one-shot that can raise a dismissed
            // keyboard on a later replacement.
        }
        .onChange(of: keyboardControl.isFirstResponder) { _, isUp in
            // Tools→iOS keeps first responder across the coalesce window; a
            // real dismiss resigns and must drop the pre-show `.system` hold.
            guard isDirectInput, !isUp else { return }
            expectsDirectSystemKeyboard = false
        }
        .onChange(of: keyboardInset.height) { _, height in
            // Release the Tools→iOS pre-show hold only after the software
            // keyboard has actually appeared. Clearing while height is still
            // zero would dip through `.hidden`; clearing once height is
            // positive keeps `.system` via the live measurement. A later
            // hardware-keyboard hide can then drop to zero inset cleanly.
            guard isDirectInput, expectsDirectSystemKeyboard, height > 0 else { return }
            expectsDirectSystemKeyboard = false
        }
    }

    private var agentSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: console.agents.map {
                TerminalAgentSwitcherItem(agent: $0, pins: console.pins)
            },
            selectedID: agent.id,
            onSelect: switchToAgent,
            onTogglePin: { id in
                console.togglePin(hostID: id.hostID, paneID: id.paneID)
            })
    }

    private var terminalKeysContext: TerminalKeysContext {
        TerminalKeysContext(
            settings: terminal,
            skills: skills.map { store in
                TerminalSkillsContext(store: store) { skill in
                    viewingSkill = skill
                }
            },
            includesDraftTools: !isDirectInput
        ) {
            isManagingSnippets = true
        }
    }

    /// Read inside the view body so it follows `ConsoleStore`'s observation:
    /// a fresh keepalive measurement re-renders this row and nothing else.
    /// No request of its own — the Host's connection measured this already.
    private var hostTelemetry: HostTelemetryPresentation? {
        HostTelemetryPresentation(
            status: console.hostStatuses[agent.hostID],
            latency: console.hostLatencies[agent.hostID])
    }

    private var directInputPresentation: AgentDirectInputPresentation {
        AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: usesDirectToolsKeyboard,
            expectsSystemKeyboard: expectsDirectSystemKeyboard,
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight)
    }

    private var activeKeyboardPresentation: AgentComposerKeyboardPresentation {
        if isDirectInput, directToComposerHandoffID == nil {
            return directInputPresentation.keyboardPresentation
        }
        return composerKeyboardPresentation
    }

    private var composerKeyboardLayout: AgentComposerKeyboardLayout {
        if isDirectInput {
            // Single seam: never rebuild layout beside the resolved presentation.
            return directInputPresentation.layout
        }
        return AgentComposerKeyboardLayout(
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight,
            presentation: composerKeyboardPresentation)
    }

    private var composerActions: AgentComposerActions {
        AgentComposerActions(
            canBegin: attach.staging.canBegin,
            attachLinkCount: attach.attachLinks.count,
            addImage: { isSelectingPhoto = true },
            addFile: { isSelectingFile = true },
            showAttachLinks: { isShowingAttachLinks = true },
            openTerminal: canOpenTerminal ? openTerminal : nil,
            isOpeningTerminal: isOpeningTerminal,
            startAgent: { isStartingAgent = true },
            manageSnippets: { isManagingSnippets = true },
            showSkills: skills != nil ? { isShowingSkillsPicker = true } : nil,
            showWorktreeDetails: agent.isLinkedWorktree
                ? {
                    if let checkout = agent.repositoryCheckout {
                        worktreeStore = makeWorktreeStore(checkout: checkout)
                        isShowingWorktree = true
                    }
                } : nil,
            renameAgent: { isRenamingAgent = true },
            renameWorkspace: { isRenamingWorkspace = true },
            closeAgent: { isConfirmingClose = true })
    }

    private func makeWorktreeStore(checkout: RepositoryCheckout) -> WorktreeDetailStore {
        let hostID = agent.hostID
        let workspaceID = agent.agent.workspaceID
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: hostID, workspaceID: workspaceID, checkout: checkout))
        return WorktreeDetailStore(
            request: request,
            workspaceLabel: agent.workspaceLabel ?? checkout.repoName,
            checkout: checkout,
            list: { [console] workspaceID in
                try await console.listWorktrees(
                    forWorkspaceID: workspaceID, on: hostID)
            },
            remove: { [console] request in
                try await console.removeWorktree(request, on: hostID)
            },
            hasWorkingAgent: { [console] in
                console.agents.contains {
                    $0.hostID == hostID
                        && $0.agent.workspaceID == workspaceID
                        && $0.agent.status == .working
                }
            })
    }

    private var terminalSurface: some View {
        terminalScreen
            .id(attach.terminalID)
        .overlay { statusOverlay }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            attachmentStatus
        }
        // Below the keyboard's own inset, so the strip rides above the
        // keyboard while it is up and rests on the screen's edge once it is
        // down. It outlives the keyboard on purpose: an Agent is worth
        // switching to whether or not the user is typing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputChrome
        }
        // Not SwiftUI's keyboard avoidance: it retracts in two stages and the
        // terminal would resize twice per dismissal. See TerminalKeyboardInset.
        .modifier(
            AgentTerminalKeyboardInsetModifier(
                height: composerKeyboardLayout.contentInset))
        // This dock is always present at the system keyboard's last complete
        // height. In iOS mode it is transparent behind the system keyboard;
        // in Tools mode it is already in place when UIKit removes its native
        // candidate row, so no intermediate gap is ever exposed.
        .overlay(alignment: .bottom) {
            AgentToolsKeyboard(
                store: composer,
                context: terminalKeysContext,
                height: composerKeyboardLayout.availableToolsHeight,
                quickKeysEnabled: true,
                sendQuickKey: keyboardControl.sendQuickKey)
            .opacity(activeKeyboardPresentation == .tools ? 1 : 0)
            .allowsHitTesting(activeKeyboardPresentation == .tools)
            .accessibilityHidden(activeKeyboardPresentation != .tools)
        }
        // The navigation bar remains present only as the owner of the status
        // bar appearance. Its content stays hidden, while this inset keeps
        // terminal output below the system clock.
        .padding(.top, statusBarInset)
        .background(
            terminal.themes.selection(for: colorScheme)
                .surfaceBackground(for: colorScheme))
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .leading) {
            AgentEdgeBackGesture { dismiss() }
        }
        .toolbarColorScheme(
            terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme),
            for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // `toolbarColorScheme` takes effect only while the bar background is
        // visible. A clear visible background keeps the bar visually absent
        // and the terminal unobscured while still applying status-bar contrast.
        .toolbarBackground(Color.clear, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
    }

    private func prepareComposerKeyboardPresentation(
        _ presentation: AgentComposerKeyboardPresentation
    ) {
        switch presentation {
        case .tools:
            keyboardInset.pauseHeightCapture()
        case .hidden, .system:
            keyboardInset.resumeHeightCapture()
        }
    }

    @ViewBuilder
    private var inputChrome: some View {
        if isDirectInput, directToComposerHandoffID == nil {
            directInputChrome
        } else {
            ZStack(alignment: .bottom) {
                composerChrome
                    .opacity(directToComposerHandoffID == nil ? 1 : 0)
                    .allowsHitTesting(directToComposerHandoffID == nil)
                    .accessibilityHidden(directToComposerHandoffID != nil)
                if directToComposerHandoffID != nil {
                    // Composer is mounted underneath so its UITextView can take
                    // first responder, but the visible chrome keeps describing
                    // the terminal that still owns hardware input until then.
                    directInputChrome
                }
            }
            .frame(
                height: directToComposerHandoffID == nil ? nil : directInputChromeHeight,
                alignment: .bottom)
            .clipped()
        }
    }

    private var directInputChrome: some View {
        AgentDirectInputChrome(
            context: AgentDirectInputChromeContext(
                presentation: .init(
                    status: agent.agent.status,
                    hostTelemetry: hostTelemetry,
                    chromeColorScheme: terminal.themes.selection(for: colorScheme)
                        .chromeColorScheme(for: colorScheme),
                    isKeyboardUp: directSwitcherKeyboardIsUp,
                    isToolsKeyboardPresented: usesDirectToolsKeyboard),
                interactions: .init(
                    switcher: agentSwitcher,
                    actions: composerActions,
                    toggleKeyboard: toggleDirectKeyboard,
                    switchKeyboard: directKeyboardSwitchAction,
                    sendQuickKey: keyboardControl.sendQuickKey,
                    showComposer: { selectInputMode(.composer) },
                    restoreComposerThen: restoreComposerThen)))
            .onAppear {
                interactionProbe?.value?.directInputChromeDidAppear(
                    sendQuickKey: { key in keyboardControl.sendQuickKey(key) },
                    toggleDirectKeyboard: { toggleDirectKeyboard() },
                    switchDirectKeyboard: presentedDirectKeyboardSwitchAction)
            }
            .onDisappear { interactionProbe?.value?.directInputChromeDidDisappear() }
            .onChange(of: isDirectKeyboardSwitchPresented) { _, _ in
                interactionProbe?.value?.updateSwitchDirectKeyboard(
                    presentedDirectKeyboardSwitchAction)
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                directInputChromeHeight = height
            }
    }

    private var composerChrome: some View {
        AgentComposerView(
            store: composer,
            status: agent.agent.status,
            hostTelemetry: hostTelemetry,
            chromeColorScheme: terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme),
            switcher: agentSwitcher,
            keyboardHandoff: keyboardHandoff,
            keyboardHeight: composerKeyboardLayout.availableToolsHeight,
            actions: composerActions,
            skills: skills,
            keyboardPresentation: $composerKeyboardPresentation,
            prepareKeyboardPresentation: prepareComposerKeyboardPresentation,
            modeControl: composerModeControl,
            keyboardHandoffID: directToComposerHandoffID,
            isKeyboardHandoffCurrent: { id in
                isOnStage()
                    && keyboardInset.activeResponderHandoffID == id
                    && directToComposerHandoffID == id
            },
            onFirstResponderRequest: composerFirstResponderRequest,
            onKeyboardHandoffSettled: composerKeyboardHandoffSettled)
    }

    private var composerModeControl: TerminalAgentSwitcherModeControl {
        if horizontalSizeClass == .regular {
            return .segmented(
                selection: inputMode.mode,
                select: selectInputMode)
        }
        return .button(
            systemImage: "rectangle.bottomhalf.inset.filled",
            accessibilityLabel: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
            accessibilityHint: AgentDirectInputPresentation.hideComposerAccessibilityHint,
            action: { selectInputMode(.direct) })
    }

    /// Switcher toggle glyph: first responder or tools, not software inset alone.
    private var directSwitcherKeyboardIsUp: Bool {
        keyboardControl.isKeyboardUp || usesDirectToolsKeyboard || keyboardInset.height > 0
    }

    private var directKeyboardSwitchAction: (() -> Void)? {
        guard isDirectKeyboardSwitchAvailable else { return nil }
        return { switchDirectKeyboard() }
    }

    private var presentedDirectKeyboardSwitchAction: (() -> Void)? {
        guard isDirectKeyboardSwitchPresented else { return nil }
        return directKeyboardSwitchAction
    }

    private var isDirectKeyboardSwitchPresented: Bool {
        directSwitcherKeyboardIsUp && isDirectKeyboardSwitchAvailable
    }

    private var isDirectKeyboardSwitchAvailable: Bool {
        composerKeyboardLayout.availableToolsHeight > 0
            || keyboardInset.lastPresentedHeight > 0
            || keyboardControl.isKeyboardUp
    }

    private func selectInputMode(_ mode: AgentInputMode) {
        guard mode != inputMode.mode else { return }
        guard composerToDirectHandoffID == nil,
              directToComposerHandoffID == nil,
              settlingKeyboardHandoffID == nil
        else { return }
        if mode == .direct, composerKeyboardPresentation == .system {
            directKeyboardIntent.setWantsKeyboard(true)
            keyboardControl.setKeyboardMode(.text)
            let id = keyboardInset.beginResponderHandoff(
                currentHeight: currentWindowKeyboardHeight
            ) { expiredID in
                cancelKeyboardHandoff(expiredID)
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                composerToDirectHandoffID = id
            }
            return
        }
        if mode == .composer,
           isDirectInput,
           keyboardControl.isFirstResponder,
           !usesDirectToolsKeyboard
        {
            let id = keyboardInset.beginResponderHandoff(
                currentHeight: currentWindowKeyboardHeight
            ) { expiredID in
                cancelKeyboardHandoff(expiredID)
            }
            keyboardHandoff.arm(for: agent.id)
            composerKeyboardPresentation = .system
            directToComposerHandoffID = id
            return
        }
        applyInputMode(mode)
    }

    private func applyInputMode(
        _ mode: AgentInputMode,
        preservingKeyboardHandoff: Bool = false
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch mode {
            case .direct:
                if !preservingKeyboardHandoff {
                    prepareComposerKeyboardPresentation(.hidden)
                }
                composerKeyboardPresentation = .hidden
                composerToDirectHandoffID = nil
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                keyboardControl.setKeyboardMode(.text)
                inputMode.select(.direct)
            case .composer:
                directToComposerHandoffID = nil
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                directKeyboardIntent.setWantsKeyboard(false)
                keyboardControl.setKeyboardMode(.text)
                if !preservingKeyboardHandoff {
                    keyboardControl.dismissKeyboard()
                    keyboardInset.resumeHeightCapture()
                }
                inputMode.select(.composer)
                // Composer onAppear consumes this and focuses the draft.
                if !preservingKeyboardHandoff {
                    keyboardHandoff.arm(for: agent.id)
                }
            }
        }
        switch mode {
        case .direct:
            UIAccessibility.post(
                notification: .announcement,
                argument: "Keyboard. Typing into the Agent.")
            if !keyboardControl.isFirstResponder {
                Task { @MainActor in
                    await Task.yield()
                    directKeyboardIntent.setWantsKeyboard(true)
                    keyboardControl.requestKeyboard()
                }
            }
        case .composer:
            UIAccessibility.post(notification: .announcement, argument: "Composer.")
        }
    }

    private func cancelKeyboardHandoff(_ id: UUID) {
        var ownsHandoff = false
        if composerToDirectHandoffID == id {
            composerToDirectHandoffID = nil
            directKeyboardIntent.setWantsKeyboard(false)
            ownsHandoff = true
        }
        if directToComposerHandoffID == id {
            directToComposerHandoffID = nil
            keyboardHandoff.cancel(for: agent.id)
            ownsHandoff = true
        }
        if settlingKeyboardHandoffID == id {
            settlingKeyboardHandoffID = nil
            ownsHandoff = true
        }
        guard ownsHandoff else { return }
        keyboardInset.cancelResponderHandoff(
            id, currentHeight: currentWindowKeyboardHeight)
    }

    private func currentWindowKeyboardHeight() -> CGFloat? {
        guard let window = keyboardControl.terminal?.window else { return nil }
        let frame = window.bounds.intersection(window.keyboardLayoutGuide.layoutFrame)
        let includesBottomSafeArea = abs(frame.maxY - window.bounds.maxY) <= 1
        return TerminalKeyboardInset.insetHeight(
            covered: frame.height,
            bottomSafeArea: includesBottomSafeArea ? window.safeAreaInsets.bottom : 0)
    }

    private func cancelKeyboardHandoffs() {
        if let id = composerToDirectHandoffID
            ?? directToComposerHandoffID
            ?? settlingKeyboardHandoffID
        {
            cancelKeyboardHandoff(id)
        }
    }

    private func composerFirstResponderRequest(_ id: UUID, _ succeeded: Bool) {
        guard directToComposerHandoffID == id else { return }
        guard succeeded else {
            cancelKeyboardHandoff(id)
            return
        }
        settlingKeyboardHandoffID = id
        applyInputMode(.composer, preservingKeyboardHandoff: true)
    }

    private func composerKeyboardHandoffSettled(_ id: UUID) {
        endKeyboardHandoff(id)
    }

    private func endKeyboardHandoff(_ id: UUID) {
        guard settlingKeyboardHandoffID == id else { return }
        settlingKeyboardHandoffID = nil
        keyboardInset.endResponderHandoff(id)
    }

    private func restoreComposerThen(_ action: @escaping () -> Void) {
        selectInputMode(.composer)
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func toggleDirectKeyboard() {
        if usesDirectToolsKeyboard {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                keyboardInset.resumeHeightCapture()
                keyboardControl.setKeyboardMode(.text)
            }
            directKeyboardIntent.setWantsKeyboard(false)
            keyboardControl.dismissKeyboard()
        } else if keyboardControl.isKeyboardUp {
            expectsDirectSystemKeyboard = false
            directKeyboardIntent.setWantsKeyboard(false)
            keyboardControl.dismissKeyboard()
        } else {
            directKeyboardIntent.setWantsKeyboard(true)
            keyboardControl.requestKeyboard()
        }
    }

    private func switchDirectKeyboard() {
        let enteringTools = !usesDirectToolsKeyboard
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if enteringTools {
                expectsDirectSystemKeyboard = false
                keyboardInset.pauseHeightCapture()
                usesDirectToolsKeyboard = true
                keyboardControl.setKeyboardMode(.controls)
            } else {
                // Hold `.system` through UIKit's coalesce window so content
                // inset stays at lastPresentedHeight instead of dipping to zero.
                expectsDirectSystemKeyboard = true
                keyboardInset.resumeHeightCapture()
                usesDirectToolsKeyboard = false
                keyboardControl.setKeyboardMode(.text)
            }
        }
        if enteringTools {
            directKeyboardIntent.setWantsKeyboard(true)
            keyboardControl.requestKeyboard()
        }
    }

    private func armDirectKeyboardClaimIfNeeded() {
        guard isDirectInput else { return }
        guard AgentDirectInputPresentation.shouldClaimKeyboard(
            wantsKeyboard: directKeyboardIntent.wantsKeyboard,
            isKeyboardUp: keyboardControl.isKeyboardUp,
            usesToolsKeyboard: usesDirectToolsKeyboard,
            softwareKeyboardHeight: keyboardInset.height)
        else { return }
        directKeyboardIntent.setWantsKeyboard(true)
        keyboardHandoff.arm(for: agent.id)
    }

    private func handleActivation() {
        let afterPossibleSuspension = activity.lastAbsenceMayHaveSuspended
        if afterPossibleSuspension {
            armDirectKeyboardClaimIfNeeded()
        }
        attach.didBecomeActive(afterPossibleSuspension: afterPossibleSuspension)
    }

    private func openAttachLink(_ link: AttachLink) {
        let openURL = openURL
        attach.openAttachLink(link) { url in
            guard !Task.isCancelled else { return false }
            let (results, continuation) = AsyncStream<Bool>.makeStream(
                bufferingPolicy: .bufferingNewest(1))
            openURL(url) { accepted in
                continuation.yield(accepted)
                continuation.finish()
            }
            return await withTaskCancellationHandler {
                for await accepted in results {
                    return accepted
                }
                return false
            } onCancel: {
                continuation.finish()
            }
        }
    }

    /// Opens another Agent from the switcher strip or the new-agent sheet.
    /// The keyboard is armed first:
    /// the selection change rebuilds this screen from scratch, and the new
    /// terminal claims the handoff as it comes up.
    private func switchToAgent(_ id: ConsoleAgent.ID) {
        guard id != agent.id else { return }
        // The strip outlives the keyboard, so a switch made with the keyboard
        // down must not raise one on the other side. Direct Input may keep
        // first responder with a hardware keyboard and a zero inset.
        let keyboardIsUp =
            isDirectInput
            ? AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: directKeyboardIntent.wantsKeyboard,
                isKeyboardUp: keyboardControl.isKeyboardUp,
                usesToolsKeyboard: usesDirectToolsKeyboard,
                softwareKeyboardHeight: keyboardInset.height)
            : keyboardInset.height > 0
        if keyboardIsUp {
            keyboardHandoff.arm(for: id)
        }
        onSwitch(id)
    }

    private func performClose() async {
        if await attach.confirmClose() {
            onClosed()
        } else {
            closeErrorMessage = attach.closeFailureMessage
        }
    }

    /// The dialog wears the terminal's theme, not the system's.
    private var themePalette: TerminalThemePalette {
        terminal.themes.selection(for: colorScheme).palette(for: colorScheme)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let presentation = TerminalStatusPresentation(status: attach.terminalStatus) {
            switch presentation.kind {
            case .connecting:
                // No dim: a reattach would otherwise flash the whole screen dark.
                TerminalStatusDialog(
                    glyph: .progress,
                    title: presentation.title,
                    message: presentation.message,
                    palette: themePalette,
                    dimsBackground: presentation.dimsBackground)
            case .ended:
                TerminalStatusDialog(
                    glyph: .symbol("cable.connector.slash"),
                    title: presentation.title,
                    message: presentation.message,
                    palette: themePalette,
                    dimsBackground: presentation.dimsBackground
                ) {
                    Button("Reattach") { attach.retryTerminal() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            // .live needs nothing, and .stopped only reaches the view while the
            // screen is on its way off stage (see `AgentAttachStore.terminalStatus`).
            EmptyView()
        }
    }

    @ViewBuilder
    private var attachmentStatus: some View {
        if let presentation = attach.staging.presentation {
            AttachmentStatusBar(
                icon: presentation.icon,
                title: presentation.title,
                accessibilityLabel: presentation.accessibilityLabel
            ) {
                ForEach(presentation.commands, id: \.self) { command in
                    stagingCommandButton(command)
                }
            }
        }
    }

    @ViewBuilder
    private func stagingCommandButton(_ command: ComposerStagingStore.Command) -> some View {
        switch command {
        case .cancel:
            Button("Cancel", role: .cancel) { attach.staging.perform(command) }
        case .retry:
            Button("Retry") { attach.staging.perform(command) }
        case .copyPath:
            Button("Copy Path") { attach.staging.perform(command) }
        case .dismiss:
            Button("Dismiss", role: .cancel) { attach.staging.perform(command) }
        }
    }

    @ViewBuilder
    private var pasteReviewSheet: some View {
        if let review = attach.pendingPaste {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "\(review.lineCount) lines, \(review.characterCount) characters")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(review.preview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                }
                .padding()
                .navigationTitle("Review Paste")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { attach.cancelPaste() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste") { attach.confirmPaste() }
                            .disabled(!attach.canConfirmPaste)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        Self.displayTitle(for: agent)
    }

    static func displayTitle(for agent: ConsoleAgent) -> String {
        agent.agent.title.isEmpty ? agent.agent.displayName : agent.agent.title
    }
}

/// Preserve edge-swipe navigation after the title bar is removed.
private struct AgentEdgeBackGesture: View {
    let dismiss: @MainActor () -> Void

    var body: some View {
        Color.clear
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard value.startLocation.x <= 24,
                              horizontal >= 72,
                              abs(value.translation.height) <= horizontal * 0.75
                        else { return }
                        dismiss()
                    })
            .accessibilityHidden(true)
    }
}

private struct AttachLinksView: View {
    let links: [AttachLink]
    let open: (AttachLink) -> Void
    let copy: (AttachLink) -> Void

    var body: some View {
        NavigationStack {
            List(links) { link in
                Button {
                    open(link)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.host)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(link.target)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(link.host)
                .accessibilityValue(link.target)
                .accessibilityHint("Opens in your default browser")
                .accessibilityAction(named: "Copy Link") {
                    copy(link)
                }
                .contextMenu {
                    Button("Copy Link", systemImage: "doc.on.doc") {
                        copy(link)
                    }
                }
            }
            .navigationTitle("Attach Links")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(idealWidth: 460, idealHeight: 520)
    }
}

private struct AttachmentStatusBar<Actions: View>: View {
    let icon: String
    let title: String
    let accessibilityLabel: String
    let actions: Actions

    init(
        icon: String,
        title: String,
        accessibilityLabel: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .lineLimit(3)
            HStack(spacing: 12) {
                Spacer()
                actions
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AgentTerminalKeyboardInsetModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.bottom, height)
    }
}
