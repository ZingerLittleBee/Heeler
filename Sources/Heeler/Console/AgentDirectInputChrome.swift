import SwiftUI
import UIKit

/// Compact Agent-detail chrome for Direct Input: status, a shortcut row while
/// the system keyboard is up, and the Agent switcher with Show Composer.
/// App content rather than a keyboard accessory, so UIKit's candidate-row
/// teardown cannot tear it down or leave a hollow gap.
struct AgentDirectInputChrome: View {
    let status: AgentStatus
    let hostTelemetry: HostTelemetryPresentation?
    let chromeColorScheme: ColorScheme
    let switcher: TerminalAgentSwitcher
    let keyboardHandoff: TerminalKeyboardHandoff
    let isKeyboardUp: Bool
    let isToolsKeyboardPresented: Bool
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

    /// Same arithmetic Shell uses: a transient zero inset while first
    /// responder is retained must not hide the chrome mid-swap.
    static func keyboardPresentation(
        usesToolsKeyboard: Bool,
        insetHeight: CGFloat,
        keyboardIsUp: Bool
    ) -> AgentComposerKeyboardPresentation {
        if usesToolsKeyboard { return .tools }
        if insetHeight > 0 || keyboardIsUp { return .system }
        return .hidden
    }

    /// Shortcut keys ride the system keyboard only. Tools mode already has
    /// the pad; a dismissed keyboard must leave no hollow black bar.
    static func showsShortcutRow(
        presentation: AgentComposerKeyboardPresentation
    ) -> Bool {
        presentation == .system
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusLabel
                    Spacer(minLength: 8)
                    if let hostTelemetry {
                        hostTelemetryLabel(hostTelemetry)
                    }
                }
                .padding(.horizontal, 16)
                .environment(\.colorScheme, chromeColorScheme)

                if showShortcutRow {
                    shortcutRow
                }

                TerminalAgentSwitcherRow(
                    switcher: focusPreservingSwitcher,
                    isKeyboardUp: isKeyboardUp,
                    toggleKeyboard: toggleKeyboard,
                    isToolsKeyboardPresented: isToolsKeyboardPresented,
                    switchKeyboard: switchKeyboard,
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
                    if mode == .composer { showComposer() }
                })
        }
        return .button(
            systemImage: "square.and.pencil",
            accessibilityLabel: "Show Composer",
            accessibilityHint: "Restores the Composer. The draft is unchanged.",
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
                    Button {
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
                }

                Spacer(minLength: 8)

                Button("Composer", action: showComposer)
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
                    .background(
                        Color(uiColor: .secondarySystemFill),
                        in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Show Composer")
                    .accessibilityHint("Restores the Composer. The draft is unchanged.")

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

    private var statusLabel: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(status.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(status.rawValue.capitalized)
    }

    private func hostTelemetryLabel(
        _ telemetry: HostTelemetryPresentation
    ) -> some View {
        Text(telemetry.title)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(
                chromeColorScheme == .dark
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(telemetry.accessibilityLabel)
            .accessibilityValue(telemetry.accessibilityValue)
    }
}
