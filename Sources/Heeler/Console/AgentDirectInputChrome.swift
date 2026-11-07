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
        let changes: AgentDetailChanges?
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
        let paste: (String) -> Void
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
                    changes: presentation.changes,
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
        InputShortcutStripRow(
            strip: strip,
            keyAccessibilityHint: String(localized: "Sends this key directly to the Agent"),
            sendKey: interactions.sendQuickKey
        ) { item in
            switch item {
            case .paste:
                pasteKeyButton
            case .more:
                moreMenu
            case .key:
                EmptyView()
            }
        }
    }

    /// A system paste control, so a tap needs no Allow Paste prompt. Below
    /// 34 pt tall it disables itself, so it is laid out at 34 pt and scaled
    /// to the key caps' 30 pt.
    private var pasteKeyButton: some View {
        PinnedPasteControl(
            backgroundColor: PinnedPasteControl.keyCapFill, cornerRadius: 7
        ) { text in
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

    private var moreMenu: some View {
        Menu {
            AgentActionMenuContent(
                actions: interactions.actions,
                sections: AgentActionMenuPolicy.directInputMoreSections,
                restoreComposerThen: interactions.restoreComposerThen)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .inputShortcutKeyCap()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .buttonStyle(TerminalKeyboardButtonStyle())
        .accessibilityLabel("More")
        .accessibilityHint("Opens Agent actions")
        .agentCloseConfirmation(interactions.actions.closeConfirmation)
    }
}
