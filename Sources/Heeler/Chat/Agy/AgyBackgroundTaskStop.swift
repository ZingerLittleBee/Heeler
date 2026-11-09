import Foundation

/// What Chat's Stop presses in Antigravity CLI after its Esc, for the
/// commands the stopped turn sent to the background (ADR 0024). agy 1.5.3
/// makes a command a background task once its WaitMsBeforeAsync passes,
/// 10 s on every call seen, and from then on Esc and Ctrl+C leave it
/// running; only `k` in agy's `/tasks` panel ends it, with no confirmation.
///
/// Once the screen shows the turn ended, this types `/tasks` into the empty
/// box, presses Enter on the `/` popup's `/tasks` row, and then, in the
/// panel, `k` on each of the turn's running commands that is not a daemon,
/// moving one row at a time, and Esc to close it. Every key goes only after
/// a fresh read passes its check. The panel's top rows must name all of
/// the turn's background commands, newest first, so a task from an earlier
/// turn is never selected: rows match by command, since their times are
/// the Host's local time. A check that fails presses nothing more but an
/// Esc that closes the panel, and says what still runs.
@MainActor
struct AgyBackgroundTaskStop {
    struct Timing: Sendable {
        /// How long the turn may take to end after the Esc; past it Stop's
        /// own wait says the Agent still works.
        var turnEnd: Duration = .seconds(3)
        /// How long the popup, the panel or a move may take to show.
        var step: Duration = .milliseconds(1_500)
        /// How long a killed row may take to stop reading `running`: under
        /// a second, twice, live.
        var kill: Duration = .seconds(2)
        var poll: Duration = .milliseconds(150)
        /// How long Chat's transcript may take to bring a command's task:
        /// the read under way may have begun before agy wrote it, and a read
        /// that found new lines took up to 5.8 s over SFTP (live, 31 reads).
        var transcript: Duration = .seconds(8)
    }

    /// The turn Chat's transcript leaves open, as last read.
    struct OpenTurn: Equatable, Sendable {
        /// The conversation Chat follows (`AgentChatStore.conversationGeneration`).
        var conversation: Int
        /// The turn's first entry; nil for a turn opened above the loaded
        /// lines. A prompt, or a task's end after a reply, opens another.
        var firstEntry: ChatEntryID?
        /// Its background commands, oldest first
        /// (`ChatTranscript.openTurnBackgroundCommands`).
        var commands: [ChatBackgroundCommand]

        func isSameTurn(as other: OpenTurn) -> Bool {
            conversation == other.conversation && firstEntry == other.firstEntry
        }
    }

    /// What the follow-through reads of Chat's conversation.
    struct Transcript {
        /// A send of Chat's waits for its record, so the open turn the
        /// transcript shows may be the one before.
        var awaitsRecord: @MainActor () -> Bool
        var openTurn: @MainActor () -> OpenTurn
        /// `AgentChatStore.readAgain(within:until:)`.
        var readAgain: @MainActor (Duration, @MainActor () -> Bool) async -> Bool
    }

    /// What Chat's Stop presses after its Esc, built as Stop is tapped so it
    /// stops the turn the tap saw (`ChatStopPlan.composerInterrupt`); nil
    /// while a send of Chat's waits for its record. Only a send whose echo
    /// still waits can be that turn's prompt; an overdue one would otherwise
    /// keep Stop from every later turn.
    ///
    /// agy writes the step that makes a command a task as it lists the task
    /// under the box, but Chat's read can bring it seconds later, after a
    /// tap (live). So with none of the open turn's commands read at the tap,
    /// a task listed on the screen after the Esc has Chat read again, and
    /// the commands that turn then has, if it is still the open one, are
    /// ended.
    static func followThrough(
        reading transcript: Transcript, io: BlockedScreenIO, mayContinue: @escaping @MainActor () -> Bool,
        timing: Timing = Timing(), clock: BlockedCardClock = .live
    ) -> ChatStopFollowThrough? {
        guard !transcript.awaitsRecord() else { return nil }
        let tapped = transcript.openTurn()
        func stop(_ turn: OpenTurn) -> AgyBackgroundTaskStop? {
            guard turn.isSameTurn(as: tapped) else { return nil }
            return AgyBackgroundTaskStop(
                commands: turn.commands, io: io, mayContinue: mayContinue, timing: timing, clock: clock)
        }
        if let stop = stop(tapped) { return { await stop.run() } }
        return {
            guard let screen = try? await io.readScreen(), AgyScreen(screen).showsRunningTasks else { return nil }
            _ = await transcript.readAgain(timing.transcript) { stop(transcript.openTurn()) != nil }
            return await stop(transcript.openTurn())?.run()
        }
    }

    /// Why a step stopped.
    private struct Halt: Error {}

    /// The turn's background commands, newest first as the panel lists them.
    private let listed: [ChatBackgroundCommand]
    /// What the panel's top rows read: the commands, newest first.
    private let names: [String?]
    private let io: BlockedScreenIO
    private let mayContinue: @MainActor () -> Bool
    private let timing: Timing
    private let clock: BlockedCardClock

    /// - Parameters:
    ///   - commands: The stopped turn's background commands, oldest first
    ///     (`ChatTranscript.openTurnBackgroundCommands`; see
    ///     `followThrough`). Nil when none is a running command other than
    ///     a daemon.
    ///   - mayContinue: Checked before every key: false while a Composer
    ///     send types, which could land in the box between two of them.
    init?(
        commands: [ChatBackgroundCommand], io: BlockedScreenIO, mayContinue: @escaping @MainActor () -> Bool,
        timing: Timing = Timing(), clock: BlockedCardClock = .live
    ) {
        guard commands.contains(where: \.isStoppable) else { return nil }
        listed = commands.reversed()
        names = listed.map { $0.command?.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.io = io
        self.mayContinue = mayContinue
        self.timing = timing
        self.clock = clock
    }

    /// Ends the turn's running commands; returns what still runs and how to
    /// end it, or nil when they ended or the turn did not.
    func run() async -> String? {
        do {
            // A turn that keeps running is Stop's own wait's to report, and a
            // second tap follows through again.
            guard try await poll(within: timing.turnEnd, until: { !AgyScreen($0).showsRunningTurn }) != nil
            else { return nil }
        } catch {
            return Self.unreadNotice(for: listed.filter(\.isStoppable))
        }
        var ended: Set<Int> = []
        do {
            try await press(.paste(Self.tasksCommand), when: Self.showsIdleBox)
            _ = try await screen(within: timing.step, showing: Self.showsTasksPopup)
            try await press(.keys(["enter"]), when: Self.showsTasksPopup)
            let names = names
            var panel = try await self.panel(within: timing.step) { _ in true }
            for index in listed.indices where listed[index].isStoppable {
                let row = panel.rows[index]
                if row.hasEnded {
                    ended.insert(index)
                    continue
                }
                guard row.isRunning else { throw Halt() }
                while let from = panel.selected, from != index {
                    let to = from < index ? from + 1 : from - 1
                    try await press(.keys([from < index ? "down" : "up"])) {
                        Self.panel(on: $0, naming: names)?.selected == from
                    }
                    panel = try await self.panel(within: timing.step) { $0.selected == to }
                }
                try await press(.keys(["k"])) { screen in
                    guard let panel = Self.panel(on: screen, naming: names), panel.selected == index else { return false }
                    return panel.rows[index].isRunning
                }
                panel = try await self.panel(within: timing.kill) { $0.rows[index].hasEnded }
                ended.insert(index)
            }
            try await press(.keys(["esc"]), when: Self.showsPanel)
            guard try await poll(within: timing.step, until: { !Self.showsPanel($0) }) != nil else {
                return Self.panelLeftOpen
            }
            return nil
        } catch {
            let closed = await closePanel()
            let left = listed.indices.filter { listed[$0].isStoppable && !ended.contains($0) }
            if left.isEmpty { return closed ? nil : Self.panelLeftOpen }
            return Self.notice(for: left.map { listed[$0] })
        }
    }

    // MARK: Steps

    /// Types after a fresh read passes `check`. Where the typing checks the
    /// screen again itself (`BlockedScreenIO.typeWhileShowing`), that read is
    /// the one it holds to.
    private func press(
        _ typing: BlockedScreenIO.Typing, when check: @escaping @Sendable (ANSIScreen) -> Bool
    ) async throws {
        guard mayContinue(), check(try await io.readScreen()) else { throw Halt() }
        try await io.type(typing, whileShowing: check)
    }

    /// Reads the screen until one passes `isDone`, for up to `window`.
    private func poll(
        within window: Duration, until isDone: (ANSIScreen) -> Bool
    ) async throws -> ANSIScreen? {
        let deadline = clock.now() + window
        while true {
            let screen = try await io.readScreen()
            if isDone(screen) { return screen }
            guard clock.now() < deadline else { return nil }
            try await clock.sleep(timing.poll)
        }
    }

    private func screen(within window: Duration, showing isDone: (ANSIScreen) -> Bool) async throws -> ANSIScreen {
        guard let screen = try await poll(within: window, until: isDone) else { throw Halt() }
        return screen
    }

    /// The panel naming the turn's commands, once it also passes `isDone`.
    private func panel(
        within window: Duration, until isDone: (AgyScreen.TaskPanel) -> Bool
    ) async throws -> AgyScreen.TaskPanel {
        let names = names
        let screen = try await screen(within: window) { screen in
            Self.panel(on: screen, naming: names).map(isDone) == true
        }
        guard let panel = Self.panel(on: screen, naming: names) else { throw Halt() }
        return panel
    }

    /// After a failed check: Esc while the panel shows, unless a send types.
    /// Returns whether no panel shows.
    private func closePanel() async -> Bool {
        guard let screen = try? await io.readScreen() else { return false }
        guard Self.showsPanel(screen) else { return true }
        guard mayContinue(), (try? await io.type(.keys(["esc"]), whileShowing: Self.showsPanel)) != nil else {
            return false
        }
        return (try? await poll(within: timing.step, until: { !Self.showsPanel($0) })) != nil
    }

    // MARK: Screens

    nonisolated static let tasksCommand = "/tasks"

    /// agy's empty idle box, with no dialog, popup or running turn: what a
    /// Composer send needs too.
    nonisolated static func showsIdleBox(_ screen: ANSIScreen) -> Bool {
        InputBoxStateDetector.detect(screen, program: .agy).isSendable
    }

    /// `> /tasks  View background tasks` under the box holding `/tasks`.
    nonisolated static func showsTasksPopup(_ screen: ANSIScreen) -> Bool {
        let agy = AgyScreen(screen)
        return agy.composer?.mode == .prompt && agy.composer?.draft == tasksCommand
            && agy.slashSelection == AgyScreen.SlashSelection(command: tasksCommand, description: "View background tasks")
    }

    nonisolated static func showsPanel(_ screen: ANSIScreen) -> Bool {
        AgyScreen(screen).taskPanel != nil
    }

    /// The panel when its top rows name `names` in order.
    nonisolated static func panel(on screen: ANSIScreen, naming names: [String?]) -> AgyScreen.TaskPanel? {
        guard let panel = AgyScreen(screen).taskPanel, panel.rows.count >= names.count,
            zip(panel.rows, names).allSatisfy({ $0.command == $1 })
        else { return nil }
        return panel
    }

    // MARK: Notices

    /// Why a Composer send waits while this types.
    static let sendHold =
        "Stop is still ending the turn's background commands in Antigravity CLI. Try again in a moment."

    static let panelLeftOpen =
        "Stop ended the turn and its background commands, but Antigravity CLI's task list may still be open. Close it in the terminal with Esc."

    /// What still runs once the turn ended, and how to end it in the terminal.
    static func notice(for commands: [ChatBackgroundCommand]) -> String {
        let one = commands.count == 1
        return "Stop ended the turn, but \(list(commands)) still \(one ? "runs" : "run") in the background. "
            + "Stop \(one ? "it" : "them") in the terminal: /tasks, then k."
    }

    /// What may still run when no screen showed the turn's end.
    static func unreadNotice(for commands: [ChatBackgroundCommand]) -> String {
        "Heeler couldn't read the Agent's screen after Stop, so \(list(commands)) may still run in the background. "
            + "Stop \(commands.count == 1 ? "it" : "them") in the terminal: /tasks, then k."
    }

    /// `“a”`, `“a” and “b”`, `“a”, “b” and “c”`.
    private static func list(_ commands: [ChatBackgroundCommand]) -> String {
        let names = commands.map { command in
            command.command.map { "\u{201C}\(short($0))\u{201D}" } ?? "a command"
        }
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A command short enough to read in a notice.
    private static func short(_ command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 40 || line != command else { return trimmed }
        return String(trimmed.prefix(39)) + "\u{2026}"
    }
}

extension AgyBackgroundTaskStop.Transcript {
    /// The conversation `chat` follows.
    init(chat: AgentChatStore, awaitsRecord: @escaping @MainActor () -> Bool) {
        self.init(
            awaitsRecord: awaitsRecord,
            openTurn: {
                let transcript = chat.conversation.transcript
                return AgyBackgroundTaskStop.OpenTurn(
                    conversation: chat.conversationGeneration, firstEntry: transcript.turns.last?.firstEntryID,
                    commands: transcript.openTurnBackgroundCommands)
            },
            readAgain: { await chat.readAgain(within: $0, until: $1) })
    }
}
