import SwiftUI
import UIKit

/// Compact Agent-detail chrome for Direct Input: status, Agent switcher with
/// Show Composer, and a shortcut row while the software keyboard is up.
/// Bottom-up order matches the approved geometry: system keyboard, shortcut
/// row, switcher, status. App content rather than a keyboard accessory, so
/// UIKit's candidate-row teardown cannot tear it down or leave a hollow gap.
struct AgentDirectInputChrome: View {
    let status: AgentStatus
    let hostTelemetry: HostTelemetryPresentation?
    let chromeColorScheme: ColorScheme
    let switcher: TerminalAgentSwitcher
    let keyboardHandoff: TerminalKeyboardHandoff
    /// Ghostty first-responder / tools intent for the switcher toggle glyph.
    let isKeyboardUp: Bool
    let isToolsKeyboardPresented: Bool
    /// Software-keyboard shortcut row only — never hardware-first-responder.
    let showShortcutRow: Bool
    let actions: AgentComposerActions
    let toggleKeyboard: () -> Void
    let switchKeyboard: (() -> Void)?
    let sendQuickKey: (AgentQuickKey) -> Void
    let showComposer: () -> Void
    /// Routes More / Add actions that own the draft: restore Composer first.
    let restoreComposerThen: (@escaping () -> Void) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale

    private static let shortcutKeys: [AgentQuickKey] = [
        .escape, .tab, .shiftTab, .enter,
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                AgentDetailStatusChrome(
                    status: status,
                    hostTelemetry: hostTelemetry,
                    chromeColorScheme: chromeColorScheme)

                TerminalAgentSwitcherRow(
                    switcher: focusPreservingSwitcher,
                    isKeyboardUp: isKeyboardUp,
                    toggleKeyboard: toggleKeyboard,
                    isToolsKeyboardPresented: isToolsKeyboardPresented,
                    switchKeyboard: switchKeyboard,
                    modeControl: modeControl)

                // Adjacent to the software keyboard it augments — below the
                // switcher in this top-to-bottom stack, above the keyboard.
                if showShortcutRow {
                    shortcutRow
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var modeControl: TerminalAgentSwitcherModeControl {
        if horizontalSizeClass == .regular {
            return .segmented(
                selection: .direct,
                select: { mode in
                    if mode == .composer { showComposer() }
                })
        }
        return .button(
            systemImage: "square.and.pencil",
            accessibilityLabel: AgentDirectInputPresentation.showComposerAccessibilityLabel,
            accessibilityHint: AgentDirectInputPresentation.showComposerAccessibilityHint,
            action: showComposer)
    }

    private var focusPreservingSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: switcher.items,
            selectedID: switcher.selectedID,
            onSelect: { id in
                if isKeyboardUp {
                    keyboardHandoff.arm(for: id)
                }
                switcher.onSelect(id)
            },
            onTogglePin: switcher.onTogglePin)
    }

    private var shortcutRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.shortcutKeys, id: \.self) { key in
                    shortcutKeyButton(key)
                }

                Spacer(minLength: 8)

                Button("Composer", action: showComposer)
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
                    .background(
                        Color(uiColor: .secondarySystemFill),
                        in: .rect(cornerRadius: 8))
                    .accessibilityLabel(
                        AgentDirectInputPresentation.showComposerAccessibilityLabel)
                    .accessibilityHint(
                        AgentDirectInputPresentation.showComposerAccessibilityHint)

                moreMenu

                Button(action: toggleKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss keyboard")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 48)
        .background(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / max(displayScale, 1))
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    /// Escape carries the source-specific row identity so hosted a11y traversal
    /// can discover the software-keyboard shortcut row. A `.contain` container
    /// identifier does not materialize in that walk; Tools keypad Escape must
    /// keep the shared spoken label without this identifier.
    @ViewBuilder
    private func shortcutKeyButton(_ key: AgentQuickKey) -> some View {
        let button = Button {
            UIDevice.current.playInputClick()
            sendQuickKey(key)
        } label: {
            Text(key.title ?? key.accessibilityLabel)
                .font(.caption.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: .rect(cornerRadius: 8))
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityHint("Sends this key directly to the Agent")

        if key == .escape {
            button.accessibilityIdentifier(
                AgentDirectInputPresentation.shortcutRowAccessibilityIdentifier)
        } else {
            button
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("Add Image", systemImage: "photo") {
                    restoreComposerThen { actions.addImage() }
                }
                .disabled(!actions.canBegin)
                Button("Add File", systemImage: "doc") {
                    restoreComposerThen { actions.addFile() }
                }
                .disabled(!actions.canBegin)
            }
            Section {
                Button("Open Terminal", systemImage: "apple.terminal") {
                    actions.openTerminal?()
                }
                .disabled(actions.openTerminal == nil || actions.isOpeningTerminal)
                Button("New Agent", systemImage: "plus") {
                    actions.startAgent()
                }
                if let showSkills = actions.showSkills {
                    Button("Skills", systemImage: "sparkles") {
                        restoreComposerThen(showSkills)
                    }
                }
                Button("Snippets", systemImage: "quote.bubble") {
                    restoreComposerThen(actions.manageSnippets)
                }
            }
            Section {
                if let showWorktreeDetails = actions.showWorktreeDetails {
                    Button("Worktree Details", systemImage: "arrow.triangle.branch") {
                        showWorktreeDetails()
                    }
                }
                Button("Rename Agent", systemImage: "pencil") {
                    actions.renameAgent()
                }
                Button("Rename Workspace", systemImage: "pencil.line") {
                    actions.renameWorkspace()
                }
                Button("Close Agent", systemImage: "trash", role: .destructive) {
                    actions.closeAgent()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
        .accessibilityHint("Opens Agent actions")
    }
}
