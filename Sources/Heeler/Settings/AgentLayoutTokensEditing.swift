import Foundation

enum AgentLayoutTokenStyle: Equatable {
    case `default`
    case secondary

    var label: String {
        switch self {
        case .default: "Default"
        case .secondary: "Secondary"
        }
    }

    /// Read-only marker. Default is the unmarked state, so only Secondary shows.
    var badge: String? {
        switch self {
        case .default: nil
        case .secondary: "Secondary"
        }
    }

    /// Menu action that switches to the other style.
    var toggleActionTitle: String {
        switch self {
        case .default: "Secondary Style"
        case .secondary: "Default Style"
        }
    }

    var toggled: AgentLayoutTokenStyle {
        switch self {
        case .default: .secondary
        case .secondary: .default
        }
    }
}

/// Field mutations over the Console's three row slots, each persisted at
/// once through `AgentListFieldsEditor.commit`. A row index outside those
/// slots is a no-op: it never inserts a row or writes another Host. Editing
/// an empty slot beyond the layout's last row pads the layout with empty
/// rows up to it.
enum AgentLayoutTokensEditing {
    static let heelerFieldsUnavailable =
        "Row 1 and Row 2 follow herdr. Add Heeler fields in Row 3."

    /// True for every Console row slot, whether or not `rows` reaches it.
    static func isValidRow(_ rowIndex: Int, in rows: [AgentRow]) -> Bool {
        AgentRowSlot.forRow(rowIndex) != nil
    }

    /// The slot's fields; empty when the layout has no row there yet.
    static func row(_ rowIndex: Int, in rows: [AgentRow]) -> AgentRow {
        rows.indices.contains(rowIndex) ? rows[rowIndex] : []
    }

    static func navigationSubtitle(hostName: String, rowIndex: Int? = nil) -> String {
        var parts: [String] = []
        if !hostName.isEmpty { parts.append(hostName) }
        if let rowIndex, let slot = AgentRowSlot.forRow(rowIndex) { parts.append("\(slot.label) row") }
        return parts.joined(separator: " · ")
    }

    /// Footer of the Add Field sheet.
    static func addFieldFooter(rowIndex: Int) -> String {
        switch AgentRowSlot.forRow(rowIndex) {
        case .herdr?:
            "This row follows herdr, so it offers herdr fields; Sync from plugin refills it."
        case .heeler?:
            "This is Heeler's row: it can mix herdr and Heeler fields."
        case nil:
            ""
        }
    }

    static func availableHeelerFields(in row: AgentRow, rowIndex: Int) -> [AgentRowToken] {
        guard AgentRowSlot.forRow(rowIndex)?.allowsHeelerFields == true else { return [] }
        return availableBuiltins(in: row, from: AgentRowToken.heelerBuiltins)
    }

    static func description(for token: AgentRowToken) -> String {
        switch token {
        case .stateIcon:
            "Status icon. Heeler's status column at the end of Row 1 always shows it; it is not offered as a field."
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

    /// `nil` when `rowIndex` is outside the Console's row slots. A slot past
    /// the layout's last row is reached by padding with empty rows.
    static func replacingRow(
        in rows: [AgentRow], at rowIndex: Int, change: (inout AgentRow) -> Void
    ) -> [AgentRow]? {
        guard isValidRow(rowIndex, in: rows) else { return nil }
        var row = self.row(rowIndex, in: rows)
        change(&row)
        var next = rows
        if rows.indices.contains(rowIndex) {
            next[rowIndex] = row
        } else {
            // A rejected change on an empty slot must not pad the layout.
            guard !row.isEmpty else { return rows }
            while next.count < rowIndex { next.append([]) }
            next.append(row)
        }
        return next
    }

    @MainActor
    @discardableResult
    static func add(
        _ token: AgentRowToken,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex) { row in
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
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex) { row in
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
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex) { row in
            guard offsets.allSatisfy({ row.indices.contains($0) }) else { return }
            guard (0...row.count).contains(destination) else { return }
            row.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    /// Swaps the field at `index` with its left (`-1`) or right (`+1`) neighbour.
    @MainActor
    @discardableResult
    static func shift(
        _ index: Int,
        by delta: Int,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int
    ) -> Bool {
        guard delta == -1 || delta == 1 else { return false }
        // `move(fromOffsets:toOffset:)` counts the destination before removal.
        let destination = delta < 0 ? index - 1 : index + 2
        guard destination >= 0 else { return false }
        return move(
            IndexSet(integer: index), to: destination,
            editor: editor, hostID: hostID, rowIndex: rowIndex)
    }

    @MainActor
    @discardableResult
    static func setStyle(
        _ style: AgentLayoutTokenStyle,
        at index: Int,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex) { row in
            guard row.indices.contains(index) else { return }
            row[index] = applying(style, to: row[index])
        }
    }

    /// Persists one row change through `editor.commit`. False when the slot
    /// does not exist, the change is a no-op, or saving failed.
    @MainActor
    @discardableResult
    static func apply(
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int,
        change: (inout AgentRow) -> Void
    ) -> Bool {
        let rows = editor.layout(for: hostID).rows
        guard let next = replacingRow(in: rows, at: rowIndex, change: change), next != rows else {
            return false
        }
        return editor.commit(hostID) { $0.rows = next }
    }
}
