import SwiftUI

struct AgentListFieldsSettingsView: View {
    let console: ConsoleStore
    let hosts: [Host]
    @State private var editor: AgentListFieldsEditor
    @State private var presentation = AgentListFieldsPresentation()
    @State private var expandedHosts: Set<Host.ID> = []
    @State private var expandedOverrides: Set<UUID> = []
    @State private var openedRow: AgentListFieldsEditorDestination?
    @State private var confirmingDiscard = false
    @State private var didSucceedSave = false
    @State private var showingOther: Set<Host.ID> = []
    @State private var otherKindByHost: [Host.ID: String] = [:]
    @State private var otherHintByHost: [Host.ID: String] = [:]

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
        .onAppear { reconcileAllHosts() }
        .onChange(of: openedRowIndex) { _, index in
            if openedRow != nil, index == nil { openedRow = nil }
        }
    }

    private var hostList: some View {
        List {
            sessionSection
            ForEach(hosts) { host in
                Group { hostBlock(host) }
            }
            AgentLayoutErrorView(editor: editor)
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(editor.isEditing ? .active : .inactive))
        .navigationDestination(item: $openedRow) { destination in
            AgentListFieldsRowDestination(
                editor: editor, presentation: presentation, destination: destination,
                hostName: hostName(for: destination.hostID))
        }
        .refreshable {
            await console.refreshSidebarLayouts()
            reconcileAllHosts()
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
        } else if !hosts.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { beginDrafts() }
                    .accessibilityIdentifier("settings.agentList.edit")
            }
        }
    }

    private var sessionSection: some View {
        Section {
            if let status = AgentListFieldsSessionStatus.current(
                isEditing: editor.isEditing, isDirty: editor.hasUnsavedChanges,
                didSucceedSave: didSucceedSave)
            {
                Text(status.title)
                    .font(.subheadline)
                    .foregroundStyle(status == .unsaved ? Color.orange : Color.green)
            }
            Text(editor.isEditing
                ? "Changes stay in a draft until you tap the checkmark. Sync fills one Host's draft without saving it."
                : "Each Host decides which fields appear on its Agent rows in Console. Tap Edit to change them.")
                .foregroundStyle(.secondary)
        }
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    @ViewBuilder
    private func hostBlock(_ host: Host) -> some View {
        let expanded = expandedHosts.contains(host.id)
        let isSyncing = editor.syncStates[host.id] == .syncing
        Section {
            hostHeader(host, expanded: expanded)
                .moveDisabled(true)
                .deleteDisabled(true)
        }
        .onAppear { presentation.ensure(host.id, layout: editor.layout(for: host.id)) }
        .onChange(of: editor.layout(for: host.id)) { _, layout in
            presentation.ensure(host.id, layout: layout)
        }

        if expanded {
            previewSection(host)
            rowsSection(host, kind: nil, rowIDs: presentation.hostRowIDs(host.id), isSyncing: isSyncing)
            overridesSection(host, isSyncing: isSyncing)
            if editor.isEditing {
                syncSection(host, isSyncing: isSyncing)
            }
        }
    }

    private func hostHeader(_ host: Host, expanded: Bool) -> some View {
        let caption = AgentListFieldsSourceCaption.text(editor.underlyingSource(for: host.id))
        let isDirty = editor.dirtyHostIDs.contains(host.id)
        Button {
            toggle(host.id, in: &expandedHosts)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unsaved changes")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: host.displayName)
                        .foregroundStyle(.primary)
                    Text(verbatim: caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AgentListFieldsHostHeader.accessibilityLabel(
                name: host.displayName, caption: caption, isExpanded: expanded))
        .accessibilityIdentifier("settings.agentList.host.\(host.id.uuidString)")
    }

    private func previewSection(_ host: Host) -> some View {
        let layout = editor.layout(for: host.id)
        return Section {
            AgentListFieldsPreview(layout: layout, hostName: host.displayName)
                .allowsHitTesting(false)
            if layout.rows.isEmpty {
                Text(AgentListFieldsCopy.emptyRows)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Console preview")
        }
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    private func rowsSection(
        _ host: Host, kind: String?, rowIDs: [UUID], isSyncing: Bool
    ) -> some View {
        let layoutRows = rows(hostID: host.id, kind: kind)
        let canMutate = editor.isEditing && !isSyncing
        return Section {
            ForEach(Array(zip(rowIDs, layoutRows)), id: \.0) { rowID, row in
                let index = rowIDs.firstIndex(of: rowID) ?? 0
                AgentListFieldsRowButton(
                    index: index, row: row,
                    canMutate: canMutate, rowCount: layoutRows.count,
                    onOpen: {
                        openedRow = AgentListFieldsEditorDestination(
                            rowID: rowID, hostID: host.id, kind: kind)
                    },
                    onDelete: { deleteRows(hostID: host.id, kind: kind, at: IndexSet(integer: index)) },
                    onMove: { destination in
                        moveRows(
                            hostID: host.id, kind: kind, from: IndexSet(integer: index),
                            to: destination)
                    })
                .moveDisabled(!canMutate)
                .deleteDisabled(!canMutate)
            }
            .onMove(perform: canMutate
                ? { offsets, destination in
                    moveRows(hostID: host.id, kind: kind, from: offsets, to: destination)
                } : nil)
            .onDelete(perform: canMutate
                ? { offsets in deleteRows(hostID: host.id, kind: kind, at: offsets) } : nil)
            if editor.isEditing {
                Button {
                    addRow(hostID: host.id, kind: kind)
                } label: {
                    Label("Add Row", systemImage: "plus")
                }
                .disabled(!canMutate || layoutRows.count >= AgentRowLayout.maximumRows)
                .moveDisabled(true)
                .deleteDisabled(true)
            }
        }
    }

    private func overridesSection(_ host: Host, isSyncing: Bool) -> some View {
        let overrides = presentation.overrides(for: host.id)
        let canMutate = editor.isEditing && !isSyncing
        return Section {
            if overrides.isEmpty {
                Text(AgentListFieldsCopy.noOverrides)
                    .foregroundStyle(.secondary)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }
            ForEach(overrides) { override in
                DisclosureGroup(isExpanded: overrideExpansion(override.id)) {
                    let overrideRows = rows(hostID: host.id, kind: override.kind)
                    ForEach(Array(zip(override.rowIDs, overrideRows)), id: \.0) { rowID, row in
                        overrideRow(
                            host: host, override: override, rowID: rowID, row: row,
                            canMutate: canMutate)
                    }
                    .onMove(perform: canMutate
                        ? { offsets, destination in
                            moveRows(
                                hostID: host.id, kind: override.kind, from: offsets, to: destination)
                        } : nil)
                    .onDelete(perform: canMutate
                        ? { offsets in
                            deleteRows(hostID: host.id, kind: override.kind, at: offsets)
                        } : nil)
                    if editor.isEditing {
                        Button {
                            addRow(hostID: host.id, kind: override.kind)
                        } label: {
                            Label("Add Row", systemImage: "plus")
                        }
                        .disabled(
                            !canMutate
                                || override.rowIDs.count >= AgentRowLayout.maximumRows)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                    }
                } label: {
                    overrideLabel(override)
                }
                .moveDisabled(true)
                .deleteDisabled(!canMutate)
                .accessibilityAction(named: "Remove Override") {
                    guard canMutate else { return }
                    removeOverride(kind: override.kind, on: host.id)
                }
            }
            .onDelete(perform: canMutate
                ? { offsets in removeOverrides(at: offsets, on: host.id) } : nil)
            if editor.isEditing {
                addOverrideControls(host, canMutate: canMutate)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }
        } header: {
            Text("Agent overrides")
        }
    }

    private func overrideRow(
        host: Host, override: AgentListFieldsOverrideRecord, rowID: UUID, row: AgentRow,
        canMutate: Bool
    ) -> some View {
        let index = override.rowIDs.firstIndex(of: rowID) ?? 0
        return AgentListFieldsRowButton(
            index: index, row: row,
            canMutate: canMutate, rowCount: override.rowIDs.count,
            onOpen: {
                openedRow = AgentListFieldsEditorDestination(
                    rowID: rowID, hostID: host.id, kind: override.kind)
            },
            onDelete: {
                deleteRows(hostID: host.id, kind: override.kind, at: IndexSet(integer: index))
            },
            onMove: { destination in
                moveRows(
                    hostID: host.id, kind: override.kind, from: IndexSet(integer: index),
                    to: destination)
            })
        .moveDisabled(!canMutate)
        .deleteDisabled(!canMutate)
    }

    private func overrideLabel(_ override: AgentListFieldsOverrideRecord) -> some View {
        let count = override.rowIDs.count
        let rowsLabel = count == 1 ? "1 row" : "\(count) rows"
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: override.kind)
            Text(verbatim: rowsLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func addOverrideControls(_ host: Host, canMutate: Bool) -> some View {
        let existing = Array(editor.layout(for: host.id).rowsByAgent.keys)
        if showingOther.contains(host.id) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "Agent kind",
                    text: Binding(
                        get: { otherKindByHost[host.id] ?? "" },
                        set: {
                            otherKindByHost[host.id] = $0
                            otherHintByHost[host.id] = nil
                        }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canMutate)
                if let hint = otherHintByHost[host.id] {
                    Text(verbatim: hint)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { hideOther(host.id) }
                    Spacer()
                    Button("Add") { submitOtherOverride(on: host) }
                        .disabled(!canMutate)
                }
            }
        } else {
            Menu {
                ForEach(
                    AgentListFieldsOverrideProposal.menuKinds(
                        seen: seenKinds(on: host.id), existing: existing),
                    id: \.self
                ) { kind in
                    Button(kind) { addOverride(kind, on: host.id) }
                }
                Button("Other…") { showingOther.insert(host.id) }
            } label: {
                Label("Add Override", systemImage: "plus")
            }
            .disabled(!canMutate)
        }
    }

    private func syncSection(_ host: Host, isSyncing: Bool) -> some View {
        Section {
            Button {
                Task { await sync(host.id) }
            } label: {
                if isSyncing {
                    HStack {
                        Text("Syncing…")
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Label("Sync from plugin", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(isSyncing)
            .accessibilityIdentifier("settings.agentList.sync.\(host.id.uuidString)")

            if let message = editor.syncStates[host.id]?.message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(syncFailed(host.id) ? Color.red : Color.secondary)
                    if syncFailed(host.id) {
                        Button("Retry") { Task { await sync(host.id) } }
                            .disabled(isSyncing)
                    }
                }
                .accessibilityIdentifier("settings.agentList.syncTip.\(host.id.uuidString)")
            }
        }
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    private var openedRowIndex: Int? {
        openedRow.flatMap { presentation.rowIndex(for: $0) }
    }

    private func beginDrafts() {
        didSucceedSave = false
        editor.beginEditing()
        reconcileAllHosts()
    }

    private func discardDrafts() {
        editor.cancel()
        didSucceedSave = false
        showingOther = []
        otherKindByHost = [:]
        otherHintByHost = [:]
        reconcileAllHosts()
    }

    private func saveDrafts() {
        let dirty = editor.hasUnsavedChanges
        editor.save()
        guard !editor.isEditing else { return }
        didSucceedSave = dirty
        showingOther = []
        otherKindByHost = [:]
        otherHintByHost = [:]
        reconcileAllHosts()
    }

    private func sync(_ hostID: Host.ID) async {
        await editor.syncFromPlugin(hostID)
        if case .filled = editor.syncStates[hostID] {
            presentation.replace(hostID, layout: editor.layout(for: hostID))
            hideOther(hostID)
        }
    }

    private func reconcileAllHosts() {
        for host in hosts {
            presentation.ensure(host.id, layout: editor.layout(for: host.id))
        }
    }

    private func rows(hostID: Host.ID, kind: String?) -> [AgentRow] {
        let layout = editor.layout(for: hostID)
        return kind.map { layout.rowsByAgent[$0] ?? [] } ?? layout.rows
    }

    private func addRow(hostID: Host.ID, kind: String?) {
        guard editor.isEditing, editor.syncStates[hostID] != .syncing else { return }
        let current = rows(hostID: hostID, kind: kind)
        guard current.count < AgentRowLayout.maximumRows else { return }
        editor.setRows(current + [[]], kind: kind, for: hostID)
        guard editor.errorMessage == nil else { return }
        if let kind {
            _ = presentation.appendOverrideRow(hostID: hostID, kind: kind)
        } else {
            _ = presentation.appendHostRow(hostID)
        }
    }

    private func deleteRows(hostID: Host.ID, kind: String?, at offsets: IndexSet) {
        guard editor.isEditing, editor.syncStates[hostID] != .syncing else { return }
        var next = rows(hostID: hostID, kind: kind)
        next.remove(atOffsets: offsets)
        editor.setRows(next, kind: kind, for: hostID)
        guard editor.errorMessage == nil else { return }
        if let kind {
            presentation.deleteOverrideRows(hostID: hostID, kind: kind, at: offsets)
        } else {
            presentation.deleteHostRows(hostID, at: offsets)
        }
    }

    private func moveRows(hostID: Host.ID, kind: String?, from offsets: IndexSet, to destination: Int) {
        guard editor.isEditing, editor.syncStates[hostID] != .syncing else { return }
        var next = rows(hostID: hostID, kind: kind)
        next.move(fromOffsets: offsets, toOffset: destination)
        editor.setRows(next, kind: kind, for: hostID)
        guard editor.errorMessage == nil else { return }
        if let kind {
            presentation.moveOverrideRows(hostID: hostID, kind: kind, from: offsets, to: destination)
        } else {
            presentation.moveHostRows(hostID, from: offsets, to: destination)
        }
    }

    private func addOverride(_ kind: String, on hostID: Host.ID) {
        guard editor.isEditing, editor.syncStates[hostID] != .syncing else { return }
        let existing = Array(editor.layout(for: hostID).rowsByAgent.keys)
        let proposal = AgentListFieldsOverrideProposal.validate(kind, existing: existing)
        guard case .valid(let resolved) = proposal else { return }
        let seed = editor.layout(for: hostID).rows
        editor.update(hostID) { $0.rowsByAgent[resolved] = seed }
        guard editor.errorMessage == nil else { return }
        let id = presentation.addOverride(hostID: hostID, kind: resolved, rowCount: seed.count)
        expandedOverrides.insert(id)
        hideOther(hostID)
    }

    private func submitOtherOverride(on host: Host) {
        let existing = Array(editor.layout(for: host.id).rowsByAgent.keys)
        let proposal = AgentListFieldsOverrideProposal.validate(
            otherKindByHost[host.id] ?? "", existing: existing)
        if case .valid(let kind) = proposal {
            addOverride(kind, on: host.id)
        } else {
            otherHintByHost[host.id] = proposal.message
        }
    }

    private func removeOverrides(at offsets: IndexSet, on hostID: Host.ID) {
        guard editor.isEditing, editor.syncStates[hostID] != .syncing else { return }
        let kinds = presentation.overrideKinds(hostID, at: offsets)
        editor.update(hostID) { layout in
            for kind in kinds { layout.rowsByAgent[kind] = nil }
        }
        guard editor.errorMessage == nil else { return }
        presentation.removeOverrides(hostID: hostID, at: offsets)
    }

    private func removeOverride(kind: String, on hostID: Host.ID) {
        guard editor.isEditing, editor.syncStates[hostID] != .syncing else { return }
        editor.update(hostID) { $0.rowsByAgent[kind] = nil }
        guard editor.errorMessage == nil else { return }
        presentation.removeOverride(hostID: hostID, kind: kind)
    }

    private func seenKinds(on hostID: Host.ID) -> [String] {
        console.agents.filter { $0.hostID == hostID }.map(\.agent.kind)
    }

    private func hostName(for hostID: Host.ID) -> String {
        hosts.first { $0.id == hostID }?.displayName ?? ""
    }

    private func syncFailed(_ hostID: Host.ID) -> Bool {
        if case .failed = editor.syncStates[hostID] { return true }
        return false
    }

    private func hideOther(_ hostID: Host.ID) {
        showingOther.remove(hostID)
        otherKindByHost[hostID] = nil
        otherHintByHost[hostID] = nil
    }

    private func overrideExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedOverrides.contains(id) },
            set: { expanded in
                if expanded { expandedOverrides.insert(id) } else { expandedOverrides.remove(id) }
            })
    }

    private func toggle(_ hostID: Host.ID, in set: inout Set<Host.ID>) {
        if set.contains(hostID) { set.remove(hostID) } else { set.insert(hostID) }
    }
}

private struct AgentListFieldsRowDestination: View {
    let editor: AgentListFieldsEditor
    let presentation: AgentListFieldsPresentation
    let destination: AgentListFieldsEditorDestination
    let hostName: String

    var body: some View {
        if let index = presentation.rowIndex(for: destination) {
            AgentLayoutTokensView(
                editor: editor, hostID: destination.hostID, kind: destination.kind,
                rowIndex: index, hostName: hostName)
        } else {
            ContentUnavailableView(
                "Row unavailable",
                systemImage: "rectangle.slash",
                description: Text("This row is no longer in the layout."))
        }
    }
}

private struct AgentListFieldsRowButton: View {
    let index: Int
    let row: AgentRow
    let canMutate: Bool
    let rowCount: Int
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Row \(index + 1)")
                        .foregroundStyle(.primary)
                    AgentListFieldsChipRow(row: row)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AgentListFieldsRowLabel.accessibilityLabel(index: index, row: row))
        .accessibilityAction(named: "Delete Row") {
            guard canMutate else { return }
            onDelete()
        }
        .accessibilityAction(named: "Move Row Up") {
            guard canMutate, let destination = AgentListFieldsRowOrder.moveUpDestination(index: index)
            else { return }
            onMove(destination)
        }
        .accessibilityAction(named: "Move Row Down") {
            guard canMutate,
                let destination = AgentListFieldsRowOrder.moveDownDestination(
                    index: index, count: rowCount)
            else { return }
            onMove(destination)
        }
    }
}

private struct AgentListFieldsChipRow: View {
    let row: AgentRow

    var body: some View {
        if row.isEmpty {
            Text("No fields yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(row.enumerated()), id: \.offset) { offset, token in
                    Text(verbatim: token.token.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(token.dim == true ? Color.secondary : Color.primary)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .accessibilityLabel(
                            AgentListFieldsChipLabel.text(
                                index: offset, count: row.count, token: token))
                }
            }
        }
    }
}

/// Presentation identity for a Field Editor push. `id` is a view-state row
/// token, not a layout schema field, so move/delete/sync cannot retarget it.
struct AgentListFieldsEditorDestination: Hashable, Identifiable {
    let rowID: UUID
    let hostID: Host.ID
    let kind: String?

    var id: String { "\(hostID.uuidString):\(kind ?? "_"):\(rowID.uuidString)" }
}

struct AgentListFieldsOverrideRecord: Identifiable, Equatable {
    let id: UUID
    let kind: String
    var rowIDs: [UUID]
}

/// Per-Host row and override identity that lives only in view state.
@MainActor
@Observable
final class AgentListFieldsPresentation {
    private var hostRows: [Host.ID: [UUID]] = [:]
    private var overridesByHost: [Host.ID: [AgentListFieldsOverrideRecord]] = [:]

    func hostRowIDs(_ hostID: Host.ID) -> [UUID] {
        hostRows[hostID] ?? []
    }

    func overrides(for hostID: Host.ID) -> [AgentListFieldsOverrideRecord] {
        overridesByHost[hostID] ?? []
    }

    func rowIndex(for destination: AgentListFieldsEditorDestination) -> Int? {
        if let kind = destination.kind {
            guard let override = overridesByHost[destination.hostID]?.first(where: { $0.kind == kind })
            else { return nil }
            return override.rowIDs.firstIndex(of: destination.rowID)
        }
        return hostRows[destination.hostID]?.firstIndex(of: destination.rowID)
    }

    func replace(_ hostID: Host.ID, layout: AgentRowLayout) {
        hostRows[hostID] = layout.rows.map { _ in UUID() }
        overridesByHost[hostID] = layout.rowsByAgent.keys.sorted().map { kind in
            AgentListFieldsOverrideRecord(
                id: UUID(), kind: kind,
                rowIDs: (layout.rowsByAgent[kind] ?? []).map { _ in UUID() })
        }
    }

    /// Keep tokens when structure still matches; rebuild when counts or kinds change.
    /// Wholesale content replacement with the same shape must call `replace` instead.
    func ensure(_ hostID: Host.ID, layout: AgentRowLayout) {
        guard hostRows[hostID] != nil else {
            replace(hostID, layout: layout)
            return
        }
        let recorded = overridesByHost[hostID] ?? []
        let kindsMatch = Set(recorded.map(\.kind)) == Set(layout.rowsByAgent.keys)
        let hostCountMatches = hostRows[hostID]?.count == layout.rows.count
        let overrideCountsMatch = recorded.allSatisfy {
            $0.rowIDs.count == (layout.rowsByAgent[$0.kind]?.count ?? -1)
        }
        if !kindsMatch || !hostCountMatches || !overrideCountsMatch {
            replace(hostID, layout: layout)
        }
    }

    @discardableResult
    func appendHostRow(_ hostID: Host.ID) -> UUID {
        var rows = hostRows[hostID] ?? []
        let id = UUID()
        rows.append(id)
        hostRows[hostID] = rows
        return id
    }

    func deleteHostRows(_ hostID: Host.ID, at offsets: IndexSet) {
        var rows = hostRows[hostID] ?? []
        rows.remove(atOffsets: offsets)
        hostRows[hostID] = rows
    }

    func moveHostRows(_ hostID: Host.ID, from offsets: IndexSet, to destination: Int) {
        var rows = hostRows[hostID] ?? []
        rows.move(fromOffsets: offsets, toOffset: destination)
        hostRows[hostID] = rows
    }

    @discardableResult
    func addOverride(hostID: Host.ID, kind: String, rowCount: Int) -> UUID {
        var overrides = overridesByHost[hostID] ?? []
        let record = AgentListFieldsOverrideRecord(
            id: UUID(), kind: kind, rowIDs: (0..<rowCount).map { _ in UUID() })
        overrides.append(record)
        overridesByHost[hostID] = overrides
        return record.id
    }

    func overrideKinds(_ hostID: Host.ID, at offsets: IndexSet) -> [String] {
        let overrides = overridesByHost[hostID] ?? []
        return offsets.compactMap { overrides.indices.contains($0) ? overrides[$0].kind : nil }
    }

    func removeOverrides(hostID: Host.ID, at offsets: IndexSet) {
        var overrides = overridesByHost[hostID] ?? []
        overrides.remove(atOffsets: offsets)
        overridesByHost[hostID] = overrides
    }

    func removeOverride(hostID: Host.ID, kind: String) {
        var overrides = overridesByHost[hostID] ?? []
        overrides.removeAll { $0.kind == kind }
        overridesByHost[hostID] = overrides
    }

    @discardableResult
    func appendOverrideRow(hostID: Host.ID, kind: String) -> UUID? {
        guard var overrides = overridesByHost[hostID],
            let index = overrides.firstIndex(where: { $0.kind == kind })
        else { return nil }
        let id = UUID()
        overrides[index].rowIDs.append(id)
        overridesByHost[hostID] = overrides
        return id
    }

    func deleteOverrideRows(hostID: Host.ID, kind: String, at offsets: IndexSet) {
        guard var overrides = overridesByHost[hostID],
            let index = overrides.firstIndex(where: { $0.kind == kind })
        else { return }
        overrides[index].rowIDs.remove(atOffsets: offsets)
        overridesByHost[hostID] = overrides
    }

    func moveOverrideRows(
        hostID: Host.ID, kind: String, from offsets: IndexSet, to destination: Int
    ) {
        guard var overrides = overridesByHost[hostID],
            let index = overrides.firstIndex(where: { $0.kind == kind })
        else { return }
        overrides[index].rowIDs.move(fromOffsets: offsets, toOffset: destination)
        overridesByHost[hostID] = overrides
    }
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
    static let emptyRows = "No rows. Console shows the Agent name."
    static let noOverrides = "No overrides. Every Agent uses the rows above."
}

enum AgentListFieldsHostHeader {
    static func accessibilityLabel(name: String, caption: String, isExpanded: Bool) -> String {
        "\(name), \(caption), \(isExpanded ? "expanded" : "collapsed")"
    }
}

enum AgentListFieldsChipLabel {
    static func text(index: Int, count: Int, token: AgentRowStyledToken) -> String {
        let style = token.dim == true ? "secondary style" : "default style"
        return "Field \(index + 1) of \(count): \(token.token.rawValue), \(style)"
    }
}

enum AgentListFieldsRowLabel {
    static func accessibilityLabel(index: Int, row: AgentRow) -> String {
        let title = "Row \(index + 1)"
        if row.isEmpty { return "\(title), No fields yet" }
        let fields = row.enumerated().map { offset, token in
            AgentListFieldsChipLabel.text(index: offset, count: row.count, token: token)
        }
        return ([title] + fields).joined(separator: ", ")
    }
}

enum AgentListFieldsRowOrder {
    static func moveUpDestination(index: Int) -> Int? {
        guard index > 0 else { return nil }
        return index - 1
    }

    static func moveDownDestination(index: Int, count: Int) -> Int? {
        guard index < count - 1 else { return nil }
        return index + 2
    }
}
