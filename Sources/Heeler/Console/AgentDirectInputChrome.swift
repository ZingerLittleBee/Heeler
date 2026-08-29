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
        /// Switcher `onSelect` is `AgentTerminalView.switchToAgent`, the sole
        /// production owner of Direct Input keyboard-claim arming.
        let switcher: TerminalAgentSwitcher
        let actions: AgentComposerActions
        let toggleKeyboard: () -> Void
        let switchKeyboard: (() -> Void)?
        let sendQuickKey: (AgentQuickKey) -> Void
        let showComposer: () -> Void
        /// Routes More / Add actions that own the draft: restore Composer first.
        let restoreComposerThen: (@escaping () -> Void) -> Void
    }

    let presentation: Presentation
    let interactions: Interactions
}

/// Compact Agent-detail chrome for Direct Input: status, a persistent shortcut
/// row, and the Agent switcher.
/// Bottom-up order: system keyboard, switcher, shortcut row, status. The
/// shortcut row sits immediately above the persistent Agent strip. App content
/// rather than a keyboard accessory, so UIKit's candidate-row teardown cannot
/// tear it down or leave a hollow gap.
struct AgentDirectInputChrome: View {
    let context: AgentDirectInputChromeContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale

    private static let shortcutKeys: [AgentQuickKey] = [
        .escape, .tab, .shiftTab, .enter,
        .up, .down, .left, .right,
    ]

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
        if horizontalSizeClass == .regular {
            return .segmented(
                selection: .direct,
                select: { mode in
                    if mode == .composer { interactions.showComposer() }
                })
        }
        return .button(
            systemImage: "square.and.pencil",
            accessibilityLabel: AgentDirectInputPresentation.showComposerAccessibilityLabel,
            accessibilityHint: AgentDirectInputPresentation.showComposerAccessibilityHint,
            action: interactions.showComposer)
    }

    private var shortcutRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Self.shortcutKeys, id: \.self) { key in
                        shortcutKeyButton(key)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
            }

            moreMenu
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .secondarySystemBackground))
        }
        .frame(height: 44)
        .background(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / max(displayScale, 1))
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func shortcutKeyButton(_ key: AgentQuickKey) -> some View {
        Button {
            UIDevice.current.playInputClick()
            interactions.sendQuickKey(key)
        } label: {
            shortcutKeyLabel(key)
                .frame(minWidth: keyCapWidth(for: key), minHeight: 30)
                .background(
                    Color(uiColor: .secondarySystemFill),
                    in: .rect(cornerRadius: 7))
        }
        .frame(height: 44)
        .contentShape(.rect)
        .buttonStyle(.plain)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityHint("Sends this key directly to the Agent")
    }

    private func keyCapWidth(for key: AgentQuickKey) -> CGFloat {
        switch key {
        case .escape, .tab:
            38
        case .shiftTab:
            46
        case .enter:
            42
        case .left, .up, .down, .right:
            30
        case .backspace:
            64
        }
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

    private var moreMenu: some View {
        Menu {
            AgentActionMenuContent(
                actions: interactions.actions,
                sections: AgentActionMenuPolicy.directInputMoreSections,
                restoreComposerThen: interactions.restoreComposerThen)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .accessibilityLabel("More")
        .accessibilityHint("Opens Agent actions")
    }
}
