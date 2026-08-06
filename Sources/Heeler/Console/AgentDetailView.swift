import PhotosUI
import SwiftUI
import UIKit

#if DEBUG
struct AttachRecoveryDiagnostic {
    let absence: Duration
    let sshGeneration: UInt64?

    func lines(
        attachStatus: AttachTerminalStore.Status,
        terminalSurfaceAttached: Bool
    ) -> [String] {
        [
            "Away: \(absence.components.seconds) s",
            sshObservation,
            "Attach session/channel: \(attachObservation(attachStatus))",
            "Terminal surface: "
                + (terminalSurfaceAttached
                    ? "new surface attached" : "attachment not yet observed"),
            "Render loop: unobserved (no presentation acknowledgement)",
        ]
    }

    private var sshObservation: String {
        guard let sshGeneration else {
            return "SSH generation: unobserved"
        }
        return "SSH generation: \(sshGeneration)"
    }

    private func attachObservation(_ status: AttachTerminalStore.Status) -> String {
        switch status {
        case .waitingForSize:
            "new PTY Attach waiting for terminal size"
        case .connecting:
            "new PTY Attach opening; first output unobserved"
        case .live:
            "new PTY Attach produced output"
        case .ended(let message):
            "new PTY Attach ended: \(message)"
        case .stopped:
            "new PTY Attach stopped"
        }
    }
}
#endif

/// The Agent detail screen: one interactive Attach terminal. Ghostty owns
/// rendering, scrollback, and IME; the adapter routes input-row taps and touch
/// scrolling without adding separate terminal chrome.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
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
    /// Opens another Agent from the terminal's switcher strip. The owner moves
    /// the selection, exactly as a tap in the Agent list would.
    private let onSwitch: (ConsoleAgent.ID) -> Void
    /// Leaves the screen after a confirmed close. A callback rather than
    /// `dismiss`: as a split view's detail root this view has nothing to
    /// dismiss — the owner clears the sidebar selection instead, which also
    /// pops the collapsed stack on iPhone.
    private let onClosed: () -> Void
    @State private var attach: AgentAttachStore
    /// Nil for agent kinds without a skills source catalog; the Keys
    /// keyboard hides the Skills tab in that case.
    @State private var skills: SkillsPaneStore?
    @State private var keyboardControl = TerminalKeyboardControl()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isConfirmingClose = false
    @State private var isStartingAgent = false
    @State private var isManagingSnippets = false
    @State private var isRenamingAgent = false
    /// The skill whose full document is on screen; set from the Skills
    /// pane's long-press menu.
    @State private var viewingSkill: AgentSkill?
    @State private var isRenamingWorkspace = false
    @State private var isShowingAttachLinks = false
    @State private var closeErrorMessage: String?
    #if DEBUG
    @State private var attachRecoveryDiagnostic: AttachRecoveryDiagnostic?
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        isOnStage: @escaping () -> Bool,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        attachStore: AgentAttachStore? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        _attach = State(
            initialValue: attachStore ?? AgentAttachStore(
                target: agent.agent.paneID,
                paneTitle: Self.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                isOnStage: isOnStage,
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID)
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
        guard
            let kind = SupportedAgentKind(rawValue: agent.agent.kind),
            SkillSourceCatalog.supports(kind)
        else { return nil }
        let projectRoot = agent.skillsProjectRoot
        return SkillsPaneStore { [console] forceRefresh in
            try await console.fetchSkills(
                kind: kind,
                projectRoot: projectRoot,
                on: agent.hostID,
                forceRefresh: forceRefresh)
        }
    }

    private var terminalScreen: TerminalScreenView {
        let currentAttach = attach
        let surfaceID = currentAttach.terminalID
        var screen = TerminalScreenView(feed: currentAttach.terminalFeed)
        #if DEBUG
        screen.onSurfaceAttached = {
            currentAttach.terminalSurfaceDidAttach(surfaceID)
        }
        #endif
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
        screen.onSnippet = { text, bracketed in
            attach.insertSnippet(text, bracketedPaste: bracketed)
        }
        screen.keysContext = TerminalKeysContext(
            settings: terminal,
            skills: skills.map { store in
                TerminalSkillsContext(store: store) { skill in
                    viewingSkill = skill
                }
            }
        ) {
            isManagingSnippets = true
        }
        screen.claimsKeyboard = { keyboardHandoff.consume(agent.id) }
        screen.keyboardControl = keyboardControl
        screen.isLocalInputEnabled = attach.isLocalInputEnabled
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { fontSize in terminal.zoom.setFontSize(fontSize) }
        return screen
    }

    var body: some View {
        lifecycleSurface
    }

    private var presentedSurface: some View {
        terminalSurface
        .toolbar {
            toolbarContent
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
            attach.selectImage(PhotosPickerImageSelection(item: item))
        }
        // Follows the grace period, not the raw scene phase: an image upload
        // is exactly the work worth finishing while the app is briefly out of
        // sight, and it is cancelled only once the app really suspends.
        .onChange(of: activity.phase) { _, phase in
            guard phase == .suspended else { return }
            attach.didEnterBackground()
        }
        // Not the phase: a background→foreground round trip the grace period
        // absorbs never leaves `.active`, so the return that has to prove the
        // attach channel is exactly the one an `onChange` on the phase cannot
        // see (#141).
        .onChange(of: activity.activationCount) { _, _ in
            handleActivation()
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            attach.transportGenerationDidChange(generation)
        }
        // Paired with the leave below: SwiftUI hands out onDisappear for
        // removals the user never made, and the state that comes back is the
        // one that left. Rejoining is what makes that survivable — and both
        // calls must stay synchronous, because the spurious pair can land in
        // one transaction and rejoin() can only undo a leave it can see.
        .onAppear {
            attach.rejoin()
        }
        .onDisappear {
            attach.leave()
        }
    }

    private var agentSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: console.agents.map {
                TerminalAgentSwitcherItem(
                    id: $0.id, title: $0.switcherLabel, status: $0.agent.status)
            },
            selectedID: agent.id,
            onSelect: switchToAgent)
    }

    private var terminalSurface: some View {
        terminalScreen
            .id(attach.terminalID)
        .overlay { statusOverlay }
        #if DEBUG
        .overlay(alignment: .topLeading) { attachRecoveryDiagnosticOverlay }
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            imageAttachStatus
        }
        // Below the keyboard's own inset, so the strip rides above the
        // keyboard while it is up and rests on the screen's edge once it is
        // down. It outlives the keyboard on purpose: an Agent is worth
        // switching to whether or not the user is typing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalAgentSwitcherRow(
                switcher: agentSwitcher,
                // The strip's own toggle: the inset is what the terminal has
                // already been resized for, so it is what the icon must agree
                // with.
                isKeyboardUp: keyboardInset.height > 0,
                toggleKeyboard: keyboardControl.toggleKeyboard)
        }
        // Not SwiftUI's keyboard avoidance: it retracts in two stages and the
        // terminal would resize twice per dismissal. See TerminalKeyboardInset.
        .terminalKeyboardInset(keyboardInset)
        // background(_:ignoresSafeAreaEdges:) defaults to .all: the theme
        // colour reaches under the transparent navigation bar and into the
        // home-indicator area without moving the terminal grid or touching
        // keyboard resize. Must stay outside the safeAreaInset above.
        .background(
            terminal.themes.selection(for: colorScheme)
                .surfaceBackground(for: colorScheme))
        .toolbarColorScheme(
            terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme),
            for: .navigationBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleActivation() {
        let afterPossibleSuspension = activity.lastAbsenceMayHaveSuspended
        attach.didBecomeActive(afterPossibleSuspension: afterPossibleSuspension)

        #if DEBUG
        if afterPossibleSuspension, let absence = activity.lastAbsenceDuration {
            attachRecoveryDiagnostic = AttachRecoveryDiagnostic(
                absence: absence,
                sshGeneration: console.hostConnectionGenerations[agent.hostID])
        } else {
            attachRecoveryDiagnostic = nil
        }
        #endif
    }

    #if DEBUG
    @ViewBuilder
    private var attachRecoveryDiagnosticOverlay: some View {
        if let diagnostic = attachRecoveryDiagnostic {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attach recovery diagnostic")
                    .fontWeight(.semibold)
                ForEach(
                    Array(
                        diagnostic.lines(
                            attachStatus: attach.terminalStatus,
                            terminalSurfaceAttached: attach.terminalSurfaceAttached
                        ).enumerated()),
                    id: \.offset
                ) { _, line in
                    Text(line)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("attach-recovery-diagnostic")
        }
    }

    #endif

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !attach.attachLinks.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAttachLinks = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                        Text("\(attach.attachLinks.count)")
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel("Attach Links")
                .accessibilityValue(attachLinkCountDescription)
                .popover(isPresented: $isShowingAttachLinks) {
                    AttachLinksView(
                        links: attach.attachLinks,
                        open: { link in openAttachLink(link) },
                        copy: { link in UIPasteboard.general.string = link.target })
                    .presentationCompactAdaptation(.sheet)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Attach Image", systemImage: "photo.badge.plus")
            }
            .disabled(!attach.canSelectImage)
            .accessibilityLabel("Attach Image")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Agent", systemImage: "plus") {
                    isStartingAgent = true
                }
                Button("Snippets", systemImage: "quote.bubble") {
                    isManagingSnippets = true
                }
                Button("Rename Agent", systemImage: "pencil") {
                    isRenamingAgent = true
                }
                Button("Rename Workspace", systemImage: "pencil.line") {
                    isRenamingWorkspace = true
                }
                Button("Close Agent", systemImage: "trash", role: .destructive) {
                    isConfirmingClose = true
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
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
        // down must not raise one on the other side.
        if keyboardInset.height > 0 {
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
        switch attach.terminalStatus {
        case .waitingForSize, .connecting:
            // No dim: a reattach would otherwise flash the whole screen dark.
            TerminalStatusDialog(
                glyph: .progress,
                title: "Connecting…",
                palette: themePalette,
                dimsBackground: false)
        case .ended(let message):
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"),
                title: "Session Ended",
                message: message,
                palette: themePalette
            ) {
                Button("Reattach") { attach.retryTerminal() }
                    .buttonStyle(.borderedProminent)
            }
        // .live needs nothing, and .stopped only reaches the view while the
        // screen is on its way off stage (see `AgentAttachStore.terminalStatus`).
        case .live, .stopped:
            EmptyView()
        }
    }

    @ViewBuilder
    private var imageAttachStatus: some View {
        switch attach.imageState {
        case .idle:
            EmptyView()
        case .preparing:
            ImageAttachStatusBar(
                icon: "photo",
                title: "Preparing Image…",
                accessibilityLabel: "Preparing Image"
            ) {
                Button("Cancel", role: .cancel) { attach.cancelImage() }
            }
        case .uploading(let progress):
            ImageAttachStatusBar(
                icon: "arrow.up.circle",
                title: "Uploading Image… \(Int(progress.fractionCompleted * 100))%",
                accessibilityLabel:
                    "Uploading Image, \(Int(progress.fractionCompleted * 100)) percent"
            ) {
                Button("Cancel", role: .cancel) { attach.cancelImage() }
            }
        case .failed(let failure), .backgroundInterrupted(let failure):
            ImageAttachStatusBar(
                icon: "exclamationmark.triangle",
                title: failure.message,
                accessibilityLabel: failure.message
            ) {
                if failure.isRetryable {
                    Button("Retry") { attach.retryImage() }
                }
                Button("Dismiss", role: .cancel) { attach.dismissImageResult() }
            }
        case .completed(let result):
            ImageAttachStatusBar(
                icon: result.copied && result.inserted ? "checkmark.circle" : "info.circle",
                title: result.message,
                accessibilityLabel: result.message
            ) {
                if !result.copied {
                    Button("Copy Path") { attach.copyImagePath() }
                }
                if !result.inserted {
                    Button("Insert Path") { attach.insertImagePath() }
                }
                Button("Done", role: .cancel) { attach.dismissImageResult() }
            }
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
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        Self.displayTitle(for: agent)
    }

    private var attachLinkCountDescription: String {
        let count = attach.attachLinks.count
        return count == 1 ? "1 distinct link" : "\(count) distinct links"
    }

    private static func displayTitle(for agent: ConsoleAgent) -> String {
        agent.agent.title.isEmpty ? agent.agent.displayName : agent.agent.title
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

private struct ImageAttachStatusBar<Actions: View>: View {
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
