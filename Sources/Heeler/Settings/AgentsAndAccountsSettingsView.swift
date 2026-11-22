import SwiftUI

/// Settings › Agents & Accounts (#621, #622): the one place to keep Launch
/// Presets and each Host's Accounts for every harness. New Agent offers the
/// presets; Usage and Chat read the Accounts.
struct AgentsAndAccountsSettingsView: View {
    let console: ConsoleStore
    let hosts: [Host]
    /// Hosts has Hosts, and only Rex Servers are on: there is no Host to add,
    /// only none that keeps Accounts.
    var hasOnlyRexServersOn = false
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
                        HStack(alignment: .center, spacing: 12) {
                            AgentKindBadge(kind: preset.kind)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).foregroundStyle(.primary)
                                LaunchPresetSummary(preset: preset)
                            }
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
                if hosts.isEmpty, hasOnlyRexServersOn {
                    Text("Accounts are kept on Hosts with a herdr or tmux Server. Rex Servers keep none.")
                        .foregroundStyle(.secondary)
                } else if hosts.isEmpty {
                    Text("Add a Host to keep its Accounts.").foregroundStyle(.secondary)
                }
                // A Host's Servers keep one set of Accounts on it, so the Host
                // is listed once and reached over the Server Usage reads through.
                ForEach(AgentUsageHost.grouped(hosts)) { host in
                    let record = console.usageRecord(of: host)
                    NavigationLink {
                        HostAccountsView(
                            hostName: host.name, store: console.hostAccountsStore(for: record.id),
                            usage: console.isUsageEnabled ? console.agentUsageStore(for: record.id) : nil)
                    } label: {
                        HostAccountsRowLabel(
                            name: host.name, recordID: record.id, store: console.hostAccountsStore(for: record.id))
                    }
                    .accessibilityIdentifier("settings.accounts.\(host.name)")
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text(
                    String(localized: "Each harness’s config folders on a Host, such as a second Claude Code or Codex sign-in. Kept on the Host for every device; Usage, Chat and Launch Presets read them."))
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
    let name: String
    /// The record `store` reaches the Host over, which changes when another
    /// of the Host's Servers takes over.
    let recordID: Host.ID
    let store: HostAccountsStore

    var body: some View {
        let count = SupportedAgentKind.allCases.reduce(0) { $0 + store.file.accounts(for: $1).count }
        LabeledContent {
            if count > 0 { Text(count.formatted()).monospacedDigit() }
        } label: {
            Label(name, systemImage: "server.rack")
        }
        .task(id: recordID) { if store.loadState == .idle { try? await store.load() } }
    }
}
