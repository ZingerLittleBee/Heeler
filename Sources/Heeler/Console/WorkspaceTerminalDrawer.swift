import SwiftUI

/// Workspace navigation docked to the terminal's trailing edge: a slim handle
/// that costs the output neither width nor height, and expands in place into
/// a panel listing the Workspace's terminals. The rail and strip it replaced
/// both took space from the output the user came to read; a system menu hid
/// the list behind a popup that never felt attached to the edge.
struct WorkspaceTerminalDrawer: View {
    let terminals: [ConsoleTerminal]
    let selectedPaneID: String
    var palette: TerminalThemePalette = .system
    let onSelect: (ConsoleTerminal) -> Void

    static let handleSize = CGSize(width: 30, height: 68)
    /// The handle's hit area reaches past its visible edge into the terminal.
    static let handleHitWidth: CGFloat = 44
    static let panelWidth: CGFloat = 248
    static let rowHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 14

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The surface's own theme colours, like every other floating control.
    func palette(_ palette: TerminalThemePalette) -> Self {
        var copy = self
        copy.palette = palette
        return copy
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if isExpanded {
                // A tap anywhere else closes the panel instead of reaching
                // the terminal underneath it.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { setExpanded(false) }
                    .accessibilityHidden(true)
                panel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                handle
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .foregroundStyle(palette.foreground)
        .onChange(of: selectedPaneID) { _, _ in
            if isExpanded { setExpanded(false) }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            isExpanded = expanded
        }
    }

    private var handle: some View {
        Button {
            setExpanded(true)
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                .background { surface }
                .frame(width: Self.handleHitWidth, alignment: .trailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Workspace terminals")
        .accessibilityValue("\(terminals.count) terminals")
        .accessibilityHint("Shows the terminals in this Workspace")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Workspace")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.foreground.opacity(0.7))
                Spacer(minLength: 0)
                Button {
                    setExpanded(false)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Workspace terminals")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(height: 36)
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(orderedTerminals) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.rowHeight * 6 + 6)
        }
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background { surface }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace terminals")
    }

    private func row(_ item: ConsoleTerminal) -> some View {
        let selected = item.paneID == selectedPaneID
        return Button {
            // Collapse first: a retained Agent surface survives the switch
            // and would otherwise come back with the panel still open.
            setExpanded(false)
            if !selected {
                onSelect(item)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isAgent ? "sparkles" : "terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(item.displayTabTitle)
                    .font(.caption)
                    .foregroundStyle(palette.foreground.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(
                palette.foreground.opacity(selected ? 0.16 : 0),
                in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(item.isAgent ? "Agent" : "Terminal"), \(item.displayTitle)")
        .accessibilityValue(item.displayTabTitle)
        .accessibilityHint(selected ? "" : item.displayCwd)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The floating-control surface, squared off on the edge it is docked to.
    private var surface: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: Self.cornerRadius,
            bottomLeadingRadius: Self.cornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous)
        return shape
            .fill(palette.background.mix(with: palette.foreground, by: 0.16).opacity(0.96))
            .overlay {
                shape.strokeBorder(palette.foreground.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .allowsHitTesting(false)
    }
}
