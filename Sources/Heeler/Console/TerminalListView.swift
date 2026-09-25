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

    /// By Host's side margins. Cards span the width of the Host rows, and
    /// Workspace headers line up with the cards' edges.
    private static let byHostCardMargin: CGFloat = 16
    private static let byHostHeaderMargin: CGFloat = 0
    /// What the Agents tab's plain-list Host headers add over this grouped
    /// list's compact section spacing.
    private static let byHostHeaderExtraHeight: CGFloat = 16
    /// Between Workspace cards; the header's own 44-point row already
    /// separates collapsed ones.
    private static let workspaceSpacing: CGFloat = 0
    /// Taken off the grouped list's own header padding, above and below, so
    /// collapsed Workspaces stack like rows; the 44-point target stays.
    private static let workspaceHeaderTrim: CGFloat = 7

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
                        ForEach(issues) { ConsoleHostIssueRow(issue: $0, onOpenHost: onOpenHost) }
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
                        if let issue = group.issue, !group.isCollapsed,
                            !group.opensConnectionDetail
                        {
                            ConsoleHostIssueRow(issue: issue, onOpenHost: onOpenHost)
                        }
                    } header: {
                        TerminalHostHeader(group: group) {
                            if group.opensConnectionDetail {
                                onOpenHost(group.hostID)
                            } else {
                                toggle(group.hostID)
                            }
                        }
                            // Back out the card margin and match the plain
                            // list's header rhythm, so a Host sits exactly
                            // where it does in the Agents tab.
                            .padding(.horizontal, -Self.byHostCardMargin)
                            // Above every Host but the first, never below:
                            // an expanded Host keeps its Workspaces close, and
                            // toggling it leaves its own header's height alone.
                            .padding(
                                .top, group.id == groups.first?.id ? 0 : Self.byHostHeaderExtraHeight)
                    }
                    .listSectionSpacing(isFolded(group) ? .compact : .custom(0))
                    if !group.isCollapsed && !group.opensConnectionDetail {
                        ForEach(group.workspaces) { workspace in
                            workspaceSection(
                                workspace, showsHost: false,
                                headerOutset: Self.byHostCardMargin - Self.byHostHeaderMargin)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.horizontal, Self.byHostCardMargin, for: .scrollContent)
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

    /// `headerOutset` widens the header past the card on both sides.
    private func workspaceSection(
        _ workspace: TerminalWorkspaceGroup, showsHost: Bool, headerOutset: CGFloat = 0
    ) -> some View {
        Section {
            if !workspace.isCollapsed {
                ForEach(workspace.terminals) {
                    terminalRow($0, showsTab: workspace.terminals.count > 1)
                }
                // Every card ends in New Terminal, clear of the header's
                // collapse control: a mistap there would open a real tab.
                newTerminalRow(workspace)
            }
        } header: {
            TerminalWorkspaceHeader(
                workspace: workspace,
                showsHost: showsHost,
                onToggle: { toggle(workspace.id) })
                .padding(.horizontal, -headerOutset)
                .padding(.vertical, -Self.workspaceHeaderTrim)
        }
        .listSectionSpacing(.custom(Self.workspaceSpacing))
    }

    private func isFolded(_ group: TerminalHostGroup) -> Bool {
        group.isCollapsed || group.opensConnectionDetail
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
            // A quiet secondary action: the card's shells stay the focus.
            // The plus keeps the tile column so the label lines up with
            // the rows' titles.
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30)
                    .accessibilityHidden(true)
                Text("New Terminal")
                    .font(.subheadline)
                Spacer(minLength: 0)
                if creating.contains(workspace.id) {
                    ProgressView()
                }
            }
        }
        .foregroundStyle(.secondary)
        .disabled(creating.contains(workspace.id))
        .hoverEffect(.highlight)
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

/// A Workspace card's header: name, a quiet Host, and the chevron that
/// collapses the card. New Terminal lives in the card itself.
private struct TerminalWorkspaceHeader: View {
    let workspace: TerminalWorkspaceGroup
    let showsHost: Bool
    let onToggle: () -> Void

    private var detail: String? {
        var parts: [String] = []
        if showsHost { parts.append(workspace.hostName) }
        if workspace.isCollapsed { parts.append(String(workspace.terminals.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        // Collapsing is the header's frequent action, so the whole row
        // toggles and the chevron takes the trailing, thumb-side slot.
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
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(workspace.isCollapsed ? 0 : 90))
                    // The Host header's chevron width, so both line up; the
                    // whole row is the tap target.
                    .frame(width: 12)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            showsHost ? "\(workspace.title), \(workspace.hostName)" : workspace.title)
        .accessibilityValue(
            "\(workspace.terminals.count) terminals, \(workspace.isCollapsed ? "Collapsed" : "Expanded")"
        )
        .accessibilityHint(
            workspace.isCollapsed ? "Expands this Workspace." : "Collapses this Workspace.")
        .accessibilityAddTraits(.isHeader)
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
                HostStatusGlyph(tone: group.readiness.tone)
                Text(group.hostName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(group.readiness.dimsName ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if group.isCollapsed, group.terminalCount > 0 {
                    Text(group.terminalCount == 1 ? "1 terminal" : "\(group.terminalCount) terminals")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: Capsule())
                }
                Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .center)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.hostName), \(group.readiness.text)")
        .accessibilityValue(
            group.opensConnectionDetail ? "" : group.isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(
            group.opensConnectionDetail
                ? "Shows why this Host can't connect."
                : group.isCollapsed ? "Expands this Host." : "Collapses this Host.")
        .accessibilityAddTraits(.isHeader)
    }

    /// A failing Host never expands; its chevron points at the sheet.
    private var isFolded: Bool { group.isCollapsed || group.opensConnectionDetail }
}
