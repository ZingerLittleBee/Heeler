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
    private let contentContainer = UIView()
    private lazy var tabBar = TerminalKeysTabBar(tabs: tabs) { [weak self] tab in
        self?.select(tab)
    }
    private var controlPad: TerminalControlPadView?
    /// Held strongly: nothing else owns it, and its view lives in the keyboard
    /// window rather than in a view controller's hierarchy.
    private var paneHost: UIHostingController<AnyView>?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight)
    }

    /// Called after a Snippet is sent. The user's next move is almost always
    /// Enter, which lives on the control pad.
    func returnToControls() {
        select(.controls)
    }

    private func configureLayout() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        addSubview(tabBar)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),

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
        selectedTab = tab
        tabBar.select(tab)

        controlPad?.isHidden = tab != .controls
        paneHost?.view.isHidden = tab == .controls

        switch tab {
        case .controls:
            installControlPadIfNeeded()
        case .snippets, .skills, .appearance:
            installPane(for: tab)
        }
        localInputEnabledDidChange()
    }

    private func installControlPadIfNeeded() {
        guard controlPad == nil, let terminalView else { return }
        let pad = TerminalControlPadView(terminalView: terminalView)
        pad.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            pad.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pad.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            pad.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        controlPad = pad
    }

    private func installPane(for tab: TerminalKeysTab) {
        guard let context else { return }
        let root = AnyView(paneContent(for: tab, context: context))
        if let paneHost {
            paneHost.rootView = root
            paneHost.view.isHidden = false
            return
        }

        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // Not a child view controller: the input view lives in the keyboard
        // window, not in the screen's hierarchy, so containment would claim a
        // parent relationship that isn't true. The strong reference above is
        // what keeps it alive.
        contentContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        paneHost = host
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
        controlPad?.isUserInteractionEnabled = isEnabled
        controlPad?.alpha = isEnabled ? 1 : 0.5

        let paneSendsInput = selectedTab == .snippets || selectedTab == .skills
        paneHost?.view.isUserInteractionEnabled = isEnabled || !paneSendsInput
        paneHost?.view.alpha = (paneSendsInput && !isEnabled) ? 0.5 : 1
    }
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
