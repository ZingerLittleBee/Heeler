import SwiftUI

/// Both list modes participate in the split view's single selection. Agent
/// routes retain their existing notification and multiwindow identity.
enum ConsoleSelection: Hashable {
    case agent(ConsoleAgent.ID)
    case terminal(ConsoleTerminal.ID)
}

enum ConsoleListTab: String, CaseIterable, Identifiable {
    case agents
    case terminals

    var id: Self { self }
    var title: String { self == .agents ? "Agents" : "Terminals" }
}

struct ConsoleTerminalWorkspaceSection: Identifiable {
    let id: String
    let title: String
    let terminals: [ConsoleTerminal]
}

struct ConsoleTerminalHostSection: Identifiable {
    let host: Host
    let workspaces: [ConsoleTerminalWorkspaceSection]
    var id: Host.ID { host.id }

    /// Host catalog order, then snapshot workspace/tab/pane order. Workspace
    /// IDs are scoped to their Host, including during search and filtering.
    static func sections(
        hosts: [Host], terminals: [ConsoleTerminal],
        filteredHostID: Host.ID?, searchQuery: String
    ) -> [Self] {
        hosts.filter { filteredHostID == nil || $0.id == filteredHostID }.map { host in
            let matching = terminals.filter {
                $0.hostID == host.id && $0.matchesSearch(searchQuery)
            }.sorted {
                ($0.workspaceOrder, $0.tabPosition ?? Int.max, $0.snapshotOrder)
                    < ($1.workspaceOrder, $1.tabPosition ?? Int.max, $1.snapshotOrder)
            }
            var workspaceIDs: [String] = []
            var grouped: [String: [ConsoleTerminal]] = [:]
            for terminal in matching {
                if grouped[terminal.workspaceID] == nil {
                    workspaceIDs.append(terminal.workspaceID)
                }
                grouped[terminal.workspaceID, default: []].append(terminal)
            }
            return Self(
                host: host,
                workspaces: workspaceIDs.map { id in
                    let rows = grouped[id, default: []]
                    let label = rows.first?.workspaceLabel?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return ConsoleTerminalWorkspaceSection(
                        id: id,
                        title: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Workspace \(id)",
                        terminals: rows)
                })
        }
    }
}

struct TerminalListView: View {
    let hosts: [Host]
    let terminals: [ConsoleTerminal]
    let issues: [ConsoleHostStatusPresentation]
    let filteredHostID: Host.ID?
    let searchQuery: String
    @Binding var selection: ConsoleSelection?
    let onOpenHost: (Host.ID) -> Void

    private var sections: [ConsoleTerminalHostSection] {
        ConsoleTerminalHostSection.sections(
            hosts: hosts, terminals: terminals,
            filteredHostID: filteredHostID, searchQuery: searchQuery)
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    if let issue = issues.first(where: { $0.hostID == section.id }) {
                        hostIssue(issue)
                    }
                    if section.workspaces.isEmpty {
                        if !issues.contains(where: { $0.hostID == section.id }) {
                            Text(isSearching ? "No matching terminals" : "No terminals")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(section.workspaces) { workspace in
                            HStack {
                                Label(workspace.title, systemImage: "rectangle.3.group")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(workspace.terminals.count, format: .number)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(workspace.title), \(workspace.terminals.count) terminals")
                            .listRowSeparator(.hidden)
                            ForEach(workspace.terminals) { terminal in
                                NavigationLink(value: route(for: terminal)) {
                                    terminalRow(terminal)
                                }
                                .hoverEffect(.highlight)
                            }
                        }
                    }
                } header: {
                    Label(section.host.displayName, systemImage: "server.rack")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }

    private func route(for terminal: ConsoleTerminal) -> ConsoleSelection {
        terminal.agentID.map(ConsoleSelection.agent) ?? .terminal(terminal.id)
    }

    private func terminalRow(_ terminal: ConsoleTerminal) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: terminal.isAgent ? "sparkles" : "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(terminal.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if terminal.isAgent {
                    Text("Agent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Label(tabTitle(terminal), systemImage: "rectangle.topthird.inset.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(terminal.displayCwd.isEmpty ? "Path unavailable" : terminal.displayCwd)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func tabTitle(_ terminal: ConsoleTerminal) -> String {
        let label = terminal.tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty { return label }
        return terminal.tabPosition.map { "Tab \($0)" } ?? "Tab \(terminal.tabID)"
    }

    @ViewBuilder
    private func hostIssue(_ issue: ConsoleHostStatusPresentation) -> some View {
        if issue.navigates {
            Button { onOpenHost(issue.hostID) } label: {
                issueLabel(issue)
            }
            .accessibilityHint("Opens this Host's settings.")
        } else {
            issueLabel(issue)
        }
    }

    private func issueLabel(_ issue: ConsoleHostStatusPresentation) -> some View {
        Label(issue.message.replacingOccurrences(of: "Loading Agents", with: "Loading Terminals"),
              systemImage: issue.systemImage)
            .font(.footnote)
            .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
    }
}
