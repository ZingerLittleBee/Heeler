import SwiftUI

/// Visibility and enablement for the Attach message-jump chrome, as a pure
/// function of the three inputs the MVP cares about. Kept out of `body` so
/// tests can pin the policy without hosting SwiftUI. `refs #268`.
struct MessageJumpControlAvailability: Equatable, Sendable {
    /// Shown only on the alternate screen: that is where Attach history is
    /// remote and the control has work to do.
    var isVisible: Bool
    /// Disabled (not hidden) while a jump is in flight or the agent is
    /// working — a spinner keeps repainting, and the loop's "frame stopped
    /// changing" terminator cannot survive that.
    var isEnabled: Bool

    static func evaluate(
        isAlternateScreen: Bool,
        agentStatus: AgentStatus,
        isRunning: Bool
    ) -> Self {
        let isVisible = isAlternateScreen
        let isEnabled = isVisible
            && agentStatus != .working
            && !isRunning
        return Self(isVisible: isVisible, isEnabled: isEnabled)
    }
}

/// Owns the per-Attach index, scroll handle, and jump loop for Agent detail.
/// Constructed once per screen; reset when the Attach session is replaced.
@MainActor
@Observable
final class AgentMessageJumpWiring {
    let scrollControl: TerminalScrollControl
    let messageIndex: AttachUserMessageIndex
    let controller: TerminalMessageJumpController

    init() {
        let scrollControl = TerminalScrollControl()
        let messageIndex = AttachUserMessageIndex()
        self.scrollControl = scrollControl
        self.messageIndex = messageIndex
        self.controller = TerminalMessageJumpController(
            step: { direction, rows in
                scrollControl.scrollRows(
                    towardOlderContent: direction == .older,
                    rows: rows)
            },
            matches: { messageIndex.frameContainsMessage($0) })
    }

    /// Drops indexed messages and cancels an in-flight jump. Entries describe
    /// one session's scrollback and must not outlive it.
    func resetSession() {
        controller.cancel()
        messageIndex.reset()
    }
}

/// Compact up/down controls that walk the remote TUI between user messages.
///
/// Down walks toward live output one user message at a time; when no newer
/// message remains, the same button finishes the trip with
/// ``TerminalMessageJumpController/returnToLive()`` so the user can reach the
/// live bottom without a third control. Placement is the trailing edge at
/// mid-height — above ``TerminalKeyboardTapTarget/alternateScreenBottomRegion``
/// so it does not fight the agent TUI's input box. The stack is content-sized
/// only: no full-bleed hit target over the terminal.
struct MessageJumpControlView: View {
    let availability: MessageJumpControlAvailability
    let notice: String?
    let onOlder: () -> Void
    let onNewer: () -> Void

    var body: some View {
        if availability.isVisible {
            VStack(spacing: 6) {
                if let notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(spacing: 2) {
                    jumpButton(
                        systemImage: "chevron.up",
                        label: "Earlier message",
                        action: onOlder)
                    jumpButton(
                        systemImage: "chevron.down",
                        label: "Newer message",
                        action: onNewer)
                }
                .padding(4)
                .background(
                    .regularMaterial,
                    in: .rect(cornerRadius: 10, style: .continuous))
            }
            .disabled(!availability.isEnabled)
            .accessibilityElement(children: .contain)
        }
    }

    private func jumpButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

enum MessageJumpNotice {
    /// Quiet, non-modal copy for a finished jump. `askingForOlder` distinguishes
    /// "no earlier message" from "already at live output".
    static func text(
        for outcome: TerminalMessageJumpController.Outcome,
        askingForOlder: Bool
    ) -> String? {
        switch outcome {
        case .found, .cancelled:
            return nil
        case .reachedEnd:
            return askingForOlder ? "No earlier message" : "Back at live output"
        case .exhausted:
            return "Couldn't find the message"
        }
    }
}
