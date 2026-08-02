import SwiftUI
import UIKit

/// The panes of the Keys keyboard. Controls comes first and is selected by
/// default: it is everything Keys mode used to be, and gaining two neighbours
/// should not cost the old behaviour an extra tap.
enum TerminalKeysTab: Int, CaseIterable, Identifiable {
    case controls
    case snippets
    case skills
    case appearance

    var id: Self { self }

    var systemImageName: String {
        switch self {
        case .controls: "square.grid.3x3"
        // Not `curlybraces`: that says "code snippet", and these are phrases.
        case .snippets: "quote.bubble"
        case .skills: "sparkles"
        case .appearance: "paintpalette"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .controls: "Control Keys"
        case .snippets: "Snippets"
        case .skills: "Skills"
        case .appearance: "Terminal Appearance"
        }
    }
}

/// What the Skills pane needs from the screen: the store that probes and
/// caches the agent's skills. Only agents of a kind with a skills source
/// catalog get one; the tab is hidden otherwise.
@MainActor
struct TerminalSkillsContext {
    let store: SkillsPaneStore
}

/// What the Keys keyboard needs from the app to fill its Snippets, Skills,
/// and Appearance panes. A terminal built without one — a preview, a test —
/// shows the control keys alone rather than empty tabs.
@MainActor
struct TerminalKeysContext {
    let settings: TerminalSettings
    /// Nil hides the Skills tab: the agent's kind has no skills mechanism
    /// this app knows how to probe.
    let skills: TerminalSkillsContext?
    /// Opens the Snippets management surface. That means leaving the keyboard,
    /// so the screen owns the presentation and the keyboard only asks.
    let manageSnippets: () -> Void

    init(
        settings: TerminalSettings,
        skills: TerminalSkillsContext? = nil,
        manageSnippets: @escaping () -> Void
    ) {
        self.settings = settings
        self.skills = skills
        self.manageSnippets = manageSnippets
    }
}

/// The Keys keyboard: one pane at a time above a row of icon tabs.
final class TerminalKeysKeyboardView: UIInputView, UIInputViewAudioFeedback {
    static let defaultHeight: CGFloat = 224
    static let tabBarHeight: CGFloat = 44

    private weak var terminalView: HerdrTerminalView?
    private let keyboardHeight: CGFloat
    private let context: TerminalKeysContext?
    /// The panes laid out side by side, one keyboard wide each. Tapping a tab
    /// and swiping across the content are then the same move — a page change —
    /// rather than two mechanisms that have to be kept in agreement. Not
    /// private: tests read where the content area stands.
    let pager: UIScrollView = TerminalKeysPagerView()
    private let pages = UIStackView()
    private var pageViews: [TerminalKeysTab: UIView] = [:]
    private lazy var tabBar = TerminalKeysTabBar(tabs: tabs) { [weak self] tab in
        self?.select(tab)
    }
    private var controlPad: TerminalControlPadView?
    /// Held strongly: nothing else owns them, and their views live in the
    /// keyboard window rather than in a view controller's hierarchy.
    private var paneHosts: [TerminalKeysTab: UIHostingController<AnyView>] = [:]
    /// The width the page offset was last computed against. `contentOffset` is
    /// in points, so a resize silently leaves the pager between two panes.
    private var laidOutPagerWidth: CGFloat = 0
    private(set) var selectedTab: TerminalKeysTab = .controls

    var enableInputClicksWhenVisible: Bool { true }

    private var tabs: [TerminalKeysTab] {
        guard let context else { return [.controls] }
        return TerminalKeysTab.allCases.filter {
            $0 != .skills || context.skills != nil
        }
    }

    init(
        frame: CGRect,
        keyboardHeight: CGFloat,
        terminalView: HerdrTerminalView,
        context: TerminalKeysContext?
    ) {
        self.terminalView = terminalView
        self.keyboardHeight = keyboardHeight
        self.context = context
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .systemBackground
        configureLayout()
        select(.controls)
        localInputEnabledDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard pager.bounds.width != laidOutPagerWidth else { return }
        laidOutPagerWidth = pager.bounds.width
        scrollToSelectedPage(animated: false)
    }

    /// Called after a Snippet is sent. The user's next move is almost always
    /// Enter, which lives on the control pad.
    func returnToControls() {
        select(.controls)
    }

    private func configureLayout() {
        pager.translatesAutoresizingMaskIntoConstraints = false
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        // The keys want their highlight the instant they are touched; the pager
        // takes the touch away again if the finger turns out to be swiping.
        pager.delaysContentTouches = false
        pager.delegate = self
        pages.axis = .horizontal
        pages.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        pager.addSubview(pages)
        addSubview(pager)
        addSubview(tabBar)

        let content = pager.contentLayoutGuide
        let frame = pager.frameLayoutGuide

        for tab in tabs {
            let page = makePage(for: tab)
            pageViews[tab] = page
            pages.addArrangedSubview(page)
            // Each pane exactly one keyboard wide: what paging needs to land on
            // a pane boundary. Sized one by one rather than as a multiple of the
            // whole row, which the layout engine solves a hair short.
            page.widthAnchor.constraint(equalTo: frame.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            pager.topAnchor.constraint(equalTo: topAnchor),
            pager.leadingAnchor.constraint(equalTo: leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: tabBar.topAnchor),

            pages.topAnchor.constraint(equalTo: content.topAnchor),
            pages.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pages.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pages.heightAnchor.constraint(equalTo: frame.heightAnchor),

            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
            tabBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    /// Switches panes. A tab the keyboard was not built with — Snippets on a
    /// terminal with no context — is ignored rather than shown empty.
    func select(_ tab: TerminalKeysTab) {
        guard tabs.contains(tab) else { return }
        applySelection(tab)
        // Off screen there is no animation to watch, and a test that renders
        // the keyboard immediately after would catch it mid-flight.
        scrollToSelectedPage(animated: window != nil)
    }

    /// The selection itself, without moving the pager: a drag has already moved
    /// it, and animating back to where the finger is would fight the gesture.
    private func applySelection(_ tab: TerminalKeysTab) {
        selectedTab = tab
        tabBar.select(tab)
        // VoiceOver would otherwise walk straight from the last control key
        // into the Snippets list sitting off screen beside it.
        for (candidate, page) in pageViews {
            page.accessibilityElementsHidden = candidate != tab
        }
    }

    private func scrollToSelectedPage(animated: Bool) {
        guard let index = tabs.firstIndex(of: selectedTab), pager.bounds.width > 0 else { return }
        let offset = CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0)
        guard pager.contentOffset != offset else { return }
        pager.setContentOffset(offset, animated: animated)
    }

    private func makePage(for tab: TerminalKeysTab) -> UIView {
        switch tab {
        case .controls:
            guard let terminalView else { return UIView() }
            let pad = TerminalControlPadView(terminalView: terminalView)
            controlPad = pad
            return pad
        case .snippets, .skills, .appearance:
            guard let context else { return UIView() }
            let host = UIHostingController(
                rootView: AnyView(paneContent(for: tab, context: context)))
            host.view.backgroundColor = .clear
            // Not a child view controller: the input view lives in the keyboard
            // window, not in the screen's hierarchy, so containment would claim
            // a parent relationship that isn't true. The strong reference above
            // is what keeps it alive.
            paneHosts[tab] = host
            return host.view
        }
    }

    @ViewBuilder
    private func paneContent(
        for tab: TerminalKeysTab,
        context: TerminalKeysContext
    ) -> some View {
        switch tab {
        case .snippets:
            SnippetsKeyboardPane(
                store: context.settings.snippets,
                onSend: { [weak self] snippet in
                    guard let self, let terminalView else { return }
                    UIDevice.current.playInputClick()
                    terminalView.sendSnippet(snippet)
                    returnToControls()
                },
                onManage: context.manageSnippets)
        case .skills:
            if let skills = context.skills {
                SkillsKeyboardPane(
                    store: skills.store,
                    onInsert: { [weak self] skill in
                        guard let self, let terminalView else { return }
                        UIDevice.current.playInputClick()
                        terminalView.sendInsertedText(skill.insertionText)
                        returnToControls()
                    })
            }
        case .appearance:
            TerminalAppearancePane(
                themes: context.settings.themes,
                zoom: context.settings.zoom,
                fonts: context.settings.fonts)
        case .controls:
            EmptyView()
        }
    }

    /// Appearance is not input, so it stays usable while Attach is paused for
    /// an image upload. The control keys and Snippets do not.
    func localInputEnabledDidChange() {
        let isEnabled = terminalView?.isLocalInputEnabled ?? true
        let inputPanes = [
            controlPad, paneHosts[.snippets]?.view, paneHosts[.skills]?.view,
        ]
        for pane in inputPanes.compactMap({ $0 }) {
            pane.isUserInteractionEnabled = isEnabled
            pane.alpha = isEnabled ? 1 : 0.5
        }
    }
}

extension TerminalKeysKeyboardView: UIScrollViewDelegate {
    /// The tab bar follows the finger rather than the settled page: a pane
    /// dragged halfway in with the old tab still lit reads as a stuck UI.
    ///
    /// Only while a finger is involved. A programmatic scroll already knows its
    /// tab, and a resize hands out offsets measured against the old width.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating,
              let tab = tab(
                  nearestTo: scrollView.contentOffset.x, pageWidth: scrollView.bounds.width),
              tab != selectedTab
        else { return }
        applySelection(tab)
    }

    /// Which pane a horizontal offset has landed on. UIKit owns the drag; this
    /// mapping is the part of the swipe that is ours.
    func tab(nearestTo offsetX: CGFloat, pageWidth: CGFloat) -> TerminalKeysTab? {
        guard pageWidth > 0 else { return nil }
        let index = Int((offsetX / pageWidth).rounded())
        return tabs.indices.contains(index) ? tabs[index] : nil
    }
}

/// The pane pager, which takes its touches back from the keys.
/// `UIScrollView` refuses by default to cancel a touch that landed on a
/// `UIControl`, which would leave a control key held — and repeating — for the
/// length of a swipe across the pad.
private final class TerminalKeysPagerView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// The icon row along the bottom. Selection is a filled capsule behind the
/// glyph, the same shape iOS uses for a selected segment.
final class TerminalKeysTabBar: UIView {
    private let onSelect: (TerminalKeysTab) -> Void
    private var buttons: [TerminalKeysTab: UIButton] = [:]

    init(tabs: [TerminalKeysTab], onSelect: @escaping (TerminalKeysTab) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)

        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        addSubview(row)

        for tab in tabs {
            let button = makeButton(for: tab)
            buttons[tab] = button
            row.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UITraitCollection.current.displayScale),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func select(_ tab: TerminalKeysTab) {
        for (candidate, button) in buttons {
            let isSelected = candidate == tab
            button.configuration?.baseBackgroundColor =
                isSelected ? .secondarySystemFill : .clear
            button.configuration?.baseForegroundColor = isSelected ? .tintColor : .secondaryLabel
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        }
    }

    private func makeButton(for tab: TerminalKeysTab) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: tab.systemImageName,
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = .secondaryLabel

        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = tab.accessibilityLabel
        button.addAction(UIAction { [weak self] _ in self?.onSelect(tab) }, for: .touchUpInside)
        return button
    }
}
