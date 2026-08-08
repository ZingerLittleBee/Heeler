import SwiftUI

/// Pushed destinations under Settings › About.
///
/// Each case is the route identity *and* the concrete view type the
/// `NavigationLink` constructs. Tests bind the identity to
/// `destinationTypeName` so a decoy `LabeledContent` (or any other view) cannot
/// keep the route green while unlinking `AcknowledgementsView` (#161 / #135).
enum SettingsAboutDestination: String, Equatable, CaseIterable, Sendable {
    case acknowledgements = "settings.about.acknowledgements"

    /// Metatype of the view this route constructs. The only allowed
    /// destination for `.acknowledgements` is `AcknowledgementsView`.
    var destinationTypeName: String {
        switch self {
        case .acknowledgements:
            String(reflecting: AcknowledgementsView.self)
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .acknowledgements:
            AcknowledgementsView()
        }
    }
}

/// The settings sheet root: a shallow menu into the two settings domains.
/// Keeping it a menu means the per-Host notification rows can grow without
/// pushing the appearance controls out of reach, and vice versa.
struct SettingsView: View {
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    @Environment(\.dismiss) private var dismiss

    static let repositoryURL = URL(string: "https://github.com/ZingerLittleBee/Heeler")

    /// Semantic identity of the About → Acknowledgements route.
    ///
    /// Equals `SettingsAboutDestination.acknowledgements.rawValue`. Tests assert
    /// the id, the destination mapping, and the source wiring together so a
    /// decoy row cannot stand in for the real screen (#161, same lesson as #135).
    static let acknowledgementsRouteID = SettingsAboutDestination.acknowledgements.rawValue

    /// Rows in the About section, in display order. The body iterates this
    /// list; the Acknowledgements entry is a navigation destination, not a
    /// static label, and its id is `acknowledgementsRouteID`.
    static var aboutRows: [AboutRow] {
        var rows: [AboutRow] = [.version, .acknowledgements]
        if repositoryURL != nil {
            rows.append(.repository)
        }
        if NotificationPrivacyCopy.privacyPolicyURL != nil {
            rows.append(.privacyPolicy)
        }
        return rows
    }

    /// One About-section row. Enum cases are identity: a decoy string label is
    /// not `.acknowledgements`.
    enum AboutRow: Equatable, Identifiable {
        case version
        case acknowledgements
        case repository
        case privacyPolicy

        var id: String {
            switch self {
            case .version: "settings.about.version"
            case .acknowledgements: SettingsView.acknowledgementsRouteID
            case .repository: "settings.about.repository"
            case .privacyPolicy: "settings.about.privacyPolicy"
            }
        }
    }

    /// Maps an About row to a pushed destination, or `nil` for rows that do
    /// not navigate (version, external links). The Acknowledgements
    /// `NavigationLink` is built only through this mapping.
    static func aboutDestination(for row: AboutRow) -> SettingsAboutDestination? {
        switch row {
        case .acknowledgements:
            .acknowledgements
        case .version, .repository, .privacyPolicy:
            nil
        }
    }

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
                    appearancePicker
                    NavigationLink {
                        TerminalAppearanceSettingsView(terminal: terminal)
                    } label: {
                        Label("Terminal Appearance", systemImage: "paintpalette")
                    }
                }

                Section {
                    ForEach(Self.aboutRows) { row in
                        aboutRow(row)
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

    @ViewBuilder
    private func aboutRow(_ row: AboutRow) -> some View {
        switch row {
        case .version:
            LabeledContent("Version", value: Self.versionString)
        case .acknowledgements:
            // Destination comes only from `aboutDestination(for:)` so the
            // route identity and `AcknowledgementsView` cannot drift apart.
            if let destination = Self.aboutDestination(for: row) {
                NavigationLink {
                    destination.destinationView
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                .accessibilityIdentifier(destination.rawValue)
            }
        case .repository:
            if let repositoryURL = Self.repositoryURL {
                Link(destination: repositoryURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        case .privacyPolicy:
            if let privacyURL = NotificationPrivacyCopy.privacyPolicyURL {
                Link(destination: privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
    }

    /// The app's own light/dark override. A menu picker, not a pushed screen:
    /// three options do not earn a navigation level.
    private var appearancePicker: some View {
        Picker(
            selection: Binding(
                get: { appearance.selection },
                set: { appearance.select($0) })
        ) {
            ForEach(AppAppearanceOption.allCases) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
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
