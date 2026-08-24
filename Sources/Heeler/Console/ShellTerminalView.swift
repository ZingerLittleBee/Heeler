import SwiftUI

/// Local Agent Detail destination for one ordinary herdr shell terminal.
/// Ghostty owns direct keyboard input, output, scrollback and resize. There is
/// intentionally no Composer, Agent switcher, staging, notification, or Agent
/// operation on this surface.
struct ShellTerminalView: View {
    let store: ShellTerminalStore
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
    let isReturning: Bool
    let onBack: @MainActor () async -> Void

    @State private var keyboardControl = TerminalKeyboardControl()
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
        screen.keysContext = TerminalKeysContext(
            settings: terminal,
            showsSnippets: false,
            manageSnippets: {})
        screen.keyboardControl = keyboardControl
        screen.isLocalInputEnabled = true
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { terminal.zoom.setFontSize($0) }
        return screen
    }

    var body: some View {
        terminalScreen
            .id(store.terminalID)
            .overlay { statusOverlay }
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
            .onAppear { store.rejoin() }
            .onDisappear { store.leave() }
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
