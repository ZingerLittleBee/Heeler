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

    private func hostRow(_ host: Host) -> some View {
        let caption = AgentListFieldsSourceCaption.text(editor.underlyingSource(for: host.id))
        return Section {
            NavigationLink {
                AgentListFieldsHostDetailView(host: host, console: console, hosts: hosts, editor: editor)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: host.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(verbatim: caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowInsets(AgentListFieldsChrome.headerInsets)
            .agentListHostSurface(isFirst: true, isLast: true)
            .accessibilityLabel(
                AgentListFieldsHostHeader.accessibilityLabel(
                    name: host.displayName, caption: caption))
            .accessibilityIdentifier("settings.agentList.host.\(host.id.uuidString)")
        }
        .listSectionSeparator(.hidden)
    }
}

/// One Host's rows as three fixed slots. Row 1 and Row 2 carry herdr's
/// sidebar fields; Row 3 is Heeler's own row. Slots are never added, moved,
/// or deleted, so a row's index is its identity everywhere on this screen.
struct AgentListFieldsHostDetailView: View {
    let host: Host
    let console: ConsoleStore
    let hosts: [Host]
    var editor: AgentListFieldsEditor
    @State private var expandedOverrides: Set<String> = []
    @State private var openedRow: AgentListFieldsEditorDestination?
    @State private var confirmingDiscard = false
    @State private var didSucceedSave = false
    @State private var showingOther = false
    @State private var otherKind = ""
    @State private var otherHint: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        hostList
            .frame(maxWidth: AgentListFieldsCopy.readableWidth)
            .frame(maxWidth: .infinity)
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.large)
            .navigationBarBackButtonHidden(editor.isEditing)
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { discardDrafts() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your unsaved rows will be lost.")
            }
            .onChange(of: overrideKinds) { _, kinds in
                // A removed override closes its pushed Field Editor.
                if let openedRow, let kind = openedRow.kind, !kinds.contains(kind) {
                    self.openedRow = nil
                }
            }
    }

    private var layout: AgentRowLayout { editor.layout(for: host.id) }
    private var overrideKinds: [String] { layout.rowsByAgent.keys.sorted() }

    private var hostList: some View {
        let isSyncing = editor.syncStates[host.id] == .syncing
        let bottom = hostBottom
        return List {
            sessionSection
            Section {
                previewRow
                hostRows(isSyncing: isSyncing)
                slotsNote
                overridesBlock(isSyncing: isSyncing, bottom: bottom)
                if editor.isEditing {
                    syncRow(isSyncing: isSyncing)
                }
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
        .environment(\.editMode, fieldsEditMode)
        .navigationDestination(item: $openedRow) { destination in
            AgentLayoutTokensView(
                editor: editor, hostID: destination.hostID, kind: destination.kind,
                rowIndex: destination.rowIndex, hostName: hostName(for: destination.hostID))
        }
        .refreshable {
            await console.refreshSidebarLayouts()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editor.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if editor.hasUnsavedChanges { confirmingDiscard = true } else { discardDrafts() }
                }
                .accessibilityIdentifier("settings.agentList.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveDrafts()
                } label: {
                    Label("Save changes", systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Save changes")
                .accessibilityIdentifier("settings.agentList.save")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { beginDrafts() }
                    .accessibilityIdentifier("settings.agentList.edit")
            }
        }
    }

    private var sessionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let status = AgentListFieldsSessionStatus.current(
                    isEditing: editor.isEditing, isDirty: editor.hasUnsavedChanges,
                    didSucceedSave: didSucceedSave)
                {
                    Text(status.title)
                        .font(.footnote)
                        .foregroundStyle(status == .unsaved ? Color.orange : Color.green)
                }
                Text(verbatim: AgentListFieldsSourceCaption.text(editor.underlyingSource(for: host.id)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(editor.isEditing
                    ? AgentListFieldsCopy.editingIntro
                    : AgentListFieldsCopy.detailIntro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    /// Edit mode only drives the native minus on Agent overrides; row slots
    /// are fixed and never expose reorder or delete affordances.
    private var fieldsEditMode: Binding<EditMode> {
        Binding<EditMode>.constant(editor.isEditing ? EditMode.active : EditMode.inactive)
    }

    private enum HostBottom: Equatable {
        case noOverrides
        case override(String)
        case sync
    }

    private enum NestedBottom: Equatable {
        case header
        case row(Int)
    }

    private var hostBottom: HostBottom {
        if editor.isEditing { return .sync }
        if let last = overrideKinds.last { return .override(last) }
        return .noOverrides
    }

    private func nestedBottom(for kind: String) -> NestedBottom {
        expandedOverrides.contains(kind) ? .row(AgentRowLayout.maximumConsoleRows - 1) : .header
    }

    private func isHostLastOverrideHeader(bottom: HostBottom, kind: String) -> Bool {
        guard case .override(let last) = bottom, last == kind else { return false }
        return nestedBottom(for: kind) == .header
    }

    private func isHostLastOverrideRow(bottom: HostBottom, kind: String, index: Int) -> Bool {
        guard case .override(let last) = bottom, last == kind else { return false }
        return nestedBottom(for: kind) == .row(index)
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
        .moveDisabled(true)
        .deleteDisabled(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hostRows(isSyncing: Bool) -> some View {
        let slotRows = AgentRowSlot.slotRows(layout.rows)
        ForEach(Array(slotRows.enumerated()), id: \.offset) { index, row in
            AgentListFieldsRowButton(
                index: index, row: row, canOpen: !isSyncing,
                onOpen: {
                    openedRow = AgentListFieldsEditorDestination(
                        hostID: host.id, kind: nil, rowIndex: index)
                })
                .listRowInsets(AgentListFieldsChrome.rowInsets)
                .agentListHostSurface(isFirst: false, isLast: false)
                .moveDisabled(true)
                .deleteDisabled(true)
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
            .moveDisabled(true)
            .deleteDisabled(true)
    }

    @ViewBuilder
    private func overridesBlock(isSyncing: Bool, bottom: HostBottom) -> some View {
        let kinds = overrideKinds
        let canMutate = editor.isEditing && !isSyncing
        if kinds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                overridesHeadingLabel
                Text(AgentListFieldsCopy.noOverrides)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if editor.isEditing {
                    addOverrideControls(host, canMutate: canMutate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(AgentListFieldsChrome.overridesChromeInsets)
            .listRowSeparator(.hidden)
            .agentListHostSurface(isFirst: false, isLast: bottom == .noOverrides)
            .moveDisabled(true)
            .deleteDisabled(true)
        } else {
            overridesHeadingLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(AgentListFieldsChrome.overridesHeadingInsets)
                .listRowSeparator(.hidden)
                .agentListHostSurface(isFirst: false, isLast: false)
                .moveDisabled(true)
                .deleteDisabled(true)
            ForEach(kinds, id: \.self) { kind in
                overrideGroup(kind: kind, isSyncing: isSyncing, canMutate: canMutate, bottom: bottom)
            }
            .onDelete(perform: canMutate
                ? { offsets in removeOverrides(at: offsets) } : nil)
            if editor.isEditing {
                addOverrideControls(host, canMutate: canMutate)
                    .listRowInsets(AgentListFieldsChrome.overridesActionInsets)
                    .listRowSeparator(.hidden)
                    .agentListHostSurface(isFirst: false, isLast: false)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }
        }
    }

    private var overridesHeadingLabel: some View {
        Text("Agent overrides")
            .font(.caption2.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func overrideGroup(
        kind: String, isSyncing: Bool, canMutate: Bool, bottom: HostBottom
    ) -> some View {
        let expanded = expandedOverrides.contains(kind)
        let nestedEnd = nestedBottom(for: kind)
        return DisclosureGroup(isExpanded: overrideExpansion(kind)) {
            overrideRowsContent(kind: kind, isSyncing: isSyncing, bottom: bottom)
        } label: {
            overrideLabel(kind, expanded: expanded)
        }
        .disclosureGroupStyle(AgentListFieldsOverrideDisclosureStyle())
        .listRowInsets(AgentListFieldsChrome.overrideHeaderInsets)
        .listRowBackground(
            AgentListFieldsOverrideRowChrome(
                hostIsLast: isHostLastOverrideHeader(bottom: bottom, kind: kind),
                nestedIsFirst: true,
                nestedIsLast: nestedEnd == .header,
                fill: AgentListFieldsChrome.nestedFill,
                showChildDivider: nestedEnd != .header))
        .listRowSeparator(.hidden)
        .moveDisabled(true)
        .deleteDisabled(!canMutate)
        .accessibilityAction(named: "Remove Override") {
            guard canMutate else { return }
            removeOverride(kind: kind)
        }
    }

    @ViewBuilder
    private func overrideRowsContent(kind: String, isSyncing: Bool, bottom: HostBottom) -> some View {
        let slotRows = AgentRowSlot.slotRows(layout.rowsByAgent[kind] ?? [])
        let nestedEnd = nestedBottom(for: kind)
        ForEach(Array(slotRows.enumerated()), id: \.offset) { index, row in
            let isNestedLast = nestedEnd == .row(index)
            AgentListFieldsRowButton(
                index: index, row: row, compact: true, canOpen: !isSyncing,
                onOpen: {
                    openedRow = AgentListFieldsEditorDestination(
                        hostID: host.id, kind: kind, rowIndex: index)
                })
                .listRowInsets(AgentListFieldsChrome.overrideRowInsets)
                .listRowBackground(
                    AgentListFieldsOverrideRowChrome(
                        hostIsLast: isHostLastOverrideRow(bottom: bottom, kind: kind, index: index),
                        nestedIsFirst: false,
                        nestedIsLast: isNestedLast,
                        fill: AgentListFieldsChrome.cardFill,
                        showChildDivider: !isNestedLast))
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        }
    }

    private func overrideLabel(_ kind: String, expanded: Bool) -> some View {
        let count = (layout.rowsByAgent[kind] ?? []).filter { !$0.isEmpty }.count
        let rowsLabel = count == 1 ? "1 row" : "\(count) rows"
        return HStack(alignment: .center, spacing: 8) {
            Text(verbatim: kind)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.primary)
            Text(verbatim: rowsLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
    }

    @ViewBuilder
    private func addOverrideControls(_ host: Host, canMutate: Bool) -> some View {
        let existing = overrideKinds
        if showingOther {
            otherOverrideForm(canMutate: canMutate)
        } else {
            Menu {
                ForEach(
                    AgentListFieldsOverrideProposal.menuKinds(
                        seen: seenKinds(on: host.id), existing: existing),
                    id: \.self
                ) { kind in
                    Button(kind) { addOverride(kind) }
                }
                Button("Other…") { showingOther = true }
            } label: {
                Label("Add Override", systemImage: "plus")
            }
            .disabled(!canMutate)
        }
    }

    @ViewBuilder
    private func otherOverrideForm(canMutate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 7) {
                    otherKindField(canMutate: canMutate)
                    otherKindActions(canMutate: canMutate)
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    otherKindField(canMutate: canMutate)
                    otherKindActions(canMutate: canMutate)
                }
            }
            if let otherHint {
                Text(verbatim: otherHint)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func otherKindField(canMutate: Bool) -> some View {
        TextField(
            "Agent kind",
            text: Binding(
                get: { otherKind },
                set: {
                    otherKind = $0
                    otherHint = nil
                }))
            .font(.system(.subheadline, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(!canMutate)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AgentListFieldsChrome.previewFill))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
            }
    }

    private func otherKindActions(canMutate: Bool) -> some View {
        HStack(spacing: 12) {
            Button("Add") { submitOtherOverride() }
                .disabled(!canMutate)
            Button("Cancel") { hideOther() }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func syncRow(isSyncing: Bool) -> some View {
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
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(AgentListFieldsChrome.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(tipIdentifier)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { Task { await sync() } }
                            .disabled(isSyncing)
                    }
                    .accessibilityIdentifier(tipIdentifier)
                case nil:
                    Button {
                        Task { await sync() }
                    } label: {
                        Label("Sync from plugin", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSyncing)
                    .accessibilityIdentifier(identifier)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowInsets(AgentListFieldsChrome.syncInsets)
        .listRowSeparator(.hidden)
        .agentListHostSurface(isFirst: false, isLast: true)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    private func beginDrafts() {
        didSucceedSave = false
        editor.beginEditing()
    }

    private func discardDrafts() {
        editor.cancel()
        didSucceedSave = false
        hideOther()
    }

    private func saveDrafts() {
        let dirty = editor.hasUnsavedChanges
        editor.save()
        guard !editor.isEditing else { return }
        didSucceedSave = dirty
        hideOther()
    }

    private func sync() async {
        await editor.syncFromPlugin(host.id, hostName: host.displayName)
        if case .filled = editor.syncStates[host.id] {
            hideOther()
        }
    }

    private func addOverride(_ kind: String) {
        guard editor.isEditing, editor.syncStates[host.id] != .syncing else { return }
        let proposal = AgentListFieldsOverrideProposal.validate(kind, existing: overrideKinds)
        guard case .valid(let resolved) = proposal else { return }
        let seed = layout.rows
        editor.update(host.id) { $0.rowsByAgent[resolved] = seed }
        guard editor.errorMessage == nil else { return }
        expandedOverrides.insert(resolved)
        hideOther()
    }

    private func submitOtherOverride() {
        let proposal = AgentListFieldsOverrideProposal.validate(otherKind, existing: overrideKinds)
        if case .valid(let kind) = proposal {
            addOverride(kind)
        } else {
            otherHint = proposal.message
        }
    }

    private func removeOverrides(at offsets: IndexSet) {
        guard editor.isEditing, editor.syncStates[host.id] != .syncing else { return }
        let kinds = overrideKinds
        let removed = offsets.compactMap { kinds.indices.contains($0) ? kinds[$0] : nil }
        editor.update(host.id) { layout in
            for kind in removed { layout.rowsByAgent[kind] = nil }
        }
        guard editor.errorMessage == nil else { return }
        expandedOverrides.subtract(removed)
    }

    private func removeOverride(kind: String) {
        guard editor.isEditing, editor.syncStates[host.id] != .syncing else { return }
        editor.update(host.id) { $0.rowsByAgent[kind] = nil }
        guard editor.errorMessage == nil else { return }
        expandedOverrides.remove(kind)
    }

    private func seenKinds(on hostID: Host.ID) -> [String] {
        console.agents.filter { $0.hostID == hostID }.map(\.agent.kind)
    }

    private func hostName(for hostID: Host.ID) -> String {
        hosts.first { $0.id == hostID }?.displayName ?? ""
    }

    private func hideOther() {
        showingOther = false
        otherKind = ""
        otherHint = nil
    }

    private func overrideExpansion(_ kind: String) -> Binding<Bool> {
        Binding(
            get: { expandedOverrides.contains(kind) },
            set: { expanded in
                if expanded { expandedOverrides.insert(kind) } else { expandedOverrides.remove(kind) }
            })
    }
}

/// Emits the override header and its rows as sibling list rows so the native
/// minus stays on the header, while the header uses a down/up chevron instead
/// of the system disclosure accessory.
private struct AgentListFieldsOverrideDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isExpanded.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(.plain)
        if configuration.isExpanded {
            configuration.content
        }
    }
}

/// One fixed row slot: title and its field chips. Provenance is explained
/// once by the note under the rows, not tagged per row.
private struct AgentListFieldsRowButton: View {
    let index: Int
    let row: AgentRow
    var compact: Bool = false
    let canOpen: Bool
    let onOpen: () -> Void

    private var slot: AgentRowSlot? { AgentRowSlot.forRow(index) }

    var body: some View {
        Button {
            guard canOpen else { return }
            onOpen()
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Row \(index + 1)")
                        .font(compact ? .subheadline : .callout)
                        .foregroundStyle(.primary)
                    AgentListFieldsChipRow(row: row, slot: slot)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityLabel(AgentListFieldsRowLabel.accessibilityLabel(index: index, row: row))
    }
}

private struct AgentListFieldsChipRow: View {
    let row: AgentRow
    let slot: AgentRowSlot?

    var body: some View {
        if row.isEmpty {
            Text(AgentListFieldsRowLabel.emptyText(slot: slot))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            AgentListFieldsChipWrap(spacing: 5) {
                ForEach(Array(row.enumerated()), id: \.offset) { offset, token in
                    Text(verbatim: token.token.rawValue)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AgentListFieldsChrome.chipInk)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(
                                cornerRadius: AgentListFieldsChrome.chipRadius, style: .continuous)
                                .fill(AgentListFieldsChrome.chipFill))
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: AgentListFieldsChrome.chipRadius, style: .continuous)
                                .strokeBorder(AgentListFieldsChrome.chipStroke, lineWidth: 0.5)
                        }
                        .accessibilityLabel(
                            AgentListFieldsChipLabel.text(
                                index: offset, count: row.count, token: token))
                }
            }
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

private struct AgentListFieldsHostSurface: View {
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

private struct AgentListFieldsOverrideRowChrome: View {
    var hostIsLast: Bool
    var nestedIsFirst: Bool
    var nestedIsLast: Bool
    var fill: Color
    var showChildDivider: Bool

    var body: some View {
        ZStack {
            AgentListFieldsHostSurface(
                isFirst: false, isLast: hostIsLast, fill: AgentListFieldsChrome.cardFill)
            AgentListFieldsNestedWell(
                isFirst: nestedIsFirst,
                isLast: nestedIsLast,
                fill: fill,
                showChildDivider: showChildDivider)
                .padding(.horizontal, AgentListFieldsChrome.pageInset)
                .padding(.bottom, hostIsLast ? 4 : 0)
        }
    }
}

private struct AgentListFieldsNestedWell: View {
    var isFirst: Bool
    var isLast: Bool
    var fill: Color
    var showChildDivider: Bool

    var body: some View {
        let radius = AgentListFieldsChrome.nestedRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0,
            style: .continuous)
        let line = Color(uiColor: .separator)
        ZStack {
            shape.fill(fill)
            if isFirst && isLast {
                shape.strokeBorder(line, lineWidth: 0.5)
            } else {
                HStack(spacing: 0) {
                    Rectangle().fill(line).frame(width: 0.5)
                    Spacer(minLength: 0)
                    Rectangle().fill(line).frame(width: 0.5)
                }
                .clipShape(shape)
                if isFirst {
                    VStack(spacing: 0) {
                        Rectangle().fill(line).frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                    .clipShape(shape)
                }
                if isLast {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(line).frame(height: 0.5)
                    }
                    .clipShape(shape)
                }
                if showChildDivider {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color(uiColor: .separator).opacity(0.55))
                            .frame(height: 0.5)
                            .padding(.horizontal, 0.5)
                    }
                }
            }
        }
    }
}

private extension View {
    func agentListHostSurface(
        isFirst: Bool, isLast: Bool, fill: Color = AgentListFieldsChrome.cardFill
    ) -> some View {
        listRowBackground(AgentListFieldsHostSurface(isFirst: isFirst, isLast: isLast, fill: fill))
    }
}

private enum AgentListFieldsChrome {
    static let pageInset: CGFloat = 16
    static let hostSpacing: CGFloat = 18
    static let hostCornerRadius: CGFloat = 12
    static let chipRadius: CGFloat = 5
    static let nestedRadius: CGFloat = 10
    /// In-card wash: original `#FAFAFC` on white. Do not use
    /// `tertiarySystemGroupedBackground` in light — that token is the page.
    static let previewFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return .tertiarySystemGroupedBackground
        }
        return UIColor(red: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)
    })
    static let nestedFill = previewFill
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let chipFill = Color(uiColor: .tertiarySystemFill)
    static let chipStroke = Color(uiColor: .separator)
    static let chipInk = Color.primary.opacity(0.75)
    static let success = Color(uiColor: .systemGreen)
    static let headerInsets = EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
    static let previewInsets = EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)
    static let rowInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let slotsNoteInsets = EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16)
    static let overridesChromeInsets = EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16)
    static let overridesHeadingInsets = EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16)
    static let overridesActionInsets = EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)
    static let overrideHeaderInsets = EdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 28)
    static let overrideRowInsets = EdgeInsets(top: 9, leading: 28, bottom: 9, trailing: 28)
    static let syncInsets = EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16)
}

/// Identity for a Field Editor push. Row slots are fixed, so the slot index
/// is stable across every edit and sync; an override is named by its kind.
struct AgentListFieldsEditorDestination: Hashable, Identifiable {
    let hostID: Host.ID
    let kind: String?
    let rowIndex: Int

    var id: String { "\(hostID.uuidString):\(kind ?? "_"):\(rowIndex)" }
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

enum AgentListFieldsSessionStatus: Equatable {
    case unsaved, saved

    var title: String {
        switch self {
        case .unsaved: "Unsaved changes"
        case .saved: "Saved"
        }
    }

    static func current(isEditing: Bool, isDirty: Bool, didSucceedSave: Bool) -> Self? {
        if isEditing { return isDirty ? .unsaved : nil }
        return didSucceedSave ? .saved : nil
    }
}

enum AgentListFieldsOverrideProposal: Equatable {
    case valid(String)
    case empty
    case duplicate(String)

    var message: String? {
        switch self {
        case .valid: nil
        case .empty: "Enter an Agent kind."
        case .duplicate(let existing): "This Host already has a \(existing.uppercased()) override."
        }
    }

    /// Trim, reject empty, and reject case-insensitive duplicates. The stored
    /// kind keeps the typed spelling; `rowsByAgent` lookup stays case-sensitive.
    static func validate(_ raw: String, existing: [String]) -> Self {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let match = existing.first(where: {
            $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return .duplicate(match)
        }
        return .valid(trimmed)
    }

    /// Unique kinds from this Host's Console agents, omitting overrides.
    static func menuKinds(seen: [String], existing: [String]) -> [String] {
        let existingKeys = Set(existing.map { $0.lowercased() })
        var used = Set<String>()
        var result: [String] = []
        for kind in seen {
            let trimmed = kind.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !existingKeys.contains(key), used.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum AgentListFieldsCopy {
    static let readableWidth: CGFloat = 640
    static let noHosts = "Add a Host to configure its Agent rows."
    static let noOverrides = "No overrides. Every Agent uses the rows above."
    static let listIntro =
        "Each Host decides which fields appear on its Agent rows in Console. Open a Host to change them."
    static let detailIntro = "Tap Edit to change this Host's rows."
    static let editingIntro =
        "Changes stay in a draft until you tap the checkmark. Sync fills this Host's draft without saving it."
    static let rowSlots =
        "Row 1 and Row 2 follow herdr's sidebar fields; Sync from plugin refills them. "
        + "Row 3 is Heeler's row and can also use Heeler fields. "
        + "The status badge always ends Row 1."
}

enum AgentListFieldsHostHeader {
    static func accessibilityLabel(name: String, caption: String) -> String {
        "\(name), \(caption)"
    }
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
