import Foundation
import Observation

/// The Agent's pane as a Blocked card reads and answers it: the screen
/// through `agent.read`, keys through `agent.send_keys` and typed text
/// through `pane.send_input`. Never the Attach PTY.
struct BlockedScreenIO: Sendable {
    var readScreen: @Sendable () async throws -> ANSIScreen
    var sendKeys: @Sendable ([String]) async throws -> Void
    var paste: @Sendable (String) async throws -> Void

    /// For a Chat that cannot reach the pane: every call fails.
    static let unavailable = BlockedScreenIO(
        readScreen: { throw TransportError.hostFeatureUnavailable(feature: "Chat") },
        sendKeys: { _ in throw TransportError.hostFeatureUnavailable(feature: "Chat") },
        paste: { _ in throw TransportError.hostFeatureUnavailable(feature: "Chat") })
}

/// Time as a Blocked card waits on it. Tests pass a clock that moves only
/// when the card sleeps.
struct BlockedCardClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = BlockedCardClock(now: { ContinuousClock.now }, sleep: { try await Task.sleep(for: $0) })
}

/// A dialog the parsers know, with the transcript's request for it.
struct BlockedCard: Equatable, Sendable {
    let dialog: BlockedDialog
    /// The call the dialog asks about, when the transcript shows it.
    let request: ChatPendingRequest?
}

/// Chat's answer to herdr's Blocked (ADR 0021): the dialog on the Agent's
/// screen as a native card, answered with keys.
///
/// The screen decides everything a card offers. While Chat shows a Blocked
/// Agent the store reads it every second. An action reads it again first
/// and sends nothing if the dialog changed, waits until the dialog has
/// shown for a moment, sends the plan's keys while checking each of its
/// expectations, then watches for the effect. Nothing is ever resent: a
/// dialog that does not respond keeps the card waiting for a fresh read.
@MainActor
@Observable
final class BlockedCardStore {
    struct Timing: Sendable {
        var watchInterval: Duration = .seconds(1)
        /// Between reads while an action checks its steps and effect.
        var pollInterval: Duration = .milliseconds(150)
        var expectationWindow: Duration = .milliseconds(1_500)
        var confirmationWindow: Duration = .seconds(3)
        /// How long a dialog must have shown before the first key: a key
        /// sent as the dialog draws can land on the screen before it.
        var grace: Duration = .milliseconds(150)
        /// How long the Agent may be Blocked with no dialog on screen before
        /// the card says it can't read one. herdr reports Blocked a moment
        /// before the program draws its dialog, and a moment after an
        /// answer removed it.
        var unreadableAfter: Duration = .seconds(2)
    }

    enum Content: Equatable {
        case none
        case card(BlockedCard)
        /// Something dialog-like the parsers could not name or trust: its
        /// rows verbatim, with a button per numbered option.
        case generic(GenericDialogExcerpt)
        /// herdr reports the Agent Blocked, but its screen shows nothing
        /// Heeler recognizes as a dialog.
        case unreadable
    }

    enum Progress: Equatable {
        case ready
        /// Keys are going out; every control waits.
        case acting
        /// The keys went out and the Agent has not shown their effect.
        /// Controls come back with the next read.
        case unconfirmed
    }

    let program: ChatProgram
    private(set) var content: Content = .none
    private(set) var progress: Progress = .ready
    /// Why the last action sent nothing or stopped part way.
    private(set) var notice: String?
    /// Bumped when an answer hands the turn back to the user (a Codex
    /// decline or interrupt), so Chat focuses its Composer.
    private(set) var composerFocusRequest = 0
    /// Confirmed answers the transcript can't show, for the timeline.
    private(set) var history = BlockedHistory()
    /// Folded to a bar; a new dialog unfolds it.
    var isCollapsed = false

    @ObservationIgnored private let io: BlockedScreenIO
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let clock: BlockedCardClock
    @ObservationIgnored private var activity: ChatAgentActivity = .unknown
    @ObservationIgnored private var pendingRequests: [ChatPendingRequest] = []
    @ObservationIgnored private var resolvedToolUseIDs: Set<String> = []
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The dialog on screen and when it first showed.
    @ObservationIgnored private var firstSeen: (fingerprint: DialogFingerprint, at: ContinuousClock.Instant)?
    /// A dialog an action gave up on part way, shown as the generic card
    /// until another dialog replaces it.
    @ObservationIgnored private var degraded: (fingerprint: DialogFingerprint, reason: String)?
    /// Since when a screen without a dialog may be Blocked for a reason
    /// the card can't read: Blocked starting, or an answer taking effect.
    @ObservationIgnored private var quietSince: ContinuousClock.Instant?

    init(program: ChatProgram, io: BlockedScreenIO, timing: Timing = Timing(), clock: BlockedCardClock = .live) {
        self.program = program
        self.io = io
        self.timing = timing
        self.clock = clock
    }

    // MARK: Inputs

    /// A Chat view shows the Agent: watch it while it is Blocked.
    func show() {
        isVisible = true
        updateWatching()
    }

    func hide() {
        isVisible = false
        updateWatching()
    }

    func suspend() {
        isSuspended = true
        updateWatching()
    }

    func resume() {
        isSuspended = false
        updateWatching()
    }

    /// The Agent or its Host is gone.
    func end() {
        isVisible = false
        updateWatching()
        clear()
    }

    /// herdr's latest status. Leaving Blocked clears the card unless an
    /// action is still checking its effect.
    func update(activity: ChatAgentActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        if activity == .blocked { quietSince = clock.now() }
        if activity != .blocked, progress != .acting { clear() }
        updateWatching()
    }

    /// The conversation as last read: requests a card can match, and calls
    /// whose results confirm an answer.
    func update(transcript: ChatTranscript) {
        pendingRequests = transcript.pendingRequests
        var resolved: Set<String> = []
        for entry in transcript.entries {
            switch entry.content {
            case .tool(let tool):
                if let id = tool.callID, !Self.isOpen(tool.status) { resolved.insert(id) }
            case .plan(let plan):
                if let id = plan.callID, !Self.isOpen(plan.status) { resolved.insert(id) }
            default:
                break
            }
        }
        resolvedToolUseIDs = resolved
    }

    // MARK: Actions

    /// Answers the card's dialog. Waits for a fresh read after an answer
    /// that showed no effect, so a second tap is never a resend.
    func perform(_ action: DialogAction) async {
        guard progress == .ready, case .card(let shown) = content else { return }
        let program = program
        let requests = pendingRequests
        var answered: BlockedCard?
        let isConfirmed = await act(on: shown.dialog.fingerprint) { observation throws(DialogPlanError) in
            guard let dialog = observation.result.dialog else { throw .unsupported(Self.changedMessage) }
            let request = BlockedRequestMatch.request(for: dialog, in: requests)
            answered = BlockedCard(dialog: dialog, request: request)
            return try DialogActionPlanner.plan(
                action, for: dialog, toolUseID: program == .claude ? request?.callID : nil)
        }
        if isConfirmed, let answered { record(action, on: answered) }
    }

    /// Keeps what the transcript won't show of an answer that took effect.
    private func record(_ action: DialogAction, on card: BlockedCard) {
        let dialog = card.dialog
        switch action {
        case .choose(let ordinal) where dialog.kind == .codexAsyncQuestion:
            let title = DialogRowScanner.comparable(dialog.title)
            guard let option = dialog.option(ordinal),
                let question = card.request?.questions.first(where: { DialogRowScanner.comparable($0.text) == title }),
                let id = question.id
            else { return }
            history.queue(option.label, forQuestion: id)
        case .choose(let ordinal), .amend(let ordinal, _):
            let allows: Set<DialogOptionRole> = [.approve, .approvePersistent, .approveModeSwitch]
            guard let id = card.request?.callID, let role = dialog.option(ordinal)?.role, allows.contains(role) else {
                return
            }
            history.record(.allowed, forCall: id)
        case .dismiss:
            guard let id = card.request?.callID else { return }
            history.record(.stopped, forCall: id)
        case .respond, .approvePlan, .submitSelection, .expandQuestions, .skipQuestion:
            break
        }
    }

    /// Answers a question form: each page in turn, checked against its
    /// question before its keys and turned by them, then Claude's review
    /// page once it lists the same answers. A page that shows anything else
    /// stops the answers there, on the generic card.
    func submit(_ answers: [QuestionFormAnswer]) async {
        guard progress == .ready, case .card(let shown) = content, let form = QuestionForm(card: shown),
            answers.count == form.questions.count
        else { return }
        progress = .acting
        notice = nil
        // A text the dialog won't take would stop the answers part way.
        for case .text(let text) in answers {
            do {
                _ = try DialogActionPlanner.fieldText(text)
            } catch {
                finish(notice: error.message)
                return
            }
        }
        guard var current = await observe() else {
            finish(notice: Self.unreadMessage)
            return
        }
        present(current)
        guard current.result.fingerprint == shown.dialog.fingerprint, var page = current.result.dialog else {
            finish(notice: Self.changedMessage)
            return
        }
        let toolUseID = program == .claude ? shown.request?.callID : nil
        await waitOutGrace(for: page.fingerprint)
        for index in form.questions.indices {
            let stopped =
                "Heeler stopped at question \(index + 1): the dialog didn't respond the way it expected. "
                + Self.finishThere
            let plan: DialogActionPlan
            do {
                plan = try DialogActionPlanner.plan(
                    form.action(answers[index], forQuestion: index, on: page), for: page, toolUseID: toolUseID)
            } catch {
                if index == 0 {
                    finish(notice: error.message)
                } else {
                    stopPartWay(on: page.fingerprint, last: current, reason: "\(error.message) \(Self.finishThere)")
                }
                return
            }
            guard case .sent(let turned) = await send(plan.steps, to: page.fingerprint, stopReason: stopped) else {
                return
            }
            // Codex submits every answer with the last one.
            if index == form.questions.count - 1, program == .codex {
                await confirm(plan, on: page.fingerprint)
                return
            }
            guard let turned, let next = turned.result.dialog else {
                stopPartWay(on: page.fingerprint, last: turned ?? current, reason: stopped)
                return
            }
            current = turned
            page = next
            // The page just drew: a key now could land before it.
            try? await clock.sleep(timing.grace)
        }
        let reviewProblem =
            "Claude's review lists other answers than the card's, so Heeler didn't submit them. "
            + "Check them here or in the terminal."
        guard form.review(page, shows: answers), let submitOption = page.options.first(where: { $0.role == .submit }),
            let plan = try? DialogActionPlanner.plan(
                .choose(ordinal: submitOption.ordinal), for: page, toolUseID: toolUseID)
        else {
            stopPartWay(on: page.fingerprint, last: current, reason: reviewProblem)
            return
        }
        guard case .sent = await send(plan.steps, to: page.fingerprint) else { return }
        await confirm(plan, on: page.fingerprint)
    }

    /// The generic card's option button.
    func press(number: Int) async {
        guard progress == .ready, case .generic(let shown) = content else { return }
        let program = program
        await act(on: shown.fingerprint) { [degraded] observation throws(DialogPlanError) in
            let excerpt: GenericDialogExcerpt
            switch observation.result {
            case .unrecognized(let fresh):
                excerpt = fresh
            case .dialog(let dialog):
                excerpt = Self.excerpt(of: dialog, on: observation.screen, reason: degraded?.reason ?? "")
            case .none:
                throw .unsupported(Self.changedMessage)
            }
            return try DialogActionPlanner.plan(number: number, for: excerpt, program: program)
        }
    }

    /// The key pad: keys the user picks, sent as they are, then a fresh read.
    func sendKeys(_ keys: [String]) async {
        guard progress != .acting else { return }
        progress = .acting
        notice = nil
        do {
            try await io.sendKeys(keys)
        } catch {
            notice = Self.sendFailure(error)
        }
        try? await clock.sleep(timing.pollInterval)
        progress = .ready
        if let observation = await observe() { present(observation) }
    }

    // MARK: Watching

    private func updateWatching() {
        let shouldWatch = isVisible && !isSuspended && activity == .blocked
        if shouldWatch, watcher == nil {
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    try? await self.clock.sleep(self.timing.watchInterval)
                }
            }
        } else if !shouldWatch, let watcher {
            watcher.cancel()
            self.watcher = nil
        }
    }

    /// One watch read; an action in flight reads for itself. Internal for
    /// tests, which drive reads directly.
    func refresh() async {
        guard progress != .acting else { return }
        let observation = await observe()
        guard progress != .acting, activity == .blocked else { return }
        guard let observation else {
            if content == .none, !isQuiet { content = .unreadable }
            return
        }
        if progress == .unconfirmed { progress = .ready }
        present(observation)
    }

    // MARK: Acting

    /// Whether the plan's effect showed.
    @discardableResult
    private func act(
        on shown: DialogFingerprint,
        plan makePlan: (DialogObservation) throws(DialogPlanError) -> DialogActionPlan
    ) async -> Bool {
        progress = .acting
        notice = nil
        guard let fresh = await observe() else {
            finish(notice: Self.unreadMessage)
            return false
        }
        present(fresh)
        guard fresh.result.fingerprint == shown else {
            finish(notice: Self.changedMessage)
            return false
        }
        let plan: DialogActionPlan
        do {
            plan = try makePlan(fresh)
        } catch {
            finish(notice: error.message)
            return false
        }
        await waitOutGrace(for: shown)
        guard case .sent = await send(plan.steps, to: shown) else { return false }
        return await confirm(plan, on: shown)
    }

    private enum StepsOutcome {
        /// Every step went out. Carries the read that met the last step
        /// when that step was a check.
        case sent(DialogObservation?)
        /// A check failed or a send did; the card says so.
        case stopped
    }

    /// Sends `steps` to the dialog with `fingerprint`, checking each
    /// expectation before the next step.
    private func send(
        _ steps: [DialogStep], to fingerprint: DialogFingerprint,
        stopReason: String = BlockedCardStore.stoppedMessage
    ) async -> StepsOutcome {
        var checked: DialogObservation?
        for step in steps {
            do {
                switch step {
                case .keys(let keys):
                    try await io.sendKeys(keys)
                    checked = nil
                case .paste(let text):
                    try await io.paste(text)
                    checked = nil
                case .expect(let expectation):
                    let check = await poll(within: timing.expectationWindow) {
                        expectation.isMet(by: $0, fingerprint: fingerprint)
                    }
                    guard check.isMet else {
                        stopPartWay(on: fingerprint, last: check.last, reason: stopReason)
                        return .stopped
                    }
                    checked = check.last
                }
            } catch {
                finish(notice: Self.sendFailure(error))
                return .stopped
            }
        }
        return .sent(checked)
    }

    /// Watches for the plan's effect on the dialog with `fingerprint`, and
    /// says whether it showed.
    @discardableResult
    private func confirm(_ plan: DialogActionPlan, on fingerprint: DialogFingerprint) async -> Bool {
        let confirmation = await poll(within: timing.confirmationWindow) {
            plan.confirmation.isMet(by: $0, fingerprint: fingerprint)
        }
        guard confirmation.isMet, let confirmed = confirmation.last else {
            progress = .unconfirmed
            notice = "The Agent hasn't responded yet."
            return false
        }
        progress = .ready
        quietSince = clock.now()
        present(confirmed)
        if plan.focusesComposer { composerFocusRequest += 1 }
        return true
    }

    private func finish(notice: String) {
        progress = .ready
        self.notice = notice
    }

    /// A step the dialog did not answer as expected: nothing more is sent,
    /// and the dialog falls back to the generic card with the reason.
    private func stopPartWay(
        on fingerprint: DialogFingerprint, last: DialogObservation?, reason: String = BlockedCardStore.stoppedMessage
    ) {
        degraded = (fingerprint, reason)
        progress = .ready
        if let last { present(last) }
        notice = reason
    }

    private func waitOutGrace(for fingerprint: DialogFingerprint) async {
        guard let firstSeen, firstSeen.fingerprint == fingerprint else { return }
        let wait = firstSeen.at + timing.grace - clock.now()
        if wait > .zero { try? await clock.sleep(wait) }
    }

    /// Reads until `isMet` holds or the window closes, with the last read.
    private func poll(
        within window: Duration, until isMet: (DialogObservation) -> Bool
    ) async -> (isMet: Bool, last: DialogObservation?) {
        let deadline = clock.now() + window
        var last: DialogObservation?
        while true {
            if let observation = await observe() {
                last = observation
                if isMet(observation) { return (true, observation) }
            }
            if clock.now() >= deadline || Task.isCancelled { return (false, last) }
            try? await clock.sleep(timing.pollInterval)
        }
    }

    private func observe() async -> DialogObservation? {
        guard let screen = try? await io.readScreen() else { return nil }
        return DialogObservation(
            screen: screen, program: program, activity: activity, resolvedToolUseIDs: resolvedToolUseIDs)
    }

    // MARK: Presenting

    private func present(_ observation: DialogObservation) {
        let fingerprint = observation.result.fingerprint
        if fingerprint != firstSeen?.fingerprint {
            firstSeen = fingerprint.map { ($0, clock.now()) }
            if degraded?.fingerprint != fingerprint { degraded = nil }
            if fingerprint != nil { isCollapsed = false }
            notice = nil
        }
        let next: Content
        switch observation.result {
        case .dialog(let dialog):
            if let degraded, degraded.fingerprint == dialog.fingerprint {
                next = .generic(Self.excerpt(of: dialog, on: observation.screen, reason: degraded.reason))
            } else {
                next = .card(
                    BlockedCard(dialog: dialog, request: BlockedRequestMatch.request(for: dialog, in: pendingRequests)))
            }
        case .unrecognized(let excerpt):
            next = .generic(excerpt)
        case .none:
            next = observation.activity == .blocked && !isQuiet ? .unreadable : .none
        }
        if next != content { content = next }
    }

    /// Within the moment around a dialog appearing or going, when Blocked
    /// with nothing on screen is expected.
    private var isQuiet: Bool {
        guard let quietSince else { return false }
        return clock.now() - quietSince < timing.unreadableAfter
    }

    private func clear() {
        if content != .none { content = .none }
        if progress != .ready { progress = .ready }
        if notice != nil { notice = nil }
        isCollapsed = false
        firstSeen = nil
        degraded = nil
    }

    /// A recognized dialog as the generic card shows it.
    private static func excerpt(of dialog: BlockedDialog, on screen: ANSIScreen, reason: String) -> GenericDialogExcerpt {
        let rows = dialog.rows.clamped(to: screen.rows.indices)
        var numbered: [Int: String] = [:]
        for option in dialog.options {
            if let number = option.number { numbered[number] = option.label }
        }
        return GenericDialogExcerpt(
            rows: Array(screen.rows[rows]), numbered: numbered, reason: reason, fingerprint: dialog.fingerprint)
    }

    private static func isOpen(_ status: ChatToolActivity.Status) -> Bool {
        status == .running || status == .awaitingApproval
    }

    private static let changedMessage = "This prompt changed. Check it before answering."
    private static let unreadMessage = "Heeler couldn't read the Agent's screen, so nothing was sent."
    private static let finishThere = "Finish here or in the terminal."
    private static let stoppedMessage =
        "The dialog didn't respond the way Heeler expected, so it stopped. " + finishThere

    private static func sendFailure(_ error: any Error) -> String {
        let prefix = "Heeler couldn't reach the Agent, so the answer may not have gone."
        guard let error = error as? TransportError else { return prefix }
        return "\(prefix) \(error.presentation.explanation)"
    }
}

extension DialogPlanError {
    /// Why a card sent nothing, for the card.
    var message: String {
        switch self {
        case .unsupported(let reason): reason
        case .noSuchOption: "That option isn't on the screen any more."
        case .noFocus: "Heeler can't tell which option is selected. Answer in the terminal."
        case .textFieldNotEmpty:
            "The dialog holds text typed in the terminal. Finish it there; Heeler never clears it."
        case .needsText: "Type an answer for this option first."
        case .emptyText: "Type something first."
        case .multilineText: "Use one line. A line break would answer early."
        case .unsafeText: "Remove tabs and control characters. The program would read them as keys."
        case .emptySelection: "Pick at least one answer."
        }
    }
}
