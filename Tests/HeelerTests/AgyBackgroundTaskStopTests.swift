import Foundation
import Testing

@testable import Heeler

/// agy's `/tasks` popup and panel as `AgyScreen` reads them (agy 1.5.3,
/// read through tmux as plain text).
@Suite("Antigravity CLI tasks panel")
struct AgyTaskPanelTests {
    /// The panel lists every task of the conversation, newest first, and
    /// selects the top one as it opens.
    @Test func thePanelListsTasksNewestFirstWithTheTopOneSelected() throws {
        let panel = try #require(Self.panel("agy-177-plain-tasks-panel-while-working-120x40"))

        #expect(panel.rows.map(\.command) == Array(repeating: "sleep 40", count: 4))
        #expect(panel.rows.map(\.status) == ["running", "completed (exit 0)", "cancelled", "completed (exit 0)"])
        #expect(panel.rows.map(\.isRunning) == [true, false, false, false])
        #expect(panel.selected == 0)
    }

    /// `k` turns the selected row `cancelled` in place.
    @Test func aKilledRowReadsCancelledWhereItWas() throws {
        let before = try #require(Self.panel("agy-172-plain-tasks-panel-running-120x40"))
        let after = try #require(Self.panel("agy-173-plain-tasks-panel-after-k-120x40"))

        #expect(before.rows.map(\.status) == ["running", "completed (exit 0)"])
        #expect(after.rows.map(\.status) == ["cancelled", "completed (exit 0)"])
        #expect(after.rows.map(\.hasEnded) == [true, true])
        #expect(before.selected == 0 && after.selected == 0)
    }

    @Test func theMarkedRowIsTheSelectedOne() throws {
        #expect(try #require(Self.panel("agy-174-plain-tasks-panel-second-selected-120x40")).selected == 1)
    }

    /// Narrow screens cut the hint and the status, never `running` or
    /// `cancelled`.
    @Test func narrowPanelsStillReadEachRowsStatus() throws {
        let at62 = try #require(Self.panel("agy-178-plain-tasks-panel-62x41"))
        let at40 = try #require(Self.panel("agy-179-plain-tasks-panel-40x41"))

        #expect(at62.rows.map(\.status) == ["cancelled", "completed (exit 0)", "cancelled", "completed (exit 0)"])
        #expect(at40.rows.map(\.status) == ["cancelled", "completed (exit", "cancelled", "completed (exit"])
        #expect(at40.rows.allSatisfy { $0.hasEnded })
        #expect(at40.rows.map(\.command) == Array(repeating: "sleep 40", count: 4))
    }

    /// The running-task row under the box is no panel: `k` there types into
    /// the box (the probe's B-32), so nothing may read it as one, selected
    /// or not.
    @Test(arguments: [
        "agy-169-plain-working-background-task-120x40", "agy-170-plain-idle-background-task-after-esc-120x40",
        "agy-175-plain-idle-after-tasks-120x40", "agy-180-plain-active-task-focused-by-down-120x40",
        "agy-171-plain-tasks-popup-120x40",
    ])
    func noPanelReadsAsOne(stem: String) throws {
        #expect(Self.panel(stem) == nil)
    }

    /// The `/` popup under a typed `/tasks`, idle or during a turn, through
    /// tmux, herdr and herdr-core, in agy's colors and without them.
    @Test(arguments: [
        "agy-171-plain-tasks-popup-120x40", "agy-176-plain-tasks-popup-while-working-120x40",
        "agy-182-tasks-popup-62x46", "agy-188-core-tasks-popup-200x114",
        "agy-193-core-tasks-popup-under-exited-agy-200x114", "agy-196-core-nocolor-tasks-popup-200x119",
    ])
    func thePopupSelectsTasks(stem: String) throws {
        let screen = try Self.captured(stem)
        let agy = AgyScreen(screen)

        #expect(agy.slashSelection == AgyScreen.SlashSelection(command: "/tasks", description: "View background tasks"))
        #expect(agy.composer?.draft == "/tasks")
        #expect(agy.composer?.mode == .prompt)
        #expect(AgyBackgroundTaskStop.showsTasksPopup(screen))
    }

    /// herdr-core 0.1.18's first paint sends no color for a blank, so the
    /// box's blue `>` and the blue `/tasks` agy draws for a known command
    /// come as one run, `> /tasks`, where herdr keeps the blank between
    /// them apart (182). That row is still the box: not the popup's
    /// selected row under it, also `> /tasks` in blue, nor a box an exited
    /// agy left in the scrollback (193, rows 13 to 15).
    @Test(arguments: ["agy-188-core-tasks-popup-200x114", "agy-193-core-tasks-popup-under-exited-agy-200x114"])
    func aCorePaintsBoxHoldingTasksIsTheBottomOne(stem: String) throws {
        let box = try #require(AgyScreen(try Self.captured(stem)).composer)

        #expect(box.palette == .colored)
        #expect(box.topRule == 107 && box.bottomRule == 109)
    }

    /// The panel names the stopped turn's command at the top, selected, on
    /// every Host and palette, and `k` turns it `cancelled` there.
    @Test(arguments: [
        ("agy-183-tasks-panel-running-62x46", "agy-184-tasks-panel-after-k-62x46"),
        ("agy-189-core-tasks-panel-running-200x120", "agy-190-core-tasks-panel-after-k-200x120"),
        ("agy-197-core-nocolor-tasks-panel-running-200x120", "agy-198-core-nocolor-tasks-panel-after-k-200x120"),
    ])
    func thePanelNamesTheStoppedCommandAtTheTop(running: String, killed: String) throws {
        let before = try #require(AgyBackgroundTaskStop.panel(on: try Self.captured(running), naming: ["sleep 60"]))
        let after = try #require(AgyBackgroundTaskStop.panel(on: try Self.captured(killed), naming: ["sleep 60"]))

        #expect(before.rows[0].isRunning && before.selected == 0)
        #expect(after.rows[0].status == "cancelled" && after.rows[0].hasEnded && after.selected == 0)
        #expect(before.rows.dropFirst().allSatisfy { !$0.isRunning })
    }

    /// The idle box after Esc, with the task still listed under it, and
    /// after the panel closed: both take `/tasks`.
    @Test(arguments: [
        "agy-181-idle-background-task-after-esc-62x46", "agy-185-idle-after-tasks-62x46",
        "agy-187-core-idle-background-task-after-esc-200x113", "agy-191-core-idle-after-tasks-200x113",
        "agy-192-core-idle-background-task-under-exited-agy-200x113",
        "agy-195-core-nocolor-idle-background-task-after-esc-200x118", "agy-199-core-nocolor-idle-after-tasks-200x118",
    ])
    func theIdleBoxTakesTasks(stem: String) throws {
        let screen = try Self.captured(stem)
        let agy = AgyScreen(screen)

        #expect(agy.footerHint == "? for shortcuts")
        #expect(!agy.showsRunningTurn)
        #expect(agy.taskPanel == nil)
        #expect(AgyBackgroundTaskStop.showsIdleBox(screen))
    }

    @Test(arguments: [
        "agy-186-core-working-background-task-200x113", "agy-194-core-nocolor-working-background-task-200x117",
    ])
    func aTurnRunningOnTheCoreReadsSo(stem: String) throws {
        let screen = try Self.captured(stem)

        #expect(AgyScreen(screen).showsRunningTurn)
        #expect(!AgyBackgroundTaskStop.showsIdleBox(screen))
    }

    @Test func anIdleBoxHasNoPopup() throws {
        let screen = try ScreenFixture.screen("agy-170-plain-idle-background-task-after-esc-120x40")

        #expect(AgyScreen(screen).slashSelection == nil)
        #expect(AgyBackgroundTaskStop.showsIdleBox(screen))
        #expect(!AgyBackgroundTaskStop.showsTasksPopup(screen))
    }

    private static func panel(_ stem: String) -> AgyScreen.TaskPanel? {
        (try? ScreenFixture.screen(stem)).flatMap { AgyScreen($0).taskPanel }
    }

    /// A capture's screen: herdr's or tmux's read, or for `-core-` stems
    /// herdr-core's first paint as Chat decodes it.
    static func captured(_ stem: String) throws -> ANSIScreen {
        guard stem.contains("-core-") else { return try ScreenFixture.screen(stem) }
        var paint = HerdrCoreFirstPaint()
        return try #require(paint.receive(Data(try ChatFixture.text("screens/core-paint/\(stem).paint").utf8)))
    }
}

/// Chat's Stop after its Esc in Antigravity CLI: the keys it presses in
/// agy's `/tasks` panel, each after a fresh screen passed its check, and
/// what it says when one did not.
@MainActor
@Suite("Antigravity CLI background task stop")
struct AgyBackgroundTaskStopTests {
    /// The probe's run: one `sleep 40` agy made a task, Stop's Esc, then the
    /// panel. Exactly paste `/tasks`, Enter, `k`, Esc, on both kinds of Host.
    @Test(arguments: [false, true])
    func stopKillsTheTurnsBackgroundCommand(typingChecksTheScreen: Bool) async throws {
        let pane = try AgyPane(
            reads: ["working", "idle"],
            screens: [
                "working": ScreenFixture.screen("agy-169-plain-working-background-task-120x40"),
                "idle": ScreenFixture.screen("agy-170-plain-idle-background-task-after-esc-120x40"),
                "popup": ScreenFixture.screen("agy-171-plain-tasks-popup-120x40"),
                "panel": ScreenFixture.screen("agy-172-plain-tasks-panel-running-120x40"),
                "killed": ScreenFixture.screen("agy-173-plain-tasks-panel-after-k-120x40"),
                "closed": ScreenFixture.screen("agy-175-plain-idle-after-tasks-120x40"),
            ],
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane, typingChecksTheScreen: typingChecksTheScreen)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(pane.shown == "closed")
    }

    /// The live runs' screens, one `sleep 60` agy made a task (2026-11-09):
    /// through herdr in agy's colors, and herdr-core's first paints in them
    /// and under `NO_COLOR`. Exactly paste `/tasks`, Enter, `k`, Esc.
    @Test(arguments: [
        [
            "idle": "agy-181-idle-background-task-after-esc-62x46", "popup": "agy-182-tasks-popup-62x46",
            "panel": "agy-183-tasks-panel-running-62x46", "killed": "agy-184-tasks-panel-after-k-62x46",
            "closed": "agy-185-idle-after-tasks-62x46",
        ],
        [
            "working": "agy-186-core-working-background-task-200x113",
            "idle": "agy-187-core-idle-background-task-after-esc-200x113", "popup": "agy-188-core-tasks-popup-200x114",
            "panel": "agy-189-core-tasks-panel-running-200x120", "killed": "agy-190-core-tasks-panel-after-k-200x120",
            "closed": "agy-191-core-idle-after-tasks-200x113",
        ],
        [
            "working": "agy-194-core-nocolor-working-background-task-200x117",
            "idle": "agy-195-core-nocolor-idle-background-task-after-esc-200x118",
            "popup": "agy-196-core-nocolor-tasks-popup-200x119",
            "panel": "agy-197-core-nocolor-tasks-panel-running-200x120",
            "killed": "agy-198-core-nocolor-tasks-panel-after-k-200x120",
            "closed": "agy-199-core-nocolor-idle-after-tasks-200x118",
        ],
    ])
    func stopKillsTheCommandOnEveryCapturedHost(stems: [String: String]) async throws {
        let pane = AgyPane(
            reads: stems["working"] == nil ? ["idle"] : ["working", "idle"],
            screens: try stems.mapValues(AgyTaskPanelTests.captured),
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ])

        let left = await Self.stop([Self.command("sleep 60", id: 45)], in: pane, typingChecksTheScreen: true)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(pane.shown == "closed")
    }

    /// Two commands: `k` on the newest, one row down, `k` on the other. The
    /// earlier turn's task below them is never selected.
    @Test func stopKillsEachCommandMovingOneRowAtATime() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup,
                "both": Self.panel([("sleep 50", "running"), ("sleep 40", "running"), ("npm test", "running")]),
                "first": Self.panel([("sleep 50", "cancelled"), ("sleep 40", "running"), ("npm test", "running")]),
                "down": Self.panel(
                    [("sleep 50", "cancelled"), ("sleep 40", "running"), ("npm test", "running")], selected: 1),
                "second": Self.panel(
                    [("sleep 50", "cancelled"), ("sleep 40", "cancelled"), ("npm test", "running")], selected: 1),
                "closed": Self.idle,
            ],
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "both", "both: k": "first", "first: down": "down",
                "down: k": "second", "second: esc": "closed",
            ])

        let left = await Self.stop([Self.command("sleep 40", id: 6), Self.command("sleep 50", id: 7)], in: pane)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "down", "k", "esc"])
    }

    /// A daemon the turn started keeps running, as agy's own headless runs
    /// leave it, and so does a task from an earlier turn under it.
    @Test func daemonsAndEarlierTurnsTasksKeepRunning() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup,
                "panel": Self.panel([("sleep 40", "running"), ("npm run dev", "running"), ("npm test", "running")]),
                "killed": Self.panel([("sleep 40", "cancelled"), ("npm run dev", "running"), ("npm test", "running")]),
                "closed": Self.idle,
            ],
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ])

        let left = await Self.stop(
            [Self.command("npm run dev", daemon: true, id: 5), Self.command("sleep 40", id: 6)], in: pane)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(!pane.typed.contains("down"), "the daemon's row is never selected")
    }

    /// Nothing to end: a daemon, or a command the transcript shows ended.
    @Test func aTurnWithNothingToEndPressesNothing() {
        let io = BlockedScreenIO.unavailable
        #expect(AgyBackgroundTaskStop(commands: [], io: io, mayContinue: { true }) == nil)
        #expect(
            AgyBackgroundTaskStop(
                commands: [Self.command("npm run dev", daemon: true, id: 5), Self.command("sleep 40", running: false, id: 6)],
                io: io, mayContinue: { true }) == nil)
    }

    /// A command that ended while Stop worked gets no `k`.
    @Test func aRowThatAlreadyEndedGetsNoK() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup,
                "panel": Self.panel([("sleep 40", "completed (exit 0)")]), "closed": Self.idle,
            ],
            answers: ["idle: paste /tasks": "popup", "popup: enter": "panel", "panel: esc": "closed"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "esc"])
    }

    /// A top row naming another command could be any task: no `k`, Esc out
    /// of the panel, and the notice.
    @Test func aRowNamingAnotherCommandGetsNoK() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup,
                "panel": Self.panel([("sleep 41", "running"), ("sleep 40", "running")]), "closed": Self.idle,
            ],
            answers: ["idle: paste /tasks": "popup", "popup: enter": "panel", "panel: esc": "closed"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(
            left
                == "Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs in the background. Stop it in the terminal: /tasks, then k."
        )
        #expect(pane.typed == ["paste /tasks", "enter", "esc"])
        #expect(pane.shown == "closed")
    }

    /// `/tasks` goes only into agy's empty idle box: not over a draft, such
    /// as a queued message Esc put back, nor a dialog.
    @Test(arguments: ["draft", "dialog"])
    func onlyAnIdleBoxGetsTasks(shown: String) async throws {
        let pane = try AgyPane(
            reads: [shown],
            screens: [
                "draft": Self.screen(draft: "and the tests", under: [Self.right("", Self.model)]),
                "dialog": ScreenFixture.screen("agy-30-perm-run-command-default-120x40"),
            ],
            answers: [:])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left?.hasPrefix("Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs") == true)
        #expect(pane.typed.isEmpty)
    }

    /// A row that never reads ended after `k`: Esc out, and the notice.
    @Test func aKillThatDoesNotShowEndsWithTheNotice() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup, "panel": Self.panel([("sleep 40", "running")]),
                "closed": Self.idle,
            ],
            answers: ["idle: paste /tasks": "popup", "popup: enter": "panel", "panel: esc": "closed"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left?.hasPrefix("Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs") == true)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(pane.shown == "closed")
    }

    /// A turn still running past the window is Stop's own wait's to report.
    @Test func aTurnThatKeepsRunningGetsNoKeys() async throws {
        let pane = try AgyPane(
            reads: ["working"],
            screens: ["working": ScreenFixture.screen("agy-169-plain-working-background-task-120x40")],
            answers: [:])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left == nil)
        #expect(pane.typed.isEmpty)
    }

    /// A Composer send typing could land between two keys: nothing goes.
    @Test func aSendOnItsWayStopsTheKeys() async {
        let pane = AgyPane(reads: ["idle"], screens: ["idle": Self.idle], answers: [:])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane, mayContinue: false)

        #expect(left?.hasPrefix("Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs") == true)
        #expect(pane.typed.isEmpty)
    }

    @Test func theNoticeNamesWhatStillRuns() {
        let long = "python3 -m http.server 8000 --bind 127.0.0.1 --directory /srv"

        #expect(
            AgyBackgroundTaskStop.notice(for: [Self.command("sleep 40", id: 6), Self.command("sleep 50", id: 7)])
                == "Stop ended the turn, but \u{201C}sleep 40\u{201D} and \u{201C}sleep 50\u{201D} still run in the "
                + "background. Stop them in the terminal: /tasks, then k.")
        #expect(
            AgyBackgroundTaskStop.notice(for: [Self.command(long, id: 6)])
                == "Stop ended the turn, but \u{201C}python3 -m http.server 8000 --bind 127.\u{2026}\u{201D} still "
                + "runs in the background. Stop it in the terminal: /tasks, then k.")
    }

    // MARK: Helpers

    private static func stop(
        _ commands: [ChatBackgroundCommand], in pane: AgyPane, typingChecksTheScreen: Bool = false,
        mayContinue: Bool = true
    ) async -> String? {
        guard
            let stop = AgyBackgroundTaskStop(
                commands: commands, io: pane.io(typingChecksTheScreen: typingChecksTheScreen),
                mayContinue: { mayContinue }, clock: ManualClock().clock)
        else { return "no follow-through" }
        return await stop.run()
    }

    private static func command(
        _ text: String, running: Bool = true, daemon: Bool = false, id: Int
    ) -> ChatBackgroundCommand {
        ChatBackgroundCommand(callID: "agy:\(id):tool:0", command: text, isRunning: running, isDaemon: daemon)
    }

    // Screens at 120 columns, plain as the captures read.

    private static let model = "Gemini 4 Argon \u{00B7} medium"
    private static let idle = screen(under: [right("? for shortcuts", model)])
    private static let popup = screen(
        draft: "/tasks",
        under: [
            "> /tasks  View background tasks", "  \u{2191}/\u{2193} Navigate \u{00B7} enter Select \u{00B7} tab Complete",
            right("esc to cancel", model),
        ])

    private static func panel(_ rows: [(command: String, status: String)], selected: Int = 0) -> ANSIScreen {
        let tasks = rows.indices.map { index in
            right("\(index == selected ? "> " : "  ")\u{25CF} [03:1\(index):00] \(rows[index].command)", rows[index].status)
        }
        return screen(
            under: ["Tasks", "Agent Backgrounded"] + tasks + [
                "", "Keyboard: \u{2191}/\u{2193} Navigate  \u{2190}/\u{2192} Page  enter View output  k Kill Task  x Remove Task From List",
                "", right("", model),
            ])
    }

    private static func screen(draft: String = "", under: [String]) -> ANSIScreen {
        let rule = String(repeating: "\u{2500}", count: 120)
        return ScreenFixture.synthetic(
            ["\u{25CF} Ran (sleep 40) (ctrl+o to expand)", "", rule, draft.isEmpty ? ">" : "> \(draft)", rule] + under)
    }

    /// `left`, then `right` ending at column 120.
    private static func right(_ left: String, _ right: String) -> String {
        left + String(repeating: " ", count: max(2, 120 - left.count - right.count)) + right
    }
}

/// agy's pane as Stop sees it: named screens, a typing that turns the one
/// shown into the next `answers` names (`"<shown>: <typed>"`), and the
/// first screens reads show before any typing, as a turn ending after Stop's
/// Esc. A typing nothing answers leaves the screen as it is.
private final class AgyPane: @unchecked Sendable {
    private let lock = NSLock()
    private let screens: [String: ANSIScreen]
    private let answers: [String: String]
    private var upcoming: [String]
    private var current: String
    private var log: [String] = []

    init(reads: [String], screens: [String: ANSIScreen], answers: [String: String]) {
        self.screens = screens
        self.answers = answers
        upcoming = reads
        current = reads.first ?? ""
    }

    var typed: [String] { lock.withLock { log } }
    var shown: String { lock.withLock { current } }

    func read() -> ANSIScreen {
        lock.withLock {
            if !upcoming.isEmpty { current = upcoming.removeFirst() }
            return screens[current] ?? ANSIScreen(rows: [])
        }
    }

    /// Types, refusing as herdr-core's typing does when `check` fails on
    /// the screen it would type over.
    func type(_ typing: BlockedScreenIO.Typing, check: ((ANSIScreen) -> Bool)?) throws {
        try lock.withLock {
            if let check, !check(screens[current] ?? ANSIScreen(rows: [])) {
                throw HerdrCoreChatTyping.Refusal(message: "The screen changed.")
            }
            let name: String
            switch typing {
            case .keys(let keys): name = keys.joined(separator: " ")
            case .paste(let text): name = "paste \(text)"
            }
            log.append(name)
            if let next = answers["\(current): \(name)"] { current = next }
        }
    }

    func io(typingChecksTheScreen: Bool) -> BlockedScreenIO {
        var io = BlockedScreenIO(
            readScreen: { [self] in read() },
            sendKeys: { [self] in try type(.keys($0), check: nil) },
            paste: { [self] in try type(.paste($0), check: nil) })
        if typingChecksTheScreen {
            io.typeWhileShowing = { [self] typing, check in try type(typing, check: check) }
        }
        return io
    }
}
