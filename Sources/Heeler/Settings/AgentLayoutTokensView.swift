import SwiftUI

struct AgentLayoutTokensView: View {
    let editor: AgentListFieldsEditor
    let hostID: Host.ID
    let kind: String?
    let rowIndex: Int
    var hostName: String = ""
    @State private var customName = ""
    @State private var showingAddField = false

    private var rows: [AgentRow] {
        AgentLayoutTokensEditing.rows(in: editor.layout(for: hostID), kind: kind)
    }
    private var tokens: AgentRow {
        AgentLayoutTokensEditing.isValidRow(rowIndex, in: rows) ? rows[rowIndex] : []
    }
    private var canMutate: Bool { editor.isEditing && AgentLayoutTokensEditing.isValidRow(rowIndex, in: rows) }
    private var canAddField: Bool {
        editor.isEditing && AgentLayoutTokensEditing.canAddField(to: tokens, rows: rows, rowIndex: rowIndex)
    }
    private var subtitle: String {
        AgentLayoutTokensEditing.navigationSubtitle(hostName: hostName, kind: kind)
    }

    var body: some View {
        fieldsList
            .environment(\.editMode, listEditMode)
            .navigationTitle("Row \(rowIndex + 1)")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showingAddField) { addFieldSheet }
            .onChange(of: canAddField) { _, canAdd in
                if !canAdd { showingAddField = false }
            }
    }

    /// Matches `EnvironmentValues.editMode` (`Binding<EditMode>?`). A non-optional
    /// `Binding<EditMode>` makes `environment` overload resolution fail to diagnose.
    private var listEditMode: Binding<EditMode>? {
        Binding<EditMode>.constant(editor.isEditing ? EditMode.active : EditMode.inactive)
    }

    private var fieldsList: some View {
        List {
            fieldsSection
            AgentLayoutErrorView(editor: editor)
        }
    }

    private var fieldsSection: some View {
        Section {
            ForEach(Array(tokens.indices), id: \.self) { index in
                tokenRow(tokens[index], at: index)
            }
            .onDelete(perform: deleteHandler)
            .onMove(perform: moveHandler)
            if tokens.isEmpty && AgentLayoutTokensEditing.isValidRow(rowIndex, in: rows) {
                emptyFieldsCaption
            }
            if editor.isEditing {
                addFieldButton
            }
        } header: {
            fieldsHeader
        } footer: {
            Text(fieldsFooter)
        }
    }

    /// Typed optionals, not `canMutate ? deleteTokens : nil`. A method-reference
    /// ternary is not `((IndexSet) -> Void)?` without exploding `onDelete`/`onMove`.
    private var deleteHandler: ((IndexSet) -> Void)? {
        guard canMutate else { return nil }
        return { offsets in deleteTokens(offsets) }
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard canMutate else { return nil }
        return { offsets, destination in moveTokens(offsets, destination) }
    }

    private var emptyFieldsCaption: some View {
        Text("No fields. This row renders nothing.")
            .foregroundStyle(.secondary)
            .moveDisabled(true)
            .deleteDisabled(true)
    }

    private var addFieldButton: some View {
        Button {
            customName = ""
            showingAddField = true
        } label: {
            Label("Add Field", systemImage: "plus")
        }
        .disabled(!canAddField)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    private var fieldsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Fields in this row")
        }
        .textCase(nil)
    }

    private var fieldsFooter: String {
        editor.isEditing
            ? "Fields render left to right in this row. Changes stay in the draft until you save on the previous screen."
            : "Tap Edit on the previous screen to change fields."
    }

    private var addFieldSheet: some View {
        NavigationStack {
            List {
                if availableHerdrFields.isEmpty && availableHeelerFields.isEmpty {
                    Section {
                        Text("Every built-in field is already in this row.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !availableHerdrFields.isEmpty {
                        Section {
                            ForEach(availableHerdrFields, id: \.self) { token in
                                addFieldButton(for: token)
                            }
                        } header: {
                            Text("herdr fields")
                        }
                    }
                    if !availableHeelerFields.isEmpty {
                        Section {
                            ForEach(availableHeelerFields, id: \.self) { token in
                                addFieldButton(for: token)
                            }
                        } header: {
                            Text("Heeler fields")
                        } footer: {
                            Text("These fields exist only in Heeler.")
                        }
                    }
                }
                Section {
                    TextField("$custom_name", text: $customName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                    Button("Add Custom Field") {
                        guard let token = AgentLayoutTokensEditing.customToken(
                            from: customName, alreadyIn: tokens)
                        else { return }
                        add(token)
                    }
                    .disabled(
                        AgentLayoutTokensEditing.customToken(from: customName, alreadyIn: tokens) == nil
                            || !canAddField)
                } header: {
                    Text("Custom field")
                } footer: {
                    Text("Custom names start with $ and contain 1–32 letters, digits, underscores or hyphens. Values come from herdr plugins and display as plain text.")
                }
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddField = false }
                }
            }
            .disabled(!canAddField)
        }
    }

    private var availableHerdrFields: [AgentRowToken] {
        AgentLayoutTokensEditing.availableBuiltins(in: tokens, from: AgentRowToken.herdrBuiltins)
    }

    private var availableHeelerFields: [AgentRowToken] {
        AgentLayoutTokensEditing.availableBuiltins(in: tokens, from: AgentRowToken.heelerBuiltins)
    }

    private func addFieldButton(for token: AgentRowToken) -> some View {
        Button {
            add(token)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: token.rawValue)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
                Text(AgentLayoutTokensEditing.description(for: token))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tokenRow(_ styled: AgentRowStyledToken, at index: Int) -> some View {
        let style = AgentLayoutTokensEditing.style(of: styled)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: styled.token.rawValue)
                    .fontDesign(.monospaced)
                Text(AgentLayoutTokensEditing.description(for: styled.token))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if editor.isEditing {
                Menu {
                    Button("Default") { setStyle(.default, at: index) }
                    Button("Secondary") { setStyle(.secondary, at: index) }
                } label: {
                    Text(style.label)
                        .foregroundStyle(.secondary)
                }
                .disabled(!canMutate)
            } else {
                Text(style.label)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Field \(index + 1) of \(tokens.count): \(styled.token.rawValue), \(style.label.lowercased()) style")
        .modifier(TokenEditActions(
            enabled: editor.isEditing,
            onDelete: {
                guard canMutate else { return }
                deleteTokens(IndexSet(integer: index))
            },
            onMoveUp: {
                guard canMutate, index > 0 else { return }
                moveTokens(IndexSet(integer: index), index - 1)
            },
            onMoveDown: {
                guard canMutate, index < tokens.count - 1 else { return }
                moveTokens(IndexSet(integer: index), index + 2)
            }))
    }

    private func add(_ token: AgentRowToken) {
        if AgentLayoutTokensEditing.add(
            token, editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex)
        {
            customName = ""
            showingAddField = false
        }
    }

    private func setStyle(_ style: AgentLayoutTokenStyle, at index: Int) {
        AgentLayoutTokensEditing.setStyle(
            style, at: index, editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex)
    }

    private func deleteTokens(_ offsets: IndexSet) {
        AgentLayoutTokensEditing.delete(
            offsets, editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex)
    }

    private func moveTokens(_ offsets: IndexSet, _ destination: Int) {
        AgentLayoutTokensEditing.move(
            offsets, to: destination, editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex)
    }
}

private struct TokenEditActions: ViewModifier {
    var enabled: Bool
    var onDelete: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: "Delete", onDelete)
                .accessibilityAction(named: "Move Up", onMoveUp)
                .accessibilityAction(named: "Move Down", onMoveDown)
        } else {
            content
        }
    }
}

enum AgentLayoutTokenStyle: Equatable {
    case `default`
    case secondary

    var label: String {
        switch self {
        case .default: "Default"
        case .secondary: "Secondary"
        }
    }
}

/// Field-editor mutations. A stale `rowIndex` is a no-op: it never inserts a
/// row, deletes a different row, or writes another Host or override.
enum AgentLayoutTokensEditing {
    static func rows(in layout: AgentRowLayout, kind: String?) -> [AgentRow] {
        kind.map { layout.rowsByAgent[$0] ?? [] } ?? layout.rows
    }

    static func isValidRow(_ rowIndex: Int, in rows: [AgentRow]) -> Bool {
        rows.indices.contains(rowIndex)
    }

    static func navigationSubtitle(hostName: String, kind: String?) -> String {
        if let kind {
            return hostName.isEmpty ? "\(kind) override" : "\(hostName) · \(kind) override"
        }
        return hostName
    }

    static func description(for token: AgentRowToken) -> String {
        switch token {
        case .stateIcon:
            "Status icon. Shown in the status column, not as a field in this row."
        case .stateText:
            "Status text. Shown in the status column, not as a field in this row."
        case .workspace:
            "Workspace or repo folder name"
        case .tab:
            "Tab title"
        case .pane:
            "Pane title"
        case .agent:
            "Agent name"
        case .terminalTitle:
            "Current terminal window title"
        case .terminalTitleStripped:
            "Terminal title without the Agent prefix"
        case .host:
            "Host name"
        case .status:
            "Agent Status as text"
        case .directory:
            "Working directory"
        case .custom:
            "Plugin field. Values come from herdr plugins and display as plain text."
        }
    }

    static func style(of token: AgentRowStyledToken) -> AgentLayoutTokenStyle {
        token.dim == true ? .secondary : .default
    }

    /// Default clears `dim`; Secondary sets `dim` to true. Token, `fg`, and
    /// `bold` stay as they are.
    static func applying(_ style: AgentLayoutTokenStyle, to token: AgentRowStyledToken)
        -> AgentRowStyledToken
    {
        var next = token
        switch style {
        case .default: next.dim = nil
        case .secondary: next.dim = true
        }
        return next
    }

    static func availableBuiltins(
        in row: AgentRow, from tokens: [AgentRowToken] = AgentRowToken.builtins
    ) -> [AgentRowToken] {
        let present = Set(row.map(\.token))
        return tokens.filter { !present.contains($0) }
    }

    static func customToken(from raw: String, alreadyIn row: AgentRow) -> AgentRowToken? {
        guard raw.hasPrefix("$"), let token = AgentRowToken(rawValue: raw), case .custom = token else {
            return nil
        }
        guard !row.contains(where: { $0.token == token }) else { return nil }
        return token
    }

    static func canAddField(to row: AgentRow, rows: [AgentRow], rowIndex: Int) -> Bool {
        isValidRow(rowIndex, in: rows) && row.count < AgentRowLayout.maximumTokensPerRow
    }

    /// `nil` when `rowIndex` does not name a row in `rows`.
    static func replacingRow(
        in rows: [AgentRow], at rowIndex: Int, change: (inout AgentRow) -> Void
    ) -> [AgentRow]? {
        guard isValidRow(rowIndex, in: rows) else { return nil }
        var next = rows
        change(&next[rowIndex])
        return next
    }

    @MainActor
    @discardableResult
    static func add(
        _ token: AgentRowToken,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        kind: String?,
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex) { row in
            guard row.count < AgentRowLayout.maximumTokensPerRow else { return }
            guard !row.contains(where: { $0.token == token }) else { return }
            row.append(AgentRowStyledToken(token))
        }
    }

    @MainActor
    @discardableResult
    static func delete(
        _ offsets: IndexSet,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        kind: String?,
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex) { row in
            let valid = IndexSet(offsets.filter { row.indices.contains($0) })
            guard !valid.isEmpty else { return }
            row.remove(atOffsets: valid)
        }
    }

    @MainActor
    @discardableResult
    static func move(
        _ offsets: IndexSet,
        to destination: Int,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        kind: String?,
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex) { row in
            guard offsets.allSatisfy({ row.indices.contains($0) }) else { return }
            guard (0...row.count).contains(destination) else { return }
            row.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    @MainActor
    @discardableResult
    static func setStyle(
        _ style: AgentLayoutTokenStyle,
        at index: Int,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        kind: String?,
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, kind: kind, rowIndex: rowIndex) { row in
            guard row.indices.contains(index) else { return }
            row[index] = applying(style, to: row[index])
        }
    }

    @MainActor
    @discardableResult
    static func apply(
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        kind: String?,
        rowIndex: Int,
        change: (inout AgentRow) -> Void
    ) -> Bool {
        guard editor.isEditing else { return false }
        let rows = Self.rows(in: editor.layout(for: hostID), kind: kind)
        guard let next = replacingRow(in: rows, at: rowIndex, change: change), next != rows else {
            return false
        }
        editor.setRows(next, kind: kind, for: hostID)
        return editor.errorMessage == nil
    }
}
