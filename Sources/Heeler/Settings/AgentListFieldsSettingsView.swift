import SwiftUI

struct AgentListFieldsSettingsView: View {
    let console: ConsoleStore
    let hosts: [Host]
    @State private var editor: AgentListFieldsEditor

    init(console: ConsoleStore, hosts: [Host]) {
        self.console = console
        self.hosts = hosts
        _editor = State(initialValue: AgentListFieldsEditor(
            layouts: console.rowLayouts, snapshots: console.sidebarSnapshots,
            fetch: { [console] hostID in await console.refreshSidebarLayout(for: hostID) }))
    }

    var body: some View {
        Group {
            if hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "desktopcomputer")
                } description: {
                    Text(AgentListFieldsCopy.noHosts)
                }
            } else {
                hostList
            }
        }
        .frame(maxWidth: AgentListFieldsCopy.readableWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle("Agent List Fields")
        .navigationBarTitleDisplayMode(.large)
    }

    private var hostList: some View {
        List {
            sessionSection
            ForEach(hosts) { host in
                hostRow(host)
            }
            AgentLayoutErrorView(editor: editor)
        }
        .listStyle(.plain)
        .listSectionSpacing(AgentListFieldsChrome.hostSpacing)
        .contentMargins(.horizontal, AgentListFieldsChrome.pageInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .listRowSeparatorTint(Color(uiColor: .separator))
        .refreshable {
            await console.refreshSidebarLayouts()
        }
    }

    private var sessionSection: some View {
        Section {
            Text(AgentListFieldsCopy.listIntro)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
    }

    /// Name only; the Host detail states where its fields come from.
    private func hostRow(_ host: Host) -> some View {
        Section {
            NavigationLink {
                AgentListFieldsHostDetailView(host: host, console: console, hosts: hosts, editor: editor)
            } label: {
                Text(verbatim: host.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .listRowInsets(AgentListFieldsChrome.headerInsets)
            .agentListHostSurface(isFirst: true, isLast: true)
            .accessibilityIdentifier("settings.agentList.host.\(host.id.uuidString)")
        }
        .listSectionSeparator(.hidden)
    }
}

/// One Host's rows as three fixed slots, edited in place. Row 1 and Row 2
/// start from herdr's sidebar fields; Row 3 is Heeler's own row. Slots are never
/// added, moved, or deleted, so a row's index is its identity everywhere on
/// this screen. Every change saves immediately through the editor. Every
/// Agent on the Host shares these rows; there are no per-kind overrides.
struct AgentListFieldsHostDetailView: View {
    let host: Host
    let console: ConsoleStore
    let hosts: [Host]
    var editor: AgentListFieldsEditor
    @State private var addingField: AgentListFieldsEditorDestination?
    @State private var confirmingSync = false

    var body: some View {
        hostList
            .frame(maxWidth: AgentListFieldsCopy.readableWidth)
            .frame(maxWidth: .infinity)
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog(
                "Replace rows with herdr's fields?", isPresented: $confirmingSync, titleVisibility: .visible
            ) {
                Button("Replace Rows") { Task { await sync() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AgentListFieldsCopy.syncConfirmation)
            }
            .sheet(item: $addingField) { destination in
                AgentListFieldsAddFieldSheet(
                    editor: editor, destination: destination, hostName: host.displayName)
            }
    }

    private var layout: AgentRowLayout { editor.layout(for: host.id) }
    private var isSyncing: Bool { editor.syncStates[host.id] == .syncing }

    private var hostList: some View {
        List {
            sessionSection
            Section {
                previewRow
                hostRows
                slotsNote
                syncRow
            }
            .listSectionSeparator(.hidden)
            AgentLayoutErrorView(editor: editor)
        }
        .listStyle(.plain)
        .listSectionSpacing(AgentListFieldsChrome.hostSpacing)
        .contentMargins(.horizontal, AgentListFieldsChrome.pageInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .listRowSeparatorTint(Color(uiColor: .separator))
        .refreshable {
            await console.refreshSidebarLayouts()
        }
    }

    private var sessionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: AgentListFieldsSourceCaption.text(editor.underlyingSource(for: host.id)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(AgentListFieldsCopy.detailIntro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
    }

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Console Preview")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            AgentListFieldsPreview(layout: layout, hostName: host.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(AgentListFieldsChrome.previewInsets)
        .agentListHostSurface(isFirst: true, isLast: false, fill: AgentListFieldsChrome.previewFill)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var hostRows: some View {
        let slotRows = AgentRowSlot.slotRows(layout.rows)
        ForEach(Array(slotRows.enumerated()), id: \.offset) { index, row in
            AgentListFieldsRowEditor(
                index: index, row: row, isEnabled: !isSyncing && !editor.isCatalogUnreadable,
                onAdd: {
                    addingField = AgentListFieldsEditorDestination(hostID: host.id, rowIndex: index)
                },
                onToggleStyle: { fieldIndex in toggleStyle(fieldIndex, rowIndex: index) },
                onShift: { fieldIndex, delta in shift(fieldIndex, by: delta, rowIndex: index) },
                onRemove: { fieldIndex in remove(fieldIndex, rowIndex: index) })
                .listRowInsets(AgentListFieldsChrome.rowInsets)
                .agentListHostSurface(isFirst: false, isLast: false)
        }
    }

    private var slotsNote: some View {
        Text(AgentListFieldsCopy.rowSlots)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(AgentListFieldsChrome.slotsNoteInsets)
            .listRowSeparator(.hidden)
            .agentListHostSurface(isFirst: false, isLast: false)
    }

    @ViewBuilder
    private var syncRow: some View {
        let identifier = "settings.agentList.sync.\(host.id.uuidString)"
        let tipIdentifier = "settings.agentList.syncTip.\(host.id.uuidString)"
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
            Group {
                switch editor.syncStates[host.id] {
                case .syncing:
                    HStack(spacing: 9) {
                        ProgressView()
                        Text("Syncing…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier(identifier)
                case .filled(let message):
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: message)
                            .font(.footnote)
                            .foregroundStyle(AgentListFieldsChrome.success)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(tipIdentifier)
                        syncButton(identifier: identifier)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(tipIdentifier)
                        Button("Retry") { Task { await sync() } }
                            .buttonStyle(.borderless)
                    }
                case nil:
                    syncButton(identifier: identifier)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(editor.isCatalogUnreadable)
        .listRowInsets(AgentListFieldsChrome.syncInsets)
        .listRowSeparator(.hidden)
        .agentListHostSurface(isFirst: false, isLast: true)
    }

    private func syncButton(identifier: String) -> some View {
        Button {
            confirmingSync = true
        } label: {
            // A plain HStack, not a Label: the list Label style reserves an
            // icon column and renders the symbol larger than the text.
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
                Text("Sync from plugin")
            }
            // An explicit tint would override the dimming a disabled button
            // gets, so the unreadable-catalog state picks the style itself.
            .foregroundStyle(
                editor.isCatalogUnreadable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.borderless)
        .disabled(isSyncing || editor.isCatalogUnreadable)
        .accessibilityIdentifier(identifier)
    }

    private func sync() async {
        await editor.replaceWithPluginFields(host.id, hostName: host.displayName)
    }

    private func toggleStyle(_ fieldIndex: Int, rowIndex: Int) {
        let row = AgentLayoutTokensEditing.row(rowIndex, in: layout.rows)
        guard row.indices.contains(fieldIndex) else { return }
        let next = AgentLayoutTokensEditing.style(of: row[fieldIndex]).toggled
        AgentLayoutTokensEditing.setStyle(
            next, at: fieldIndex, editor: editor, hostID: host.id, rowIndex: rowIndex)
    }

    private func shift(_ fieldIndex: Int, by delta: Int, rowIndex: Int) {
        AgentLayoutTokensEditing.shift(
            fieldIndex, by: delta, editor: editor, hostID: host.id, rowIndex: rowIndex)
    }

    private func remove(_ fieldIndex: Int, rowIndex: Int) {
        AgentLayoutTokensEditing.delete(
            IndexSet(integer: fieldIndex), editor: editor, hostID: host.id, rowIndex: rowIndex)
    }
}

/// One fixed row slot edited in place: the title, one menu chip per field,
/// and a trailing add chip. Provenance is explained once by the note under
/// the rows, not tagged per row.
private struct AgentListFieldsRowEditor: View {
    let index: Int
    let row: AgentRow
    let isEnabled: Bool
    let onAdd: () -> Void
    let onToggleStyle: (Int) -> Void
    let onShift: (Int, Int) -> Void
    let onRemove: (Int) -> Void

    private var canAdd: Bool { isEnabled && row.count < AgentRowLayout.maximumTokensPerRow }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Row \(index + 1)")
                .font(.callout)
                .foregroundStyle(.primary)
            AgentListFieldsChipWrap(spacing: 5) {
                ForEach(Array(row.enumerated()), id: \.offset) { offset, token in
                    fieldChip(token, at: offset)
                }
                addChip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AgentListFieldsRowLabel.accessibilityLabel(index: index, row: row))
    }

    private func fieldChip(_ token: AgentRowStyledToken, at offset: Int) -> some View {
        let style = AgentLayoutTokensEditing.style(of: token)
        return Menu {
            Button(style.toggleActionTitle) { onToggleStyle(offset) }
            if offset > 0 {
                Button("Move Left", systemImage: "arrow.left") { onShift(offset, -1) }
            }
            if offset < row.count - 1 {
                Button("Move Right", systemImage: "arrow.right") { onShift(offset, 1) }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { onRemove(offset) }
        } label: {
            AgentListFieldsChip(text: token.token.rawValue, isSecondary: style == .secondary)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(
            AgentListFieldsChipLabel.text(index: offset, count: row.count, token: token))
        .accessibilityHint("Opens field actions")
    }

    private var addChip: some View {
        Button(action: onAdd) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                if row.isEmpty {
                    Text("Add field")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, row.isEmpty ? 7 : 6)
            .padding(.vertical, 2)
            .frame(minHeight: AgentListFieldsChrome.chipMinHeight)
            .background(
                RoundedRectangle(cornerRadius: AgentListFieldsChrome.chipRadius, style: .continuous)
                    .strokeBorder(
                        AgentListFieldsChrome.chipStroke, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .accessibilityLabel("Add field to Row \(index + 1)")
    }
}

private struct AgentListFieldsChip: View {
    let text: String
    let isSecondary: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(isSecondary ? AgentListFieldsChrome.chipInkSecondary : AgentListFieldsChrome.chipInk)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minHeight: AgentListFieldsChrome.chipMinHeight)
            .background(
                RoundedRectangle(cornerRadius: AgentListFieldsChrome.chipRadius, style: .continuous)
                    .fill(AgentListFieldsChrome.chipFill))
            .overlay {
                RoundedRectangle(cornerRadius: AgentListFieldsChrome.chipRadius, style: .continuous)
                    .strokeBorder(AgentListFieldsChrome.chipStroke, lineWidth: 0.5)
            }
    }
}

/// Wraps chips in source order so long or multiple tokens stay fully visible.
private struct AgentListFieldsChipWrap: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let arranged = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews)
        for item in arranged.frames {
            subviews[item.offset].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                proposal: ProposedViewSize(item.frame.size))
        }
    }

    private func arrange(
        proposal: ProposedViewSize, subviews: Subviews
    ) -> (size: CGSize, frames: [(offset: Int, frame: CGRect)]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var frames: [(offset: Int, frame: CGRect)] = []
        for (offset, subview) in subviews.enumerated() {
            let size = fittedSize(of: subview, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            frames.append((offset, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        let height = subviews.isEmpty ? 0 : y + rowHeight
        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return (CGSize(width: width, height: height), frames)
    }

    /// A chip wider than the line is measured at `maxWidth` so its `Text` can
    /// wrap; tokens stay in source order.
    private func fittedSize(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let unconstrained = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, maxWidth > 0, unconstrained.width > maxWidth else {
            return unconstrained
        }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

struct AgentListFieldsHostSurface: View {
    var isFirst: Bool
    var isLast: Bool
    var fill: Color

    var body: some View {
        let radius = AgentListFieldsChrome.hostCornerRadius
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0,
            style: .continuous)
            .fill(fill)
    }
}

extension View {
    func agentListHostSurface(
        isFirst: Bool, isLast: Bool, fill: Color = AgentListFieldsChrome.cardFill
    ) -> some View {
        listRowBackground(AgentListFieldsHostSurface(isFirst: isFirst, isLast: isLast, fill: fill))
    }
}

enum AgentListFieldsChrome {
    static let pageInset: CGFloat = 16
    static let hostSpacing: CGFloat = 18
    static let hostCornerRadius: CGFloat = 12
    static let chipRadius: CGFloat = 5
    /// In-card wash: original `#FAFAFC` on white. Do not use
    /// `tertiarySystemGroupedBackground` in light — that token is the page.
    static let previewFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return .tertiarySystemGroupedBackground
        }
        return UIColor(red: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)
    })
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let chipFill = Color(uiColor: .tertiarySystemFill)
    static let chipStroke = Color(uiColor: .separator)
    static let chipInk = Color.primary.opacity(0.75)
    static let chipInkSecondary = Color.primary.opacity(0.42)
    static let chipMinHeight: CGFloat = 20
    static let success = Color(uiColor: .systemGreen)
    static let headerInsets = EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
    static let previewInsets = EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)
    static let rowInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let slotsNoteInsets = EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16)
    static let syncInsets = EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16)
    static let noticeInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
}

/// Identity for an Add Field sheet. Row slots are fixed, so the slot index
/// is stable across every edit and sync.
struct AgentListFieldsEditorDestination: Hashable, Identifiable {
    let hostID: Host.ID
    let rowIndex: Int

    var id: String { "\(hostID.uuidString):\(rowIndex)" }
}

enum AgentListFieldsSourceCaption {
    /// Provenance only. Callers must pass `underlyingSource`, never `.draft`.
    static func text(_ source: AgentListFieldsEditor.LayoutSource) -> String {
        switch source {
        case .draft, .saved: "Your fields"
        case .plugin: "Following herdr plugin"
        case .pluginDefaults: "herdr default fields (plugin reported a problem)"
        case .loading: "Reading herdr fields…"
        case .missing: "No herdr fields snapshot"
        case .unavailable: "herdr fields unavailable"
        }
    }
}

enum AgentListFieldsCopy {
    static let readableWidth: CGFloat = 640
    static let noHosts = "Add a Host to configure its Agent rows."
    static let listIntro =
        "Each Host decides which fields appear on its Agent rows in Console. Open a Host to change them."
    static let detailIntro =
        "Tap a field to change its style, move it, or remove it. Tap + to add one. Changes save right away."
    static let syncConfirmation =
        "This Host's rows are replaced with its herdr fields and saved right away."
    static let unreadableCatalogTitle = "Saved fields can’t be read"
    static let unreadableCatalog =
        "Heeler kept the saved data untouched. Every Host follows its herdr fields, and editing "
        + "is paused until you reset."
    static let unreadableCatalogEdit =
        "The saved Agent List Fields could not be read. Nothing was changed. Reset Saved Fields to start over."
    static let resetConfirmation =
        "The unreadable saved fields are deleted. Every Host returns to its herdr fields and can be edited again."
    static let rowSlots =
        "Row 1 and Row 2 start from herdr's sidebar fields; Sync from plugin refills them. "
        + "Row 3 is Heeler's own row. Any row can use herdr and Heeler fields. "
        + "The status badge always ends Row 1."
}

enum AgentListFieldsChipLabel {
    static func text(index: Int, count: Int, token: AgentRowStyledToken) -> String {
        let style = token.dim == true ? "secondary style" : "default style"
        return "Field \(index + 1) of \(count): \(token.token.rawValue), \(style)"
    }
}

enum AgentListFieldsRowLabel {
    static func emptyText(slot: AgentRowSlot?) -> String {
        slot == .heeler ? "Not configured" : "No fields"
    }

    static func accessibilityLabel(index: Int, row: AgentRow) -> String {
        let slot = AgentRowSlot.forRow(index)
        var parts = ["Row \(index + 1)"]
        if let slot { parts.append("\(slot.label) row") }
        if row.isEmpty {
            parts.append(emptyText(slot: slot))
        } else {
            parts += row.enumerated().map { offset, token in
                AgentListFieldsChipLabel.text(index: offset, count: row.count, token: token)
            }
        }
        return parts.joined(separator: ", ")
    }
}
