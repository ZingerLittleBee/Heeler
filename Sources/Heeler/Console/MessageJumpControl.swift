import SwiftUI
import UIKit

/// Visibility and enablement for the Attach message-jump chrome, as a pure
/// function of the three inputs the MVP cares about. Kept out of `body` so
/// tests can pin the policy without hosting SwiftUI. `refs #268`.
struct MessageJumpControlAvailability: Equatable, Sendable {
    /// Shown only on the alternate screen, and only when a scroll step can
    /// reach the remote application's own history. `herdr terminal attach` is
    /// itself an alternate-screen client, so the first condition alone would
    /// also put the buttons on a plain shell, where they would do nothing but
    /// feed it cursor keys.
    var isVisible: Bool
    /// Disabled (not hidden) while a jump is in flight or the agent is
    /// working — a spinner keeps repainting, and the loop's "frame stopped
    /// changing" terminator cannot survive that.
    var isEnabled: Bool

    static func evaluate(
        isAlternateScreen: Bool,
        canScrollRemoteContent: Bool,
        agentStatus: AgentStatus,
        isRunning: Bool
    ) -> Self {
        let isVisible = isAlternateScreen && canScrollRemoteContent
        let isEnabled = isVisible
            && agentStatus != .working
            && !isRunning
        return Self(isVisible: isVisible, isEnabled: isEnabled)
    }
}

/// Bottom inset and frames that keep the jump chrome clear of the
/// alternate-screen keyboard activation band. Pure so short-terminal
/// placement is testable without a device. When the chrome cannot sit
/// entirely above the band, production hides it rather than overlapping.
/// `refs #268`.
enum MessageJumpPlacement {
    static let trailingPadding: CGFloat = 10

    /// Distance from the terminal's bottom edge to the control's bottom edge.
    static func bottomInset(terminalHeight: CGFloat) -> CGFloat {
        guard terminalHeight > 0 else { return 0 }
        return terminalHeight * TerminalKeyboardTapTarget.alternateScreenBottomFraction
    }

    /// Height left above the protected bottom band.
    static func availableHeight(terminalHeight: CGFloat) -> CGFloat {
        max(0, terminalHeight - bottomInset(terminalHeight: terminalHeight))
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

    /// Frame for the chrome inside `terminalSize`, or `nil` when it cannot
    /// fit entirely above the keyboard band or within the trailing edge.
    /// Callers hide the chrome on `nil` rather than letting it overlap.
    static func frame(
        terminalSize: CGSize,
        chromeSize: CGSize,
        trailingPadding: CGFloat = Self.trailingPadding
    ) -> CGRect? {
        guard terminalSize.width > 0, terminalSize.height > 0 else { return nil }
        guard chromeSize.width > 0, chromeSize.height > 0 else { return nil }

        let inset = bottomInset(terminalHeight: terminalSize.height)
        guard sitsAboveBottomBand(
            terminalHeight: terminalSize.height,
            controlHeight: chromeSize.height,
            bottomInset: inset)
        else {
            return nil
        }

        let maxWidth = max(0, terminalSize.width - trailingPadding)
        let width = min(chromeSize.width, maxWidth)
        guard width > 0 else { return nil }
        let x = terminalSize.width - width - trailingPadding
        guard x >= 0 else { return nil }
        let y = terminalSize.height - inset - chromeSize.height
        guard y >= 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: chromeSize.height)
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
    /// True only after a jump Task has passed its entry generation check.
    private(set) var isJumpRunning = false
    /// How many jump bodies passed the entry guard. Test seam for the
    /// reset-before-start race.
    private(set) var jumpInvocationCount = 0

    /// True while the terminal's renderer is pinned for an in-flight jump.
    private(set) var isDisplayFrozen = false

    private var nextGeneration: UInt64 = 0
    private var jumpEpoch: UInt64 = 0
    private var jumpTask: Task<Void, Never>?
    private var freezeWatchdog: Task<Void, Never>?
    private let freezeTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - freezeTimeout: How long the frozen image may stand before the walk
    ///     is presumed stuck. A jump that outlives it thaws mid-walk, so the
    ///     user sees the remaining scroll — worse than a cut, far better than a
    ///     screen that looks hung.
    ///   - sleep: Injected so tests do not wait in real time.
    init(
        freezeTimeout: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        let scrollControl = TerminalScrollControl()
        let messageIndex = AttachUserMessageIndex()
        self.scrollControl = scrollControl
        self.messageIndex = messageIndex
        self.freezeTimeout = freezeTimeout
        self.sleep = sleep
        self.controller = TerminalMessageJumpController(
            step: { direction, rows in
                scrollControl.scrollRows(
                    towardOlderContent: direction == .older,
                    rows: rows)
            },
            visibleMessages: { messageIndex.visibleMessageKeys($0) },
            viewportRows: { scrollControl.viewportRows })
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
    /// start a follow-up against a replacement Attach. The Task body checks
    /// cancellation and generation **before** any `await`, so a reconnect that
    /// wins the main-actor queue cannot start `controller.jump` against the
    /// replacement session.
    func runJump(
        _ body: @escaping @MainActor (_ session: SessionGeneration) async -> Void
    ) {
        jumpEpoch &+= 1
        let epoch = jumpEpoch
        let session = liveGeneration
        jumpTask?.cancel()
        jumpTask = Task { @MainActor in
            guard !Task.isCancelled, self.isLive(session), epoch == self.jumpEpoch else {
                return
            }
            self.jumpInvocationCount &+= 1
            self.isJumpRunning = true
            // One freeze per press, covering every phase of the body — the
            // down button's walk and its `returnToLive` finish are one trip.
            self.beginFreeze()
            defer {
                if epoch == self.jumpEpoch {
                    self.isJumpRunning = false
                    self.endFreeze()
                }
            }
            await body(session)
        }
    }

    /// Pins the rendered image and arms the watchdog that guarantees a thaw.
    private func beginFreeze() {
        freezeWatchdog?.cancel()
        isDisplayFrozen = true
        scrollControl.freezeDisplay()
        freezeWatchdog = Task { @MainActor in
            do {
                try await self.sleep(self.freezeTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // Deliberately unconditional: whatever the jump is still doing, a
            // screen frozen this long reads as a hang.
            self.endFreeze()
        }
    }

    private func endFreeze() {
        freezeWatchdog?.cancel()
        freezeWatchdog = nil
        isDisplayFrozen = false
        scrollControl.thawDisplay()
    }

    /// Drops indexed messages, cancels an in-flight jump Task, and advances
    /// the session generation. Entries describe one session's scrollback and
    /// must not outlive it.
    func resetSession() {
        jumpTask?.cancel()
        jumpTask = nil
        jumpEpoch &+= 1
        nextGeneration &+= 1
        liveGeneration = SessionGeneration(value: nextGeneration)
        isJumpRunning = false
        // The cancelled task's `defer` sees the advanced epoch and skips its
        // thaw, so the reset owns it.
        endFreeze()
        controller.cancel()
        messageIndex.reset()
        lastViewportFrame = nil
    }
}

/// Down-button orchestration extracted so the stale-continuation guard is
/// unit-testable without hosting Agent detail. Isolated to the main actor
/// because every caller passes closures that touch MainActor jump state.
/// `refs #268`.
@MainActor
enum MessageJumpDownSequencer {
    /// Walks toward live one user message at a time. When no newer message
    /// remains, finishes with `returnToLive` — but only while `isLive` still
    /// reports the Attach session that started the jump.
    static func run(
        jumpNewer: @MainActor () async -> TerminalMessageJumpController.Outcome,
        returnToLive: @MainActor () async -> TerminalMessageJumpController.Outcome,
        isLive: @MainActor () -> Bool
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
        context.coordinator.suppressNotice = false
        let host = UIHostingController(
            rootView: makeRoot(suppressNotice: false))
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        context.coordinator.host = host
        container.embed(host.view)
        container.onChromeRejected = { [weak coordinator = context.coordinator] hadNotice in
            guard let coordinator, hadNotice, !coordinator.suppressNotice else { return }
            coordinator.suppressNotice = true
            coordinator.host?.rootView = makeRoot(suppressNotice: true)
        }
        return container
    }

    func updateUIView(_ container: MessageJumpChromeContainer, context: Context) {
        if notice == nil {
            context.coordinator.suppressNotice = false
        }
        let suppress = context.coordinator.suppressNotice
        context.coordinator.host?.rootView = makeRoot(suppressNotice: suppress)
        container.onChromeRejected = { [weak coordinator = context.coordinator] hadNotice in
            guard let coordinator, hadNotice, !coordinator.suppressNotice else { return }
            coordinator.suppressNotice = true
            coordinator.host?.rootView = makeRoot(suppressNotice: true)
        }
        container.setNeedsLayout()
    }

    private func makeRoot(suppressNotice: Bool) -> MessageJumpControlView {
        MessageJumpControlView(
            availability: availability,
            notice: suppressNotice ? nil : notice,
            onOlder: onOlder,
            onNewer: onNewer)
    }

    final class Coordinator {
        var host: UIHostingController<MessageJumpControlView>?
        var suppressNotice = false
    }
}

/// Full-bleed overlay host whose own bounds never claim a touch. Hits land on
/// enabled interactive descendants only (the jump buttons); everything else
/// returns `nil` so the terminal's pan recognizer sees the drag.
final class MessageJumpChromeContainer: UIView {
    private weak var hostedView: UIView?
    /// Called when the measured chrome cannot sit above the keyboard band.
    /// `hadNotice` is true when the current hosted tree is taller than the
    /// button column alone would be — the overlay drops the notice and retries.
    var onChromeRejected: ((_ hadNotice: Bool) -> Void)?
    /// Test seam: last frame applied to the hosted chrome, or `nil` when hidden.
    private(set) var hostedFrame: CGRect?

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
        hostedView.setNeedsLayout()
        hostedView.layoutIfNeeded()
        let maxWidth = max(0, bounds.width - MessageJumpPlacement.trailingPadding)
        let fitting = hostedView.sizeThatFits(
            CGSize(width: maxWidth > 0 ? maxWidth : CGFloat.greatestFiniteMagnitude,
                   height: CGFloat.greatestFiniteMagnitude))
        let width = min(max(fitting.width, 0), maxWidth > 0 ? maxWidth : fitting.width)
        let height = max(fitting.height, 0)
        let chromeSize = CGSize(width: width, height: height)

        if let frame = MessageJumpPlacement.frame(
            terminalSize: bounds.size,
            chromeSize: chromeSize)
        {
            hostedView.isHidden = false
            hostedView.frame = frame
            hostedFrame = frame
            return
        }

        // Cannot fit above the band (or within the width). Drop the notice if
        // one is contributing height, remeasure, and hide only if the button
        // column still cannot sit above the band.
        let buttonsOnlyHeight: CGFloat = 72
        let hadNotice = height > buttonsOnlyHeight + 1
        if hadNotice {
            onChromeRejected?(true)
            hostedView.setNeedsLayout()
            hostedView.layoutIfNeeded()
            let retryFitting = hostedView.sizeThatFits(
                CGSize(
                    width: maxWidth > 0 ? maxWidth : CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude))
            let retryWidth = min(
                max(retryFitting.width, 0),
                maxWidth > 0 ? maxWidth : retryFitting.width)
            let retryHeight = max(retryFitting.height, 0)
            if let frame = MessageJumpPlacement.frame(
                terminalSize: bounds.size,
                chromeSize: CGSize(width: retryWidth, height: retryHeight))
            {
                hostedView.isHidden = false
                hostedView.frame = frame
                hostedFrame = frame
                return
            }
        }

        hostedView.isHidden = true
        hostedFrame = nil
        onChromeRejected?(false)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hostedView, !hostedView.isHidden, hostedView.frame.contains(point) else {
            return nil
        }
        let local = convert(point, to: hostedView)
        guard let hit = hostedView.hitTest(local, with: event) else {
            return nil
        }
        // Non-interactive and disabled chrome must not steal terminal drags.
        //
        // The hit may legitimately *be* the hosting root: SwiftUI does not back
        // a `Button` with its own `UIView`, so a hosting view answers for its
        // whole interactive area and its gesture recognizers are what run the
        // action. Rejecting that identity outright made the buttons respond to
        // VoiceOver activation but to no actual touch at all (#268) — the
        // three-round automated pass never caught it, because computer use
        // drives the accessibility tree. `isInteractive` still decides, and it
        // finds no recognizer on an inert container.
        guard Self.isInteractive(hit, stoppingAt: hostedView) else {
            return nil
        }
        return hit
    }

    /// Whether `view` is an *enabled* control or hosts an enabled gesture on a
    /// user-interaction-enabled view. Disabled controls and disabled ancestors
    /// return false so terminal drags pass through. `refs #268`.
    static func isInteractive(_ view: UIView, stoppingAt root: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if !candidate.isUserInteractionEnabled {
                return false
            }
            if let control = candidate as? UIControl {
                return control.isEnabled
            }
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
