import SwiftUI
import UIKit

/// The Console's Terminals tab (#316): ordinary shell panes as one card per
/// Workspace, either flat By Workspace or nested under collapsible Host
/// sections By Host. Rows share the split view's selection with Agent rows,
/// so a tap opens the Shell Terminal in the detail column.
struct TerminalListView: View {
    let hosts: [Host]
    let console: ConsoleStore
    let presentation: TerminalListPresentationStore
    let filteredHostID: Host.ID?
    @Binding var selection: ConsoleSelection?
    /// Opens a terminal the list just created.
    let onOpen: (ConsoleTerminal) -> Void
    let onOpenHost: (Host.ID) -> Void
    let onNewTerminal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creating: Set<TerminalWorkspaceGroup.ID> = []
    @State private var createFailure: String?
    @State private var pendingClose: ConsoleTerminal?
    @State private var closeFailure: String?

    private static let byHostMargin: CGFloat = 8

    private var projection: TerminalListProjection {
        presentation.projection(hosts: hosts, console: console)
    }

    var body: some View {
        Group {
            switch presentation.mode {
            case .byWorkspace: byWorkspace
            case .byHost: byHost
            }
        }
        .alert(closeTitle, isPresented: isPresented($pendingClose)) {
            Button(closeTitle.replacingOccurrences(of: "?", with: ""), role: .destructive) {
                confirmClose()
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text(pendingClose.map(closeMessage(for:)) ?? "")
        }
        .alert("Couldn't Close Terminal", isPresented: isPresented($closeFailure)) {
            Button("OK", role: .cancel) { closeFailure = nil }
        } message: {
            Text(closeFailure ?? "")
        }
        .alert("Couldn't Open Terminal", isPresented: isPresented($createFailure)) {
            Button("OK", role: .cancel) { createFailure = nil }
        } message: {
            Text(createFailure ?? "")
        }
    }

    @ViewBuilder
    private var byWorkspace: some View {
        let workspaces = projection.workspaces(filteredHostID: filteredHostID)
        let issues = projection.issues(filteredHostID: filteredHostID)
        if workspaces.isEmpty && issues.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                if !issues.isEmpty {
                    Section {
                        ForEach(issues) { issueRow($0) }
                    }
                }
                ForEach(workspaces) { workspace in
                    workspaceSection(workspace, showsHost: true)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
        }
    }

    @ViewBuilder
    private var byHost: some View {
        let groups = projection.hostGroups(filteredHostID: filteredHostID)
        if groups.allSatisfy({ $0.workspaces.isEmpty && $0.issue == nil }) {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section {
                        if let issue = group.issue, !group.isCollapsed {
                            issueRow(issue)
                        }
                    } header: {
                        TerminalHostHeader(group: group) { toggle(group.hostID) }
                            // Back out the narrow margin so the Host lines
                            // up with the Agents tab's Host headers.
                            .padding(.leading, -Self.byHostMargin)
                    }
                    if !group.isCollapsed {
                        ForEach(group.workspaces) { workspace in
                            workspaceSection(workspace, showsHost: false)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            // Cards already sit inside a Host section, so By Host spends
            // less width on side margins than By Workspace. A zero margin
            // would square the cards off, so they keep a narrow one.
            .contentMargins(.horizontal, Self.byHostMargin, for: .scrollContent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Terminals", systemImage: "terminal")
        } description: {
            Text("Shell panes on your Hosts appear here, grouped by Workspace.")
        } actions: {
            Button("New Terminal", action: onNewTerminal)
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
        }
    }

    private func workspaceSection(
        _ workspace: TerminalWorkspaceGroup, showsHost: Bool
    ) -> some View {
        Section {
            if !workspace.isCollapsed {
                if workspace.terminals.isEmpty {
                    newTerminalRow(workspace)
                } else {
                    ForEach(workspace.terminals) {
                        terminalRow($0, showsTab: workspace.terminals.count > 1)
                    }
                }
            }
        } header: {
            TerminalWorkspaceHeader(
                workspace: workspace,
                showsHost: showsHost,
                isCreating: creating.contains(workspace.id),
                onToggle: { toggle(workspace.id) },
                onCreate: workspace.directory.map { directory in
                    { create(in: workspace, cwd: directory) }
                })
        }
    }

    private func terminalRow(_ terminal: ConsoleTerminal, showsTab: Bool) -> some View {
        NavigationLink(value: ConsoleSelection.terminal(terminal.id)) {
            TerminalRowView(terminal: terminal, showsTab: showsTab)
        }
        .hoverEffect(.highlight)
        .contextMenu {
            Section(
                "\(terminal.displayTabTitle) · \(terminal.workspaceLabel ?? "Workspace") · \(terminal.hostName)"
            ) {
                if terminal.cwd.hasPrefix("/") {
                    Button("New Terminal Here", systemImage: "plus.rectangle") {
                        create(beside: terminal)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = terminal.cwd
                    }
                }
            }
            Button(closeLabel(for: terminal), systemImage: "trash", role: .destructive) {
                pendingClose = terminal
            }
        }
        // Every close asks first. No `.destructive` role: List would animate
        // the row out while the confirmation is still up.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                pendingClose = terminal
            } label: {
                Label("Close", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func newTerminalRow(_ workspace: TerminalWorkspaceGroup) -> some View {
        Button {
            if let directory = workspace.directory {
                create(in: workspace, cwd: directory)
            } else {
                onNewTerminal()
            }
        } label: {
            HStack(spacing: 12) {
                TerminalTile(systemImage: "plus", tint: .accentColor)
                Text("New Terminal")
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                if creating.contains(workspace.id) {
                    ProgressView()
                }
            }
        }
        .disabled(creating.contains(workspace.id))
        .hoverEffect(.highlight)
    }

    @ViewBuilder
    private func issueRow(_ issue: ConsoleHostStatusPresentation) -> some View {
        let label = HStack(spacing: 8) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(issueTint(issue))
            Text(issue.message)
                .font(.footnote)
                .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if issue.navigates {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if issue.navigates {
            Button { onOpenHost(issue.hostID) } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this Host's settings.")
        } else {
            label
        }
    }

    private func issueTint(_ issue: ConsoleHostStatusPresentation) -> Color {
        switch issue.severity {
        case .critical: .red
        case .warning: .orange
        case .informational: .secondary
        }
    }

    private func toggle(_ id: TerminalWorkspaceGroup.ID) {
        withAnimation(reduceMotion ? nil : .snappy) { presentation.toggleCollapsed(id) }
    }

    private func toggle(_ hostID: Host.ID) {
        withAnimation(reduceMotion ? nil : .snappy) { presentation.toggleCollapsed(hostID) }
    }

    // MARK: Creating

    private func create(beside terminal: ConsoleTerminal) {
        let id = TerminalWorkspaceGroup.ID(
            hostID: terminal.hostID, workspaceID: terminal.workspaceID)
        create(
            id: id,
            request: ShellTerminalCreationRequest(
                workspaceID: terminal.workspaceID, cwd: terminal.cwd))
    }

    private func create(in workspace: TerminalWorkspaceGroup, cwd: String) {
        create(
            id: workspace.id,
            request: ShellTerminalCreationRequest(workspaceID: workspace.workspaceID, cwd: cwd))
    }

    private func create(id: TerminalWorkspaceGroup.ID, request: ShellTerminalCreationRequest) {
        guard creating.insert(id).inserted else { return }
        Task { @MainActor in
            defer { creating.remove(id) }
            do {
                let identity = try await console.createShellTerminal(request, on: id.hostID)
                guard let terminal = await console.waitForTerminal(identity, on: id.hostID)
                else {
                    createFailure =
                        "The terminal was created, but its Workspace hasn't refreshed yet."
                    return
                }
                onOpen(terminal)
            } catch {
                createFailure = AgentOpenTerminalStore.presentation(for: error).message
            }
        }
    }

    // MARK: Closing

    private func closeScope(for terminal: ConsoleTerminal) -> TerminalCloseScope {
        if console.closesWorkspaceWithTab(of: terminal) { return .workspace }
        return console.closesTab(of: terminal) ? .tab : .pane
    }

    private func closeLabel(for terminal: ConsoleTerminal) -> String {
        "Close \(closeScope(for: terminal).rawValue)"
    }

    private var closeTitle: String {
        pendingClose.map { "\(closeLabel(for: $0))?" } ?? "Close Tab?"
    }

    private func closeMessage(for terminal: ConsoleTerminal) -> String {
        closeScope(for: terminal).message(for: terminal)
    }

    private func confirmClose() {
        guard let terminal = pendingClose else { return }
        pendingClose = nil
        Task { @MainActor in
            do {
                try await console.closeTerminal(terminal)
            } catch {
                closeFailure = ConsoleStore.tabCloseFailureMessage(for: error)
            }
        }
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// One shell row: its named Tab or terminal title in the terminal's own
/// monospaced face over its current directory (see `TerminalRowPresentation`).
struct TerminalRowView: View {
    let terminal: ConsoleTerminal
    /// Search results mix Workspaces, so each row names its own.
    var showsWorkspace = false
    /// Set when the row shares its card with other shells.
    var showsTab = false

    private var presentation: TerminalRowPresentation {
        TerminalRowPresentation(
            terminal: terminal, showsWorkspace: showsWorkspace, showsTab: showsTab)
    }

    var body: some View {
        let presentation = presentation
        HStack(spacing: 12) {
            TerminalTile(systemImage: "terminal", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.subheadline.monospaced().weight(.medium))
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(
            "\(terminal.displayCwd.isEmpty ? "Path unavailable" : terminal.displayCwd), \(terminal.displayTabTitle)"
        )
    }
}

struct TerminalTile: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(
                tint == .secondary ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(tint.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A Workspace card's header: name, a quiet Host, and a plain + that opens
/// a new shell tab in the Workspace. Tapping the name collapses the card.
private struct TerminalWorkspaceHeader: View {
    let workspace: TerminalWorkspaceGroup
    let showsHost: Bool
    let isCreating: Bool
    let onToggle: () -> Void
    let onCreate: (() -> Void)?

    private var detail: String? {
        var parts: [String] = []
        if showsHost { parts.append(workspace.hostName) }
        if workspace.isCollapsed { parts.append(String(workspace.terminals.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Text(workspace.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    Image(systemName: workspace.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                showsHost ? "\(workspace.title), \(workspace.hostName)" : workspace.title)
            .accessibilityValue(
                "\(workspace.terminals.count) terminals, \(workspace.isCollapsed ? "Collapsed" : "Expanded")"
            )
            .accessibilityHint(
                workspace.isCollapsed ? "Expands this Workspace." : "Collapses this Workspace.")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let onCreate {
                Group {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("New Terminal in \(workspace.title)", systemImage: "plus", action: onCreate)
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.secondary)
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                    }
                }
                .frame(width: 44, height: 44)
            }
        }
        .textCase(nil)
        .frame(minHeight: 44)
    }
}

/// By Host section header, styled as `ConsoleHostSectionHeaderView` so the
/// Agents and Terminals tabs show a Host the same way. Hierarchical styles,
/// not fixed colors, so both take the section header's tint.
private struct TerminalHostHeader: View {
    let group: TerminalHostGroup
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.hostName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(group.readinessText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if group.isCollapsed, group.terminalCount > 0 {
                    Text(group.terminalCount == 1 ? "1 terminal" : "\(group.terminalCount) terminals")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.hostName), \(group.readinessText)")
        .accessibilityValue(group.isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(group.isCollapsed ? "Expands this Host." : "Collapses this Host.")
        .accessibilityAddTraits(.isHeader)
    }
}
