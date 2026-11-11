import SwiftUI

/// Phone navigation over shared names and membership, not a desktop layout.
/// Reads the live Console so deletion, replacement and reconnect retire targets.
struct AmuxOrganizationView: View {
    let host: Host
    let coreID: String
    let console: ConsoleStore
    let onSelect: (ConsoleTerminal) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agentOrigin: StartAgentStore.LaunchOrigin?
    @State private var creating = false
    @State private var failure: String?

    private var organization: AmuxOrganizationDocument? {
        console.amuxOrganizations[host.id].flatMap { $0.coreID == coreID ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let organization {
                    List {
                        ForEach(organization.spaces) { space in
                            Section {
                                launchRow(
                                    name: space.name, path: space.path,
                                    workspaceID: space.workspaceID(coreID: coreID), image: "folder")
                                ForEach(space.worktrees) { worktree in
                                    launchRow(
                                        name: worktree.name, path: worktree.path,
                                        workspaceID: worktree.workspaceID(coreID: coreID), image: "arrow.triangle.branch")
                                    ForEach(worktree.tabs) { tab in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Label(tab.name, systemImage: "rectangle.on.rectangle")
                                                .font(.subheadline.weight(.medium))
                                            if tab.terminals.isEmpty {
                                                Text("No Terminals").foregroundStyle(.secondary)
                                            }
                                            ForEach(tab.terminals, id: \.self) { address in
                                                member(address)
                                            }
                                        }
                                        .padding(.leading, 16)
                                    }
                                }
                            } header: {
                                Text(space.name)
                            }
                        }
                        Section("Unassigned") {
                            let assigned = Set(organization.spaces.flatMap { $0.worktrees.flatMap { $0.tabs.flatMap(\.terminals) } })
                            ForEach(console.terminals.filter { $0.hostID == host.id && !assigned.contains($0.paneID) }) { terminal in
                                terminalButton(terminal)
                            }
                        }
                        Section {
                            Text("Organization is read-only. New terminals and Agents start unassigned; place them from amux.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("Organization Unavailable", systemImage: "folder.badge.questionmark")
                }
            }
            .navigationTitle("amux Spaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: Binding(
                get: { agentOrigin != nil }, set: { if !$0 { agentOrigin = nil } }
            )) {
                if let agentOrigin {
                    StartAgentView(hosts: [host], console: console, origin: agentOrigin) { id in
                        if let terminal = console.terminals.first(where: { $0.hostID == id.hostID && $0.paneID == id.paneID }) {
                            onSelect(terminal)
                        }
                    }
                }
            }
            .alert("Couldn't Open Terminal", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }

    private func launchRow(name: String, path: String, workspaceID: String, image: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(name, systemImage: image).font(.headline)
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Menu {
                Button("New Terminal", systemImage: "terminal") { create(workspaceID: workspaceID, path: path) }
                Button("New Agent", systemImage: "plus") {
                    agentOrigin = .init(hostID: host.id, workspaceID: workspaceID, cwd: path)
                }
            } label: {
                Image(systemName: "plus.circle").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(String(localized: "Start in \(name)"))
            .disabled(creating || organization == nil)
        }
    }

    @ViewBuilder
    private func member(_ address: String) -> some View {
        if let terminal = console.terminals.first(where: { $0.hostID == host.id && $0.paneID == address }) {
            terminalButton(terminal)
        } else {
            Text("\(address) · Not running").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func terminalButton(_ terminal: ConsoleTerminal) -> some View {
        Button { onSelect(terminal) } label: {
            HStack {
                Image(systemName: terminal.isAgent ? "sparkles" : "terminal")
                VStack(alignment: .leading, spacing: 2) {
                    Text(terminal.displayTitle)
                    Text(terminal.paneID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create(workspaceID: String, path: String) {
        guard !creating else { return }
        creating = true
        Task { @MainActor in
            defer { creating = false }
            do {
                let identity = try await console.createShellTerminal(
                    ShellTerminalCreationRequest(workspaceID: workspaceID, cwd: path), on: host.id)
                if let terminal = await console.waitForTerminal(identity, on: host.id) { onSelect(terminal) }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
