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
        .navigationTitle("Agent List Fields")
        .navigationBarTitleDisplayMode(.large)
    }

    private var hostList: some View {
        List {
            sessionSection
            ForEach(hosts) { @Sendable host in
                MainActorContent { hostRow(host) }
            }
            AgentLayoutErrorView(editor: editor)
        }
        .listStyle(.plain)
        .listSectionSpacing(AgentListFieldsChrome.hostSpacing)
        .contentMargins(.horizontal, AgentListFieldsChrome.pageInset, for: .scrollContent)
        .readableColumnPage(contentMargin: AgentListFieldsChrome.pageInset)
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
/// start from herdr's sidebar fields; Row 3 is Heeler's own row. Each slot
/// has a left side and a right side, which ends its line in the Console.
/// Slots are never added, moved, or deleted, so a row's index is its
/// identity everywhere on this screen. Every change saves immediately through the editor. Every
/// Agent on the Host shares these rows; there are no per-kind overrides.
struct AgentListFieldsHostDetailView: View {
    let host: Host
    let console: ConsoleStore
    let hosts: [Host]
    var editor: AgentListFieldsEditor
    @State private var addingField: AgentListFieldsEditorDestination?
    @State private var confirmingSync = false
    @State private var confirmingApply = false
    /// Apply to All Hosts' result, until this Host's fields change.
    @State private var appliedMessage: String?

    var body: some View {
        hostList
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
            .task { await console.refreshPluginStatuses(for: [host.id]) }
            .onChange(of: layout) { appliedMessage = nil }
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
        .readableColumnPage(contentMargin: AgentListFieldsChrome.pageInset)
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
                if let requirement = console.pluginStatuses.status(for: host.id)?
                    .requirements(for: [.sidebarFields]).first
                {
                    // Without a snapshot, Sync from plugin silently fills
                    // fallback fields; say why before the user tries it.
                    PluginRequirementNote(text: requirement.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "settings.agentList.pluginRequirement.\(host.id.uuidString)")
                }
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
            AgentListFieldsPreview(
                layout: layout, hostName: host.displayName,
                kind: AgentListFieldsPreview.kind(onHost: host.id, among: console.agents))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(AgentListFieldsChrome.previewInsets)
        .agentListHostSurface(isFirst: true, isLast: false, fill: AgentListFieldsChrome.previewFill)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var hostRows: some View {
        let slotRows = AgentRowSlot.slotRows(layout.rows)
        let trailingRows = AgentLayoutTokensEditing.rows(.trailing, of: layout)
        ForEach(Array(slotRows.enumerated()), id: \.offset) { @Sendable index, row in
            let trailing = AgentLayoutTokensEditing.row(index, in: trailingRows)
            MainActorContent {
                AgentListFieldsRowEditor(
                    index: index, row: row, trailing: trailing,
                    isEnabled: !isSyncing && !editor.isCatalogUnreadable,
                    onAdd: { side in
                        addingField = AgentListFieldsEditorDestination(
                            hostID: host.id, rowIndex: index, side: side)
                    },
                    onToggleStyle: { fieldIndex, side in toggleStyle(fieldIndex, rowIndex: index, side: side) },
                    onShift: { fieldIndex, delta, side in
                        AgentLayoutTokensEditing.shift(
                            fieldIndex, by: delta, editor: editor, hostID: host.id, rowIndex: index, side: side)
                    },
                    onMoveAcross: { fieldIndex, side in
                        AgentLayoutTokensEditing.moveAcross(
                            fieldIndex, editor: editor, hostID: host.id, rowIndex: index, from: side)
                    },
                    onRemove: { fieldIndex, side in
                        AgentLayoutTokensEditing.delete(
                            IndexSet(integer: fieldIndex), editor: editor, hostID: host.id, rowIndex: index,
                            side: side)
                    })
                    .listRowInsets(AgentListFieldsChrome.rowInsets)
                    .agentListHostSurface(isFirst: false, isLast: false)
            }
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
            if hosts.count > 1 {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 0.5)
                applyRow
            }
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

    /// Copies this Host's fields to every other Host, after a confirmation
    /// anchored to the button, and says how many changed.
    private var applyRow: some View {
        let others = hosts.count - 1
        let isDisabled = isSyncing || editor.isCatalogUnreadable
        return VStack(alignment: .leading, spacing: 5) {
            if let appliedMessage {
                Text(verbatim: appliedMessage)
                    .font(.footnote)
                    .foregroundStyle(AgentListFieldsChrome.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.agentList.appliedTip.\(host.id.uuidString)")
            }
            Button {
                confirmingApply = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.on.square")
                        .font(.subheadline.weight(.medium))
                    Text("Apply to All Hosts")
                }
                // Dimmed by hand, as Sync from plugin's: an explicit tint
                // overrides a disabled button's own dimming.
                .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)
            .accessibilityIdentifier("settings.agentList.applyToAll.\(host.id.uuidString)")
            .confirmationDialog(
                "Apply these fields to all Hosts?", isPresented: $confirmingApply, titleVisibility: .visible
            ) {
                Button(others == 1 ? "Apply to 1 Host" : "Apply to \(others) Hosts") { applyToAllHosts() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: AgentListFieldsCopy.applyConfirmation(
                    hostName: host.displayName, otherHosts: others))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyToAllHosts() {
        appliedMessage = editor.applyToOtherHosts(from: host.id, among: hosts.map(\.id))
            .map(AgentListFieldsCopy.applied)
    }

    private func toggleStyle(_ fieldIndex: Int, rowIndex: Int, side: AgentRowSide) {
        let row = AgentLayoutTokensEditing.row(rowIndex, in: AgentLayoutTokensEditing.rows(side, of: layout))
        guard row.indices.contains(fieldIndex) else { return }
        let next = AgentLayoutTokensEditing.style(of: row[fieldIndex]).toggled
        AgentLayoutTokensEditing.setStyle(
            next, at: fieldIndex, editor: editor, hostID: host.id, rowIndex: rowIndex, side: side)
    }
}

/// One fixed row slot edited in place: the title, then the left side's
/// chips with an add chip after them and, flush right as in the Console, the
/// right side's. The right side drops under the left where both do not fit
/// on one line. Provenance is explained once by the note under the rows, not
/// tagged per row.
private struct AgentListFieldsRowEditor: View {
    let index: Int
    let row: AgentRow
    let trailing: AgentRow
    let isEnabled: Bool
    let onAdd: (AgentRowSide) -> Void
    let onToggleStyle: (Int, AgentRowSide) -> Void
    let onShift: (Int, Int, AgentRowSide) -> Void
    let onMoveAcross: (Int, AgentRowSide) -> Void
    let onRemove: (Int, AgentRowSide) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Row \(index + 1)")
                .font(.callout)
                .foregroundStyle(.primary)
            // A wrap fills the width it is offered, so each side keeps its
            // one-line width wherever that fits, and the right side wraps
            // from the left only when even one line of its own is too wide.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    chips(.leading).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    chips(.trailing).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 5) {
                    chips(.leading)
                    ViewThatFits(in: .horizontal) {
                        chips(.trailing).fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        chips(.trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AgentListFieldsRowLabel.accessibilityLabel(index: index, row: row, trailing: trailing))
    }

    private func fields(_ side: AgentRowSide) -> AgentRow { side == .leading ? row : trailing }

    private func chips(_ side: AgentRowSide) -> some View {
        let fields = fields(side)
        return ChipWrap(spacing: 5) {
            ForEach(Array(fields.enumerated()), id: \.offset) { @Sendable offset, token in
                MainActorContent { fieldChip(token, at: offset, side: side) }
            }
            addChip(side)
        }
    }

    private func fieldChip(_ token: AgentRowStyledToken, at offset: Int, side: AgentRowSide) -> some View {
        let style = AgentLayoutTokensEditing.style(of: token)
        let hasStyle = AgentLayoutTokensEditing.hasStyle(token.token, on: side)
        let count = fields(side).count
        return Menu {
            if hasStyle {
                Button(style.toggleActionTitle) { onToggleStyle(offset, side) }
            }
            if offset > 0 {
                Button("Move Left", systemImage: "arrow.left") { onShift(offset, -1, side) }
            }
            if offset < count - 1 {
                Button("Move Right", systemImage: "arrow.right") { onShift(offset, 1, side) }
            }
            if AgentLayoutTokensEditing.canMoveAcross(token.token, from: side, landing: fields(side.other)) {
                switch side {
                case .leading:
                    Button("Move to Right Side", systemImage: "arrow.right.to.line") { onMoveAcross(offset, side) }
                case .trailing:
                    Button("Move to Left Side", systemImage: "arrow.left.to.line") { onMoveAcross(offset, side) }
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { onRemove(offset, side) }
        } label: {
            AgentListFieldsChip(text: token.token.rawValue, isSecondary: hasStyle && style == .secondary)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(
            AgentListFieldsChipLabel.text(index: offset, count: count, token: token, side: side))
        .accessibilityHint("Opens field actions")
    }

    private func addChip(_ side: AgentRowSide) -> some View {
        let isEmpty = fields(side).isEmpty
        return Button { onAdd(side) } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                if isEmpty {
                    Text(side == .leading ? "Add field" : "Right side")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, isEmpty ? 7 : 6)
            .padding(.vertical, 2)
            .frame(minHeight: AgentListFieldsChrome.chipMinHeight)
            .background(
                RoundedRectangle(cornerRadius: AgentListFieldsChrome.chipRadius, style: .continuous)
                    .strokeBorder(
                        AgentListFieldsChrome.chipStroke, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || fields(side).count >= AgentRowLayout.maximumTokensPerRow)
        .accessibilityLabel(
            side == .leading ? "Add field to Row \(index + 1)" : "Add field to the right of Row \(index + 1)")
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
/// and side are stable across every edit and sync.
struct AgentListFieldsEditorDestination: Hashable, Identifiable {
    let hostID: Host.ID
    let rowIndex: Int
    var side: AgentRowSide = .leading

    var id: String { "\(hostID.uuidString):\(rowIndex):\(side == .leading ? "left" : "right")" }
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
    static let noHosts = "Add a Host to configure its Agent rows."
    static let listIntro =
        "Each Host decides which fields appear on its Agent rows in Console. Open a Host to change them."
    static let detailIntro =
        "Tap a field to change its style, move it, or remove it. Tap + to add one. Changes save right away."
    static let syncConfirmation =
        "Row 1 and Row 2 are replaced with this Host's herdr fields and saved right away. "
        + "Row 3 and every row's right side stay as they are."
    static func applyConfirmation(hostName: String, otherHosts: Int) -> String {
        let others = otherHosts == 1 ? "The other Host's rows" : "The other \(otherHosts) Hosts' rows"
        return "\(others), right sides included, are replaced with \(hostName)'s and saved right away. "
            + "Changes you make here later stay on \(hostName)."
    }

    /// Apply to All Hosts' result: how many Hosts it changed.
    static func applied(_ changed: Int) -> String {
        switch changed {
        case 0: "Every other Host already uses these fields."
        case 1: "Applied to 1 other Host."
        default: "Applied to \(changed) other Hosts."
        }
    }

    /// Sync's result when the plugin snapshot carries diagnostics.
    static let syncDiagnostics =
        "The Heeler plugin couldn't read this Host's herdr sidebar settings, so herdr's "
        + "default fields were used. Update the plugin, or run herdr config check."
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
        + "Fields on a row's right side end its line, and Sync from plugin keeps them. "
        + "The ring around each Agent's mark shows its status; status_badge adds it in a capsule. "
        + "Where the mark names the program, the Agent field leaves rows with other fields."
}

enum AgentListFieldsChipLabel {
    static func text(
        index: Int, count: Int, token: AgentRowStyledToken, side: AgentRowSide = .leading
    ) -> String {
        let field = side == .leading ? "Field" : "Right side field"
        let label = "\(field) \(index + 1) of \(count): \(token.token.rawValue)"
        guard AgentLayoutTokensEditing.hasStyle(token.token, on: side) else { return label }
        return label + (token.dim == true ? ", secondary style" : ", default style")
    }
}

enum AgentListFieldsRowLabel {
    static func emptyText(slot: AgentRowSlot?) -> String {
        slot == .heeler ? "Not configured" : "No fields"
    }

    static func accessibilityLabel(index: Int, row: AgentRow, trailing: AgentRow = []) -> String {
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
        parts += trailing.enumerated().map { offset, token in
            AgentListFieldsChipLabel.text(index: offset, count: trailing.count, token: token, side: .trailing)
        }
        return parts.joined(separator: ", ")
    }
}
