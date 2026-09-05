import SwiftUI
import Observation

/// Each edit commits one complete layout, preserving styles and kind overrides
/// that were not edited. Failed writes leave the persisted choice untouched.
@MainActor
@Observable
final class AgentListFieldsEditor {
    let layouts: AgentRowLayoutStore
    let snapshots: HerdrSidebarSnapshotStore
    var hostID: Host.ID?
    var errorMessage: String?

    init(layouts: AgentRowLayoutStore, snapshots: HerdrSidebarSnapshotStore) {
        self.layouts = layouts
        self.snapshots = snapshots
    }

    var layout: AgentRowLayout {
        if let hostID {
            return layouts.resolvedLayout(for: hostID, pluginSnapshot: snapshots.snapshot(for: hostID))
        }
        return layouts.globalLayout ?? .heelerDefault
    }

    var resetTitle: String {
        hostID != nil && layouts.globalLayout != nil ? "Use Global Layout" : "Follow herdr"
    }

    func update(_ edit: (inout AgentRowLayout) -> Void) {
        var next = layout
        edit(&next)
        save(next)
    }

    func reset() { save(nil) }

    func setRows(_ rows: [AgentRow], kind: String?) {
        update {
            if let kind { $0.rowsByAgent[kind] = rows }
            else { $0.rows = rows }
        }
    }

    private func save(_ layout: AgentRowLayout?) {
        do {
            if let hostID { try layouts.setLayout(layout, for: hostID) }
            else { try layouts.setGlobalLayout(layout) }
            errorMessage = nil
        } catch {
            errorMessage = error is AgentRowLayoutStoreError
                ? "The saved Agent List Fields could not be read. Nothing was changed."
                : "This layout could not be saved. Use at most 16 rows and 16 fields per row, with valid field names."
        }
    }
}

struct AgentListFieldsSettingsView: View {
    let console: ConsoleStore
    let hosts: [Host]
    @State private var editor: AgentListFieldsEditor
    @State private var newKind = ""

    init(console: ConsoleStore, hosts: [Host]) {
        self.console = console
        self.hosts = hosts
        _editor = State(initialValue: AgentListFieldsEditor(
            layouts: console.rowLayouts, snapshots: console.sidebarSnapshots))
    }

    var body: some View {
        @Bindable var editor = editor
        Form {
            Section {
                Picker("Apply to", selection: $editor.hostID) {
                    Text("All Hosts").tag(Host.ID?.none)
                    ForEach(hosts) { host in
                        Text(verbatim: host.displayName).tag(Optional(host.id))
                    }
                }
                Button(editor.resetTitle) { editor.reset() }
            } footer: {
                Text("Host fields take precedence over All Hosts. Follow herdr removes the selected override; Hosts with no override use their herdr fields or Heeler defaults.")
            }
            Section {
                NavigationLink("Default Rows") {
                    AgentLayoutRowsView(editor: editor, kind: nil)
                }
                Stepper("Extra spacing: \(editor.layout.rowGap)", value: Binding(
                    get: { editor.layout.rowGap },
                    set: { value in editor.update { $0.rowGap = value } }), in: 0...65535)
            } footer: {
                Text("The first nonempty row labels the Agent and its switcher. Empty layouts use the Agent name. Extra spacing between cards is limited to three steps on iOS.")
            }
            Section {
                ForEach(editor.layout.rowsByAgent.keys.sorted(), id: \.self) { kind in
                    NavigationLink {
                        AgentLayoutRowsView(editor: editor, kind: kind)
                    } label: {
                        Text(verbatim: kind)
                    }
                }
                .onDelete { offsets in
                    let keys = editor.layout.rowsByAgent.keys.sorted()
                    editor.update { layout in
                        for index in offsets { layout.rowsByAgent[keys[index]] = nil }
                    }
                }
                TextField("Agent kind, e.g. claude", text: $newKind)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add Agent Override") {
                    let kind = newKind.trimmingCharacters(in: .whitespacesAndNewlines)
                    editor.update { $0.rowsByAgent[kind] = $0.rows }
                    if editor.errorMessage == nil { newKind = "" }
                }
                .disabled(newKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || editor.layout.rowsByAgent[newKind.trimmingCharacters(in: .whitespacesAndNewlines)] != nil)
            } header: {
                Text("Rows by Agent Kind")
            } footer: {
                Text("An Agent kind uses its entire replacement layout. Other Agents use Default Rows. Status and Heeler Pin remain separate; field colors and emphasis are retained but use Heeler's appearance.")
            }
            if let hostID = editor.hostID {
                Section {
                    Text(snapshotDescription(for: hostID))
                        .foregroundStyle(.secondary)
                    Button("Refresh herdr Fields") {
                        Task { await console.refreshSidebarLayouts() }
                    }
                }
            }
            AgentLayoutErrorView(editor: editor)
        }
        .navigationTitle("Agent List Fields")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .refreshable { await console.refreshSidebarLayouts() }
    }

    private func snapshotDescription(for id: Host.ID) -> String {
        switch console.sidebarSnapshots.states[id] {
        case .loading: "Reading herdr fields…"
        case .loaded(let snapshot?):
            snapshot.diagnostics.isEmpty ? "herdr fields are available."
                : "herdr reported a configuration problem and supplied its default fields."
        case .loaded(nil): "No herdr fields snapshot. Heeler defaults are available."
        case .unavailable, nil: "herdr fields are unavailable. Local fields or Heeler defaults apply."
        }
    }
}

private struct AgentLayoutRowsView: View {
    let editor: AgentListFieldsEditor
    let kind: String?

    private var rows: [AgentRow] { kind.map { editor.layout.rowsByAgent[$0] ?? [] } ?? editor.layout.rows }

    var body: some View {
        List {
            Section {
                ForEach(Array(rows.indices), id: \.self) { index in
                    NavigationLink {
                        AgentLayoutTokensView(editor: editor, kind: kind, rowIndex: index)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Row \(index + 1)")
                            Text(verbatim: rows[index].isEmpty ? "Empty row" : rows[index].map(\.token.rawValue).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    var next = rows
                    next.remove(atOffsets: offsets)
                    editor.setRows(next, kind: kind)
                }
                .onMove { offsets, destination in
                    var next = rows
                    next.move(fromOffsets: offsets, toOffset: destination)
                    editor.setRows(next, kind: kind)
                }
                Button("Add Row", systemImage: "plus") {
                    editor.setRows(rows + [[]], kind: kind)
                }
                .disabled(rows.count >= AgentRowLayout.maximumRows)
            } footer: {
                Text("Empty fields and rows are omitted when displayed. Edit to delete or reorder rows.")
            }
            AgentLayoutErrorView(editor: editor)
        }
        .navigationTitle(kind ?? "Default Rows")
        .toolbar { EditButton() }
    }
}

private struct AgentLayoutTokensView: View {
    let editor: AgentListFieldsEditor
    let kind: String?
    let rowIndex: Int
    @State private var customName = ""

    private var rows: [AgentRow] { kind.map { editor.layout.rowsByAgent[$0] ?? [] } ?? editor.layout.rows }
    private var tokens: AgentRow { rows.indices.contains(rowIndex) ? rows[rowIndex] : [] }

    var body: some View {
        List {
            Section {
                ForEach(Array(tokens.indices), id: \.self) { index in
                    Text(verbatim: tokens[index].token.rawValue)
                }
                .onDelete { offsets in mutate { $0.remove(atOffsets: offsets) } }
                .onMove { offsets, destination in
                    mutate { $0.move(fromOffsets: offsets, toOffset: destination) }
                }
            } header: {
                Text("Fields")
            } footer: {
                Text("Status fields are accepted but shown in the status column. Edit to delete or reorder fields.")
            }
            Section {
                Menu("Add Field", systemImage: "plus") {
                    ForEach(AgentRowToken.builtins, id: \.self) { token in
                        Button(token.rawValue) { mutate { $0.append(.init(token)) } }
                    }
                }
                TextField("$custom_name", text: $customName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add Custom Field") {
                    guard let token = customToken else { return }
                    mutate { $0.append(.init(token)) }
                    if editor.errorMessage == nil { customName = "" }
                }
                .disabled(customToken == nil)
            } footer: {
                Text("Custom names start with $ and contain 1–32 letters, digits, underscores or hyphens. Values come from herdr plugins and display as plain text.")
            }
            .disabled(tokens.count >= AgentRowLayout.maximumTokensPerRow || !rows.indices.contains(rowIndex))
            AgentLayoutErrorView(editor: editor)
        }
        .navigationTitle("Row \(rowIndex + 1)")
        .toolbar { EditButton() }
    }

    private var customToken: AgentRowToken? {
        guard customName.hasPrefix("$") else { return nil }
        return AgentRowToken(rawValue: customName)
    }

    private func mutate(_ change: (inout AgentRow) -> Void) {
        var next = rows
        guard next.indices.contains(rowIndex) else { return }
        change(&next[rowIndex])
        editor.setRows(next, kind: kind)
    }
}

private struct AgentLayoutErrorView: View {
    let editor: AgentListFieldsEditor

    var body: some View {
        if let message = editor.errorMessage {
            Section {
                Text(verbatim: message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.agentList.error")
            }
        }
    }
}
