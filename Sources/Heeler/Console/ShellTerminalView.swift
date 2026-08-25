import SwiftUI
import UIKit

/// Local Agent Detail destination for one ordinary herdr shell terminal.
/// Ghostty owns direct keyboard input, output, scrollback and resize. There is
/// intentionally no Composer, Agent switcher, staging, notification, or Agent
/// operation on this surface.
///
/// The keyboard chrome is app-owned, the Composer's arrangement: the input row
/// sits above the keyboard as ordinary content, and Keys mode suppresses the
/// system keyboard behind an app-side dock at the measured keyboard footprint.
/// Nothing rides the keyboard itself, so switching modes cannot tear the row
/// down, and the IME's composition survives a round trip through Keys.
struct ShellTerminalView: View {
    let store: ShellTerminalStore
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
    let isReturning: Bool
    let onBack: @MainActor () async -> Void

    @State private var keyboardControl = TerminalKeyboardControl()
    @State private var keyboardMode: TerminalKeyboardMode = .text
    @State private var keyboardInset = TerminalKeyboardInset()
    @Environment(\.colorScheme) private var colorScheme

    private var terminalScreen: TerminalScreenView {
        var screen = TerminalScreenView(feed: store.terminalFeed)
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
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { terminal.zoom.setFontSize($0) }
        return screen
    }

    /// The Composer's keyboard arithmetic, reused verbatim: Keys mode is the
    /// tools presentation, a raised system keyboard is the system one.
    private var keyboardPresentation: AgentComposerKeyboardPresentation {
        if keyboardMode == .controls { return .tools }
        return keyboardInset.height > 0 ? .system : .hidden
    }

    private var keyboardLayout: AgentComposerKeyboardLayout {
        AgentComposerKeyboardLayout(
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight,
            presentation: keyboardPresentation)
    }

    private var isKeysDockPresented: Bool {
        keyboardMode == .controls
    }

    var body: some View {
        terminalScreen
            .id(store.terminalID)
            .overlay { statusOverlay }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardPresentation != .hidden {
                    ShellTerminalInputRow(
                        mode: Binding(
                            get: { keyboardMode },
                            set: { setKeyboardMode($0) }),
                        paste: { keyboardControl.paste($0) },
                        insertNewLine: {
                            UIDevice.current.playInputClick()
                            keyboardControl.sendNewLine()
                        })
                }
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
                    sendControlKey: { keyboardControl.sendControlKey($0) })
                .opacity(isKeysDockPresented ? 1 : 0)
                .allowsHitTesting(isKeysDockPresented)
                .accessibilityHidden(!isKeysDockPresented)
            }
            // Keyboard avoidance is owned by `TerminalKeyboardInset`; UIKit's
            // keyboard safe area would resize Ghostty a second time.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(
                terminal.themes.selection(for: colorScheme)
                    .surfaceBackground(for: colorScheme)
            )
            .toolbarColorScheme(
                terminal.themes.selection(for: colorScheme)
                    .chromeColorScheme(for: colorScheme),
                for: .navigationBar
            )
            .navigationBarBackButtonHidden(true)
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await onBack() }
                    } label: {
                        Label("Back to Agent", systemImage: "chevron.left")
                    }
                    .disabled(isReturning)
                }
            }
            .overlay(alignment: .leading) {
                ShellTerminalEdgeBackGesture(isEnabled: !isReturning) {
                    await onBack()
                }
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
            .onChange(of: activity.activationCount, initial: true) { _, _ in
                store.didBecomeActive(
                    afterPossibleSuspension: activity.lastAbsenceMayHaveSuspended)
            }
            // A recovered terminal is a fresh surface with no keyboard raised;
            // app-side mode state has to follow it back to Text.
            .onChange(of: store.terminalID) { _, _ in
                setKeyboardMode(.text)
            }
            .onAppear { store.rejoin() }
            .onDisappear { store.leave() }
    }

    private func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        guard mode != keyboardMode else { return }
        switch mode {
        case .controls:
            // Candidate bars publish transition-only frames while UIKit
            // removes the system keyboard; the dock keeps the last complete
            // measurement instead.
            keyboardInset.pauseHeightCapture()
        case .text:
            keyboardInset.resumeHeightCapture()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            keyboardMode = mode
        }
        keyboardControl.setKeyboardMode(mode)
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
struct ShellTerminalInputRow: View {
    @Binding var mode: TerminalKeyboardMode
    let paste: (String) -> Void
    let insertNewLine: () -> Void
    /// Matches the Composer chrome's small glyphs, or the row's icons read as
    /// borrowed from a different set.
    private static let glyphPointSize: CGFloat = 12
    @Environment(\.displayScale) private var displayScale

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
            .frame(width: 44, height: 44)

            Spacer(minLength: 4)

            Picker("Terminal keyboard mode", selection: $mode) {
                Text("Text").tag(TerminalKeyboardMode.text)
                Text("Keys").tag(TerminalKeyboardMode.controls)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 184)

            Spacer(minLength: 4)

            Button(action: insertNewLine) {
                Image(systemName: "text.append")
                    .font(.system(size: Self.glyphPointSize))
                    .foregroundStyle(Color(uiColor: .label))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Insert New Line")
            .accessibilityHint("Adds a line break without submitting")
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

/// The shell terminal's Keys dock: the full control pad and the Appearance
/// pane. No Snippets or Skills — those belong to the Agent Composer.
struct ShellTerminalKeysDock: View {
    let settings: TerminalSettings
    let height: CGFloat
    let sendControlKey: (TerminalControlKey) -> Void
    @State private var selectedTab: TerminalKeysTab = .controls

    static let tabs: [TerminalKeysTab] = [.controls, .appearance]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    TerminalControlPadRepresentable(send: sendControlKey)
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
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
    }
}

/// Hosts the UIKit control pad — key repeat and touch handling included —
/// inside the SwiftUI dock.
private struct TerminalControlPadRepresentable: UIViewRepresentable {
    let send: (TerminalControlKey) -> Void

    func makeUIView(context _: Context) -> TerminalControlPadView {
        TerminalControlPadView(send: send)
    }

    func updateUIView(_: TerminalControlPadView, context _: Context) {}
}

private struct ShellTerminalEdgeBackGesture: View {
    let isEnabled: Bool
    let onBack: @MainActor () async -> Void

    var body: some View {
        Color.clear
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard isEnabled,
                            value.startLocation.x <= 24,
                            horizontal >= 72,
                            abs(value.translation.height) <= horizontal * 0.75
                        else { return }
                        Task { await onBack() }
                    }
            )
            .accessibilityHidden(true)
    }
}
