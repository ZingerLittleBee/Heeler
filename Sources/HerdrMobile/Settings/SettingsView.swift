import GhosttyTerminal
import SwiftUI
import UIKit

struct SettingsView: View {
    let terminalThemes: TerminalThemeSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    @Bindable var relaySettings: NotificationRelaySettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isShowingExplainer = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    notificationRow
                } header: {
                    Text("Agent Notifications")
                } footer: {
                    Text("Get notified when an Agent is waiting for your input or finishes.")
                }

                // The persistent privacy disclosure (#76): the same story as
                // the pre-permission explainer, reachable any time, linking to
                // PRIVACY.md.
                privacySection

                // Per-Host preferences (#75): registration on/off plus the
                // separate Done flag, once this device holds a push token.
                if pushRegistration.deviceToken != nil {
                    ForEach(notificationPreferences.hosts) { host in
                        hostNotificationSection(host)
                    }
                }

                // Custom Push Relay base URL (#76): only meaningful to a
                // self-builder; empty leaves every Host's plugin config alone.
                customRelaySection

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
            .task { await notificationPreferences.refresh() }
            // The user can finish push bootstrap inside this very sheet;
            // the per-Host rows appear the moment the token lands.
            .onChange(of: pushRegistration.deviceToken) { _, token in
                guard token != nil else { return }
                Task { await notificationPreferences.refresh() }
            }
            // The disclosure gate (#76): the iOS permission prompt only fires
            // after the user reads the explainer and taps Continue.
            .sheet(isPresented: $isShowingExplainer) {
                NotificationExplainerSheet {
                    Task { await pushRegistration.enable() }
                }
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            NavigationLink {
                NotificationPrivacyDetailView()
            } label: {
                Label("How notifications stay private", systemImage: "lock.shield")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(NotificationPrivacyCopy.summary)
        }
    }

    @ViewBuilder
    private var customRelaySection: some View {
        Section {
            TextField("https://relay.example.com", text: $relaySettings.rawValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
            if relaySettings.hasInvalidEntry {
                Text("Enter a valid http or https URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Custom Push Relay")
        } footer: {
            Text(NotificationPrivacyCopy.customRelayCaveat)
        }
    }

    private func hostNotificationSection(_ host: Host) -> some View {
        Section {
            switch notificationPreferences.states[host.id] {
            case nil, .loading:
                HStack {
                    Text("Checking this Host")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            case .unavailable(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Check Again") {
                        Task { await notificationPreferences.refresh() }
                    }
                }
            case .idle(let settings):
                hostToggles(host: host, settings: settings, isUpdating: false)
            case .updating(let settings):
                hostToggles(host: host, settings: settings, isUpdating: true)
            case .failed(_, let settings):
                hostToggles(host: host, settings: settings, isUpdating: false)
            }
        } header: {
            Text(host.displayName)
        } footer: {
            // Fail loudly (#75): a toggle that could not reach the Host
            // says so and stays on the Host's confirmed value.
            if case .failed(let message, _) = notificationPreferences.states[host.id] {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func hostToggles(
        host: Host,
        settings: NotificationPreferencesStore.HostSettings,
        isUpdating: Bool
    ) -> some View {
        Toggle(
            "Notifications",
            isOn: Binding(
                get: { settings.isRegistered },
                set: { enabled in
                    Task {
                        await notificationPreferences.setNotificationsEnabled(
                            enabled, for: host)
                    }
                }))
            .disabled(isUpdating)
        if settings.isRegistered {
            Toggle(
                "Done Notifications",
                isOn: Binding(
                    get: { settings.notify.done },
                    set: { enabled in
                        Task {
                            await notificationPreferences.setDoneEnabled(enabled, for: host)
                        }
                    }))
                .disabled(isUpdating)
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
                isShowingExplainer = true
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
