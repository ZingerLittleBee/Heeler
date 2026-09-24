import SwiftUI
import UIKit

/// Cohesive seam between Agent detail and Direct Input chrome. Groups the
/// live presentation gates from the interaction handlers so call sites pass
/// one typed model instead of a flat fourteen-argument surface.
@MainActor
struct AgentDirectInputChromeContext {
    struct Presentation {
        let status: AgentStatus
        let hostTelemetry: HostTelemetryPresentation?
        let chromeColorScheme: ColorScheme
        /// Ghostty first-responder / tools intent for the switcher toggle glyph.
        let isKeyboardUp: Bool
        let isToolsKeyboardPresented: Bool
    }

    struct Interactions {
        /// Switcher `onSelect` is the screen's switch, the sole production
        /// owner of Direct Input keyboard-claim arming.
        let switcher: TerminalAgentSwitcher
        /// What More offers: the row's Agent actions.
        let actions: AgentComposerActions
        let toggleKeyboard: () -> Void
        let switchKeyboard: (() -> Void)?
        let sendQuickKey: (AgentQuickKey) -> Void
        let paste: (String) -> Void
        let showComposer: () -> Void
        /// Routes More / Add actions that own the draft: restore Composer first.
        let restoreComposerThen: (@escaping () -> Void) -> Void
    }

    let presentation: Presentation
    let interactions: Interactions
}

/// Compact Direct Input chrome for Agent detail (an Agent's or a shell row's):
/// status, a persistent shortcut row, and the switcher.
/// Bottom-up order: system keyboard, switcher, shortcut row, status. The
/// shortcut row sits immediately above the persistent Agent strip. App content
/// rather than a keyboard accessory, so UIKit's candidate-row teardown cannot
/// tear it down or leave a hollow gap.
struct AgentDirectInputChrome: View {
    let context: AgentDirectInputChromeContext
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    private let strip = InputShortcutStripPresentation()

    private var presentation: AgentDirectInputChromeContext.Presentation {
        context.presentation
    }

    private var interactions: AgentDirectInputChromeContext.Interactions {
        context.interactions
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                AgentDetailStatusChrome(
                    status: presentation.status,
                    hostTelemetry: presentation.hostTelemetry,
                    chromeColorScheme: presentation.chromeColorScheme)

                // Immediately above the Agent list/switcher strip. Keyboard
                // show/hide stays on the switcher row — not duplicated here.
                shortcutRow

                TerminalAgentSwitcherRow(
                    switcher: interactions.switcher,
                    isKeyboardUp: presentation.isKeyboardUp,
                    toggleKeyboard: interactions.toggleKeyboard,
                    isToolsKeyboardPresented: presentation.isToolsKeyboardPresented,
                    switchKeyboard: interactions.switchKeyboard,
                    modeControl: modeControl)
            }
            .padding(.vertical, 8)
        }
    }

    private var modeControl: TerminalAgentSwitcherModeControl {
        .button(
            systemImage: "square.and.pencil",
            accessibilityLabel: AgentDirectInputPresentation.showComposerAccessibilityLabel,
            accessibilityHint: AgentDirectInputPresentation.showComposerAccessibilityHint,
            action: interactions.showComposer)
    }

    private var shortcutRow: some View {
        scrollingShortcutRow
        .frame(height: InputChromeLayout.shortcutRowHeight)
        .background(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / max(displayScale, 1))
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var scrollingShortcutRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(strip.leadingItems, id: \.self) { item in
                        sizedStripItem(item)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
            }

            HStack(spacing: 4) {
                ForEach(strip.trailingItems, id: \.self) { item in
                    sizedStripItem(item)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [.clear, Color(uiColor: .separator).opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing)
                    .frame(width: InputChromeLayout.pinnedFadeWidth)
                    .offset(x: -InputChromeLayout.pinnedFadeWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func sizedStripItem(_ item: InputShortcutStripItem) -> some View {
        stripItem(item)
            .frame(
                width: InputChromeLayout.compactWidth(for: item),
                height: InputChromeLayout.shortcutRowHeight)
    }

    @ViewBuilder
    private func stripItem(_ item: InputShortcutStripItem) -> some View {
        switch item {
        case .key(let key):
            shortcutKeyButton(key)
        case .paste:
            pasteKeyButton
        case .more:
            moreMenu
        }
    }

    @ViewBuilder
    private func shortcutKeyButton(_ key: AgentQuickKey) -> some View {
        if key == .backspace {
            TerminalBackspaceButton(isToolbar: true) { sendShortcutKey(key) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Button {
                sendShortcutKey(key)
            } label: {
                shortcutKeyCap {
                    shortcutKeyLabel(key)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .buttonStyle(TerminalKeyboardButtonStyle())
            .accessibilityLabel(key.accessibilityLabel)
            .accessibilityHint("Sends this key directly to the Agent")
        }
    }

    private func sendShortcutKey(_ key: AgentQuickKey) {
        UIDevice.current.playInputClick()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        interactions.sendQuickKey(key)
    }

    /// A system paste control, so a tap needs no Allow Paste prompt. Below
    /// 34 pt tall it disables itself, so it is laid out at 34 pt and scaled
    /// to the key caps' 30 pt.
    private var pasteKeyButton: some View {
        KeyCapPasteControl { text in
            UIDevice.current.playInputClick()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            interactions.paste(text)
        }
        // The control resolves its colors once, when it is created.
        .id(colorScheme)
        .frame(
            width: InputChromeLayout.pasteControlSide,
            height: InputChromeLayout.pasteControlSide)
        .scaleEffect(
            InputChromeLayout.pasteVisualWidth / InputChromeLayout.pasteControlSide)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHint("Pastes the clipboard into the Agent")
    }

    @ViewBuilder
    private func shortcutKeyLabel(_ key: AgentQuickKey) -> some View {
        if let systemImageName = key.systemImageName {
            Image(systemName: systemImageName)
                .font(.system(size: 12, weight: .semibold))
        } else if let title = key.title {
            Text(title)
                .font(.caption.weight(.medium))
        }
    }

    private func shortcutKeyCap<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 30)
    }

    private var moreMenu: some View {
        Menu {
            AgentActionMenuContent(
                actions: interactions.actions,
                sections: AgentActionMenuPolicy.directInputMoreSections,
                restoreComposerThen: interactions.restoreComposerThen)
        } label: {
            shortcutKeyCap {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .buttonStyle(TerminalKeyboardButtonStyle())
        .accessibilityLabel("More")
        .accessibilityHint("Opens Agent actions")
    }
}

/// UIKit's paste control dressed as a Direct Input key cap. SwiftUI's
/// `PasteButton` cannot be: its glyph is always white, and in light mode iOS
/// darkens a light tint behind it.
private struct KeyCapPasteControl: UIViewRepresentable {
    let paste: (String) -> Void

    func makeUIView(context: Context) -> KeyCapPasteView {
        KeyCapPasteView(paste: paste)
    }

    func updateUIView(_ view: KeyCapPasteView, context: Context) {
        view.onPaste = paste
    }
}

private final class KeyCapPasteView: UIView {
    var onPaste: (String) -> Void

    /// The key caps' translucent `secondarySystemFill` flattened onto the
    /// row's `secondarySystemBackground`, because the control paints its
    /// background opaque.
    private static let keyCapFill = UIColor { traits in
        let fill = UIColor.secondarySystemFill.resolvedColor(with: traits)
        let base = UIColor.secondarySystemBackground.resolvedColor(with: traits)
        var (fillRed, fillGreen, fillBlue, fillAlpha): (CGFloat, CGFloat, CGFloat, CGFloat) =
            (0, 0, 0, 0)
        var (baseRed, baseGreen, baseBlue, baseAlpha): (CGFloat, CGFloat, CGFloat, CGFloat) =
            (0, 0, 0, 0)
        fill.getRed(&fillRed, green: &fillGreen, blue: &fillBlue, alpha: &fillAlpha)
        base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha)
        let blend = { (top: CGFloat, bottom: CGFloat) in
            top * fillAlpha + bottom * (1 - fillAlpha)
        }
        return UIColor(
            red: blend(fillRed, baseRed),
            green: blend(fillGreen, baseGreen),
            blue: blend(fillBlue, baseBlue),
            alpha: 1)
    }

    init(paste: @escaping (String) -> Void) {
        onPaste = paste
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 7
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = Self.keyCapFill
        let control = UIPasteControl(configuration: configuration)
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: topAnchor),
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) })
        else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text, !text.isEmpty else { return }
            Task { @MainActor in self?.onPaste(text) }
        }
    }
}
