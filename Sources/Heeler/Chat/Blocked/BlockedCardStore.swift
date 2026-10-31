import Foundation
import Observation

/// The Agent's pane as a Blocked card reads and answers it: the screen
/// through `agent.read`, keys through `agent.send_keys` and typed text
/// through `pane.send_input`. Never the Attach PTY. On herdr-core, a viewer's
/// paint and an attach of Chat's own (ADR 0035), which refuses a key once the
/// Agent no longer holds the foreground the screen was read under.
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

/// Chat's answer to herdr's Blocked (ADR 0024): the dialog on the Agent's
/// screen as a native card, answered with keys.
///
/// The screen decides everything a card offers. While Chat shows a Blocked
/// Agent the store reads it every second, and also an idle Claude whose
/// AskUserQuestion call is open (see `readsIdleQuestion`). An action reads it again first
/// and sends nothing if the dialog changed, waits until the dialog has
/// shown for a moment, sends the plan's keys while checking each of its
/// expectations, then watches for the effect. Nothing is ever resent: a
/// dialog that does not respond keeps its answers off until the screen
/// shows something else or the transcript shows the answer took.
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
        /// Oh My Pi ignores ctrl+q for 500 ms after drawing an approval.
        /// That time starts before Heeler first sees the panel, so waiting
        /// this long from then is conservative.
        var approvalArm: Duration = .milliseconds(650)
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
        /// The keys went out and the Agent has not shown their effect. Only
        /// Stop acts until a read shows another screen or a waiting call
        /// resolves (on Grok Build, one the card could be answering starts
        /// or resolves): the keys may still land.
        case unconfirmed
    }

    let program: ChatProgram
    private(set) var content: Content = .none
    /// What the `.unreadable` card says in place of its sentence and key
    /// pad, for a program whose prompt would act on the pad's keys (see
    /// `ChatProgram.offersKeysWhenBlockedWithoutDialog`). nil keeps both.
    private(set) var unreadableNote: String?
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
    /// Bumped when another dialog shows, and not when the same one's focus
    /// moves, which on OpenCode swaps a permission's lines for its rule's.
    /// The card's identity, so a note or choice made on one dialog's card
    /// never carries to the next.
    private(set) var dialogGeneration = 0

    /// Whether Stop acts: also after an answer that showed no effect, as a
    /// way out of a dialog that keeps the card waiting.
    var canStop: Bool { progress != .acting }

    @ObservationIgnored private let io: BlockedScreenIO
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let clock: BlockedCardClock
    @ObservationIgnored private var activity: ChatAgentActivity = .unknown
    @ObservationIgnored private var pendingRequests: [ChatPendingRequest] = []
    /// Why the newest turn failed, for a program whose card explains a
    /// block without a dialog.
    @ObservationIgnored private var latestFailure: String?
    @ObservationIgnored private var resolvedToolUseIDs: Set<String> = []
    /// Calls the transcript shows past their approval: running or resolved.
    @ObservationIgnored private var startedToolUseIDs: Set<String> = []
    /// The calls that waited for approval when an action's keys went out,
    /// on Grok Build only those the card could be answering (see
    /// `waitingCalls(answering:)`).
    @ObservationIgnored private var waitingWhenSent: Set<String> = []
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The dialog an answer showed no effect on, while it stays on screen.
    @ObservationIgnored private var unconfirmedFingerprint: DialogFingerprint?
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

    /// A Chat view shows the Agent: watch it while it is Blocked, or while
    /// an idle Claude has an open AskUserQuestion call.
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
    /// action is still checking its effect, or an idle Claude still has an
    /// open AskUserQuestion call.
    func update(activity: ChatAgentActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        if activity == .blocked { quietSince = clock.now() }
        if !readsScreen, progress != .acting { clear() }
        updateWatching()
    }

    /// The conversation as last read: requests a card can match, and calls
    /// whose results confirm an answer or, on Grok Build, whose starts show
    /// it took.
    func update(transcript: ChatTranscript) {
        let waiting = Set(pendingRequests.compactMap(\.callID))
        pendingRequests = transcript.pendingRequests
        if !program.offersKeysWhenBlockedWithoutDialog { latestFailure = Self.latestFailure(in: transcript) }
        var resolved: Set<String> = []
        var started: Set<String> = []
        for entry in transcript.entries {
            switch entry.content {
            case .tool(let tool):
                if let id = tool.callID, !Self.isOpen(tool.status) { resolved.insert(id) }
                if let id = tool.callID, tool.status != .awaitingApproval { started.insert(id) }
            case .plan(let plan):
                if let id = plan.callID, !Self.isOpen(plan.status) { resolved.insert(id) }
            default:
                break
            }
        }
        startedToolUseIDs = started
        releaseIfAWaitingCallStarted()
        // Two identical dialogs in a row look unchanged on screen, so an
        // answer that showed no effect took once a call that waited
        // resolves. A call that only starts waiting proves nothing: the
        // transcript can catch up with the dialog answered. On Grok Build
        // the release above counts a resolved call too, and only one the
        // card could be answering: the previous card's call can resolve in
        // a late read.
        if program != .grok, progress == .unconfirmed,
            !waiting.isDisjoint(with: resolved.subtracting(resolvedToolUseIDs))
        {
            progress = .ready
            unconfirmedFingerprint = nil
        }
        resolvedToolUseIDs = resolved
        // An idle Claude's question reads only while its call is open.
        if !readsScreen, progress != .acting, content != .none { clear() }
        updateWatching()
    }

    /// herdr 0.9.5 reports Claude Code 2.1.301 idle, not Blocked, on some
    /// AskUserQuestion screens: the review page, and a question with
    /// previews. An open AskUserQuestion call stands in for Blocked there.
    private var readsIdleQuestion: Bool {
        program == .claude && activity == .idle && pendingRequests.contains { $0.toolName == "AskUserQuestion" }
    }

    /// Whether the screen may show a dialog the card answers.
    private var readsScreen: Bool { activity == .blocked || readsIdleQuestion }

    // MARK: Actions

    /// Answers the card's dialog. After an answer that showed no effect only
    /// Stop goes until the screen changes, so a second tap is never a
    /// resend.
    func perform(_ action: DialogAction) async {
        guard progress == .ready || (action == .dismiss && canStop), case .card(let shown) = content else { return }
        let requests = pendingRequests
        var answered: BlockedCard?
        let isConfirmed = await act(on: shown.dialog.fingerprint) { observation throws(DialogPlanError) in
            guard let dialog = observation.result.dialog else { throw .unsupported(Self.changedMessage) }
            let request = BlockedRequestMatch.request(for: dialog, in: requests)
            answered = BlockedCard(dialog: dialog, request: request)
            // Each program's planner decides whether the call's result
            // confirms the answer.
            return try DialogActionPlanner.plan(action, for: dialog, toolUseID: request?.callID)
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
            // Claude records a plan's approval itself ("User has approved
            // your plan"), whichever button gave it.
            let allows: Set<DialogOptionRole> = [.approve, .approvePersistent, .approveModeSwitch]
            guard dialog.kind != .claudePlan, let id = card.request?.callID, let role = dialog.option(ordinal)?.role,
                allows.contains(role)
            else { return }
            history.record(.allowed, forCall: id)
        case .dismiss:
            // Oh My Pi's Esc denies the call and goes on, Grok Build's
            // reject row ends the turn, and OpenCode's rejects a permission
            // or dismisses a question, as their transcripts record.
            guard let id = card.request?.callID,
                ![.ompApproval, .grokPermission, .openCodePermission, .openCodeQuestion].contains(dialog.kind)
            else {
                return
            }
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
        let toolUseID = shown.request?.callID
        await waitOutGrace(for: page)
        waitingWhenSent = waitingCalls(answering: page)
        for index in form.questions.indices {
            let stopped =
                "Heeler stopped at question \(index + 1): the dialog didn't respond the way it expected. "
                + Self.finishThere
            let next = index == form.questions.count - 1 ? "Claude's review" : "question \(index + 2)"
            let answered = "Heeler answered question \(index + 1) and can't read \(next). " + Self.finishThere
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
            guard
                case .sent(let turned) = await send(
                    plan.steps, to: page.fingerprint, stopReason: stopped, turnedReason: answered)
            else {
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
        progress = unconfirmedFingerprint == nil ? .ready : .unconfirmed
        if let observation = await observe() {
            releaseIfChanged(observation)
            present(observation)
        }
    }

    // MARK: Watching

    private func updateWatching() {
        let shouldWatch = isVisible && !isSuspended && readsScreen
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
        guard progress != .acting, readsScreen else { return }
        let observation = await observe()
        guard progress != .acting, readsScreen else { return }
        guard let observation else {
            if activity == .blocked, content == .none, !isQuiet {
                let note = whyBlocked(on: nil)
                if note != unreadableNote { unreadableNote = note }
                content = .unreadable
            }
            return
        }
        releaseIfChanged(observation)
        present(observation)
    }

    /// Brings the controls back once the dialog an answer showed no effect
    /// on has gone.
    private func releaseIfChanged(_ observation: DialogObservation) {
        guard progress == .unconfirmed, let unconfirmed = unconfirmedFingerprint else { return }
        if let fresh = observation.result.fingerprint, unconfirmed.matches(fresh) {
            unconfirmedFingerprint = unconfirmed.merging(fresh)
            return
        }
        progress = .ready
        unconfirmedFingerprint = nil
    }

    /// Grok Build can follow an answered card with one just like it, as for
    /// parallel subagents with one description, and herdr stays Blocked
    /// between them, so the answer shows no effect on screen. Grok writes a
    /// call's start only once it runs, after any approval, so a call the
    /// card could be answering that waited when the keys went out and has
    /// started or resolved since shows they took. Another call starting or
    /// resolving shows nothing: the previous card's call read late, or a
    /// call that needs no approval, which reads as waiting until it starts
    /// while herdr reports Blocked. The other programs' open calls read
    /// waiting or running from herdr's status alone, so their answers wait
    /// for a call to resolve or the screen to change.
    private func releaseIfAWaitingCallStarted() {
        guard program == .grok, progress == .unconfirmed, !waitingWhenSent.isDisjoint(with: startedToolUseIDs)
        else { return }
        progress = .ready
        unconfirmedFingerprint = nil
        notice = nil
    }

    /// The waiting calls whose start would show an answer to `dialog`
    /// took: on Grok Build those the card could be answering
    /// (`BlockedRequestMatch.requests(answering:in:)`), or every waiting
    /// call where it matches none, as on the other programs.
    private func waitingCalls(answering dialog: BlockedDialog?) -> Set<String> {
        let waiting = Set(pendingRequests.compactMap(\.callID))
        guard program == .grok, let dialog else { return waiting }
        let answering = Set(BlockedRequestMatch.requests(answering: dialog, in: pendingRequests).compactMap(\.callID))
        return answering.isEmpty ? waiting : answering
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
        await waitOutGrace(for: shown, kind: fresh.result.dialog?.kind)
        waitingWhenSent = waitingCalls(answering: fresh.result.dialog)
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
    ///
    /// - Parameter turnedReason: Why it stopped when a page turn's check
    ///   failed on a screen with no dialog Heeler reads: the keys took, and
    ///   the next page is one it can't read. Another dialog it reads keeps
    ///   `stopReason`.
    private func send(
        _ steps: [DialogStep], to fingerprint: DialogFingerprint,
        stopReason: String = BlockedCardStore.stoppedMessage, turnedReason: String? = nil
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
                        var reason = stopReason
                        if case .page = expectation, let turnedReason, let last = check.last,
                            last.result.dialog == nil
                        {
                            reason = turnedReason
                        }
                        stopPartWay(on: fingerprint, last: check.last, reason: reason)
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
            // The last read can show lines the first didn't, as OpenCode's
            // rule in place of the request once Always allow has focus.
            unconfirmedFingerprint = fingerprint
            if let last = confirmation.last?.result.fingerprint, last.matches(fingerprint) {
                unconfirmedFingerprint = fingerprint.merging(last)
            }
            notice = "The Agent hasn't responded yet. Answer in the terminal if it stays."
            // A start the transcript showed while the effect was checked.
            releaseIfAWaitingCallStarted()
            return false
        }
        progress = .ready
        unconfirmedFingerprint = nil
        quietSince = clock.now()
        present(confirmed)
        if plan.focusesComposer { composerFocusRequest += 1 }
        return true
    }

    private func finish(notice: String) {
        progress = unconfirmedFingerprint == nil ? .ready : .unconfirmed
        self.notice = notice
    }

    /// A step the dialog did not answer as expected: nothing more is sent,
    /// and the dialog falls back to the generic card with the reason.
    private func stopPartWay(
        on fingerprint: DialogFingerprint, last: DialogObservation?, reason: String = BlockedCardStore.stoppedMessage
    ) {
        degraded = (fingerprint, reason)
        progress = .ready
        unconfirmedFingerprint = nil
        if let last { present(last) }
        notice = reason
    }

    private func waitOutGrace(for dialog: BlockedDialog) async {
        await waitOutGrace(for: dialog.fingerprint, kind: dialog.kind)
    }

    /// Waits until the dialog has shown long enough to take a key: the
    /// grace, or an Oh My Pi approval's arm.
    private func waitOutGrace(for fingerprint: DialogFingerprint, kind: BlockedDialogKind?) async {
        guard let firstSeen, firstSeen.fingerprint.matches(fingerprint) else { return }
        let settle = kind == .ompApproval ? max(timing.grace, timing.approvalArm) : timing.grace
        let wait = firstSeen.at + settle - clock.now()
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
        if let seen = firstSeen, let fingerprint, seen.fingerprint.matches(fingerprint) {
            // The same dialog, its focus perhaps moved: keep when it showed,
            // and the lines each read showed of it.
            firstSeen = (seen.fingerprint.merging(fingerprint), seen.at)
        } else if fingerprint != nil || firstSeen != nil {
            firstSeen = fingerprint.map { ($0, clock.now()) }
            dialogGeneration += 1
            if let degraded, fingerprint.map(degraded.fingerprint.matches) != true { self.degraded = nil }
            if fingerprint != nil { isCollapsed = false }
            notice = nil
        }
        let next: Content
        switch observation.result {
        case .dialog(let dialog):
            if let degraded, degraded.fingerprint.matches(dialog.fingerprint) {
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
        let note = next == .unreadable ? whyBlocked(on: observation.screen) : nil
        if note != unreadableNote { unreadableNote = note }
        if next != content { content = next }
    }

    /// Why the Agent is Blocked, said in place of the key pad, for a
    /// program whose prompt would act on its keys: only OpenCode. The
    /// first that applies: a subagent panel on `screen` covering the
    /// request, the newest turn's failure, or a likely failed model
    /// request.
    private func whyBlocked(on screen: ANSIScreen?) -> String? {
        guard !program.offersKeysWhenBlockedWithoutDialog else { return nil }
        if let screen, OpenCodeScreenReader.read(screen).route == .subagentPanel {
            return "OpenCode's subagent panel covers its request. Close the panel in the terminal to answer it."
        }
        if let latestFailure {
            // A question, an exclamation or an ellipsis ends the sentence
            // by itself.
            let end = ["?", "!", "…"].contains { latestFailure.hasSuffix($0) } ? "" : "."
            return "OpenCode stopped with an error: \(latestFailure)\(end) herdr holds Chat's messages while it "
                + "reports Blocked, so continue in the terminal."
        }
        return "OpenCode reports Blocked, but its screen shows no question. This usually means the model request "
            + "failed. Check the terminal."
    }

    /// Within the moment around a dialog appearing or going, when Blocked
    /// with nothing on screen is expected.
    private var isQuiet: Bool {
        guard let quietSince else { return false }
        return clock.now() - quietSince < timing.unreadableAfter
    }

    private func clear() {
        if content != .none { content = .none }
        if unreadableNote != nil { unreadableNote = nil }
        if progress != .ready { progress = .ready }
        unconfirmedFingerprint = nil
        waitingWhenSent = []
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

    /// The newest turn's error, when that turn ended failed or its newest
    /// entry is the error: on one line, and cut after 200 characters.
    private static func latestFailure(in transcript: ChatTranscript) -> String? {
        // Without a turn of their own, the loaded entries are the turn
        // opened above them.
        let start =
            transcript.turns.last.flatMap { turn in transcript.entries.lastIndex { $0.id == turn.firstEntryID } } ?? 0
        let ending = transcript.turns.isEmpty ? transcript.precedingTurnEnd?.ending : transcript.turns.last?.ending
        let newestIsError = transcript.entries.last.flatMap(errorMessage) != nil
        guard ending == .failed || newestIsError,
            let message = transcript.entries[start...].reversed().lazy.compactMap(errorMessage).first
        else { return nil }
        var line = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.count > 200 {
            line = String(line.prefix(200)) + "…"
        } else if line.hasSuffix(".") {
            // The note's own period ends it.
            line.removeLast()
        }
        return line.isEmpty ? nil : line
    }

    private static func errorMessage(_ entry: ChatEntry) -> String? {
        guard case .notice(let notice) = entry.content, notice.kind == .error else { return nil }
        return notice.title
    }

    private static let changedMessage = "This prompt changed. Check it before answering."
    private static let unreadMessage = "Heeler couldn't read the Agent's screen, so nothing was sent."
    private static let finishThere = "Finish here or in the terminal."
    private static let stoppedMessage =
        "The dialog didn't respond the way Heeler expected, so it stopped. " + finishThere

    private static func sendFailure(_ error: any Error) -> String {
        if let refusal = error as? HerdrCoreChatTyping.Refusal { return refusal.message }
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
        case .composerDraft:
            "Oh My Pi's input box holds a draft, so keys would go into it. Press Enter in the terminal to queue it, "
                + "or clear it, then answer."
        }
    }
}
