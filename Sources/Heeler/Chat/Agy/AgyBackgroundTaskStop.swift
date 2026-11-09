import Foundation
import os

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
/// the Host's local time. A check that fails presses nothing more than what
/// takes `/tasks` back out, and says what still runs.
@MainActor
struct AgyBackgroundTaskStop {
    struct Timing: Sendable {
        /// How long the turn may take to end after the Esc; past it Stop's
        /// own wait says the Agent still works.
        var turnEnd: Duration = .seconds(3)
        /// How long the popup, the panel or a move may take to show. A read's
        /// own time, 0.8 to 1.65 s through herdr live, does not count
        /// against it (`poll`).
        var step: Duration = .seconds(3)
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
    /// Chat reads again unless the screen after the Esc lists no task, and
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
            // Only a screen that shows no task spares the wait; one that
            // could not be read says nothing of what runs.
            if let screen = try? await io.readScreen(), !AgyScreen(screen).showsRunningTasks { return nil }
            _ = await transcript.readAgain(timing.transcript) { stop(transcript.openTurn()) != nil }
            return await stop(transcript.openTurn())?.run()
        }
    }

    /// Why a step stopped: what it waited for and did not see.
    private struct Halt: Error {
        let step: String
    }

    private static let logger = Logger(subsystem: "dev.bybee.heeler", category: "ChatStop")

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
        let stoppable = listed.filter(\.isStoppable)
        do {
            // A turn that keeps running is Stop's own wait's to report, and a
            // second tap follows through again.
            guard try await poll(within: timing.turnEnd, until: { !AgyScreen($0).showsRunningTurn }) != nil
            else { return nil }
            guard mayContinue(), Self.showsIdleBox(try await io.readScreen()) else { throw Halt(step: "the idle box") }
        } catch {
            Self.log(error)
            return error is Halt ? Self.notice(for: stoppable) : Self.unreadNotice(for: stoppable)
        }
        var ended: Set<Int> = []
        do {
            try await io.type(.paste(Self.tasksCommand), whileShowing: Self.showsIdleBox)
            _ = try await screen(within: timing.step, step: "the popup", showing: Self.showsTasksPopup)
            try await press(.keys(["enter"]), step: "the popup", when: Self.showsTasksPopup)
            let names = names
            var panel = try await self.panel(within: timing.step, step: "the panel") { _ in true }
            for index in listed.indices where listed[index].isStoppable {
                let row = panel.rows[index]
                if row.hasEnded {
                    ended.insert(index)
                    continue
                }
                guard row.isRunning else { throw Halt(step: "a running row") }
                while let from = panel.selected, from != index {
                    let to = from < index ? from + 1 : from - 1
                    try await press(.keys([from < index ? "down" : "up"]), step: "the selected row") {
                        Self.panel(on: $0, naming: names)?.selected == from
                    }
                    panel = try await self.panel(within: timing.step, step: "the next row") { $0.selected == to }
                }
                try await press(.keys(["k"]), step: "the row to kill") { screen in
                    guard let panel = Self.panel(on: screen, naming: names), panel.selected == index else { return false }
                    return panel.rows[index].isRunning
                }
                panel = try await self.panel(within: timing.kill, step: "the row ended") { $0.rows[index].hasEnded }
                ended.insert(index)
            }
            try await press(.keys(["esc"]), step: "the panel", when: Self.showsPanel)
            guard try await poll(within: timing.step, until: { !Self.showsPanel($0) }) != nil else {
                return Self.panelLeftOpen
            }
            return nil
        } catch {
            Self.log(error)
            let undone = await undoTasks()
            let left = listed.indices.filter { listed[$0].isStoppable && !ended.contains($0) }
            if left.isEmpty { return undone ? nil : Self.panelLeftOpen }
            return Self.notice(for: left.map { listed[$0] })
        }
    }

    // MARK: Steps

    /// Types after a fresh read passes `check`. Where the typing checks the
    /// screen again itself (`BlockedScreenIO.typeWhileShowing`), that read is
    /// the one it holds to.
    private func press(
        _ typing: BlockedScreenIO.Typing, step: String, when check: @escaping @Sendable (ANSIScreen) -> Bool
    ) async throws {
        try await press(typing, on: try await io.readScreen(), step: step, when: check)
    }

    /// Types if `screen`, just read, passes `check`, unless a send types.
    private func press(
        _ typing: BlockedScreenIO.Typing, on screen: ANSIScreen, step: String,
        when check: @escaping @Sendable (ANSIScreen) -> Bool
    ) async throws {
        guard mayContinue(), check(screen) else { throw Halt(step: step) }
        try await io.type(typing, whileShowing: check)
    }

    /// Reads the screen until one passes `isDone`, for up to `window`. The
    /// window is agy's to draw in: a read shows the screen as it reaches
    /// herdr, and the first one after a key often showed agy before it
    /// drew (live), so the last read is the first to begin once the
    /// window passed, however long a read takes. A read that fails is
    /// tried again until then, so one failing herdr read does not stop a
    /// step the next would see.
    private func poll(
        within window: Duration, until isDone: (ANSIScreen) -> Bool
    ) async throws -> ANSIScreen? {
        let deadline = clock.now() + window
        while true {
            let begun = clock.now()
            do {
                let screen = try await io.readScreen()
                if isDone(screen) { return screen }
            } catch {
                guard begun < deadline else { throw error }
            }
            guard begun < deadline else { return nil }
            try await clock.sleep(timing.poll)
        }
    }

    private func screen(
        within window: Duration, step: String, showing isDone: (ANSIScreen) -> Bool
    ) async throws -> ANSIScreen {
        guard let screen = try await poll(within: window, until: isDone) else { throw Halt(step: step) }
        return screen
    }

    /// The panel naming the turn's commands, once it also passes `isDone`.
    private func panel(
        within window: Duration, step: String, until isDone: (AgyScreen.TaskPanel) -> Bool
    ) async throws -> AgyScreen.TaskPanel {
        let names = names
        let screen = try await screen(within: window, step: step) { screen in
            Self.panel(on: screen, naming: names).map(isDone) == true
        }
        guard let panel = Self.panel(on: screen, naming: names) else { throw Halt(step: step) }
        return panel
    }

    /// After a failed check or key: takes back what this typed, unless a
    /// send types. Esc closes the panel, which leaves the box empty; in the
    /// box, a Backspace for each of `/tasks`'s characters, sent at once,
    /// clears it and closes its popup. Esc would close the popup but keep
    /// `/tasks`, and a second Esc open the popup again (agy 1.5.3, live).
    /// Returns whether neither shows.
    private func undoTasks() async -> Bool {
        do {
            var screen = try await io.readScreen()
            if Self.showsPanel(screen) {
                try await press(.keys(["esc"]), on: screen, step: "the panel to close", when: Self.showsPanel)
                guard let closed = try await poll(within: timing.step, until: { !Self.showsPanel($0) }) else {
                    return false
                }
                screen = closed
            }
            guard Self.holdsTasks(screen) else { return true }
            try await press(.keys(Self.eraseTasks), on: screen, step: "/tasks to erase", when: Self.holdsTasks)
            return try await poll(within: timing.step, until: { !Self.holdsTasks($0) }) != nil
        } catch {
            Self.log(error)
            return false
        }
    }

    private static func log(_ error: any Error) {
        if let halt = error as? Halt {
            logger.notice("Stop's follow-through did not see \(halt.step, privacy: .public)")
        } else {
            logger.error("Stop's follow-through could not read or type: \(String(describing: error))")
        }
    }

    // MARK: Screens

    nonisolated static let tasksCommand = "/tasks"
    nonisolated static let eraseTasks = Array(repeating: "backspace", count: tasksCommand.count)

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

    /// The panel, whether or not its rows read: `Tasks` under the box, as
    /// over `No background tasks.`.
    nonisolated static func showsPanel(_ screen: ANSIScreen) -> Bool {
        let agy = AgyScreen(screen)
        return agy.taskPanel != nil || agy.below == "Tasks"
    }

    /// The box holding the `/tasks` this typed, with its popup or not.
    nonisolated static func holdsTasks(_ screen: ANSIScreen) -> Bool {
        let box = AgyScreen(screen).composer
        return box?.mode == .prompt && box?.draft == tasksCommand
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
