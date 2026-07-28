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

    private static let websiteURL = URL(string: "https://herdr.dev")

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

                Section {
                    LabeledContent("Version", value: Self.versionString)
                    if let website = Self.websiteURL {
                        Link(destination: website) {
                            Label("herdr.dev", systemImage: "globe")
                        }
                    }
                    if let privacyURL = NotificationPrivacyCopy.privacyPolicyURL {
                        Link(destination: privacyURL) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                    }
                } header: {
                    Text("About")
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

    /// "0.1.0 (1)": marketing version plus build number, the pair App Store
    /// Connect and TestFlight feedback identify a build by.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
