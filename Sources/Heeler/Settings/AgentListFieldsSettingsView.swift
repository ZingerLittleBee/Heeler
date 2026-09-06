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
                hostBlock(host)
            }
            AgentLayoutErrorView(editor: editor)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(AgentListFieldsChrome.hostSpacing)
        .modifier(AgentListFieldsHostListInsets())
        .environment(\.editMode, fieldsEditMode)
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
            VStack(alignment: .leading, spacing: 8) {
                if let status = AgentListFieldsSessionStatus.current(
                    isEditing: editor.isEditing, isDirty: editor.hasUnsavedChanges,
                    didSucceedSave: didSucceedSave)
                {
                    Text(status.title)
                        .font(.footnote)
                        .foregroundStyle(status == .unsaved ? Color.orange : Color.green)
                }
                Text(editor.isEditing
                    ? "Changes stay in a draft until you tap the checkmark. Sync fills one Host's draft without saving it."
                    : "Each Host decides which fields appear on its Agent rows in Console. Tap Edit to change them.")
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

    private func hostBlock(_ host: Host) -> some View {
        let expanded = expandedHosts.contains(host.id)
        let isSyncing = editor.syncStates[host.id] == .syncing
        return Section {
            hostHeader(host, expanded: expanded)
                .listRowInsets(AgentListFieldsChrome.headerInsets)
                .moveDisabled(true)
                .deleteDisabled(true)

            if expanded {
                previewRow(host)
                if editor.layout(for: host.id).rows.isEmpty {
                    Text(AgentListFieldsCopy.emptyRows)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowInsets(AgentListFieldsChrome.rowInsets)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                }
                hostRows(host, isSyncing: isSyncing)
                overridesBlock(host, isSyncing: isSyncing)
                if editor.isEditing {
                    syncRow(host, isSyncing: isSyncing)
                }
            }
        }
        .onAppear { presentation.ensure(host.id, layout: editor.layout(for: host.id)) }
        .onChange(of: editor.layout(for: host.id)) { _, layout in
            presentation.ensure(host.id, layout: layout)
        }
    }

    private var fieldsEditMode: Binding<EditMode> {
        Binding<EditMode>.constant(editor.isEditing ? EditMode.active : EditMode.inactive)
    }

    private func hostHeader(_ host: Host, expanded: Bool) -> some View {
        let caption = AgentListFieldsSourceCaption.text(editor.underlyingSource(for: host.id))
        let isDirty = editor.dirtyHostIDs.contains(host.id)
        return Button {
            toggle(host.id, in: &expandedHosts)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 7) {
                        Text(verbatim: host.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if isDirty {
                            Circle()
                                .fill(.orange)
                                .frame(
                                    width: AgentListFieldsChrome.dirtyDot,
                                    height: AgentListFieldsChrome.dirtyDot)
                                .accessibilityLabel("Unsaved changes")
                        }
                    }
                    Text(verbatim: caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AgentListFieldsHostHeader.accessibilityLabel(
                name: host.displayName, caption: caption, isExpanded: expanded))
        .accessibilityIdentifier("settings.agentList.host.\(host.id.uuidString)")
    }

    private func previewRow(_ host: Host) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Console Preview")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            AgentListFieldsPreview(layout: editor.layout(for: host.id), hostName: host.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(AgentListFieldsChrome.previewInsets)
        .listRowBackground(AgentListFieldsChrome.previewFill)
        .moveDisabled(true)
        .deleteDisabled(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hostRows(_ host: Host, isSyncing: Bool) -> some View {
        let rowIDs = presentation.hostRowIDs(host.id)
        let layoutRows = rows(hostID: host.id, kind: nil)
        let canMutate = editor.isEditing && !isSyncing
        let canOpen = AgentListFieldsRowNavigation.canOpenFieldEditor(isSyncing: isSyncing)
        ForEach(Array(zip(rowIDs, layoutRows)), id: \.0) { rowID, row in
            let index = rowIDs.firstIndex(of: rowID) ?? 0
            AgentListFieldsRowButton(
                index: index, row: row, showsChevron: !canMutate,
                canOpen: canOpen, canMutate: canMutate, rowCount: layoutRows.count,
                onOpen: {
                    openedRow = AgentListFieldsEditorDestination(
                        rowID: rowID, hostID: host.id, kind: nil)
                },
                onDelete: { deleteRows(hostID: host.id, kind: nil, at: IndexSet(integer: index)) },
                onMove: { destination in
                    moveRows(
                        hostID: host.id, kind: nil, from: IndexSet(integer: index),
                        to: destination)
                })
                .listRowInsets(AgentListFieldsChrome.rowInsets)
                .moveDisabled(!canMutate)
                .deleteDisabled(!canMutate)
        }
        .onMove(perform: canMutate
            ? { offsets, destination in
                moveRows(hostID: host.id, kind: nil, from: offsets, to: destination)
            } : nil)
        .onDelete(perform: canMutate
            ? { offsets in deleteRows(hostID: host.id, kind: nil, at: offsets) } : nil)
        if editor.isEditing {
            addRowControl(hostID: host.id, kind: nil, count: layoutRows.count, canMutate: canMutate)
                .listRowInsets(AgentListFieldsChrome.rowInsets)
        }
    }

    @ViewBuilder
    private func overridesBlock(_ host: Host, isSyncing: Bool) -> some View {
        let overrides = presentation.overrides(for: host.id)
        let canMutate = editor.isEditing && !isSyncing
        Text("Agent overrides")
            .font(.caption2.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(AgentListFieldsChrome.overridesHeadingInsets)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
        if overrides.isEmpty {
            Text(AgentListFieldsCopy.noOverrides)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowInsets(AgentListFieldsChrome.overridesBodyInsets)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        }
        ForEach(overrides) { override in
            overrideGroup(host: host, override: override, isSyncing: isSyncing, canMutate: canMutate)
        }
        .onDelete(perform: canMutate
            ? { offsets in removeOverrides(at: offsets, on: host.id) } : nil)
        if editor.isEditing {
            addOverrideControls(host, canMutate: canMutate)
                .listRowInsets(AgentListFieldsChrome.overridesBodyInsets)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        }
    }

    private func overrideGroup(
        host: Host, override: AgentListFieldsOverrideRecord, isSyncing: Bool, canMutate: Bool
    ) -> some View {
        let expanded = expandedOverrides.contains(override.id)
        let overrideRows = rows(hostID: host.id, kind: override.kind)
        let childCount = overrideRows.count + (editor.isEditing ? 1 : 0)
        return DisclosureGroup(isExpanded: overrideExpansion(override.id)) {
            overrideRowsContent(
                host: host, override: override, overrideRows: overrideRows,
                isSyncing: isSyncing, canMutate: canMutate)
        } label: {
            overrideLabel(override, expanded: expanded)
        }
        .disclosureGroupStyle(AgentListFieldsOverrideDisclosureStyle())
        .listRowInsets(AgentListFieldsChrome.overrideHeaderInsets)
        .listRowBackground(
            AgentListFieldsNestedBlockBackground(
                isFirst: true, isLast: !expanded || childCount == 0,
                fill: AgentListFieldsChrome.nestedFill))
        .listRowSeparator(.hidden)
        .moveDisabled(true)
        .deleteDisabled(!canMutate)
        .accessibilityAction(named: "Remove Override") {
            guard canMutate else { return }
            removeOverride(kind: override.kind, on: host.id)
        }
    }

    @ViewBuilder
    private func overrideRowsContent(
        host: Host, override: AgentListFieldsOverrideRecord, overrideRows: [AgentRow],
        isSyncing: Bool, canMutate: Bool
    ) -> some View {
        let canOpen = AgentListFieldsRowNavigation.canOpenFieldEditor(isSyncing: isSyncing)
        ForEach(Array(zip(override.rowIDs, overrideRows)), id: \.0) { rowID, row in
            let index = override.rowIDs.firstIndex(of: rowID) ?? 0
            AgentListFieldsRowButton(
                index: index, row: row, showsChevron: !canMutate, compact: true,
                canOpen: canOpen, canMutate: canMutate, rowCount: override.rowIDs.count,
                onOpen: {
                    openedRow = AgentListFieldsEditorDestination(
                        rowID: rowID, hostID: host.id, kind: override.kind)
                },
                onDelete: {
                    deleteRows(
                        hostID: host.id, kind: override.kind, at: IndexSet(integer: index))
                },
                onMove: { destination in
                    moveRows(
                        hostID: host.id, kind: override.kind, from: IndexSet(integer: index),
                        to: destination)
                })
                .listRowInsets(AgentListFieldsChrome.overrideRowInsets)
                .listRowBackground(
                    AgentListFieldsNestedBlockBackground(
                        isFirst: false,
                        isLast: !editor.isEditing && index == overrideRows.count - 1,
                        fill: AgentListFieldsChrome.cardFill))
                .listRowSeparator(.hidden)
                .moveDisabled(!canMutate)
                .deleteDisabled(!canMutate)
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
            addRowControl(
                hostID: host.id, kind: override.kind, count: override.rowIDs.count,
                canMutate: canMutate)
                .listRowInsets(AgentListFieldsChrome.overrideRowInsets)
                .listRowBackground(
                    AgentListFieldsNestedBlockBackground(
                        isFirst: false, isLast: true, fill: AgentListFieldsChrome.cardFill))
                .listRowSeparator(.hidden)
        }
    }

    private func overrideLabel(_ override: AgentListFieldsOverrideRecord, expanded: Bool) -> some View {
        let count = override.rowIDs.count
        let rowsLabel = count == 1 ? "1 row" : "\(count) rows"
        return HStack(alignment: .center, spacing: 8) {
            Text(verbatim: override.kind)
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

    private func addRowControl(
        hostID: Host.ID, kind: String?, count: Int, canMutate: Bool
    ) -> some View {
        Button {
            addRow(hostID: hostID, kind: kind)
        } label: {
            Label("Add Row", systemImage: "plus")
        }
        .disabled(!canMutate || count >= AgentRowLayout.maximumRows)
        .moveDisabled(true)
        .deleteDisabled(true)
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
                .buttonStyle(.borderless)
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

    @ViewBuilder
    private func syncRow(_ host: Host, isSyncing: Bool) -> some View {
        let identifier = "settings.agentList.sync.\(host.id.uuidString)"
        let tipIdentifier = "settings.agentList.syncTip.\(host.id.uuidString)"
        VStack(alignment: .leading, spacing: 8) {
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
                    .accessibilityIdentifier(tipIdentifier)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await sync(host.id) } }
                        .disabled(isSyncing)
                }
                .accessibilityIdentifier(tipIdentifier)
            case nil:
                Button {
                    Task { await sync(host.id) }
                } label: {
                    Label("Sync from plugin", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
                .accessibilityIdentifier(identifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .overlay(alignment: .top) {
            Divider()
        }
        .listRowInsets(AgentListFieldsChrome.syncInsets)
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
        await editor.syncFromPlugin(hostID, hostName: hostName(for: hostID))
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

    private func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

/// Emits the override header and its rows as sibling list rows so native
/// minus/drag stay on the inner `ForEach`, while the header uses a down/up
/// chevron instead of the system disclosure accessory.
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
    var showsChevron: Bool = true
    var compact: Bool = false
    let canOpen: Bool
    let canMutate: Bool
    let rowCount: Int
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void

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
                    AgentListFieldsChipRow(row: row)
                }
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
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

private struct AgentListFieldsNestedBlockBackground: View {
    var isFirst: Bool
    var isLast: Bool
    var fill: Color

    var body: some View {
        let radius = AgentListFieldsChrome.nestedRadius
        ZStack {
            AgentListFieldsChrome.cardFill
            UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? radius : 0,
                bottomLeadingRadius: isLast ? radius : 0,
                bottomTrailingRadius: isLast ? radius : 0,
                topTrailingRadius: isFirst ? radius : 0,
                style: .continuous)
                .fill(fill)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 0.5)
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 0.5)
                }
                .overlay(alignment: .top) {
                    if isFirst {
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 0.5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isLast {
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 0.5)
                    }
                }
                .padding(.horizontal, AgentListFieldsChrome.pageInset)
                .padding(.top, isFirst ? 4 : 0)
                .padding(.bottom, isLast ? 4 : 0)
        }
    }
}

/// iOS 26 can set grouped section margins directly. iOS 18 uses the
/// scroll-content margin so the 16pt page inset is not dropped.
private struct AgentListFieldsHostListInsets: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.listSectionMargins(.horizontal, AgentListFieldsChrome.pageInset)
        } else {
            content.contentMargins(.horizontal, AgentListFieldsChrome.pageInset, for: .scrollContent)
        }
    }
}

private enum AgentListFieldsChrome {
    static let pageInset: CGFloat = 16
    static let hostSpacing: CGFloat = 18
    static let chipRadius: CGFloat = 5
    static let nestedRadius: CGFloat = 10
    static let dirtyDot: CGFloat = 7
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
    static let overridesHeadingInsets = EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16)
    static let overridesBodyInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    static let overrideHeaderInsets = EdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 28)
    static let overrideRowInsets = EdgeInsets(top: 9, leading: 28, bottom: 9, trailing: 28)
    static let syncInsets = EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)
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

enum AgentListFieldsRowNavigation {
    /// Pending Sync blocks pushing the Field Editor. Read-only and edit
    /// navigation stay available once that Host is not syncing.
    static func canOpenFieldEditor(isSyncing: Bool) -> Bool { !isSyncing }
}
