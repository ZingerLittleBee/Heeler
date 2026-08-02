import SwiftUI
import UIKit

/// One chip in the keyboard's Agent switcher: the label it shows and the
/// status its dot carries.
struct TerminalAgentSwitcherItem: Equatable, Sendable {
    let id: ConsoleAgent.ID
    let title: String
    let status: AgentStatus
}

/// What the terminal screen hands its keyboard accessory: the Agents to
/// offer, the one currently on screen, and where a tap goes.
struct TerminalAgentSwitcher {
    var items: [TerminalAgentSwitcherItem]
    var selectedID: ConsoleAgent.ID?
    var onSelect: @MainActor (ConsoleAgent.ID) -> Void
}

/// Carries the user's "I am still typing" intent across the terminal teardown
/// an Agent switch forces. Deliberately not observable: arming it must not
/// invalidate the SwiftUI view that is about to be replaced anyway, and the
/// new terminal has to read the intent before its first layout.
@MainActor
final class TerminalKeyboardHandoff {
    private var armedID: ConsoleAgent.ID?

    func arm(for id: ConsoleAgent.ID) {
        armedID = id
    }

    /// Reads and clears the intent — a handoff is good for exactly one screen,
    /// so a later push from the Agent list starts with the keyboard down.
    func consume(_ id: ConsoleAgent.ID) -> Bool {
        guard armedID == id else { return false }
        armedID = nil
        return true
    }
}

/// The switcher row: a horizontally scrolling strip of Agent chips, resting
/// on the terminal's bottom edge so switching Agents never costs a trip back
/// to the Console.
///
/// It rides the terminal rather than the keyboard accessory on purpose: an
/// Agent is worth switching to whether or not the user is typing, and living
/// on the keyboard meant UIKit tore the strip down and rebuilt it — losing its
/// scroll position — every time the keyboard moved.
@MainActor
final class TerminalAgentSwitcherBar: UIView, UIScrollViewDelegate {
    /// Short on purpose: every point it takes is one the terminal loses.
    static let preferredHeight: CGFloat = 40

    var onSelect: (@MainActor (ConsoleAgent.ID) -> Void)?

    /// The strip as it currently reads, in order.
    private(set) var chips: [TerminalAgentChip] = []

    /// Gutter between the strip's ends and the first and last chip.
    private static let rowInset: CGFloat = 8

    private let scrollView = StripScrollView()
    private let row = UIStackView()
    private var items: [TerminalAgentSwitcherItem] = []
    private var selectedID: ConsoleAgent.ID?
    private var scrollsToSelectionOnLayout = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureScrollView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(items: [TerminalAgentSwitcherItem], selectedID: ConsoleAgent.ID?) {
        guard items != self.items || selectedID != self.selectedID else { return }
        let selectionChanged = selectedID != self.selectedID
        self.items = items
        self.selectedID = selectedID

        // Chips are reused by Agent identity so a status change does not
        // restart the Working dot's pulse or throw away the scroll offset.
        var reusable = Dictionary(chips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [TerminalAgentChip] = []
        for item in items {
            let chip = reusable.removeValue(forKey: item.id) ?? makeChip(id: item.id)
            chip.apply(item, selected: item.id == selectedID)
            ordered.append(chip)
        }
        for stale in reusable.values {
            row.removeArrangedSubview(stale)
            stale.removeFromSuperview()
        }
        for (index, chip) in ordered.enumerated()
        where row.arrangedSubviews.firstIndex(of: chip) != index {
            row.insertArrangedSubview(chip, at: index)
        }
        chips = ordered

        if selectionChanged {
            scrollsToSelectionOnLayout = true
            setNeedsLayout()
        }
    }

    /// An Agent switch builds a whole new terminal, so the strip that comes
    /// back starts at offset zero — with the chip the user just picked off
    /// screen if the list is long. The strip is measured over several passes
    /// (no width at all on the first update, chip widths later still), so
    /// rather than firing once, it keeps the open Agent in view on every
    /// layout until the user scrolls it themselves.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard scrollsToSelectionOnLayout,
              let selectedID,
              let chip = chips.first(where: { $0.id == selectedID })
        else { return }
        // The chips lay out inside the row's own pass, and they have no frame
        // to scroll to until that has run.
        row.setNeedsLayout()
        row.layoutIfNeeded()
        let visibleWidth = scrollView.bounds.width
        let contentWidth = scrollView.contentSize.width
        let chipFrame = chip.convert(chip.bounds, to: scrollView)
        // A content width the scroll view has not published yet means the row
        // is still short of its chips: mid-pass the open Agent looks like it
        // fits when it does not. Stay armed and wait for the real measure.
        guard visibleWidth > 0, contentWidth > 0, chipFrame.width > 0 else { return }

        // Scrolled by hand rather than with `scrollRectToVisible`: that one is
        // a no-op mid-layout, which is exactly when the strip needs it. Move
        // the least that brings the chip and its gutter fully into view, so a
        // chip already on screen does not shift under the user.
        let leading = chipFrame.minX - TerminalAgentChip.spacing
        let trailing = chipFrame.maxX + TerminalAgentChip.spacing
        var offsetX = scrollView.contentOffset.x
        if trailing > offsetX + visibleWidth {
            offsetX = trailing - visibleWidth
        }
        if leading < offsetX {
            offsetX = leading
        }
        offsetX = min(max(offsetX, 0), max(contentWidth - visibleWidth, 0))
        guard offsetX != scrollView.contentOffset.x else { return }
        scrollView.contentOffset.x = offsetX
    }

    /// An Agent switch rebuilds the screen around the strip, which comes back
    /// at its start.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsLayout()
        }
    }

    /// The user looking around the strip outranks keeping the open Agent in
    /// view; the next switch arms it again.
    func scrollViewWillBeginDragging(_: UIScrollView) {
        scrollsToSelectionOnLayout = false
    }

    /// A scroll position the user did not ask for — UIKit clamping the strip
    /// against a content size it has only just published. Bounds do not change
    /// for that, so this is the only signal that the open Agent may have slid
    /// off screen.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollsToSelectionOnLayout,
              !scrollView.isDragging, !scrollView.isDecelerating
        else { return }
        setNeedsLayout()
    }

    private func makeChip(id: ConsoleAgent.ID) -> TerminalAgentChip {
        let chip = TerminalAgentChip(id: id)
        chip.addTarget(self, action: #selector(chipTapped), for: .touchUpInside)
        return chip
    }

    @objc private func chipTapped(_ chip: TerminalAgentChip) {
        guard chip.id != selectedID else { return }
        onSelect?(chip.id)
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        // The strip is measured over several passes and its content width is
        // published last, so that is when the open Agent's position is finally
        // worth reading.
        scrollView.onContentWidthChange = { [weak self] in self?.setNeedsLayout() }
        addSubview(scrollView)

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = TerminalAgentChip.spacing
        scrollView.addSubview(row)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Self.rowInset),
            row.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Self.rowInset),
            row.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
            row.heightAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }
}

/// A scroll view that says when its content width lands. Nothing else
/// announces the pass that finally sizes the strip, and the bounds do not
/// change for it, so no layout would otherwise be asked for.
private final class StripScrollView: UIScrollView {
    var onContentWidthChange: (() -> Void)?

    override var contentSize: CGSize {
        didSet {
            guard contentSize.width != oldValue.width else { return }
            onContentWidthChange?()
        }
    }
}

/// One Agent chip: a status dot and a label in a capsule, filled when it is
/// the Agent on screen.
final class TerminalAgentChip: UIControl {
    static let spacing: CGFloat = 6
    private static let height: CGFloat = 28
    private static let maximumWidth: CGFloat = 148
    private static let dotSize: CGFloat = 8
    private static let pulseKey = "herdr.agentChip.pulse"

    let id: ConsoleAgent.ID
    var title: String? { label.text }
    /// Whether the Working dot is animating. Reads the layer, so it also
    /// answers "did leaving the window strip the animation?".
    var isPulsing: Bool { dot.layer.animation(forKey: Self.pulseKey) != nil }

    private let dot = UIView()
    private let label = UILabel()
    private var isWorking = false

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    init(id: ConsoleAgent.ID) {
        self.id = id
        super.init(frame: .zero)
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Leaving the window strips layer animations.
        if window != nil {
            updatePulse()
        }
    }

    func apply(_ item: TerminalAgentSwitcherItem, selected: Bool) {
        isSelected = selected
        label.text = item.title
        label.textColor = selected ? .label : .secondaryLabel
        dot.backgroundColor = item.status.inkUIColor
        backgroundColor = selected ? .tertiarySystemBackground : .clear
        isWorking = item.status == .working
        updatePulse()

        accessibilityLabel = item.title
        accessibilityValue = item.status.rawValue.capitalized
        accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityHint = selected ? nil : "Switches this terminal to that Agent"
    }

    private func configureContent() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous
        isAccessibilityElement = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = Self.dotSize / 2

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = UIStackView(arrangedSubviews: [dot, label])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Self.spacing
        content.isUserInteractionEnabled = false
        addSubview(content)

        let width = widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth)
        width.priority = .required
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            width,
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Working is the one status worth animating: a still dot cannot tell a
    /// busy Agent from an idle one at a glance.
    private func updatePulse() {
        guard isWorking, !UIAccessibility.isReduceMotionEnabled else {
            dot.layer.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard dot.layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer.add(pulse, forKey: Self.pulseKey)
    }
}

/// The resident Agent strip, as the terminal screen mounts it: the chips over
/// the keyboard's own fill, with the keyboard toggle pinned at the trailing
/// edge — outside the scroll view, so the one control that summons the
/// keyboard back can never scroll out of reach.
struct TerminalAgentSwitcherRow: View {
    let switcher: TerminalAgentSwitcher
    let isKeyboardUp: Bool
    let toggleKeyboard: () -> Void
    /// Matches `UIPasteControl`'s fixed glyph size in the row below, or the
    /// two read as icons borrowed from different sets.
    private static let glyphPointSize: CGFloat = 12
    @Environment(\.displayScale) private var displayScale

    private var hairline: CGFloat { 1 / max(displayScale, 1) }

    var body: some View {
        HStack(spacing: 0) {
            StripRepresentable(switcher: switcher)
            // Fences the pinned button off from the strip, so the chips read
            // as a list that ends rather than as one the button belongs to.
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: hairline, height: 20)
            Button(action: toggleKeyboard) {
                Image(
                    systemName: isKeyboardUp
                        ? "keyboard.chevron.compact.down" : "keyboard"
                )
                .font(.system(size: Self.glyphPointSize))
                .foregroundStyle(Color(uiColor: .label))
                .frame(width: 44, height: TerminalAgentSwitcherBar.preferredHeight)
                .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isKeyboardUp ? "Dismiss keyboard" : "Show keyboard")
            .padding(.trailing, 8)
        }
        .frame(height: TerminalAgentSwitcherBar.preferredHeight)
        .background(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: hairline)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private struct StripRepresentable: UIViewRepresentable {
        let switcher: TerminalAgentSwitcher

        func makeUIView(context _: Context) -> TerminalAgentSwitcherBar {
            TerminalAgentSwitcherBar()
        }

        /// The strip is a scroll view whose content is as wide as its chips,
        /// so measured by its own constraints it asks for the entire list.
        /// SwiftUI would lay the row out against that and push the pinned
        /// toggle off the screen. The strip takes the width it is offered; the
        /// chips scroll inside it, which is the whole point of a strip.
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView _: TerminalAgentSwitcherBar,
            context _: Context
        ) -> CGSize? {
            CGSize(
                width: proposal.width ?? 0,
                height: TerminalAgentSwitcherBar.preferredHeight)
        }

        func updateUIView(_ bar: TerminalAgentSwitcherBar, context _: Context) {
            bar.onSelect = switcher.onSelect
            bar.update(items: switcher.items, selectedID: switcher.selectedID)
        }
    }
}
