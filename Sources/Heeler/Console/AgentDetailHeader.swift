import SwiftUI

/// Floating controls over an Agent or terminal. Separate glass pieces float
/// over the terminal: Back at the leading end, the Agent's title beside it,
/// and at the far end a More menu that stays put. The room between them is
/// left to the terminal, and folding leaves only the menu, so the header can
/// cover almost no output.
///
/// Back is the way out of a detail pushed over the list, on an iPhone or in
/// a compact iPad window, which the edge swipe alone never showed (#396).
/// Beside an iPad's sidebar there is nothing to go back to, so the header
/// keeps only its menu.
///
/// The menu holds the screen's actions and the item that folds or unfolds
/// the header, each titled in one word. Actions are plain values rather than
/// views, so a screen can leave out the ones it cannot offer.
///
/// An Agent that has Chat also shows a button for the surface it is not
/// showing, Chat or its terminal, sharing the menu's capsule in both states,
/// so the other surface stays one tap away while the header is folded.
///
/// Level with a detail column's bar, the menu and surface button move into
/// the bar as `AgentDetailHeaderBarControls`: the bar sits above the screen
/// and takes every touch across its row, so controls drawn under it could
/// not be pressed.
struct AgentDetailHeader: View {
    static let controlSize: CGFloat = 44
    /// How much of the glass shows, the rest letting output through.
    static let glassOpacity: Double = 0.8
    /// Buttons sharing a capsule sit closer than standalone ones.
    static let capsuleButtonWidth: CGFloat = 36
    static let capsuleInset: CGFloat = (controlSize - capsuleButtonWidth) / 2

    /// Where the header's top edge sits. Beside an iPad's sidebar it lines
    /// up with the detail column's bar, level with the sidebar's buttons and
    /// Show Sidebar, even while output starts below the bar; elsewhere it
    /// rides just below the output's top. A bar's buttons fill a control's
    /// height from its top edge, with the bar's remaining height below
    /// them, so the header starts at that edge rather than centering.
    static func top(outputTop: CGFloat, barRow: NavigationBarBand?) -> CGFloat {
        guard let barRow, levelsWithBar(barRow) else { return outputTop + 4 }
        return barRow.top
    }

    /// Whether the header shares the bar's row, which then holds the
    /// header's trailing controls.
    static func levelsWithBar(_ barRow: NavigationBarBand?) -> Bool {
        guard let barRow else { return false }
        return barRow.bottom - barRow.top >= controlSize
    }

    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    /// Nil where the detail stands beside the list rather than over it.
    let onBack: (() -> Void)?
    var actions: [AgentDetailHeaderAction] = []
    /// Nil for a screen with one surface, such as a shell terminal.
    var surfaceSwitch: AgentDetailSurfaceSwitch?
    /// Nil for a screen that names nothing, such as a shell terminal.
    var title: AgentDetailHeaderTitle?
    /// Temporarily replaces the task title and reveals it even while folded,
    /// without changing the user's expansion preference or the other controls.
    var statusTitle: String?
    /// The bar holds the trailing controls; the header keeps their room
    /// clear so the expanded title stays centred.
    var trailingInBar = false

    /// The width of the trailing controls, measured so the leading slot can match it.
    @State private var trailingWidth: CGFloat = 0
    /// The trailing safe inset, which a floating tab bar takes. The row starts
    /// this far in too, so the title centres on the content, not the row.
    @State private var trailingSafeInset: CGFloat = 0

    /// Both side slots are this wide while expanded, so the title sits at the
    /// header's centre rather than between controls of different widths.
    private var slotWidth: CGFloat {
        trailingInBar ? barControlsWidth : max(trailingWidth, Self.controlSize)
    }

    /// As wide as `AgentDetailHeaderTrailingControls` draws in the bar.
    private var barControlsWidth: CGFloat {
        guard surfaceSwitch != nil else { return Self.controlSize }
        return 2 * Self.capsuleButtonWidth + 2 * Self.capsuleInset
    }

    private var showsTitle: Bool { isExpanded || statusTitle != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingSlot
            if showsTitle, let title {
                titlePill(title)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Spacer(minLength: 0)
            }
            trailingControls
                .frame(width: showsTitle ? slotWidth : nil, alignment: .trailing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: {
            trailingSafeInset = $0
        }
        .padding(.leading, trailingSafeInset)
        .foregroundStyle(palette.foreground)
    }

    /// Back while expanded, on a slot as wide as the trailing controls.
    /// A folded header reserves an empty slot only while showing recovery.
    @ViewBuilder
    private var leadingSlot: some View {
        if isExpanded {
            if let onBack {
                AgentDetailHeaderButton("Back", systemImage: "chevron.left", action: onBack)
                    .headerGlass(in: .circle)
                    .frame(width: slotWidth, alignment: .leading)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Color.clear.frame(width: slotWidth)
            }
        } else if showsTitle {
            Color.clear.frame(width: slotWidth)
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if trailingInBar {
            if showsTitle {
                Color.clear.frame(width: slotWidth, height: Self.controlSize)
            }
        } else {
            AgentDetailHeaderTrailingControls(
                palette: palette, isExpanded: $isExpanded, actions: actions,
                surfaceSwitch: surfaceSwitch)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                trailingWidth = $0
            }
        }
    }

    /// Fills the room up to the trailing capsule, so the gaps on either side
    /// match, truncating the title at its end and the directory at its
    /// start, so the folder the Agent works in stays readable.
    private func titlePill(_ title: AgentDetailHeaderTitle) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if statusTitle != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.foreground)
                        .accessibilityHidden(true)
                }
                Text(statusTitle ?? title.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(title.harness)
                    .layoutPriority(1)
                if let directory = title.directory {
                    Text(verbatim: "·")
                        .layoutPriority(1)
                    Text(directory)
                        .truncationMode(.head)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.foreground.opacity(0.6))
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Self.controlSize, maxHeight: Self.controlSize)
        .headerGlass(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `AgentDetailHeader`'s trailing controls as an item of the detail
/// column's bar, beside Show Sidebar, for a header that shares the bar's
/// row. The item draws the header's own capsule, so it keeps the floating
/// header's size rather than the bar's wider item spacing.
struct AgentDetailHeaderBarControls: ToolbarContent {
    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    var actions: [AgentDetailHeaderAction] = []
    var surfaceSwitch: AgentDetailSurfaceSwitch?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            AgentDetailHeaderTrailingControls(
                palette: palette, isExpanded: $isExpanded, actions: actions,
                surfaceSwitch: surfaceSwitch)
        }
        .toolbarItemBackground(.hidden)
    }
}

/// The header's far end on its own glass: the surface button and the More
/// menu sharing a capsule, or the menu alone on a circle.
struct AgentDetailHeaderTrailingControls: View {
    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    let actions: [AgentDetailHeaderAction]
    let surfaceSwitch: AgentDetailSurfaceSwitch?

    /// A bar button's glyph size and weight, as Show Sidebar beside these
    /// draws it, so the symbols keep the balance SF Symbols gives them.
    static let glyphFont = Font.system(size: 17)

    var body: some View {
        if let surfaceSwitch {
            HStack(spacing: 0) {
                surfaceButton(surfaceSwitch)
                moreMenu(width: AgentDetailHeader.capsuleButtonWidth)
            }
            .padding(.horizontal, AgentDetailHeader.capsuleInset)
            .fixedSize()
            .headerGlass(in: .capsule)
            .foregroundStyle(palette.foreground)
        } else {
            moreMenu(width: AgentDetailHeader.controlSize)
                .headerGlass(in: .circle)
        }
    }

    @ViewBuilder
    private func glyph(_ glyph: AgentGlyph) -> some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name).font(Self.glyphFont)
        case .codeBubble:
            // Drawn the way `text.bubble` is, so the bar sizes both alike.
            Image(systemName: "bubble")
                .font(Self.glyphFont)
                .overlay { CodeBubbleMarks() }
        }
    }

    /// Swaps to the surface not showing, drawn with that surface's glyph.
    private func surfaceButton(_ control: AgentDetailSurfaceSwitch) -> some View {
        let target = control.other
        return Button {
            control.select(target)
        } label: {
            glyph(target.showGlyph)
                .frame(
                    width: AgentDetailHeader.capsuleButtonWidth,
                    height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.showTitle)
        .accessibilityHint(target.showAccessibilityHint)
    }

    /// Stays at the far end in both states: the screen's actions, then the
    /// item that folds or unfolds the header.
    private func moreMenu(width: CGFloat) -> some View {
        Menu {
            AgentDetailHeaderMenuItems(actions: actions, isExpanded: $isExpanded)
        } label: {
            Image(systemName: "ellipsis")
                .font(Self.glyphFont)
                .foregroundStyle(palette.foreground)
                .frame(width: width, height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        // Plain, or a bar pads the menu as one of its own buttons.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
    }
}

/// The More menu's items: the screen's actions, then the item that folds
/// or unfolds the header.
private struct AgentDetailHeaderMenuItems: View {
    let actions: [AgentDetailHeaderAction]
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(actions) { @Sendable action in
            MainActorContent {
                Button(action.title, systemImage: action.systemImage, action: action.perform)
            }
        }
        Button(
            isExpanded ? "Collapse" : "Expand",
            // A window's top bar, which is what this shows and hides: put
            // away while it is out, filled in while it is folded.
            systemImage: isExpanded
                ? "menubar.arrow.up.rectangle" : "inset.filled.topthird.rectangle"
        ) {
            withAnimation(reduceMotion ? nil : .snappy) {
                isExpanded.toggle()
            }
        }
    }
}

/// What `AgentDetailHeader` names: the Agent's task on the first line, and
/// its harness and directory on the second.
struct AgentDetailHeaderTitle: Equatable {
    let title: String
    let harness: String
    let directory: String?
}

extension AgentDetailHeaderTitle {
    /// The task title as the Console list shows it, the harness by its
    /// product name rather than a custom Agent name, and the launch
    /// directory with the Host account's home shortened to `~`.
    init(_ agent: ConsoleAgent) {
        self.init(
            title: AgentTerminalView.displayTitle(for: agent),
            harness: SupportedAgentKind(rawValue: agent.agent.kind)?.displayName
                ?? agent.agent.kind,
            directory: agent.displayCwd.isEmpty ? nil : agent.displayCwd)
    }
}

/// The surface an Agent detail shows, and how to swap it, for
/// `AgentDetailHeader`'s surface button. Main-actor isolated, and so
/// Sendable, for the same reason as `AgentDetailHeaderAction`.
@MainActor
struct AgentDetailSurfaceSwitch {
    let current: AgentDetailSurface
    let select: (AgentDetailSurface) -> Void

    /// The surface the header's button brings up.
    var other: AgentDetailSurface {
        switch current {
        case .chat: .terminal
        case .terminal: .chat
        }
    }
}

/// One of the actions in `AgentDetailHeader`'s More menu. Isolated to the
/// main actor, which makes it Sendable: the menu's `ForEach` content is
/// `@Sendable` and hands each action to `MainActorContent` (#471).
@MainActor
struct AgentDetailHeaderAction: Identifiable {
    let title: LocalizedStringKey
    let systemImage: String
    let perform: () -> Void

    nonisolated var id: String { systemImage }
}

/// An icon button inside `AgentDetailHeader`. It has no surface of its own:
/// the header puts it on a glass circle.
struct AgentDetailHeaderButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: AgentDetailHeader.controlSize, height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Puts `AgentDetailHeader`'s trailing controls in the bar while
    /// `isShown`, for a header made with `trailingInBar`.
    ///
    /// `onBack` puts Back in the bar as well, for a screen whose header
    /// leaves it out. On iPhone Duo the system draws the bar along the
    /// display's side, Back first, where the floating one would sit at the
    /// top across the screen from the bar.
    func detailHeaderBarControls(
        _ isShown: Bool,
        palette: TerminalThemePalette,
        isExpanded: Binding<Bool>,
        actions: [AgentDetailHeaderAction],
        surfaceSwitch: AgentDetailSurfaceSwitch? = nil,
        onBack: (() -> Void)? = nil
    ) -> some View {
        toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: onBack)
                }
            }
            if isShown {
                AgentDetailHeaderBarControls(
                    palette: palette, isExpanded: isExpanded, actions: actions,
                    surfaceSwitch: surfaceSwitch)
            }
        }
    }

    /// Publishes `usesVerticalToolbar` for the screens below, from the
    /// system's vertical bar edge where the SDK and system have one. Behind
    /// a compiler check while CI builds with Xcode 26.
    @ViewBuilder
    func readsVerticalToolbar() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            modifier(VerticalToolbarReader())
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Liquid Glass where the system has it, a blur before that. The glass
    /// sits behind the icons at part strength, so the output under the
    /// buttons still shows through while the icons stay solid. Chat's
    /// floating buttons share it at their own strength.
    func headerGlass(
        in shape: some Shape, opacity: Double = AgentDetailHeader.glassOpacity
    ) -> some View {
        background {
            Group {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .opacity(opacity)
        }
        .contentShape(shape)
    }
}

extension EnvironmentValues {
    /// Whether the system draws this screen's bars along the display's side,
    /// as iPhone Duo does on its outer display and on its inner one in
    /// landscape. A detail's Back then moves from its floating header into
    /// the bar.
    @Entry var usesVerticalToolbar = false
}

#if compiler(>=6.4)
@available(iOS 27.1, *)
private struct VerticalToolbarReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
        content.environment(\.usesVerticalToolbar, toolbarVerticalEdge != nil)
    }
}
#endif
