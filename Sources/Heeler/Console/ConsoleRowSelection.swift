import SwiftUI
import UIKit

/// How the Console's sidebar lists show the row on stage beside them.
///
/// `List(selection:)` would paint the system selection: a full-width band
/// in the tint, which is system blue while the list has keyboard focus, and
/// it flips the row's hierarchical text to white. Neither suits a list set
/// beside a terminal, so the sidebar draws the app's own quiet selection,
/// the same neutral fill the terminal drawer uses, inside the row's shape.
enum ConsoleRowSelection {
    static let fill = Color(uiColor: .tertiarySystemFill)
}

/// A rounded, inset fill behind a selected sidebar row; nothing elsewhere.
/// Compact width keeps no persistent selection, so the list's own press
/// highlight is left alone there.
struct ConsoleRowSelectionBackground: ViewModifier {
    let isSelected: Bool
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        if isSidebarColumn {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            content.listRowBackground(
                shape
                    .fill(isSelected ? ConsoleRowSelection.fill : Color.clear)
                    .background(ListRowFocusHalo(shape: shape))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3))
        } else {
            content
        }
    }
}

/// Keeps a sidebar row's text in its normal colors while selected: the list
/// raises a selected row's background prominence, which turns hierarchical
/// styles such as the Host name's `.secondary` white.
struct ConsoleRowSelectionContent: ViewModifier {
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        if isSidebarColumn {
            content
                .environment(\.backgroundProminence, .standard)
                .foregroundStyle(Color.primary)
        } else {
            content
        }
    }
}

/// The ring a hardware keyboard's focus draws around a sidebar row takes
/// the list's tint; neutral, it frames the selection instead of shouting
/// system blue beside the terminal.
struct ConsoleSidebarListTint: ViewModifier {
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        content.tint(isSidebarColumn ? Color(uiColor: .systemGray) : nil)
    }
}

/// Fits a plain list row's keyboard focus ring to `shape`, drawn where this
/// view sits in the row's background. A plain list rings the whole cell, a
/// square band across the sidebar around the rounded, inset row it frames.
struct ListRowFocusHalo<S: Shape>: UIViewRepresentable {
    let shape: S

    func makeUIView(context: Context) -> ListRowFocusHaloView {
        ListRowFocusHaloView()
    }

    func updateUIView(_ view: ListRowFocusHaloView, context: Context) {
        let shape = shape
        view.outline = .shape { shape.path(in: $0).cgPath }
    }
}

/// Fits a grouped list row's keyboard focus ring to the corners its card
/// rounds on the cell. The cell's own ring has a small radius of its own,
/// so on a card's first and last rows it overhangs the card's corners.
struct ListRowCellFocusHalo: UIViewRepresentable {
    func makeUIView(context: Context) -> ListRowFocusHaloView {
        ListRowFocusHaloView()
    }

    func updateUIView(_ view: ListRowFocusHaloView, context: Context) {
        view.outline = .cellCorners
    }
}

final class ListRowFocusHaloView: UIView {
    enum Outline {
        /// A shape laid out in this view's bounds.
        case shape((CGRect) -> CGPath)
        /// The corners the cell's section rounds.
        case cellCorners
    }

    var outline: Outline? {
        didSet { setNeedsLayout() }
    }

    /// The cell this view shaped, and the effect it set there.
    private weak var shapedCell: UICollectionViewCell?
    private weak var shapedEffect: UIFocusEffect?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseHalo()
        } else {
            applyHalo()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyHalo()
    }

    private var cell: UICollectionViewCell? {
        var view = superview
        while let current = view {
            if let cell = current as? UICollectionViewCell { return cell }
            view = current.superview
        }
        return nil
    }

    /// The halo takes the cell's coordinate space.
    private func applyHalo() {
        guard window != nil, let outline, let cell, !bounds.isEmpty else { return }
        let frame = convert(bounds, to: cell)
        let path: CGPath
        switch outline {
        case .shape(let makePath):
            var transform = CGAffineTransform(translationX: frame.minX, y: frame.minY)
            guard
                let placed = makePath(CGRect(origin: .zero, size: frame.size))
                    .copy(using: &transform)
            else { return }
            path = placed
        case .cellCorners:
            path = Self.cornerPath(of: cell, in: frame)
        }
        if shapedCell !== cell { releaseHalo() }
        let effect = UIFocusHaloEffect(path: UIBezierPath(cgPath: path))
        cell.focusEffect = effect
        shapedCell = cell
        shapedEffect = effect
    }

    /// Hands the cell back to the system's ring, which UIKit fits to
    /// whatever row the cell holds next each time it draws. Only while the
    /// cell still has this view's halo: a row arriving in a reused cell can
    /// shape it before the leaving row lets go.
    private func releaseHalo() {
        if let shapedCell, let shapedEffect, shapedCell.focusEffect === shapedEffect {
            shapedCell.focusEffect = UIFocusEffect()
        }
        shapedCell = nil
        shapedEffect = nil
    }

    /// `rect` with the cell's corners. An inset grouped list rounds a
    /// card's first and last rows through the cell's corner configuration
    /// (read here in layout, so UIKit lays this view out again when the
    /// cell's corners change), and before iOS 26 through its layer.
    private static func cornerPath(of cell: UICollectionViewCell, in rect: CGRect) -> CGPath {
        func radius(_ corner: UIRectCorner, _ mask: CACornerMask) -> CGFloat {
            if #available(iOS 26.0, *) { return cell.effectiveRadius(corner: corner) }
            return cell.layer.maskedCorners.contains(mask) ? cell.layer.cornerRadius : 0
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: radius(.topLeft, .layerMinXMinYCorner),
            bottomLeadingRadius: radius(.bottomLeft, .layerMinXMaxYCorner),
            bottomTrailingRadius: radius(.bottomRight, .layerMaxXMaxYCorner),
            topTrailingRadius: radius(.topRight, .layerMaxXMinYCorner),
            style: .continuous
        ).path(in: rect).cgPath
    }
}

/// A sidebar row's context menu. Lifting the list cell shows what the cell
/// is beside the terminal: a clear background, so the row's text floats
/// over the glass and past the sidebar's edge. The sidebar lifts a card of
/// the row instead; compact width keeps the system's lifted row, unless the
/// row draws its own card inside a wider cell (`liftsCard`).
struct ConsoleRowContextMenu<MenuItems: View, Preview: View>: ViewModifier {
    private let liftsCard: Bool
    private let menuItems: MenuItems
    private let preview: Preview
    @Environment(\.isSidebarColumn) private var isSidebarColumn
    @State private var rowWidth: CGFloat?

    init(
        liftsCard: Bool = false,
        @ViewBuilder menuItems: () -> MenuItems,
        @ViewBuilder preview: () -> Preview
    ) {
        self.liftsCard = liftsCard
        self.menuItems = menuItems()
        self.preview = preview()
    }

    func body(content: Content) -> some View {
        if isSidebarColumn || liftsCard {
            content
                // Measured from a background: reading the row's own
                // geometry drops the list-row background and focus halo
                // an Agent row carries.
                .background {
                    Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        rowWidth = $0
                    }
                }
                .contextMenu {
                    menuItems
                } preview: {
                    preview
                        .padding(.horizontal, ConsoleRowLift.padding)
                        .padding(.vertical, 12)
                        // Narrower when it must be: the system caps a
                        // preview's width, and a fixed frame past the cap
                        // would clip the row's ends.
                        .frame(
                            idealWidth: ConsoleRowLift.cardWidth(rowWidth: rowWidth),
                            maxWidth: ConsoleRowLift.cardWidth(rowWidth: rowWidth),
                            alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
        } else {
            content.contextMenu { menuItems }
        }
    }
}

/// The card a row lifts: its content, at the row's width, inset as a card
/// insets its rows, so the lifted card is the resting one up to the widest
/// preview the system allows (about 344pt on an iPad in landscape).
enum ConsoleRowLift {
    static let padding: CGFloat = 16
    /// Until the row has been measured, the card of a sidebar at its ideal
    /// width.
    static let fallbackWidth: CGFloat = 340

    static func cardWidth(rowWidth: CGFloat?) -> CGFloat {
        guard let rowWidth, rowWidth > 0 else { return fallbackWidth }
        return rowWidth + 2 * padding
    }
}
