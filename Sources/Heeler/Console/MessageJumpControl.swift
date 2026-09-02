import SwiftUI
import UIKit

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

/// Bottom inset that keeps the jump chrome clear of the alternate-screen
/// keyboard activation band. Pure so short-terminal placement is testable
/// without a device. `refs #268`.
enum MessageJumpPlacement {
    /// Distance from the terminal's bottom edge to the control's bottom edge.
    static func bottomInset(terminalHeight: CGFloat) -> CGFloat {
        guard terminalHeight > 0 else { return 0 }
        return terminalHeight * TerminalKeyboardTapTarget.alternateScreenBottomFraction
    }

    /// Whether a control of `controlHeight` whose bottom sits `bottomInset`
    /// above the terminal bottom stays entirely above the keyboard band.
    static func sitsAboveBottomBand(
        terminalHeight: CGFloat,
        controlHeight: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        guard terminalHeight > 0, controlHeight >= 0 else { return false }
        let bandTop = terminalHeight - Self.bottomInset(terminalHeight: terminalHeight)
        let controlBottom = terminalHeight - bottomInset
        let controlTop = controlBottom - controlHeight
        return controlBottom <= bandTop + .ulpOfOne && controlTop >= 0
    }
}

/// Owns the per-Attach index, scroll handle, and jump loop for Agent detail.
/// Constructed once per screen; reset when the Attach session is replaced.
///
/// ``SessionGeneration`` mirrors ``TerminalInputController/SessionGeneration``:
/// a jump Task captures the live generation, and any follow-up such as
/// ``returnToLive`` is abandoned once ``resetSession`` has advanced it.
@MainActor
@Observable
final class AgentMessageJumpWiring {
    struct SessionGeneration: Sendable, Hashable {
        fileprivate let value: UInt64
    }

    let scrollControl: TerminalScrollControl
    let messageIndex: AttachUserMessageIndex
    let controller: TerminalMessageJumpController

    /// Latest viewport frame delivered through Agent detail's production seam.
    private(set) var lastViewportFrame: String?
    private(set) var liveGeneration = SessionGeneration(value: 0)

    private var nextGeneration: UInt64 = 0
    private var jumpTask: Task<Void, Never>?

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

    /// Feeds the jump controller from `TerminalScreenView.onViewportTextChanged`.
    func deliverViewportText(_ text: String) {
        lastViewportFrame = text
        controller.frameDidChange(text)
    }

    /// True while `generation` is still the Attach session this wiring serves.
    func isLive(_ generation: SessionGeneration) -> Bool {
        generation == liveGeneration
    }

    /// Runs jump work bound to the current session. ``resetSession`` cancels
    /// the task and advances the generation so a returned continuation cannot
    /// start a follow-up against a replacement Attach.
    func runJump(
        _ body: @escaping @MainActor (_ session: SessionGeneration) async -> Void
    ) {
        let session = liveGeneration
        jumpTask?.cancel()
        jumpTask = Task { @MainActor in
            await body(session)
        }
    }

    /// Drops indexed messages, cancels an in-flight jump Task, and advances
    /// the session generation. Entries describe one session's scrollback and
    /// must not outlive it.
    func resetSession() {
        jumpTask?.cancel()
        jumpTask = nil
        nextGeneration &+= 1
        liveGeneration = SessionGeneration(value: nextGeneration)
        controller.cancel()
        messageIndex.reset()
        lastViewportFrame = nil
    }
}

/// Down-button orchestration extracted so the stale-continuation guard is
/// unit-testable without hosting Agent detail. `refs #268`.
enum MessageJumpDownSequencer {
    /// Walks toward live one user message at a time. When no newer message
    /// remains, finishes with `returnToLive` — but only while `isLive` still
    /// reports the Attach session that started the jump.
    static func run(
        jumpNewer: () async -> TerminalMessageJumpController.Outcome,
        returnToLive: () async -> TerminalMessageJumpController.Outcome,
        isLive: () -> Bool
    ) async -> TerminalMessageJumpController.Outcome? {
        let outcome = await jumpNewer()
        guard isLive() else { return nil }
        if outcome == .reachedEnd {
            guard isLive() else { return nil }
            let live = await returnToLive()
            guard isLive() else { return nil }
            return live
        }
        return outcome
    }
}

/// Compact up/down controls that walk the remote TUI between user messages.
///
/// Down walks toward live output one user message at a time; when no newer
/// message remains, the same button finishes the trip with
/// ``TerminalMessageJumpController/returnToLive()``. Only the buttons take
/// hits — notice, material, padding, and inter-button gaps pass through to
/// the terminal underneath.
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
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.regularMaterial)
                                .allowsHitTesting(false)
                        }
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(spacing: 0) {
                    jumpButton(
                        systemImage: "chevron.up",
                        label: "Earlier message",
                        action: onOlder)
                    jumpButton(
                        systemImage: "chevron.down",
                        label: "Newer message",
                        action: onNewer)
                }
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.regularMaterial)
                        .allowsHitTesting(false)
                }
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
                .frame(width: 44, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Positions the jump chrome above the alternate-screen bottom band and
/// passes every non-button hit through to the terminal. `refs #268`.
struct MessageJumpChromeOverlay: UIViewRepresentable {
    var availability: MessageJumpControlAvailability
    var notice: String?
    var onOlder: () -> Void
    var onNewer: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MessageJumpChromeContainer {
        let container = MessageJumpChromeContainer()
        let host = UIHostingController(
            rootView: MessageJumpControlView(
                availability: availability,
                notice: notice,
                onOlder: onOlder,
                onNewer: onNewer))
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        context.coordinator.host = host
        container.embed(host.view)
        return container
    }

    func updateUIView(_ container: MessageJumpChromeContainer, context: Context) {
        context.coordinator.host?.rootView = MessageJumpControlView(
            availability: availability,
            notice: notice,
            onOlder: onOlder,
            onNewer: onNewer)
        container.setNeedsLayout()
    }

    final class Coordinator {
        var host: UIHostingController<MessageJumpControlView>?
    }
}

/// Full-bleed overlay host whose own bounds never claim a touch. Hits land on
/// interactive descendants only (the jump buttons); everything else returns
/// `nil` so the terminal's pan recognizer sees the drag.
final class MessageJumpChromeContainer: UIView {
    private weak var hostedView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func embed(_ view: UIView) {
        hostedView?.removeFromSuperview()
        hostedView = view
        view.backgroundColor = .clear
        view.isOpaque = false
        addSubview(view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let hostedView else { return }
        let size = hostedView.systemLayoutSizeFitting(
            CGSize(width: UIView.layoutFittingCompressedSize.width, height: 0),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        let width = max(size.width, 44)
        let height = size.height
        let inset = MessageJumpPlacement.bottomInset(terminalHeight: bounds.height)
        hostedView.frame = CGRect(
            x: bounds.width - width - 10,
            y: max(0, bounds.height - inset - height),
            width: width,
            height: height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hostedView, hostedView.frame.contains(point) else {
            return nil
        }
        let local = convert(point, to: hostedView)
        guard let hit = hostedView.hitTest(local, with: event) else {
            return nil
        }
        // The hosting root and any non-interactive chrome (material, notice,
        // layout wrappers) must not steal terminal drags.
        if hit === hostedView || !Self.isInteractive(hit, stoppingAt: hostedView) {
            return nil
        }
        return hit
    }

    /// Whether `view` or an ancestor up to `root` is a control or hosts an
    /// enabled gesture — the signal that a SwiftUI `Button` is underneath.
    static func isInteractive(_ view: UIView, stoppingAt root: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate is UIControl { return true }
            if let recognizers = candidate.gestureRecognizers,
                recognizers.contains(where: \.isEnabled)
            {
                return true
            }
            if candidate === root { break }
            current = candidate.superview
        }
        return false
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
