import SwiftUI

/// Settings › Agents & Accounts (#621, #622): the one place to keep Launch
/// Presets and each Host's Accounts for every harness. New Agent offers the
/// presets; Usage and Chat read the Accounts.
struct AgentsAndAccountsSettingsView: View {
    let console: ConsoleStore
    let hosts: [Host]
    @State private var editing: Editing?

    private struct Editing: Identifiable {
        let preset: LaunchPreset?
        var id: String { preset?.id.uuidString ?? "new" }
    }

    private var presets: LaunchPresetStore { console.launchPresets }

    var body: some View {
        Form {
            Section {
                ForEach(presets.presets) { preset in
                    Button {
                        editing = Editing(preset: preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name).foregroundStyle(.primary)
                            LaunchPresetSummary(preset: preset)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { presets.delete(presets.presets[index].id) }
                }
                .onMove { presets.move(fromOffsets: $0, toOffset: $1) }
                Button("New Preset", systemImage: "plus") { editing = Editing(preset: nil) }
                    .accessibilityIdentifier("settings.presets.new")
            } header: {
                Text("Launch Presets")
            } footer: {
                Text("A harness with its Account, arguments and environment, ready to pick in New Agent. Saved on this device.")
            }

            Section {
                if hosts.isEmpty {
                    Text("Add a Host to keep its Accounts.").foregroundStyle(.secondary)
                }
                ForEach(hosts) { host in
                    NavigationLink {
                        HostAccountsView(
                            hostName: host.displayName, store: console.hostAccountsStore(for: host.id),
                            usage: console.isUsageEnabled ? console.agentUsageStore(for: host.id) : nil)
                    } label: {
                        HostAccountsRowLabel(host: host, store: console.hostAccountsStore(for: host.id))
                    }
                    .accessibilityIdentifier("settings.accounts.\(host.displayName)")
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text(
                    "Each harness’s config folders on a Host, such as a second Claude Code or Codex sign-in. "
                        + "Kept on the Host for every device; Usage, Chat and Launch Presets read them.")
            }
        }
        .navigationTitle("Agents & Accounts")
        .sheet(item: $editing) { editing in
            NavigationStack {
                LaunchPresetEditor(preset: editing.preset, store: presets, console: console)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { self.editing = nil }
                        }
                    }
            }
        }
    }
}

/// A Host's row: its name and how many Accounts it keeps beyond each
/// harness's Default.
private struct HostAccountsRowLabel: View {
    let host: Host
    let store: HostAccountsStore

    var body: some View {
        let count = SupportedAgentKind.allCases.reduce(0) { $0 + store.file.accounts(for: $1).count }
        LabeledContent {
            if count > 0 { Text(count.formatted()).monospacedDigit() }
        } label: {
            Label(host.displayName, systemImage: "server.rack")
        }
        .task { if store.loadState == .idle { await store.load() } }
    }
}
