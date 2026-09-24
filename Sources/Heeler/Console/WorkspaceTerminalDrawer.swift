import SwiftUI

/// Workspace navigation docked to the terminal's trailing edge: a slim handle
/// that costs the output neither width nor height, and expands in place into
/// a panel listing the Workspace's terminals. The rail and strip it replaced
/// both took space from the output the user came to read; a system menu hid
/// the list behind a popup that never felt attached to the edge.
///
/// The handle rests where the user last left it: a long press lifts it and
/// the drag that follows slides it along the edge (``EdgeDockLift``).
struct WorkspaceTerminalDrawer: View {
    let terminals: [ConsoleTerminal]
    let selectedPaneID: String
    let edgeDock: EdgeDockSettings
    var palette: TerminalThemePalette = .system
    /// `var` so a host can wrap it: Agent detail captures the keyboard state
    /// before a route leaves its screen.
    var onSelect: (ConsoleTerminal) -> Void
    /// Opens a fresh shell tab in the Workspace; nil hides the New Terminal
    /// button (no launch directory to open it in).
    var onNewTerminal: (() -> Void)? = nil
    /// A creation in flight: the button shows progress and takes no hit.
    var isCreatingTerminal = false

    static let handleSize = CGSize(width: TerminalEdgeTabBackground.width, height: 68)
    /// The handle's hit area reaches past its visible edge into the terminal.
    static let handleHitWidth: CGFloat = 44
    static let panelWidth: CGFloat = 248
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 36
    static let footerHeight: CGFloat = 44
    static let visibleRowLimit = 6
    private static let rowSpacing: CGFloat = 2
    private static let panelBottomInset: CGFloat = 6
    /// One accessibility nudge moves the handle by its own height.
    private static let nudge: CGFloat = 68

    @State private var isExpanded = false
    @State private var isLifted = false
    @State private var liftTravel: CGFloat = 0
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

    /// The panel's height for `count` terminals: header, up to six rows, the
    /// bottom inset, and the New Terminal footer when one is offered. Pure so
    /// placement and the rendered frame agree.
    static func panelHeight(count: Int, hasFooter: Bool = false) -> CGFloat {
        let rows = min(max(count, 1), visibleRowLimit)
        return headerHeight + CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * rowSpacing + panelBottomInset
            + (hasFooter ? footerHeight : 0)
    }

    /// Where the handle's top edge rests inside `height`, from the remembered
    /// fraction plus any lift in progress, clamped to the edge.
    static func handleTop(
        fraction: CGFloat, liftTravel: CGFloat, height: CGFloat
    ) -> CGFloat {
        let travel = max(0, height - handleSize.height)
        return min(max(fraction * travel + liftTravel, 0), travel)
    }

    /// The fraction a handle dropped at `top` should remember.
    static func fraction(handleTop top: CGFloat, height: CGFloat) -> CGFloat {
        let travel = max(0, height - handleSize.height)
        guard travel > 0 else { return 0 }
        return top / travel
    }

    /// The open panel centres on the handle it grew from, held inside the
    /// terminal so no row lands off screen.
    static func panelTop(handleTop: CGFloat, panelHeight: CGFloat, height: CGFloat) -> CGFloat {
        let centred = handleTop + handleSize.height / 2 - panelHeight / 2
        return min(max(centred, 0), max(0, height - panelHeight))
    }

    /// The surface's own theme colours, like every other floating control.
    func palette(_ palette: TerminalThemePalette) -> Self {
        var copy = self
        copy.palette = palette
        return copy
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let handleTop = Self.handleTop(
                fraction: edgeDock.fraction(for: .workspaceDrawer),
                liftTravel: liftTravel, height: height)
            ZStack(alignment: .topTrailing) {
                if isExpanded {
                    // A tap anywhere else closes the panel instead of reaching
                    // the terminal underneath it.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { setExpanded(false) }
                        .accessibilityHidden(true)
                    let panelHeight = Self.panelHeight(
                        count: terminals.count, hasFooter: onNewTerminal != nil)
                    panel(height: panelHeight)
                        .offset(y: Self.panelTop(
                            handleTop: handleTop, panelHeight: panelHeight, height: height))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    handle(top: handleTop, height: height)
                        .offset(y: handleTop)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
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

    private func dock(handleTop top: CGFloat, height: CGFloat) {
        edgeDock.setFraction(Self.fraction(handleTop: top, height: height), for: .workspaceDrawer)
        liftTravel = 0
    }

    private func handle(top: CGFloat, height: CGFloat) -> some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .opacity(TerminalFloatingButtonStyle.iconOpacity)
            .frame(width: Self.handleSize.width, height: Self.handleSize.height)
            .background { surface }
            .frame(width: Self.handleHitWidth, alignment: .trailing)
            .contentShape(.rect)
            .onTapGesture {
                guard !isLifted else { return }
                setExpanded(true)
            }
            .edgeDockLift(
                isLifted: $isLifted,
                onMove: { liftTravel = $0 },
                onDrop: { travel in
                    dock(handleTop: Self.handleTop(
                        fraction: edgeDock.fraction(for: .workspaceDrawer),
                        liftTravel: travel, height: height), height: height)
                })
            .hoverEffect(.highlight)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Workspace terminals")
            .accessibilityValue("\(terminals.count) terminals")
            .accessibilityHint("Shows the terminals in this Workspace")
            .accessibilityAction { setExpanded(true) }
            .accessibilityAction(named: "Move up") {
                dock(handleTop: top - Self.nudge, height: height)
            }
            .accessibilityAction(named: "Move down") {
                dock(handleTop: top + Self.nudge, height: height)
            }
    }

    private func panel(height: CGFloat) -> some View {
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
            .frame(height: Self.headerHeight)
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(orderedTerminals) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, Self.panelBottomInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            if let onNewTerminal {
                newTerminalFooter(onNewTerminal)
            }
        }
        .frame(width: Self.panelWidth, height: height)
        .background {
            TerminalEdgeTabBackground(
                palette: palette, fillOpacity: TerminalEdgeTabBackground.panelFillOpacity)
        }
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

    /// Pinned below the scrolling rows so it is reachable however many
    /// terminals the Workspace holds.
    private func newTerminalFooter(_ onNewTerminal: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.foreground.opacity(0.14))
                .frame(height: 1)
                .padding(.horizontal, 10)
            Button {
                setExpanded(false)
                onNewTerminal()
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if isCreatingTerminal {
                            ProgressView()
                                .controlSize(.small)
                                .tint(palette.foreground)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .frame(width: 18)
                    .accessibilityHidden(true)
                    Text("New Terminal")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(isCreatingTerminal)
            .padding(.horizontal, 6)
            .accessibilityLabel("New Terminal")
            .accessibilityHint("Opens a new shell tab in this Workspace")
        }
        .frame(height: Self.footerHeight)
        .padding(.bottom, Self.panelBottomInset)
        // The footer sits inside the panel height; give back the inset the
        // rows already paid for so the total still matches `panelHeight`.
        .padding(.top, -Self.panelBottomInset)
    }

    /// The handle's surface, squared off on the edge it is docked to.
    private var surface: some View {
        TerminalEdgeTabBackground(palette: palette)
    }
}
