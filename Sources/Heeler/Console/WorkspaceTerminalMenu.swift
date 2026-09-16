import SwiftUI

/// Workspace navigation as one floating control over the terminal, so it
/// costs the terminal no width and no height: the rail and strip it replaced
/// both took space from the output the user came to read. The menu lists the
/// Workspace's terminals in Tab order with the open one checked.
struct WorkspaceTerminalMenu: View {
    let terminals: [ConsoleTerminal]
    let selectedPaneID: String
    var palette: TerminalThemePalette = .system
    let onSelect: (ConsoleTerminal) -> Void

    /// Tab order, then Pane order within the Tab: the same order the Console's
    /// Terminals list shows for this Workspace.
    var orderedTerminals: [ConsoleTerminal] {
        Self.ordered(terminals)
    }

    static func ordered(_ terminals: [ConsoleTerminal]) -> [ConsoleTerminal] {
        terminals.sorted {
            ($0.tabPosition ?? Int.max, $0.snapshotOrder)
                < ($1.tabPosition ?? Int.max, $1.snapshotOrder)
        }
    }

    /// The terminal a menu pick routes to, or nil for the one already open.
    static func destination(
        forPaneID paneID: String, in terminals: [ConsoleTerminal], selectedPaneID: String
    ) -> ConsoleTerminal? {
        guard paneID != selectedPaneID else { return nil }
        return terminals.first { $0.paneID == paneID }
    }

    /// Title and Tab, the way the Open Terminal dialog already names a shell.
    static func rowTitle(for terminal: ConsoleTerminal) -> String {
        "\(terminal.displayTitle) · \(terminal.displayTabTitle)"
    }

    /// The surface's own theme colours, like every other floating control.
    func palette(_ palette: TerminalThemePalette) -> Self {
        var copy = self
        copy.palette = palette
        return copy
    }

    var body: some View {
        Menu {
            Picker(
                "Workspace terminals",
                selection: Binding(
                    get: { selectedPaneID },
                    set: { paneID in
                        if let target = Self.destination(
                            forPaneID: paneID, in: terminals, selectedPaneID: selectedPaneID)
                        {
                            onSelect(target)
                        }
                    })
            ) {
                ForEach(orderedTerminals) { item in
                    // One line per row: a picker row drops a Label's subtitle,
                    // and two shells in one directory share a title.
                    Label(
                        Self.rowTitle(for: item),
                        systemImage: item.isAgent ? "sparkles" : "terminal")
                    .tag(item.paneID)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 15, weight: .semibold))
        }
        // Tab order top to bottom, even when the menu opens upward.
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(TerminalFloatingButtonStyle(highlight: palette.foreground))
        .background {
            TerminalFloatingControlBackground(palette: palette)
        }
        .foregroundStyle(palette.foreground)
        .hoverEffect(.highlight)
        .accessibilityLabel("Workspace terminals")
        .accessibilityValue("\(terminals.count) terminals")
        .accessibilityHint("Switches to another terminal in this Workspace")
    }
}
