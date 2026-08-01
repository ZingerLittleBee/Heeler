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

/// The switcher row: a horizontally scrolling strip of Agent chips. It sits
/// above the input row inside the keyboard accessory, so switching Agents
/// never costs a trip back to the Console.
@MainActor
final class TerminalAgentSwitcherBar: UIView {
    var onSelect: (@MainActor (ConsoleAgent.ID) -> Void)?

    /// The strip as it currently reads, in order.
    private(set) var chips: [TerminalAgentChip] = []

    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private var items: [TerminalAgentSwitcherItem] = []
    private var selectedID: ConsoleAgent.ID?

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
            scrollToSelection(animated: window != nil)
        }
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

    private func scrollToSelection(animated: Bool) {
        guard let selectedID,
              let chip = chips.first(where: { $0.id == selectedID })
        else { return }
        layoutIfNeeded()
        scrollView.scrollRectToVisible(
            chip.frame.insetBy(dx: -TerminalAgentChip.spacing, dy: 0), animated: animated)
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
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
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
            row.heightAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
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
        // Leaving the window strips layer animations, and the accessory leaves
        // it every time the keyboard goes down.
        if window != nil {
            updatePulse()
        }
    }

    func apply(_ item: TerminalAgentSwitcherItem, selected: Bool) {
        isSelected = selected
        label.text = item.title
        label.textColor = selected ? .label : .secondaryLabel
        dot.backgroundColor = item.status.tintUIColor
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
