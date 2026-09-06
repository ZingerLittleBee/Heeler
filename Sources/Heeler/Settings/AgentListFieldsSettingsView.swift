import SwiftUI

struct AgentListFieldsSettingsView: View {
    let console: ConsoleStore
    let hosts: [Host]
    @State private var editor: AgentListFieldsEditor
    @State private var expandedHosts: Set<Host.ID> = []
    @State private var confirmingDiscard = false

    init(console: ConsoleStore, hosts: [Host]) {
        self.console = console
        self.hosts = hosts
        _editor = State(initialValue: AgentListFieldsEditor(
            layouts: console.rowLayouts, snapshots: console.sidebarSnapshots,
            fetch: { [console] hostID in await console.refreshSidebarLayout(for: hostID) }))
    }

    var body: some View {
        Form {
            Section {
                if hosts.isEmpty {
                    Text("Add a Host to arrange its Agent list fields.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if !hosts.isEmpty {
                    Text(editor.isEditing
                        ? "Open a row to edit its fields, swipe to arrange rows or remove overrides, and tap the checkmark to save."
                        : "Each Host follows its herdr fields until you save your own rows. Tap Edit to change them.")
                }
            }
            ForEach(hosts) { host in
                Section {
                    DisclosureGroup(isExpanded: expansion(for: host.id)) {
                        AgentListHostFieldsView(editor: editor, hostID: host.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: host.displayName)
                            Text(verbatim: sourceDescription(editor.source(for: host.id)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: hostSummary(for: host.id))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.agentList.host.\(host.id.uuidString)")
                }
            }
            AgentLayoutErrorView(editor: editor)
        }
        .navigationTitle("Agent List Fields")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editor.isEditing)
        .toolbar {
            if editor.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if editor.hasUnsavedChanges { confirmingDiscard = true } else { editor.cancel() }
                    }
                    .accessibilityIdentifier("settings.agentList.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { editor.save() } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Save")
                    .accessibilityIdentifier("settings.agentList.save")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editor.beginEditing() }
                        .accessibilityIdentifier("settings.agentList.edit")
                }
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { editor.cancel() }
        }
        .refreshable { await console.refreshSidebarLayouts() }
    }

    private func expansion(for hostID: Host.ID) -> Binding<Bool> {
        Binding(
            get: { expandedHosts.contains(hostID) },
            set: { expanded in
                if expanded { expandedHosts.insert(hostID) } else { expandedHosts.remove(hostID) }
            })
    }

    private func hostSummary(for hostID: Host.ID) -> String {
        let layout = editor.layout(for: hostID)
        let rows = layout.rows.count
        let overrides = layout.rowsByAgent.count
        let rowsLabel = rows == 1 ? "1 row" : "\(rows) rows"
        let overridesLabel = overrides == 1 ? "1 override" : "\(overrides) overrides"
        return "\(rowsLabel), \(overridesLabel)"
    }

    private func sourceDescription(_ source: AgentListFieldsEditor.LayoutSource) -> String {
        switch source {
        case .draft: "Unsaved changes"
        case .saved: "Your fields"
        case .plugin: "herdr fields"
        case .pluginDefaults: "herdr default fields (configuration problem reported)"
        case .loading: "Reading herdr fields…"
        case .missing: "No herdr fields snapshot"
        case .unavailable: "herdr fields unavailable"
        }
    }
}

/// One Host's rows, kind overrides and Sync from plugin, inside
/// its disclosure group.
private struct AgentListHostFieldsView: View {
    let editor: AgentListFieldsEditor
    let hostID: Host.ID
    @State private var newKind = ""

    private var layout: AgentRowLayout { editor.layout(for: hostID) }
    private var trimmedKind: String { newKind.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSyncing: Bool { editor.syncStates[hostID] == .syncing }
    private var hasOverrides: Bool { !layout.rowsByAgent.isEmpty }

    var body: some View {
        AgentLayoutRowsContent(editor: editor, hostID: hostID, kind: nil)
        if hasOverrides || editor.isEditing {
            Text("Agent Overrides")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
            kindRows
            if editor.isEditing {
                addKindRows
            }
        }
        if editor.isEditing {
            syncSection
        }
        if let message = editor.syncStates[hostID]?.message {
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(syncFailed ? .red : .secondary)
                .accessibilityIdentifier("settings.agentList.syncTip.\(hostID.uuidString)")
        }
    }

    private var kindRows: some View {
        ForEach(layout.rowsByAgent.keys.sorted(), id: \.self) { kind in
            if editor.isEditing {
                overrideLink(for: kind)
                    .accessibilityAction(named: "Delete Override") {
                        editor.update(hostID) { $0.rowsByAgent[kind] = nil }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", role: .destructive) {
                            editor.update(hostID) { $0.rowsByAgent[kind] = nil }
                        }
                    }
            } else {
                overrideLink(for: kind)
            }
        }
    }

    @ViewBuilder
    private var addKindRows: some View {
        TextField("Agent kind, e.g. claude", text: $newKind)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button {
            let kind = trimmedKind
            editor.update(hostID) { $0.rowsByAgent[kind] = $0.rows }
            if editor.errorMessage == nil { newKind = "" }
        } label: {
            Label("Add Agent Override", systemImage: "plus")
        }
        .disabled(trimmedKind.isEmpty || layout.rowsByAgent[trimmedKind] != nil)
    }

    private var syncSection: some View {
        Button {
            Task { await editor.syncFromPlugin(hostID) }
        } label: {
            if isSyncing {
                HStack {
                    Text("Syncing from plugin…")
                    Spacer()
                    ProgressView()
                }
            } else {
                Label("Sync from plugin", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(isSyncing)
        .accessibilityIdentifier("settings.agentList.sync.\(hostID.uuidString)")
    }

    private var syncFailed: Bool {
        if case .failed = editor.syncStates[hostID] { return true }
        return false
    }

    private func rowsSummary(_ rows: [AgentRow]) -> String {
        guard !rows.isEmpty else { return "No rows" }
        let rowCount = rows.count == 1 ? "1 row" : "\(rows.count) rows"
        let fieldCount = rows.reduce(0) { $0 + $1.count }
        let fieldLabel = fieldCount == 1 ? "1 field" : "\(fieldCount) fields"
        return "\(rowCount), \(fieldLabel)"
    }

    private func overrideLink(for kind: String) -> some View {
        NavigationLink {
            AgentLayoutRowsView(editor: editor, hostID: hostID, kind: kind)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: kind)
                Text(verbatim: rowsSummary(layout.rowsByAgent[kind] ?? []))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AgentLayoutRowsView: View {
    let editor: AgentListFieldsEditor
    let hostID: Host.ID
    let kind: String

    var body: some View {
        List {
            Section {
                AgentLayoutRowsContent(editor: editor, hostID: hostID, kind: kind)
            } footer: {
                Text("Empty fields and rows are omitted when displayed.")
            }
            AgentLayoutErrorView(editor: editor)
        }
        .navigationTitle(kind)
    }
}

private struct AgentLayoutRowsContent: View {
    let editor: AgentListFieldsEditor
    let hostID: Host.ID
    let kind: String?

    private var rows: [AgentRow] {
        let layout = editor.layout(for: hostID)
        return kind.map { layout.rowsByAgent[$0] ?? [] } ?? layout.rows
    }

    var body: some View {
        ForEach(Array(rows.indices), id: \.self) { index in
            if editor.isEditing {
                rowLink(at: index)
                    .accessibilityAction(named: "Delete Row") {
                        deleteHandler?(IndexSet(integer: index))
                    }
                    .accessibilityAction(named: "Move Row Up") {
                        guard index > 0 else { return }
                        moveHandler?(IndexSet(integer: index), index - 1)
                    }
                    .accessibilityAction(named: "Move Row Down") {
                        guard index < rows.count - 1 else { return }
                        moveHandler?(IndexSet(integer: index), index + 2)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if index > 0 {
                            Button("Move Up") {
                                moveHandler?(IndexSet(integer: index), index - 1)
                            }
                        }
                        if index < rows.count - 1 {
                            Button("Move Down") {
                                moveHandler?(IndexSet(integer: index), index + 2)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete Row", role: .destructive) {
                            deleteHandler?(IndexSet(integer: index))
                        }
                    }
            } else {
                rowLink(at: index)
            }
        }
        if editor.isEditing {
            Button {
                editor.setRows(rows + [[]], kind: kind, for: hostID)
            } label: {
                Label("Add Row", systemImage: "plus")
            }
            .disabled(rows.count >= AgentRowLayout.maximumRows)
        }
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        guard editor.isEditing else { return nil }
        return { offsets in
            var next = rows
            next.remove(atOffsets: offsets)
            editor.setRows(next, kind: kind, for: hostID)
        }
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard editor.isEditing else { return nil }
        return { offsets, destination in
            var next = rows
            next.move(fromOffsets: offsets, toOffset: destination)
            editor.setRows(next, kind: kind, for: hostID)
        }
    }

    private func rowPreview(_ row: AgentRow) -> String {
        if row.isEmpty { return "No fields yet" }
        return row.map(\.token.rawValue).joined(separator: " · ")
    }

    private func rowMetadata(_ row: AgentRow) -> String {
        let count = row.count
        return count == 1 ? "1 field" : "\(count) fields"
    }

    private func rowLink(at index: Int) -> some View {
        NavigationLink {
            AgentLayoutTokensView(editor: editor, hostID: hostID, kind: kind, rowIndex: index)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Row \(index + 1)")
                Text(verbatim: rowPreview(rows[index]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(verbatim: rowMetadata(rows[index]))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
