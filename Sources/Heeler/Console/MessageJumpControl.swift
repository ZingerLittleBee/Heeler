import SwiftUI
import UIKit

/// Where the remote viewport sits relative to the jumpable history, as far
/// as the app can tell. The jump loop is open — nothing reports the remote
/// scroll offset — so this is inferred from what each walk observed and from
/// the direction of touch scrolls, and it is deliberately conservative: a
/// direction is dropped only once a walk has proven it empty or the position
/// is known to be live. `refs #268`.
struct MessageJumpReach: Equatable, Sendable {
    /// Nothing newer lies below the viewport: it sits at live output. True
    /// until something moves it older.
    private(set) var isAtLive = true
    /// The last older walk ran out of history without finding a message, and
    /// nothing has moved newer since.
    private(set) var isAtOldest = false

    var canJumpOlder: Bool { !isAtOldest }
    var canJumpNewer: Bool { !isAtLive }

    mutating func noteOlderJump(
        _ outcome: TerminalMessageJumpController.Outcome,
        movedViewport: Bool
    ) {
        if movedViewport {
            isAtLive = false
        }
        switch outcome {
        case .found, .exhausted:
            isAtOldest = false
        case .reachedEnd:
            isAtOldest = true
        case .cancelled:
            break
        }
    }

    /// Outcome of the Down press as a whole: a found newer message, or the
    /// `returnToLive` that follows when none remains.
    mutating func noteNewerJump(
        _ outcome: TerminalMessageJumpController.Outcome,
        movedViewport: Bool
    ) {
        if movedViewport {
            isAtOldest = false
        }
        switch outcome {
        case .reachedEnd:
            isAtLive = true
        case .found, .exhausted:
            isAtLive = false
        case .cancelled:
            break
        }
    }

    /// A drag moved the remote view. Older leaves live; newer may leave the
    /// oldest message, and the app cannot tell by how much, so it re-offers Up.
    mutating func noteTouchScroll(towardOlderContent: Bool) {
        if towardOlderContent {
            isAtLive = false
        } else {
            isAtOldest = false
        }
    }

    /// A new turn started. When the viewport is live, the conversation may
    /// have grown past the screen, so an earlier "no older message" verdict
    /// no longer holds. Away from live the new turn lands *below* the
    /// viewport and Up has still nothing to reach.
    mutating func noteConversationGrew() {
        if isAtLive {
            isAtOldest = false
        }
    }
}

/// Visibility and enablement for the Attach message-jump chrome, as a pure
/// function of its inputs. Kept out of `body` so tests can pin the policy
/// without hosting SwiftUI. `refs #268`.
struct MessageJumpControlAvailability: Equatable, Sendable {
    /// Up is offered: the chrome can scroll the remote view and no older walk
    /// has proven the history exhausted.
    var showsOlder: Bool
    /// Down is offered: the viewport is known to have left live output.
    var showsNewer: Bool
    /// False while a jump is in flight: the remaining button shows that
    /// walk's spinner and takes no hit.
    var isEnabled: Bool

    /// Shown only on the alternate screen, only when a scroll step can reach
    /// the remote application's own history, and only for a direction that
    /// still has somewhere to go *right now*. `herdr terminal attach` is
    /// itself an alternate-screen client, so the first condition alone would
    /// also put the buttons on a plain shell, where they would do nothing but
    /// feed it cursor keys. A jump in flight hides the other direction and
    /// keeps its own button as progress.
    ///
    /// The agent's status is deliberately not an input. A working agent is
    /// still scrollable, and reading earlier messages while it works is the
    /// point; the cost is that its spinner keeps repainting, so a walk that
    /// reaches the end of history cannot see the frame settle and instead
    /// runs out its step budget (``MessageJumpNotice``).
    var isVisible: Bool { showsOlder || showsNewer }

    static let hidden = Self(showsOlder: false, showsNewer: false, isEnabled: false)

    static func evaluate(
        isAlternateScreen: Bool,
        canScrollRemoteContent: Bool,
        reach: MessageJumpReach = MessageJumpReach(),
        runningDirection: TerminalMessageJumpController.Direction? = nil
    ) -> Self {
        let canScroll = isAlternateScreen && canScrollRemoteContent
        let showsOlder = canScroll && reach.canJumpOlder
            && (runningDirection == nil || runningDirection == .older)
        let showsNewer = canScroll && reach.canJumpNewer
            && (runningDirection == nil || runningDirection == .newer)
        let isEnabled = (showsOlder || showsNewer) && runningDirection == nil
        return Self(showsOlder: showsOlder, showsNewer: showsNewer, isEnabled: isEnabled)
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

/// Agent-specific recognition and walking rules for user-message navigation.
/// Most TUIs draw user prompts flush-left. Grok's pinned prompt is indented
/// five columns, so it needs a wider recognition window without weakening the
/// tool-output rejection used by every other Agent kind.
struct AgentMessageJumpProfile: Equatable {
    let policy: TerminalMessageJumpPolicy
    let maximumPromptIndent: Int

    static func forAgentKind(_ kind: String) -> Self {
        if kind == SupportedAgentKind.grok.rawValue {
            return Self(policy: .stickyPromptOvershoot, maximumPromptIndent: 5)
        }
        return Self(
            policy: .neighborAppearance,
            maximumPromptIndent: AttachUserMessageIndex.maximumPromptIndent)
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
    /// Direction of the jump in flight, for the chrome's progress indicator.
    /// Nil whenever ``isJumpRunning`` is false.
    private(set) var runningDirection: TerminalMessageJumpController.Direction?
    /// Which directions still have somewhere to go. Drives per-button
    /// visibility; reset with the session.
    private(set) var reach = MessageJumpReach()
    /// How many jump bodies passed the entry guard. Test seam for the
    /// reset-before-start race.
    private(set) var jumpInvocationCount = 0

    private var nextGeneration: UInt64 = 0
    private var jumpEpoch: UInt64 = 0
    private var jumpTask: Task<Void, Never>?

    init(
        policy: TerminalMessageJumpPolicy = .neighborAppearance,
        maximumPromptIndent: Int = AttachUserMessageIndex.maximumPromptIndent
    ) {
        let scrollControl = TerminalScrollControl()
        let messageIndex = AttachUserMessageIndex(maximumPromptIndent: maximumPromptIndent)
        self.scrollControl = scrollControl
        self.messageIndex = messageIndex
        self.controller = TerminalMessageJumpController(
            policy: policy,
            step: { direction, rows in
                scrollControl.scrollRows(
                    towardOlderContent: direction == .older,
                    rows: rows)
            },
            visibleMessages: { messageIndex.visibleMessageKeys($0) },
            viewportRows: { scrollControl.viewportRows })
        scrollControl.onTouchScroll = { [weak self] towardOlderContent in
            self?.noteTouchScroll(towardOlderContent: towardOlderContent)
        }
    }

    convenience init(profile: AgentMessageJumpProfile) {
        self.init(
            policy: profile.policy,
            maximumPromptIndent: profile.maximumPromptIndent)
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
        _ direction: TerminalMessageJumpController.Direction,
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
            self.runningDirection = direction
            defer {
                if epoch == self.jumpEpoch {
                    self.isJumpRunning = false
                    self.runningDirection = nil
                }
            }
            await body(session)
        }
    }

    /// One Up press: walks to the neighbouring older message and folds what
    /// the walk observed into ``reach``. Nil when `session` ended meanwhile.
    func jumpOlder(
        in session: SessionGeneration
    ) async -> TerminalMessageJumpController.Outcome? {
        let outcome = await controller.jump(.older)
        guard isLive(session) else { return nil }
        reach.noteOlderJump(outcome, movedViewport: controller.lastRunMovedViewport)
        return outcome
    }

    /// One Down press: walks toward live one user message at a time and, when
    /// no newer message remains, finishes with
    /// ``TerminalMessageJumpController/returnToLive()``. Movement from either
    /// leg counts toward ``reach``. Nil when `session` ended meanwhile.
    func jumpNewerOrLive(
        in session: SessionGeneration
    ) async -> TerminalMessageJumpController.Outcome? {
        var movedViewport = false
        let outcome = await MessageJumpDownSequencer.run(
            jumpNewer: {
                let outcome = await self.controller.jump(.newer)
                movedViewport = movedViewport || self.controller.lastRunMovedViewport
                return outcome
            },
            returnToLive: {
                let outcome = await self.controller.returnToLive()
                movedViewport = movedViewport || self.controller.lastRunMovedViewport
                return outcome
            },
            isLive: { self.isLive(session) })
        guard let outcome, isLive(session) else { return nil }
        reach.noteNewerJump(outcome, movedViewport: movedViewport)
        return outcome
    }

    /// The agent began a new turn; see ``MessageJumpReach/noteConversationGrew()``.
    func noteConversationGrew() {
        var next = reach
        next.noteConversationGrew()
        if next != reach {
            reach = next
        }
    }

    private func noteTouchScroll(towardOlderContent: Bool) {
        // Drags report every row; only a real change may touch observed state.
        var next = reach
        next.noteTouchScroll(towardOlderContent: towardOlderContent)
        if next != reach {
            reach = next
        }
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
        runningDirection = nil
        reach = MessageJumpReach()
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
/// Each direction is offered only while it has somewhere to go
/// (``MessageJumpControlAvailability``): Up disappears once a walk has run
/// out of history, Down appears only after the viewport has left live output.
/// Down walks toward live one user message at a time; when no newer message
/// remains, the same button finishes the trip with
/// ``TerminalMessageJumpController/returnToLive()``. Only the buttons take
/// hits — notice, background, padding, and inter-button gaps pass through to
/// the terminal underneath.
///
/// Drawn in the terminal's own colours, like ``TerminalStatusDialog``: a
/// system material would follow the appearance, not the theme, and read as a
/// light blob on a dark grid.
struct MessageJumpControlView: View {
    let availability: MessageJumpControlAvailability
    /// Direction whose walk is in flight, shown as a spinner in its button.
    var runningDirection: TerminalMessageJumpController.Direction?
    let notice: String?
    var palette: TerminalThemePalette = .system
    let onOlder: () -> Void
    let onNewer: () -> Void

    static let buttonSize: CGFloat = 44

    var body: some View {
        if availability.isVisible {
            VStack(alignment: .trailing, spacing: 8) {
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(palette.foreground.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            chromeBackground(in: Capsule())
                        }
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.updatesFrequently)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                VStack(spacing: 0) {
                    if availability.showsOlder {
                        jumpButton(
                            .older,
                            systemImage: "chevron.up",
                            label: "Earlier message",
                            hint: "Scrolls the Agent to the previous message you sent",
                            action: onOlder)
                    }
                    if availability.showsOlder, availability.showsNewer {
                        Rectangle()
                            .fill(palette.foreground.opacity(0.14))
                            .frame(width: 18, height: 1)
                            .allowsHitTesting(false)
                    }
                    if availability.showsNewer {
                        jumpButton(
                            .newer,
                            systemImage: "chevron.down",
                            label: "Newer message",
                            hint: "Scrolls the Agent to the next message you sent, then back to live output",
                            action: onNewer)
                    }
                }
                .background {
                    chromeBackground(in: Capsule())
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            .foregroundStyle(palette.foreground)
            .animation(.snappy(duration: 0.22), value: availability)
            .animation(.easeInOut(duration: 0.15), value: notice)
            .disabled(!availability.isEnabled)
            .accessibilityElement(children: .contain)
        }
    }

    /// The terminal's background lifted toward its foreground, with a hairline
    /// and a soft shadow so the pill separates from the grid it floats over.
    /// Lifted further than the status dialog's card: a 44-point pill over
    /// dense text needs more contrast than a full-width card does. Slightly
    /// translucent so the rows underneath stay readable through it.
    private func chromeBackground<S: InsettableShape>(in shape: S) -> some View {
        shape
            .fill(palette.background.mix(with: palette.foreground, by: 0.16).opacity(0.82))
            .overlay {
                shape.strokeBorder(palette.foreground.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .allowsHitTesting(false)
    }

    private func jumpButton(
        _ direction: TerminalMessageJumpController.Direction,
        systemImage: String,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // The walk itself is silent for up to a second; a light tap says
            // the press landed.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            ZStack {
                if runningDirection == direction {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.foreground)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .buttonStyle(MessageJumpButtonStyle(highlight: palette.foreground))
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

/// Press feedback for a jump button: a brief scale-down with a soft fill
/// behind the glyph. The whole 44-point square is the hit area; the fill
/// stays inset so the pill's edge reads as one shape. There is no disabled
/// look — a button that cannot act is hidden, not greyed.
private struct MessageJumpButtonStyle: ButtonStyle {
    let highlight: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                width: MessageJumpControlView.buttonSize,
                height: MessageJumpControlView.buttonSize)
            .background {
                Circle()
                    .fill(highlight.opacity(configuration.isPressed ? 0.16 : 0))
                    .padding(4)
            }
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// Positions the jump chrome above the alternate-screen bottom band and
/// passes every non-button hit through to the terminal. `refs #268`.
struct MessageJumpChromeOverlay: UIViewRepresentable {
    var availability: MessageJumpControlAvailability
    var runningDirection: TerminalMessageJumpController.Direction?
    var notice: String?
    var palette: TerminalThemePalette = .system
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
        container.hasNotice = notice != nil
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
        container.hasNotice = notice != nil && !suppress
        container.onChromeRejected = { [weak coordinator = context.coordinator, weak container] hadNotice in
            guard let coordinator, hadNotice, !coordinator.suppressNotice else { return }
            coordinator.suppressNotice = true
            coordinator.host?.rootView = makeRoot(suppressNotice: true)
            container?.hasNotice = false
        }
        container.setNeedsLayout()
    }

    private func makeRoot(suppressNotice: Bool) -> MessageJumpControlView {
        MessageJumpControlView(
            availability: availability,
            runningDirection: runningDirection,
            notice: suppressNotice ? nil : notice,
            palette: palette,
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
    /// `hadNotice` is true when a notice was contributing height — the overlay
    /// drops the notice and retries with the button column alone.
    var onChromeRejected: ((_ hadNotice: Bool) -> Void)?
    /// Whether the hosted tree currently includes a notice above the buttons.
    /// Set by the overlay; the button column itself varies in height (one or
    /// two buttons), so height alone cannot tell the two apart.
    var hasNotice = false
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
        if hasNotice {
            hasNotice = false
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
    /// Quiet, non-modal copy for a walk that ran out of budget. Reaching an
    /// end says nothing: the direction's button disappears instead
    /// (``MessageJumpReach``).
    static func text(for outcome: TerminalMessageJumpController.Outcome) -> String? {
        switch outcome {
        case .found, .cancelled, .reachedEnd:
            return nil
        case .exhausted:
            return "Couldn't find the message"
        }
    }
}
