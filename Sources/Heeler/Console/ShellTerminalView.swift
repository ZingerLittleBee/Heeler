import SwiftUI
import UIKit

/// Local Agent Detail destination for one ordinary herdr shell terminal.
/// Ghostty owns direct keyboard input, output, scrollback and resize. There is
/// intentionally no Composer, Agent switcher, staging, notification, or Agent
/// operation on this surface.
///
/// The keyboard follows the user across the screen change: a terminal opened
/// with the keyboard up comes up typing-ready, one opened with it down stays
/// down, and leaving for an Agent carries the state back the same way. The
/// intent travels through `TerminalKeyboardHandoff`, as Agent switches do.
///
/// The keyboard chrome is app-owned, the Composer's arrangement: the input row
/// sits above the keyboard as ordinary content, and Keys mode suppresses the
/// system keyboard behind an app-side dock at the measured keyboard footprint.
/// Nothing rides the keyboard itself, so switching modes cannot tear the row
/// down, and the IME's composition survives a round trip through Keys.
struct ShellTerminalView: View {
    let store: ShellTerminalStore
    let agentID: ConsoleAgent.ID
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
    let isReturning: Bool
    /// Nil hides the Close Terminal action entirely (previews, tests).
    var isClosingTerminal: Bool = false
    var onCloseTerminal: (@MainActor () -> Void)? = nil
    var managesLifecycle = true
    var surfaceRetention: TerminalSurfaceRetention?
    var title = "Terminal"
    var backTitle = "Back to Agent"
    /// Edge-docked Workspace navigation; nil on surfaces with nowhere to route.
    var workspaceDrawer: WorkspaceTerminalDrawer?
    /// Carries the keyboard state in from the screen that opened this
    /// terminal and back out to the Agent it leaves for; nil (previews,
    /// tests) opens with the keyboard down.
    var keyboardHandoff: TerminalKeyboardHandoff? = nil
    /// Whether Back and Close Terminal land on `agentID`'s detail. False on
    /// the Console's terminal detail, whose Back returns to the Agent list.
    var backReturnsToAgent = true
    let onBack: @MainActor () async -> Void

    @State private var keyboardControl = TerminalKeyboardControl()
    @State private var keyboardMode: TerminalKeyboardMode = .text
    @State private var keyboardInset = TerminalKeyboardInset()
    @State private var isConfirmingClose = false
    @Environment(\.colorScheme) private var colorScheme
    /// The scene root's window, known before this screen first renders.
    @Environment(\.sceneWindow) private var sceneWindow
    @Environment(\.detailCrossfade) private var detailCrossfade
    /// This view's own window, for hosts without a scene root.
    @State private var mountedWindow = WindowReference()
    @Environment(\.detailTopChromeInset) private var topChromeInset

    /// The status bar height of the window this terminal is in; see
    /// `AgentTerminalView.statusBarInset`.
    private var statusBarInset: CGFloat {
        (sceneWindow?.window ?? mountedWindow.window)?.safeAreaInsets.top ?? 0
    }

    private var terminalScreen: TerminalScreenView {
        var screen = TerminalScreenView(feed: store.terminalFeed)
        screen.retention = surfaceRetention
        screen.onSizeChanged = { cols, rows in
            store.viewDidResize(cols: cols, rows: rows)
        }
        screen.onSend = { store.send($0) }
        screen.onScroll = { sequence, rows in
            store.scroll(sequence, rows: rows)
        }
        screen.onPaste = { text, bracketed in
            store.requestPaste(text, bracketedPaste: bracketed)
        }
        screen.keyboardControl = keyboardControl
        screen.isLocalInputEnabled = true
        // The first surface of this screen takes the keyboard only if the
        // screen it came from left it up. A later surface on the same screen
        // (a recovered pipeline) is a replacement, not an arrival: it keeps
        // whatever the user last asked this screen for, read from the surface
        // it replaces, which `TerminalKeyboardControl` still holds here.
        // When the keyboard is coming, the inset must already know the window
        // and expect it before UIKit posts the first will-show, or that frame
        // is dropped and Ghostty keeps rendering under the keyboard:
        // `WindowReader` reports the window from a sibling, whose order
        // against the surface's own `didMoveToWindow` is not guaranteed.
        screen.claimsKeyboard = { [keyboardInset, keyboardControl, keyboardHandoff, sceneWindow] in
            let claims: Bool
            if let previous = keyboardControl.terminal {
                claims = previous.wantsKeyboard
            } else {
                claims = keyboardHandoff?.consumeShellTerminal() ?? false
            }
            guard claims else { return false }
            if let window = sceneWindow?.window {
                keyboardInset.attach(to: window)
            }
            Self.prepareKeyboardMode(.text, inset: keyboardInset)
            return true
        }
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { terminal.zoom.setFontSize($0) }
        return screen
    }

    /// The Composer's keyboard arithmetic, reused verbatim: Keys mode is the
    /// tools presentation, a raised system keyboard is the system one.
    private var keyboardPresentation: AgentComposerKeyboardPresentation {
        Self.keyboardPresentation(
            mode: keyboardMode,
            insetHeight: keyboardInset.height,
            keyboardIsUp: keyboardControl.isKeyboardUp)
    }

    /// Switching back to Text re-presents the system keyboard in place, and
    /// UIKit passes through a transient will-hide that zeroes the measured
    /// inset on the way — while the terminal keeps first responder the whole
    /// time. Deriving hidden from the height alone tore the input row down
    /// for that beat and let it ride back up with the keyboard. A real
    /// dismissal (a sheet, leaving the screen) resigns first responder before
    /// its will-hide, so the responder is what tells the two apart. Every
    /// transition that matters arrives with a height change, so rendering
    /// keyed off the observable inset still re-reads the responder in time.
    static func keyboardPresentation(
        mode: TerminalKeyboardMode,
        insetHeight: CGFloat,
        keyboardIsUp: Bool
    ) -> AgentComposerKeyboardPresentation {
        if mode == .controls { return .tools }
        if insetHeight > 0 || keyboardIsUp { return .system }
        return .hidden
    }

    private var keyboardLayout: AgentComposerKeyboardLayout {
        Self.keyboardLayout(
            inset: keyboardInset, presentation: keyboardPresentation)
    }

    /// A hardware keyboard attaching hides the system keyboard while the
    /// terminal keeps first responder, so Text stays `.system`; the
    /// confirmed dismissal is what releases its pin to the last footprint.
    static func keyboardLayout(
        inset: TerminalKeyboardInset,
        presentation: AgentComposerKeyboardPresentation
    ) -> AgentComposerKeyboardLayout {
        AgentComposerKeyboardLayout(
            currentHeight: inset.height,
            lastPresentedHeight: inset.lastPresentedHeight,
            presentation: presentation,
            softwareKeyboardDismissed: inset.isSoftwareKeyboardDismissed)
    }

    /// Keys suppresses the system keyboard, so UIKit really hides it and the
    /// dismissal is confirmed while the dock is up. Returning to Text
    /// expects the keyboard again, keeping the pre-show pin until its frame
    /// arrives.
    static func prepareKeyboardMode(
        _ mode: TerminalKeyboardMode, inset: TerminalKeyboardInset
    ) {
        switch mode {
        case .controls:
            // Candidate bars publish transition-only frames while UIKit
            // removes the system keyboard; the dock keeps the last complete
            // measurement instead.
            inset.pauseHeightCapture()
        case .text:
            inset.resumeHeightCapture()
            inset.expectSoftwareKeyboard()
        }
    }

    private var isKeysDockPresented: Bool {
        keyboardMode == .controls
    }

    var body: some View {
        terminalScreen
            .id(store.terminalID)
            .overlay {
                if let workspaceDrawer {
                    keyboardCarryingDrawer(workspaceDrawer).palette(themePalette)
                }
            }
            .overlay { statusOverlay }
            // The input row and controls dock must stay above the edge
            // gesture's hit region, including their leftmost buttons.
            .overlay(alignment: .leading) {
                ShellTerminalEdgeBackGesture(isEnabled: !isReturning) {
                    await goBack()
                }
            }
            // Always present, keyboard up or down: with no title bar, its
            // More menu is the only visible way back or to Close Terminal.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ShellTerminalInputRow(
                    mode: Binding(
                        get: { keyboardMode },
                        set: { setKeyboardMode($0) }),
                    paste: { keyboardControl.paste($0) },
                    more: ShellTerminalMoreMenu(
                        title: title,
                        backTitle: backTitle,
                        isReturning: isReturning,
                        isClosingTerminal: isClosingTerminal,
                        onBack: { Task { await goBack() } },
                        onCloseTerminal: onCloseTerminal == nil
                            ? nil : { isConfirmingClose = true }))
            }
            .padding(.bottom, keyboardLayout.contentInset)
            // This dock is always present at the system keyboard's last
            // complete height. In Text mode it is transparent behind the
            // system keyboard; in Keys mode it is already in place when UIKit
            // removes its native candidate row, so no intermediate gap is
            // ever exposed. See the Composer's tools dock, which this mirrors.
            .overlay(alignment: .bottom) {
                ShellTerminalKeysDock(
                    settings: terminal,
                    height: keyboardLayout.availableToolsHeight,
                    control: keyboardControl)
                .opacity(isKeysDockPresented ? 1 : 0)
                .allowsHitTesting(isKeysDockPresented)
                .accessibilityHidden(!isKeysDockPresented)
            }
            // Keyboard avoidance is owned by `TerminalKeyboardInset`; UIKit's
            // keyboard safe area would resize Ghostty a second time.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // No title bar, as on Agent detail: the navigation bar stays
            // only as the owner of the status bar appearance, and this inset
            // keeps terminal output below the system clock.
            .padding(.top, max(statusBarInset, topChromeInset))
            .background {
                // Keyboard geometry and the status bar inset follow this
                // view's own window, not whichever window of the app is key.
                WindowReader { window in
                    keyboardInset.attach(to: window)
                    mountedWindow.attach(window)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background(
                terminal.themes.selection(for: colorScheme)
                    .surfaceBackground(for: colorScheme)
            )
            .ignoresSafeArea(.container, edges: .top)
            .toolbarColorScheme(
                terminal.themes.selection(for: colorScheme)
                    .chromeColorScheme(for: colorScheme),
                for: .navigationBar
            )
            .navigationBarBackButtonHidden(true)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // `toolbarColorScheme` takes effect only while the bar background
            // is visible. A clear visible background keeps the bar visually
            // absent while still applying status-bar contrast.
            .toolbarBackground(Color.clear, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar(.visible, for: .navigationBar)
            .confirmationDialog(
                "Close Terminal?", isPresented: $isConfirmingClose, titleVisibility: .visible
            ) {
                Button("Close Terminal", role: .destructive) {
                    if backReturnsToAgent {
                        armAgentKeyboardHandoffIfKeyboardIsUp(for: agentID)
                    }
                    onCloseTerminal?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This closes the pane on the Host, ending anything running in it. "
                        + "Going Back instead leaves it for desktop handoff.")
            }
            .sheet(
                isPresented: Binding(
                    get: { store.pendingPaste != nil },
                    set: { if !$0 { store.cancelPaste() } })
            ) {
                pasteReviewSheet
            }
            .alert(
                "Paste Blocked",
                isPresented: Binding(
                    get: { store.pasteErrorMessage != nil },
                    set: { if !$0 { store.clearPasteError() } })
            ) {
                Button("OK", role: .cancel) { store.clearPasteError() }
            } message: {
                Text(store.pasteErrorMessage ?? "")
            }
            .modifier(ConsoleDetailPresentationRegistration(
                agentID: agentID,
                isPresenting: isConfirmingClose || store.pendingPaste != nil
                    || store.pasteErrorMessage != nil))
            .onChange(of: activity.activationCount, initial: true) { _, _ in
                store.didBecomeActive(
                    afterPossibleSuspension: activity.lastAbsenceMayHaveSuspended)
            }
            // A recovered terminal is a fresh surface that starts in Text and
            // decides the keyboard itself from the user's last intent (see
            // `claimsKeyboard`); app-side mode state has to follow it back to
            // Text without raising anything on its own.
            .onChange(of: store.terminalID) { _, _ in
                setKeyboardMode(.text, restoresSystemKeyboard: false)
            }
            // On iPad the Keys dock stands without a responder, so a tap on
            // the terminal's input row asks for the system keyboard.
            .onChange(of: keyboardControl.isFirstResponder) { _, isUp in
                guard isUp, keyboardMode == .controls,
                      TerminalKeyboardMode.controlsReleaseFirstResponder
                else { return }
                setKeyboardMode(.text)
            }
            .onAppear {
                detailCrossfade?.contentDidAppear()
                // A keyboard inherited from the previous screen is already
                // up: lay the input row out above it from the first frame.
                if let window = sceneWindow?.window {
                    keyboardInset.inheritPresentedKeyboard(in: window)
                }
                if managesLifecycle { store.rejoin() }
            }
            .onDisappear {
                // A departure the next screen inherits the keyboard from
                // keeps first responder until that screen claims it: a
                // dismissal here would start UIKit's hide, and the claim
                // could only re-present the keyboard once it had dropped.
                if keyboardHandoff?.isArmed != true {
                    keyboardControl.dismissKeyboard()
                }
                if managesLifecycle { store.leave() }
            }
    }

    /// `restoresSystemKeyboard` is false when Text follows a fresh surface
    /// rather than the user leaving Keys: nothing was raised to bring back.
    private func setKeyboardMode(
        _ mode: TerminalKeyboardMode, restoresSystemKeyboard: Bool = true
    ) {
        guard mode != keyboardMode else { return }
        Self.prepareKeyboardMode(mode, inset: keyboardInset)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            keyboardMode = mode
        }
        keyboardControl.setKeyboardMode(mode)
        // See `TerminalKeyboardMode.controlsReleaseFirstResponder`.
        guard TerminalKeyboardMode.controlsReleaseFirstResponder else { return }
        switch mode {
        case .controls:
            keyboardControl.dismissKeyboard()
        case .text:
            if restoresSystemKeyboard, !keyboardControl.isFirstResponder {
                keyboardControl.requestKeyboard()
            }
        }
    }

    /// Back leaves for the Agent (or the Console): the keyboard state goes
    /// with it, captured before the screen is torn down.
    private func goBack() async {
        if backReturnsToAgent {
            armAgentKeyboardHandoffIfKeyboardIsUp(for: agentID)
        }
        await onBack()
    }

    /// The Keys dock counts as up: on iPad it stands without a responder.
    private var isKeyboardUpForHandoff: Bool {
        keyboardControl.isKeyboardUp || keyboardMode == .controls
    }

    private func armAgentKeyboardHandoffIfKeyboardIsUp(for id: ConsoleAgent.ID) {
        guard let keyboardHandoff, isKeyboardUpForHandoff else { return }
        keyboardHandoff.arm(for: id, mode: keyboardMode == .controls ? .controls : .text)
    }

    private func armShellTerminalKeyboardHandoffIfKeyboardIsUp() {
        guard let keyboardHandoff else { return }
        if isKeyboardUpForHandoff {
            keyboardHandoff.armShellTerminal()
        } else {
            keyboardHandoff.cancelShellTerminal()
        }
    }

    /// The drawer's routes replace this screen with an Agent or another
    /// terminal; each captures the keyboard state before it leaves.
    private func keyboardCarryingDrawer(_ drawer: WorkspaceTerminalDrawer) -> WorkspaceTerminalDrawer {
        var carrying = drawer
        let onSelect = drawer.onSelect
        carrying.onSelect = { target in
            if let agentID = target.agentID {
                armAgentKeyboardHandoffIfKeyboardIsUp(for: agentID)
            } else if target.paneID != store.identity.paneID {
                armShellTerminalKeyboardHandoffIfKeyboardIsUp()
            }
            onSelect(target)
        }
        if let onNewTerminal = drawer.onNewTerminal {
            carrying.onNewTerminal = {
                armShellTerminalKeyboardHandoffIfKeyboardIsUp()
                onNewTerminal()
            }
        }
        return carrying
    }

    private var themePalette: TerminalThemePalette {
        terminal.themes.selection(for: colorScheme).palette(for: colorScheme)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let presentation = TerminalStatusPresentation(status: store.terminalStatus) {
            switch presentation.kind {
            case .connecting:
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
                    Button("Reattach") { store.retryTerminal() }
                        .buttonStyle(.borderedProminent)
                    if !managesLifecycle {
                        Button("Take Over") { store.takeOverTerminal() }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Disconnects another client's attachment to this terminal")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pasteReviewSheet: some View {
        if let review = store.pendingPaste {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(review.lineCount) lines, \(review.characterCount) characters")
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
                        Button("Cancel", role: .cancel) { store.cancelPaste() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste") { store.confirmPaste() }
                            .disabled(!store.canConfirmPaste)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// The input row above the keyboard: paste, the Text/Keys mode control, and
/// new line. App content rather than a keyboard accessory, so a mode switch
/// never tears it down and UIKit's candidate-row teardown never moves it.
/// The shell terminal's navigation, folded into the input row's More button
/// now that the surface has no title bar. The terminal's title heads the menu
/// so the path is still readable.
struct ShellTerminalMoreMenu: View {
    let title: String
    let backTitle: String
    let isReturning: Bool
    let isClosingTerminal: Bool
    let onBack: () -> Void
    /// Nil hides Close Terminal entirely (previews, tests).
    let onCloseTerminal: (() -> Void)?

    var body: some View {
        Menu {
            Section(title) {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                }
                .disabled(isReturning)
                if let onCloseTerminal {
                    Button(role: .destructive, action: onCloseTerminal) {
                        Label("Close Terminal", systemImage: "trash")
                    }
                    .disabled(isClosingTerminal || isReturning)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: ShellTerminalInputRow.glyphPointSize))
                .foregroundStyle(Color(uiColor: .label))
                .frame(
                    width: InputChromeLayout.shellAccessoryButtonWidth,
                    height: InputChromeLayout.shortcutRowHeight)
                .contentShape(.rect)
        }
        .accessibilityLabel("More")
        .accessibilityHint("Opens terminal actions")
    }
}

struct ShellTerminalInputRow: View {
    @Binding var mode: TerminalKeyboardMode
    let paste: (String) -> Void
    let more: ShellTerminalMoreMenu
    /// Matches the Composer chrome's small glyphs, or the row's icons read as
    /// borrowed from a different set.
    static let glyphPointSize: CGFloat = 12
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var sizeClass: InputShortcutStripPresentation.SizeClass {
        horizontalSizeClass == .regular ? .regular : .compact
    }

    var body: some View {
        HStack(spacing: 0) {
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                paste(text)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            // The system default is an accent-tinted tile, which shouts next
            // to the mode control. Painting the fill with the row's own
            // background leaves the glyph reading as a bare icon.
            .tint(Color(uiColor: .secondarySystemBackground))
            .frame(
                width: InputChromeLayout.shellAccessoryButtonWidth,
                height: InputChromeLayout.shortcutRowHeight)

            Spacer(minLength: 4)

            Picker("Terminal keyboard mode", selection: $mode) {
                Text("Text").tag(TerminalKeyboardMode.text)
                Text("Keys").tag(TerminalKeyboardMode.controls)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: InputChromeLayout.modePickerMaxWidth(for: sizeClass))

            Spacer(minLength: 4)

            // A line break without submitting (Shift+Enter) lives on the Keys
            // keyboard; the row keeps only what Text mode cannot do itself.
            more
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / max(displayScale, 1))
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// The shell terminal's Keys dock shares its full keyboard with Agent tools.
/// Appearance is available alongside it; Skills and Snippets stay Agent-specific.
struct ShellTerminalKeysDock: View {
    let settings: TerminalSettings
    let height: CGFloat
    let control: TerminalKeyboardControl
    @State private var selectedTab: TerminalKeysTab = .controls

    static let tabs: [TerminalKeysTab] = [.controls, .appearance]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    TerminalFullKeyboard(
                        isEnabled: true, keyboardControl: control,
                        send: control.sendTerminalKey)
                case .appearance:
                    TerminalAppearancePane(
                        themes: settings.themes,
                        zoom: settings.zoom,
                        fonts: settings.fonts)
                case .skills, .snippets:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 4) {
                ForEach(Self.tabs) { tab in
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
    }
}

private struct ShellTerminalEdgeBackGesture: View {
    let isEnabled: Bool
    let onBack: @MainActor () async -> Void
    /// Hit strip along the leading edge. Not input-chrome width; named so
    /// this file has no raw width literals.
    private static let hitWidth: CGFloat = 24
    private static let minimumTranslation: CGFloat = 72

    var body: some View {
        Color.clear
            .frame(width: Self.hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard isEnabled,
                            value.startLocation.x <= Self.hitWidth,
                            horizontal >= Self.minimumTranslation,
                            abs(value.translation.height) <= horizontal * 0.75
                        else { return }
                        Task { await onBack() }
                    }
            )
            .accessibilityHidden(true)
    }
}
