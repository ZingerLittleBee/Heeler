import SwiftUI

/// Pushed destinations under Settings › About.
///
/// Each case is the route identity *and* the concrete view type the
/// `NavigationLink` constructs. Tests bind the identity to
/// `destinationTypeName` so a decoy `LabeledContent` (or any other view) cannot
/// keep the route green while unlinking `AcknowledgementsView` (#161 / #135).
enum SettingsAboutDestination: String, Equatable, CaseIterable, Sendable {
    case setupGuide = "settings.about.setupGuide"
    case acknowledgements = "settings.about.acknowledgements"

    /// Metatype of the view this route constructs. The only allowed
    /// destination for `.acknowledgements` is `AcknowledgementsView`.
    var destinationTypeName: String {
        switch self {
        case .setupGuide:
            String(reflecting: HostSetupGuideView.self)
        case .acknowledgements:
            String(reflecting: AcknowledgementsView.self)
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .setupGuide:
            // Reference only: Hosts owns Pairing and the add form.
            HostSetupGuideView()
        case .acknowledgements:
            AcknowledgementsView()
        }
    }
}

/// Uses the same identity/metatype/destination convention as About routes.
enum SettingsAgentListDestination: String, Sendable {
    case fields = "settings.agentList.fields"

    var destinationTypeName: String { String(reflecting: AgentListFieldsSettingsView.self) }

    @MainActor
    func destinationView(console: ConsoleStore, hosts: [Host]) -> AgentListFieldsSettingsView {
        AgentListFieldsSettingsView(console: console, hosts: hosts)
    }
}

/// Settings › Overlay Networks, under the same identity/metatype/destination
/// convention as the other routes.
enum SettingsOverlayNetworksDestination: String, Sendable {
    case networks = "settings.overlayNetworks"

    var destinationTypeName: String { String(reflecting: OverlayNetworksSettingsView.self) }

    @MainActor
    func destinationView(
        store: OverlayNetworkStore, onHostAdded: @escaping (Host.ID) -> Void
    ) -> OverlayNetworksSettingsView {
        OverlayNetworksSettingsView(store: store, onHostAdded: onHostAdded)
    }
}

/// The Settings tab's root, or on iPad a sheet's: a shallow menu into Agent
/// fields, appearance and notifications.
/// Keeping it a menu means the per-Host notification rows can grow without
/// pushing the appearance controls out of reach, and vice versa.
struct SettingsView: View {
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    let liveActivities: HostLiveActivityCoordinator
    let console: ConsoleStore
    let hosts: [Host]
    let onHostAdded: (Host.ID) -> Void
    /// Closes Settings where it is presented as a sheet, as on iPad; nil
    /// where it is a tab.
    var onDone: (@MainActor () -> Void)? = nil
    /// Injected app-wide by `ContentView`; absent in previews, where the
    /// Overlay Networks row is left out.
    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    static let agentListDestination = SettingsAgentListDestination.fields
    static let overlayNetworksDestination = SettingsOverlayNetworksDestination.networks

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
        var rows: [AboutRow] = [.version, .setupGuide]
        if repositoryURL != nil {
            rows.append(.starOnGitHub)
        }
        rows.append(.acknowledgements)
        if NotificationPrivacyCopy.privacyPolicyURL != nil {
            rows.append(.privacyPolicy)
        }
        return rows
    }

    /// One About-section row. Enum cases are identity: a decoy string label is
    /// not `.acknowledgements`.
    enum AboutRow: Equatable, Identifiable {
        case version
        case setupGuide
        case starOnGitHub
        case acknowledgements
        case privacyPolicy

        var id: String {
            switch self {
            case .version: "settings.about.version"
            case .setupGuide: SettingsAboutDestination.setupGuide.rawValue
            case .acknowledgements: SettingsView.acknowledgementsRouteID
            case .starOnGitHub: "settings.about.starOnGitHub"
            case .privacyPolicy: "settings.about.privacyPolicy"
            }
        }
    }

    /// Maps an About row to a pushed destination, or `nil` for rows that do
    /// not navigate (version, external links). The Acknowledgements
    /// `NavigationLink` is built only through this mapping.
    static func aboutDestination(for row: AboutRow) -> SettingsAboutDestination? {
        switch row {
        case .setupGuide:
            .setupGuide
        case .acknowledgements:
            .acknowledgements
        case .version, .starOnGitHub, .privacyPolicy:
            nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        Self.agentListDestination.destinationView(console: console, hosts: hosts)
                    } label: {
                        Label("Agent List Fields", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier(Self.agentListDestination.rawValue)
                    NavigationLink {
                        NotificationSettingsView(
                            pushRegistration: pushRegistration,
                            notificationPreferences: notificationPreferences,
                            relaySettings: relaySettings,
                            liveActivities: liveActivities,
                            pluginStatuses: console.pluginStatuses,
                            refreshPluginStatuses: { [console] in
                                await console.refreshPluginStatuses(for: $0)
                            })
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

                if let overlayNetworks {
                    Section {
                        NavigationLink {
                            Self.overlayNetworksDestination.destinationView(
                                store: overlayNetworks, onHostAdded: onHostAdded)
                        } label: {
                            Label("Overlay Networks", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .accessibilityIdentifier(Self.overlayNetworksDestination.rawValue)
                    } header: {
                        Text("Connections")
                    }
                }

                Section {
                    ForEach(Self.aboutRows) { row in
                        aboutRow(row)
                    }
                } header: {
                    Text("About")
                } footer: {
                    if Self.repositoryURL != nil {
                        Text("Heeler is free and open source. If it helps you, a star on GitHub means a lot.")
                    }
                }
            }
            .readableColumnPage()
            .navigationTitle("Settings")
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
        // Covers every pushed page too.
        .readableColumn()
    }

    @ViewBuilder
    private func aboutRow(_ row: AboutRow) -> some View {
        switch row {
        case .version:
            LabeledContent {
                Text(Self.versionString)
            } label: {
                Label("Version", systemImage: "info.circle")
            }
        case .setupGuide:
            if let destination = Self.aboutDestination(for: row) {
                NavigationLink {
                    destination.destinationView
                } label: {
                    Label("Setup Guide", systemImage: "book")
                }
                .accessibilityIdentifier(destination.rawValue)
            }
        case .starOnGitHub:
            if let repositoryURL = Self.repositoryURL {
                ExternalLinkRow("Star on GitHub", systemImage: "star", destination: repositoryURL)
            }
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
        case .privacyPolicy:
            if let privacyURL = NotificationPrivacyCopy.privacyPolicyURL {
                ExternalLinkRow("Privacy Policy", systemImage: "hand.raised", destination: privacyURL)
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

/// A Settings row that leaves the app. The title stays primary like its
/// navigation siblings; a default `Link` would tint the whole row as a button.
/// The trailing arrow says the row opens outside Heeler.
struct ExternalLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let destination: URL

    init(_ title: LocalizedStringKey, systemImage: String, destination: URL) {
        self.title = title
        self.systemImage = systemImage
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            LabeledContent {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            } label: {
                Label {
                    Text(title).foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: systemImage)
                }
            }
        }
        .accessibilityAddTraits(.isLink)
    }
}
