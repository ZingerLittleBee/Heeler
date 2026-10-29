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

/// Which side of a row slot a field ends up on in the Console.
enum AgentRowSide: Hashable, Sendable {
    case leading, trailing

    var other: AgentRowSide { self == .leading ? .trailing : .leading }
}

/// Field mutations over both sides of the Console's three row slots, each
/// persisted at once through `AgentListFieldsEditor.commit`. A row index
/// outside those slots is a no-op: it never inserts a row or writes another
/// Host. Editing an empty slot beyond the layout's last row pads the layout
/// with empty rows up to it. A field sits on one side of a slot at most.
enum AgentLayoutTokensEditing {
    /// One side's rows. A layout that leaves its right side to the list
    /// edits from that side's defaults, less any field its left side
    /// already holds in the slot; the first change saves them.
    static func rows(_ side: AgentRowSide, of layout: AgentRowLayout) -> [AgentRow] {
        switch side {
        case .leading: layout.rows
        case .trailing:
            layout.trailing ?? AgentRowLayout.defaultTrailing.enumerated().map { slot, defaults in
                let left = row(slot, in: layout.rows)
                return defaults.filter { field in !left.contains { $0.token == field.token } }
            }
        }
    }

    /// `rows` with every field the same slot's right side holds taken off
    /// the left, where a Sync refilled it: the right side's place stands.
    static func keepingRightSides(_ rows: [AgentRow], of trailing: [AgentRow]?) -> [AgentRow] {
        guard let trailing else { return rows }
        return rows.enumerated().map { slot, left in
            let right = row(slot, in: trailing)
            return left.filter { field in !right.contains { $0.token == field.token } }
        }
    }

    /// Whether `token` can cross from `side` to a slot's other side, which
    /// holds `landing`.
    static func canMoveAcross(_ token: AgentRowToken, from side: AgentRowSide, landing: AgentRow) -> Bool {
        accepts(token, on: side.other) && landing.count < AgentRowLayout.maximumTokensPerRow
            && !landing.contains { $0.token == token }
    }

    static func setRows(_ rows: [AgentRow], _ side: AgentRowSide, in layout: inout AgentRowLayout) {
        switch side {
        case .leading: layout.rows = rows
        case .trailing: layout.trailing = rows
        }
    }

    /// Both sides of a slot, for checks that a field sits on one side only.
    static func slotFields(_ rowIndex: Int, of layout: AgentRowLayout) -> AgentRow {
        row(rowIndex, in: rows(.leading, of: layout)) + row(rowIndex, in: rows(.trailing, of: layout))
    }

    /// True for every Console row slot, whether or not `rows` reaches it.
    static func isValidRow(_ rowIndex: Int, in rows: [AgentRow]) -> Bool {
        AgentRowSlot.forRow(rowIndex) != nil
    }

    /// The slot's fields; empty when the layout has no row there yet.
    static func row(_ rowIndex: Int, in rows: [AgentRow]) -> AgentRow {
        rows.indices.contains(rowIndex) ? rows[rowIndex] : []
    }

    static func navigationSubtitle(
        hostName: String, rowIndex: Int? = nil, side: AgentRowSide = .leading
    ) -> String {
        var parts: [String] = []
        if !hostName.isEmpty { parts.append(hostName) }
        if let rowIndex, let slot = AgentRowSlot.forRow(rowIndex) {
            parts.append(side == .trailing ? "right side" : "\(slot.label) row")
        }
        return parts.joined(separator: " · ")
    }

    /// Footer of the Add Field sheet.
    static func addFieldFooter(rowIndex: Int, side: AgentRowSide = .leading) -> String {
        switch (AgentRowSlot.forRow(rowIndex), side) {
        case (nil, _):
            ""
        case (_, .trailing):
            "These fields end the row on the right. They are Heeler's own; Sync from plugin keeps them."
        case (.herdr?, .leading):
            "This row starts from herdr's sidebar fields; Sync from plugin refills it. Heeler fields are welcome here too."
        case (.heeler?, .leading):
            "This is Heeler's row. Sync from plugin keeps it."
        }
    }

    /// `changes` only on the right, where the totals draw as counts.
    static func availableHeelerFields(in row: AgentRow, side: AgentRowSide = .leading) -> [AgentRowToken] {
        availableBuiltins(
            in: row,
            from: AgentRowToken.heelerBuiltins + (side == .trailing ? AgentRowToken.trailingOnlyBuiltins : []))
    }

    /// Whether `side` can hold `token`: the right side's own fields stay
    /// off the left.
    static func accepts(_ token: AgentRowToken, on side: AgentRowSide) -> Bool {
        side == .trailing || !AgentRowToken.trailingOnlyBuiltins.contains(token)
    }

    /// Whether the field's style changes what the right side shows: the
    /// Host and the totals draw in their own look.
    static func hasStyle(_ token: AgentRowToken, on side: AgentRowSide) -> Bool {
        side == .leading || (token != .host && !AgentRowToken.trailingOnlyBuiltins.contains(token))
    }

    static func description(for token: AgentRowToken) -> String {
        switch token {
        case .stateIcon:
            "Status icon. The row's status badge or ring shows it; it is not offered as a field."
        case .stateText:
            "herdr's status text. Heeler shows the status with the row's badge or ring, not in this row; "
                + "add status to show it as text."
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
        case .changes:
            "Changes totals of the Agent's Checkout"
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
        rowIndex: Int,
        side: AgentRowSide = .leading
    ) -> Bool {
        guard accepts(token, on: side) else { return false }
        let other = row(rowIndex, in: rows(side.other, of: editor.layout(for: hostID)))
        guard !other.contains(where: { $0.token == token }) else { return false }
        return apply(editor: editor, hostID: hostID, rowIndex: rowIndex, side: side) { row in
            guard row.count < AgentRowLayout.maximumTokensPerRow else { return }
            guard !row.contains(where: { $0.token == token }) else { return }
            row.append(AgentRowStyledToken(token))
        }
    }

    /// Moves the field at `index` to the slot's other side, next to the
    /// gap between the two, keeping its style. Refused where the other side
    /// is full or cannot hold the field.
    @MainActor
    @discardableResult
    static func moveAcross(
        _ index: Int,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int,
        from side: AgentRowSide
    ) -> Bool {
        let layout = editor.layout(for: hostID)
        let source = rows(side, of: layout)
        let target = rows(side.other, of: layout)
        let field = row(rowIndex, in: source)
        let landing = row(rowIndex, in: target)
        guard field.indices.contains(index), canMoveAcross(field[index].token, from: side, landing: landing),
            let nextSource = replacingRow(in: source, at: rowIndex, change: { $0.remove(at: index) }),
            let nextTarget = replacingRow(in: target, at: rowIndex, change: { row in
                if side == .leading { row.insert(field[index], at: 0) } else { row.append(field[index]) }
            })
        else { return false }
        return editor.commit(hostID) { layout in
            setRows(nextSource, side, in: &layout)
            setRows(nextTarget, side.other, in: &layout)
        }
    }

    @MainActor
    @discardableResult
    static func delete(
        _ offsets: IndexSet,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int,
        side: AgentRowSide = .leading
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex, side: side) { row in
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
        rowIndex: Int,
        side: AgentRowSide = .leading
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex, side: side) { row in
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
        rowIndex: Int,
        side: AgentRowSide = .leading
    ) -> Bool {
        guard delta == -1 || delta == 1 else { return false }
        // `move(fromOffsets:toOffset:)` counts the destination before removal.
        let destination = delta < 0 ? index - 1 : index + 2
        guard destination >= 0 else { return false }
        return move(
            IndexSet(integer: index), to: destination,
            editor: editor, hostID: hostID, rowIndex: rowIndex, side: side)
    }

    @MainActor
    @discardableResult
    static func setStyle(
        _ style: AgentLayoutTokenStyle,
        at index: Int,
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int,
        side: AgentRowSide = .leading
    ) -> Bool {
        apply(editor: editor, hostID: hostID, rowIndex: rowIndex, side: side) { row in
            guard row.indices.contains(index) else { return }
            row[index] = applying(style, to: row[index])
        }
    }

    /// Persists one change to one side of a row through `editor.commit`.
    /// False when the slot does not exist, the change is a no-op, or saving
    /// failed.
    @MainActor
    @discardableResult
    static func apply(
        editor: AgentListFieldsEditor,
        hostID: Host.ID,
        rowIndex: Int,
        side: AgentRowSide = .leading,
        change: (inout AgentRow) -> Void
    ) -> Bool {
        let current = rows(side, of: editor.layout(for: hostID))
        guard let next = replacingRow(in: current, at: rowIndex, change: change), next != current else {
            return false
        }
        return editor.commit(hostID) { setRows(next, side, in: &$0) }
    }
}
