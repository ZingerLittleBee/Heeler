import PhotosUI
import SwiftUI

/// The Agent detail screen: one interactive Attach terminal. Ghostty owns
/// rendering, scrollback, and IME; the adapter routes input-row taps and touch
/// scrolling without adding separate terminal chrome.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminalThemes: TerminalThemeSettings
    private let transport: @Sendable () async -> (any Transport)?
    @State private var input: TerminalInputController
    @State private var store: AttachTerminalStore
    @State private var imageAttach: ImageAttachStore
    @State private var close: ClosePaneStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isConfirmingClose = false
    @State private var isShowingSettings = false
    @State private var closeErrorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminalThemes: TerminalThemeSettings
    ) {
        self.agent = agent
        self.console = console
        self.terminalThemes = terminalThemes
        let transport = console.transportProvider(for: agent.hostID)
        let input = TerminalInputController()
        self.transport = transport
        _input = State(initialValue: input)
        _store = State(
            initialValue: AttachTerminalStore(
                target: agent.agent.paneID,
                input: input,
                transport: transport))
        _imageAttach = State(
            initialValue: ImageAttachStore(
                transport: transport,
                input: input))
        _close = State(
            initialValue: ClosePaneStore(paneTitle: Self.displayTitle(for: agent)) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            })
    }

    var body: some View {
        TerminalScreenView(
            feed: store.feed,
            onSizeChanged: { cols, rows in
                store.viewDidResize(cols: cols, rows: rows)
            },
            onSend: { keystrokes in store.send(keystrokes) },
            onPaste: { text in _ = input.requestPaste(text) },
            isLocalInputEnabled: !input.isPaused,
            theme: terminalThemes.theme
        )
        .id(ObjectIdentifier(store))
        .overlay { statusOverlay }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            imageAttachStatus
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Attach Image", systemImage: "photo.badge.plus")
                }
                .disabled(store.status != .live || !imageAttach.canSelectImage)
                .accessibilityLabel("Attach Image")
            }
            ToolbarItem(placement: .primaryAction) {
                AgentStatusBadge(status: agent.agent.status)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Terminal Theme", systemImage: "paintpalette") {
                        isShowingSettings = true
                    }
                    Button("Close Agent", systemImage: "trash", role: .destructive) {
                        isConfirmingClose = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(terminalThemes: terminalThemes)
        }
        .sheet(
            isPresented: Binding(
                get: { input.pendingPaste != nil },
                set: { if !$0 { input.cancelPaste() } })
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
                get: { input.pasteErrorMessage != nil },
                set: { if !$0 { input.clearPasteError() } })
        ) {
            Button("OK", role: .cancel) {
                input.clearPasteError()
            }
        } message: {
            Text(input.pasteErrorMessage ?? "")
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            imageAttach.select(PhotosPickerImageSelection(item: item))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                imageAttach.didBecomeActive()
            case .background:
                imageAttach.didEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            guard generation != nil else { return }
            reconnect()
        }
        .onDisappear {
            let terminal = store
            let imageAttach = imageAttach
            console.scheduleTerminalTeardown(for: agent.hostID) {
                await imageAttach.leaveAttach()
                await terminal.stop()
            }
        }
    }

    private func reconnect() {
        let previous = store
        console.scheduleTerminalTeardown(for: agent.hostID) {
            await previous.stop()
        }
        store = AttachTerminalStore(
            target: agent.agent.paneID,
            input: input,
            transport: transport)
    }

    private func performClose() async {
        await close.confirmClose()
        switch close.state {
        case .closed:
            await store.stop()
            dismiss()
        case .failed(let message):
            closeErrorMessage = message
        case .idle, .closing:
            break
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status {
        case .waitingForSize, .connecting:
            ProgressView()
        case .ended(let message):
            ContentUnavailableView {
                Label("Session Ended", systemImage: "cable.connector.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Reattach") { store.retry() }
                    .buttonStyle(.borderedProminent)
            }
        case .live, .stopped:
            EmptyView()
        }
    }

    @ViewBuilder
    private var imageAttachStatus: some View {
        switch imageAttach.state {
        case .idle:
            EmptyView()
        case .preparing:
            ImageAttachStatusBar(
                icon: "photo",
                title: "Preparing Image…",
                accessibilityLabel: "Preparing Image"
            ) {
                Button("Cancel", role: .cancel) { imageAttach.cancel() }
            }
        case .uploading(let progress):
            ImageAttachStatusBar(
                icon: "arrow.up.circle",
                title: "Uploading Image… \(Int(progress.fractionCompleted * 100))%",
                accessibilityLabel:
                    "Uploading Image, \(Int(progress.fractionCompleted * 100)) percent"
            ) {
                Button("Cancel", role: .cancel) { imageAttach.cancel() }
            }
        case .failed(let failure), .backgroundInterrupted(let failure):
            ImageAttachStatusBar(
                icon: "exclamationmark.triangle",
                title: failure.message,
                accessibilityLabel: failure.message
            ) {
                if failure.isRetryable {
                    Button("Retry") { imageAttach.retry() }
                }
                Button("Dismiss", role: .cancel) { imageAttach.dismissResult() }
            }
        case .completed(let result):
            ImageAttachStatusBar(
                icon: result.copied && result.inserted ? "checkmark.circle" : "info.circle",
                title: result.message,
                accessibilityLabel: result.message
            ) {
                if !result.copied {
                    Button("Copy Path") { imageAttach.copyPath() }
                }
                if !result.inserted {
                    Button("Insert Path") { imageAttach.insertPath() }
                }
                Button("Done", role: .cancel) { imageAttach.dismissResult() }
            }
        }
    }

    @ViewBuilder
    private var pasteReviewSheet: some View {
        if let review = input.pendingPaste {
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
                        Button("Cancel", role: .cancel) { input.cancelPaste() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste") { _ = input.confirmPaste() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        Self.displayTitle(for: agent)
    }

    private static func displayTitle(for agent: ConsoleAgent) -> String {
        agent.agent.title.isEmpty ? agent.agent.displayName : agent.agent.title
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
