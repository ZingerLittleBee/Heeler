import GhosttyTerminal
import SwiftUI
import UIKit

struct SettingsView: View {
    let terminalThemes: TerminalThemeSettings
    let pushRegistration: PushRegistrationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                // Minimal push bootstrap copy (#71); the full pipeline
                // disclosure screen ships with #76.
                Section {
                    notificationRow
                } header: {
                    Text("Agent Notifications")
                } footer: {
                    Text("Get notified when an Agent is waiting for your input or finishes.")
                }

                Section {
                    TerminalThemePreview(theme: terminalThemes.theme)
                        .frame(height: 180)
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    Color(uiColor: .separator).opacity(0.45),
                                    lineWidth: 0.5)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityLabel("Terminal theme preview")
                } header: {
                    Text("Preview")
                } footer: {
                    Text(
                        "Changes apply instantly to current and future Attach terminals without reconnecting."
                    )
                }

                Section("Terminal Theme") {
                    ForEach(TerminalThemeOption.allCases) { option in
                        themeButton(option)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var notificationRow: some View {
        switch pushRegistration.state {
        case .unknown:
            HStack {
                Text("Checking notification status")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
            }
        case .needsPermission:
            Button("Enable Notifications") {
                Task { await pushRegistration.enable() }
            }
        case .waitingForToken:
            HStack {
                Text("Registering with Apple")
                Spacer()
                ProgressView()
            }
        case .registered(let token):
            HStack {
                Text("Notifications enabled")
                Spacer()
                if token.environment == .sandbox {
                    Text("Sandbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are turned off for herdr.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Push registration failed: \(message)")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await pushRegistration.enable() }
                }
            }
        }
    }

    private func themeButton(_ option: TerminalThemeOption) -> some View {
        let isSelected = terminalThemes.selection == option
        return Button {
            terminalThemes.select(option)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct TerminalThemePreview: UIViewRepresentable {
    let theme: TerminalTheme

    func makeUIView(context _: Context) -> TerminalThemePreviewView {
        TerminalThemePreviewView(theme: theme)
    }

    func updateUIView(_ view: TerminalThemePreviewView, context _: Context) {
        view.applyTheme(theme)
    }
}

@MainActor
private final class TerminalThemePreviewView: UITerminalView {
    private static let previewLines: [String] = [
        "\u{1B}[2J\u{1B}[H\u{1B}[1;36mherdr-mobile\u{1B}[0m",
        "\u{1B}[32m● connected\u{1B}[0m  mac-studio",
        "",
        "\u{1B}[34m~/Projects/herdr\u{1B}[0m",
        "\u{1B}[35m›\u{1B}[0m codex --continue",
        "\u{1B}[2mReady for input\u{1B}[0m",
    ]
    private static let preview = Data(previewLines.joined(separator: "\r\n").utf8)

    private let previewSession: InMemoryTerminalSession
    private let themeController: TerminalController
    private var hasLoadedPreview = false

    init(theme: TerminalTheme) {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        previewSession = session
        themeController = TerminalController(theme: theme) { builder in
            builder.withWindowPaddingX(12)
            builder.withWindowPaddingY(10)
        }
        super.init(frame: .zero)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: 13)
        controller = themeController
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Terminal theme preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasLoadedPreview else { return }
        hasLoadedPreview = true
        previewSession.receive(Self.preview)
    }

    func applyTheme(_ theme: TerminalTheme) {
        _ = themeController.setTheme(theme)
    }
}
