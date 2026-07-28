import SwiftUI

/// The settings sheet root: a shallow menu into the two settings domains.
/// Keeping it a menu means the per-Host notification rows can grow without
/// pushing the appearance controls out of reach, and vice versa.
struct SettingsView: View {
    let terminal: TerminalSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        NotificationSettingsView(
                            pushRegistration: pushRegistration,
                            notificationPreferences: notificationPreferences,
                            relaySettings: relaySettings)
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        TerminalAppearanceSettingsView(terminal: terminal)
                    } label: {
                        Label("Terminal Appearance", systemImage: "paintpalette")
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
}
