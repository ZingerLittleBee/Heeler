import PhotosUI
import SwiftUI

/// The Agent detail screen: one interactive Attach terminal. Ghostty owns
/// rendering, scrollback, and IME; the adapter routes input-row taps and touch
/// scrolling without adding separate terminal chrome.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminalThemes: TerminalThemeSettings
    private let pushRegistration: PushRegistrationStore
    private let notificationPreferences: NotificationPreferencesStore
    @State private var attach: AgentAttachStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isConfirmingClose = false
    @State private var isShowingSettings = false
    @State private var closeErrorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminalThemes: TerminalThemeSettings,
        pushRegistration: PushRegistrationStore,
        notificationPreferences: NotificationPreferencesStore
    ) {
        self.agent = agent
        self.console = console
        self.terminalThemes = terminalThemes
        self.pushRegistration = pushRegistration
        self.notificationPreferences = notificationPreferences
        _attach = State(
            initialValue: AgentAttachStore(
                target: agent.agent.paneID,
                paneTitle: Self.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID)
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            })
    }

    var body: some View {
        TerminalScreenView(
            feed: attach.terminalFeed,
            onSizeChanged: { cols, rows in
                attach.viewDidResize(cols: cols, rows: rows)
            },
            onSend: { keystrokes in attach.send(keystrokes) },
            onPaste: { text in attach.requestPaste(text) },
            isLocalInputEnabled: attach.isLocalInputEnabled,
            theme: terminalThemes.theme
        )
        .id(attach.terminalID)
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
                .disabled(!attach.canSelectImage)
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
            SettingsView(
                terminalThemes: terminalThemes,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences)
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
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            attach.selectImage(PhotosPickerImageSelection(item: item))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                attach.didBecomeActive()
            case .background:
                attach.didEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            attach.transportGenerationDidChange(generation)
        }
        .onDisappear {
            Task { await attach.leave() }
        }
    }

    private func performClose() async {
        if await attach.confirmClose() {
            dismiss()
        } else {
            closeErrorMessage = attach.closeFailureMessage
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch attach.terminalStatus {
        case .waitingForSize, .connecting:
            ProgressView()
        case .ended(let message):
            ContentUnavailableView {
                Label("Session Ended", systemImage: "cable.connector.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Reattach") { attach.retryTerminal() }
                    .buttonStyle(.borderedProminent)
            }
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
