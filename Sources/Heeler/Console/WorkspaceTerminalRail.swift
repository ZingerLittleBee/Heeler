import SwiftUI

/// Workspace navigation stays beside the terminal instead of replacing its
/// keyboard or reserving a second full sidebar on compact screens.
struct WorkspaceTerminalRail: View {
    let terminals: [ConsoleTerminal]
    let selectedPaneID: String
    let currentTabID: String
    let onSelect: (ConsoleTerminal) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var orderedTerminals: [ConsoleTerminal] {
        terminals.filter { $0.tabID == currentTabID }
            + terminals.filter { $0.tabID != currentTabID }
    }

    var body: some View {
        if !terminals.isEmpty {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.3x1")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                    ForEach(orderedTerminals) { item in
                        let selected = item.paneID == selectedPaneID
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: item.isAgent ? "sparkles" : "terminal")
                                    .font(.caption)
                                Text(item.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                if let label = item.tabLabel, !label.isEmpty {
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                            .background(
                                selected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground),
                                in: .rect(cornerRadius: 10))
                            .contentShape(.rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.isAgent ? "Agent" : "Terminal"), \(item.displayTitle)")
                        .accessibilityValue(item.tabLabel ?? "")
                        .accessibilityHint(item.displayCwd)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(6)
            }
            .frame(width: horizontalSizeClass == .regular ? 112 : 76)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .leading) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace terminals")
        }
    }
}
