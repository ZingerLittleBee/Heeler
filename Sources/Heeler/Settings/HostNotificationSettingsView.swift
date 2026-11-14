import SwiftUI

/// What a Host's notification row and page both read.
@MainActor
struct HostNotificationSettings {
    let host: Host
    let preferences: NotificationPreferencesStore
    let liveActivities: HostLiveActivityCoordinator
    let pluginStatuses: HeelerPluginStatusStore
    /// Opens the Host's page in Hosts with its Host Helper sheet up.
    let openHostHelper: (@MainActor (Host.ID) -> Void)?

    /// Shown while the Host is read again too, so a re-read keeps the row steady.
    var state: NotificationPreferencesStore.HostState? { preferences.shownState(for: host.id) }

    var settings: NotificationPreferencesStore.HostSettings? {
        switch state {
        case .idle(let settings), .updating(let settings), .failed(_, let settings): settings
        case .loading, .unavailable, nil: nil
        }
    }

    /// Whether the switches can act now: a read or a write in flight holds them.
    var canChange: Bool {
        guard !preferences.isReading(host.id) else { return false }
        if case .updating = state { return false }
        return true
    }

    var offersLiveActivity: Bool { preferences.offersLiveActivity(for: host) }

    /// A core or tmux Host's Helper as its Host page shows it, once a read has seen it.
    var helper: HostHelperPresentation? {
        guard host.serverKind == .herdrCore || host.serverKind == .tmux else { return nil }
        return preferences.helperPresentation(for: host.id)
    }

    var pluginRequirements: [HeelerPluginRequirement] {
        guard host.serverKind == .herdrTUI else { return [] }
        return pluginStatuses.status(for: host.id)?.notificationRequirements(
            liveActivityEnabled: liveActivities.isEnabled(for: host.id)) ?? []
    }

    var notificationsBinding: Binding<Bool> {
        let preferences = preferences
        let host = host
        return Binding(
            get: { settings?.isRegistered ?? false },
            set: { enabled in
                Task { await preferences.setNotificationsEnabled(enabled, for: host) }
            })
    }

    /// What the row says under the Host's name: what needs doing first, else what is on.
    var rowNote: (text: String, tone: RowTone) {
        switch state {
        case nil, .loading:
            return (String(localized: "Checking"), .quiet)
        case .unavailable(let message):
            return (message, .attention)
        case .failed(let message, _):
            return (message, .failure)
        case .idle(let settings), .updating(let settings):
            if let requirement = preferences.helperRequirement(for: host.id) {
                return (requirement, .attention)
            }
            guard settings.isRegistered else { return (String(localized: "Off"), .quiet) }
            if let plugin = pluginRequirements.first {
                return (plugin.note, .attention)
            }
            let liveActivity = offersLiveActivity && liveActivities.isEnabled(for: host.id)
            // Whole phrases, so each language words and orders them its own way.
            let text =
                switch (settings.notify.done, liveActivity) {
                case (false, false):
                    String(localized: "Blocked", comment: "Agent status")
                case (true, false):
                    String(localized: "Blocked, Done", comment: "What notifies on a Host: Agent statuses")
                case (false, true):
                    String(
                        localized: "Blocked · Live Activity",
                        comment: "What notifies on a Host: an Agent status, then the Live Activity")
                case (true, true):
                    String(
                        localized: "Blocked, Done · Live Activity",
                        comment: "What notifies on a Host: Agent statuses, then the Live Activity")
                }
            return (text, .quiet)
        }
    }

    enum RowTone {
        case quiet, attention, failure

        var color: Color {
            switch self {
            case .quiet: .secondary
            case .attention: .orange
            case .failure: .red
            }
        }
    }
}

/// One Host in Notifications: a steady row with its name, what is on, and the
/// switch; Done and Live Activity are a tap away.
struct HostNotificationRow: View {
    let model: HostNotificationSettings

    var body: some View {
        NavigationLink {
            HostNotificationSettingsView(model: model)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.host.displayName)
                        .lineLimit(1)
                    note
                }
                Spacer(minLength: 8)
                if model.settings != nil {
                    Toggle("Notifications for \(model.host.displayName)", isOn: model.notificationsBinding)
                        .labelsHidden()
                        .disabled(!model.canChange)
                        .accessibilityIdentifier(
                            "settings.notifications.toggle.\(model.host.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("settings.notifications.host.\(model.host.id.uuidString)")
    }

    private var note: some View {
        let note = model.rowNote
        return HStack(spacing: 5) {
            if model.state == nil {
                ProgressView().controlSize(.mini)
            }
            Text(note.text)
                .lineLimit(2)
        }
        .font(.subheadline)
        .foregroundStyle(note.tone.color)
    }
}

/// A Host's notification page: the switches, and what they wait on.
struct HostNotificationSettingsView: View {
    let model: HostNotificationSettings

    var body: some View {
        Form {
            Section {
                switch model.state {
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
                            let preferences = model.preferences
                            let hostID = model.host.id
                            Task { await preferences.refresh([hostID]) }
                        }
                        .disabled(model.preferences.isReading(model.host.id))
                    }
                case .idle(let settings), .updating(let settings), .failed(_, let settings):
                    toggles(settings)
                }
            } footer: {
                footer
            }
            if let helper = model.helper, let open = model.openHostHelper {
                Section {
                    hostHelperRow(helper) { open(model.host.id) }
                }
            }
        }
        .readableColumnPage()
        .navigationTitle(model.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The Helper's status, read as on the Host page; it opens that page's sheet.
    private func hostHelperRow(
        _ helper: HostHelperPresentation, open: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: open) {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(helper.value)
                    if helper.needsAttention {
                        PluginNoticeIcon(tone: .warning)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            } label: {
                // Not the button tint: the row reads like its neighbors.
                Text("Host Helper")
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.notifications.hostHelper.\(model.host.id.uuidString)")
    }

    @ViewBuilder
    private func toggles(_ settings: NotificationPreferencesStore.HostSettings) -> some View {
        let preferences = model.preferences
        let liveActivities = model.liveActivities
        let host = model.host
        Toggle("Notifications", isOn: model.notificationsBinding)
            .disabled(!model.canChange)
        if settings.isRegistered {
            Toggle(
                "Done Notifications",
                isOn: Binding(
                    get: { settings.notify.done },
                    set: { enabled in
                        Task { await preferences.setDoneEnabled(enabled, for: host) }
                    }))
                .disabled(!model.canChange)
            if model.offersLiveActivity {
                Toggle(
                    "Live Activity",
                    isOn: Binding(
                        get: { liveActivities.isEnabled(for: host.id) },
                        set: { liveActivities.setEnabled($0, for: host.id) }))
                    .disabled(!model.canChange)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let host = model.host
        let liveActivities = model.liveActivities
        let registered = model.settings?.isRegistered ?? false
        VStack(alignment: .leading, spacing: 6) {
            if let requirement = model.preferences.helperRequirement(for: host.id) {
                Text(requirement)
                    .accessibilityIdentifier("settings.notifications.helperRequirement.\(host.id.uuidString)")
            }
            if registered, model.offersLiveActivity {
                Text(NotificationPrivacyCopy.liveActivityFooter)
                if !liveActivities.areActivitiesEnabled {
                    Text(NotificationPrivacyCopy.liveActivityDisabledHint)
                }
                if liveActivities.isEnabled(for: host.id),
                    let note = liveActivities.reconcileNotes[host.id]
                {
                    Text("Live Activity: \(note)")
                }
                ForEach(model.pluginRequirements, id: \.feature) { @Sendable requirement in
                    PluginRequirementNote(text: requirement.note)
                        .accessibilityIdentifier(
                            "settings.notifications.pluginRequirement.\(host.id.uuidString)"
                                + ".\(requirement.feature)")
                }
            }
            // Fail loudly (#75): a switch that could not reach the Host
            // says so and stays on the Host's confirmed value.
            if case .failed(let message, _) = model.state {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }
}
