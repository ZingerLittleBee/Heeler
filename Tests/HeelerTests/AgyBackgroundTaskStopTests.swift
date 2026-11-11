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
        #expect(AgyBackgroundTaskStop.holdsTasks(screen))
        #expect(!AgyBackgroundTaskStop.showsPanel(screen))
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
        #expect(AgyBackgroundTaskStop.showsPanel(try Self.captured(killed)))
        #expect(!AgyBackgroundTaskStop.holdsTasks(try Self.captured(killed)))
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
        #expect(agy.showsRunningTasks == stem.contains("background-task"))
        #expect(!AgyBackgroundTaskStop.showsPanel(screen) && !AgyBackgroundTaskStop.holdsTasks(screen))
    }

    /// A running task shows under the box, or in the footer's count, which
    /// a queued message's hint cuts at 62 columns (72) and the popup keeps
    /// (176, 182); it shows nowhere once none runs.
    @Test(arguments: [
        ("agy-169-plain-working-background-task-120x40", true), ("agy-72-working-altm-send-now-62x41", true),
        ("agy-176-plain-tasks-popup-while-working-120x40", true), ("agy-182-tasks-popup-62x46", true),
        ("agy-188-core-tasks-popup-200x114", true), ("agy-196-core-nocolor-tasks-popup-200x119", true),
        ("agy-175-plain-idle-after-tasks-120x40", false), ("agy-02-idle-empty-120x40", false),
        ("agy-184-tasks-panel-after-k-62x46", false),
    ])
    func aRunningTaskShows(stem: String, shows: Bool) throws {
        #expect(AgyScreen(try Self.captured(stem)).showsRunningTasks == shows)
    }

    @Test(arguments: [
        "agy-186-core-working-background-task-200x113", "agy-194-core-nocolor-working-background-task-200x117",
    ])
    func aTurnRunningOnTheCoreReadsSo(stem: String) throws {
        let screen = try Self.captured(stem)

        #expect(AgyScreen(screen).showsRunningTurn)
        #expect(AgyScreen(screen).showsRunningTasks)
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
/// agy's `/tasks` panel, each after the latest screen passed its check, and
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

    /// Each herdr TUI read took 0.8 to 1.65 s live, and reading again before
    /// every key made a step 3 to 4.5 s. A key goes on the read its step
    /// waited for, which already shows what the key needs: one command
    /// reads the turn's end, the popup, the panel, `cancelled` and the
    /// closed panel; two also read the row moved to and its `cancelled`.
    @Test func eachKeyGoesOnTheReadItsStepWaitedFor() async {
        let one = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup, "panel": Self.panel([("sleep 40", "running")]),
                "killed": Self.panel([("sleep 40", "cancelled")]), "closed": Self.idle,
            ],
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ])
        let two = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup,
                "both": Self.panel([("sleep 50", "running"), ("sleep 40", "running")]),
                "first": Self.panel([("sleep 50", "cancelled"), ("sleep 40", "running")]),
                "down": Self.panel([("sleep 50", "cancelled"), ("sleep 40", "running")], selected: 1),
                "second": Self.panel([("sleep 50", "cancelled"), ("sleep 40", "cancelled")], selected: 1),
                "closed": Self.idle,
            ],
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "both", "both: k": "first", "first: down": "down",
                "down: k": "second", "second: esc": "closed",
            ])

        #expect(await Self.stop([Self.command("sleep 40", id: 6)], in: one) == nil)
        #expect(
            await Self.stop([Self.command("sleep 40", id: 6), Self.command("sleep 50", id: 7)], in: two) == nil)

        #expect(one.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(one.readCount == 5)
        #expect(two.typed == ["paste /tasks", "enter", "k", "down", "k", "esc"])
        #expect(two.readCount == 7)
    }

    /// A step's read that does not show what the next key needs, here the
    /// turn's end in a frame agy has yet to draw its box in, is not the one
    /// the key goes on: a fresh read is.
    @Test func aKeyTheStepsReadDoesNotPassGoesOnAFreshRead() async {
        let pane = AgyPane(
            reads: ["undrawn"],
            screens: [
                "undrawn": ScreenFixture.synthetic(["\u{25CF} Ran (sleep 40) (ctrl+o to expand)"]), "idle": Self.idle,
                "popup": Self.popup, "panel": Self.panel([("sleep 40", "running")]),
                "killed": Self.panel([("sleep 40", "cancelled")]), "closed": Self.idle,
            ],
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ],
            drawing: ["undrawn": "idle"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(pane.readCount == 6)
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

    // MARK: Taking /tasks back

    /// A popup that never reads as `/tasks`'s: once the step gives up,
    /// six Backspaces in one send take `/tasks` back out of the box and
    /// close the popup, and the notice still says what runs.
    @Test func aPopupThatNeverReadsHasTasksErased() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle,
                "unknown": Self.screen(
                    draft: "/tasks", under: ["> /tasks  List background tasks", Self.right("esc to cancel", Self.model)]),
            ],
            answers: ["idle: paste /tasks": "unknown", "unknown: \(Self.erase)": "idle"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane, typingChecksTheScreen: true)

        #expect(left?.hasPrefix("Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs") == true)
        #expect(pane.typed == ["paste /tasks", Self.erase])
        #expect(pane.shown == "idle")
    }

    /// Anything but the `/tasks` this typed stays in the box.
    @Test func aBoxHoldingMoreThanTasksIsLeftAlone() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: ["idle": Self.idle, "more": Self.screen(draft: "x/tasks", under: [Self.right("", Self.model)])],
            answers: ["idle: paste /tasks": "more"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left?.hasPrefix("Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs") == true)
        #expect(pane.typed == ["paste /tasks"])
    }

    /// A panel whose rows don't read is still the panel: Esc closes it.
    @Test func aPanelWhoseRowsDoNotReadIsClosed() async {
        let pane = AgyPane(
            reads: ["idle"],
            screens: [
                "idle": Self.idle, "popup": Self.popup,
                "empty": Self.screen(under: ["Tasks", "No background tasks.", "", Self.right("", Self.model)]),
                "closed": Self.idle,
            ],
            answers: ["idle: paste /tasks": "popup", "popup: enter": "empty", "empty: esc": "closed"])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left?.hasPrefix("Stop ended the turn, but \u{201C}sleep 40\u{201D} still runs") == true)
        #expect(pane.typed == ["paste /tasks", "enter", "esc"])
        #expect(pane.shown == "closed")
    }

    /// One read failing while the popup draws is tried again, not a reason
    /// to stop.
    @Test func aFailedReadIsTriedAgain() async {
        let pane = Self.fullPane(failing: [3])

        let left = await Self.stop([Self.command("sleep 40", id: 6)], in: pane)

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
    }

    /// herdr's reads took up to 1.65 s live: a popup the second read after
    /// the paste shows is still in time.
    @Test func aPopupTheSecondSlowReadShowsIsInTime() async throws {
        let clock = ManualClock()
        let pane = Self.fullPane(readTime: (clock, .milliseconds(1_650)))
        let built = AgyBackgroundTaskStop(
            commands: [Self.command("sleep 40", id: 6)], io: pane.io(typingChecksTheScreen: false),
            mayContinue: { true }, clock: clock.clock)
        let stop = try #require(built)

        let left = await stop.run()

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
    }

    /// Core's first read after a key often showed agy before it drew the
    /// answer: the turn's end, the popup, the panel, `cancelled` (live).
    /// A step's window is agy's time to draw, whatever a read takes: one
    /// read longer than the window, such as a 2 s read against the kill's
    /// 2 s, must not have the last word. Each step drawn one read late,
    /// with reads longer than every window, still goes through.
    @Test(arguments: ["working", "typed", "opening", "killing", "closing"])
    func aStepDrawnASlowReadLateIsStillSeen(late: String) async throws {
        let clock = ManualClock()
        let running = Self.panel([("sleep 40", "running")])
        let cancelled = Self.panel([("sleep 40", "cancelled")])
        let pane = AgyPane(
            reads: [late == "working" ? "working" : "idle"],
            screens: [
                "working": Self.screen(under: [Self.right("esc to cancel", Self.model)]), "idle": Self.idle,
                "typed": Self.screen(draft: "/tasks", under: [Self.right("", Self.model)]), "popup": Self.popup,
                "opening": Self.popup, "panel": running, "killing": running, "killed": cancelled,
                "closing": cancelled, "closed": Self.idle,
            ],
            answers: [
                "idle: paste /tasks": late == "typed" ? "typed" : "popup",
                "popup: enter": late == "opening" ? "opening" : "panel",
                "panel: k": late == "killing" ? "killing" : "killed",
                "killed: esc": late == "closing" ? "closing" : "closed",
            ],
            drawing: ["working": "idle", "typed": "popup", "opening": "panel", "killing": "killed", "closing": "closed"],
            readTime: (clock, .milliseconds(3_200)))
        let built = AgyBackgroundTaskStop(
            commands: [Self.command("sleep 40", id: 6)], io: pane.io(typingChecksTheScreen: false),
            mayContinue: { true }, clock: clock.clock)
        let stop = try #require(built)

        let left = await stop.run()

        #expect(left == nil)
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(pane.shown == "closed")
    }

    /// Esc, the popup drawn a read after the paste, the panel, `k` and Esc.
    private static func fullPane(
        failing: Set<Int> = [], readTime: (clock: ManualClock, duration: Duration)? = nil
    ) -> AgyPane {
        AgyPane(
            reads: ["idle"],
            screens: [
                "idle": idle, "typed": screen(draft: "/tasks", under: [right("", model)]), "popup": popup,
                "panel": panel([("sleep 40", "running")]), "killed": panel([("sleep 40", "cancelled")]),
                "closed": idle,
            ],
            answers: [
                "idle: paste /tasks": "typed", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ],
            drawing: ["typed": "popup"], failing: failing, readTime: readTime)
    }

    private static let erase = Array(repeating: "backspace", count: 6).joined(separator: " ")

    @Test func theNoticeNamesWhatStillRuns() {
        let long = "python3 -m http.server 8000 --bind 127.0.0.1 --directory /srv"

        #expect(
            AgyBackgroundTaskStop.notice(for: [Self.command("sleep 40", id: 6), Self.command("sleep 50", id: 7)])
                == "Stop ended the turn, but 2 background commands still run: \u{201C}sleep 40\u{201D}, "
                + "\u{201C}sleep 50\u{201D}. Stop them in the terminal: /tasks, then k.")
        #expect(
            AgyBackgroundTaskStop.notice(for: [Self.command(long, id: 6)])
                == "Stop ended the turn, but \u{201C}python3 -m http.server 8000 --bind 127.\u{2026}\u{201D} still "
                + "runs in the background. Stop it in the terminal: /tasks, then k.")
    }

    /// The count picks the sentence, and a command without its line still
    /// counts in the list.
    @Test func theUnreadNoticeNamesWhatMayStillRun() {
        let unnamed = ChatBackgroundCommand(callID: "agy:8:tool:0", command: nil, isRunning: true, isDaemon: false)

        #expect(
            AgyBackgroundTaskStop.unreadNotice(for: [Self.command("sleep 40", id: 6)])
                == "Heeler couldn't read the Agent's screen after Stop, so \u{201C}sleep 40\u{201D} may still run in "
                + "the background. Stop it in the terminal: /tasks, then k.")
        #expect(
            AgyBackgroundTaskStop.unreadNotice(for: [Self.command("sleep 40", id: 6), unnamed])
                == "Heeler couldn't read the Agent's screen after Stop, so 2 background commands may still run: "
                + "\u{201C}sleep 40\u{201D}, a command. Stop them in the terminal: /tasks, then k.")
    }

    // MARK: Built as Stop is tapped

    /// The live race: Chat's read of the step that made `sleep 60` a task
    /// landed after the tap. The task under the box after the Esc has Chat
    /// read again, and the command it then lists is ended.
    @Test func aCommandReadOnlyAfterTheTapIsEnded() async throws {
        let chat = ChatReads(Self.turn(1), then: Self.turn(1, [Self.command("sleep 60", id: 45)]))
        let pane = try Self.corePane()

        let left = await Self.tap(chat, pane)

        #expect(left == .some(nil))
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(chat.readsAgain == 1)
    }

    /// A command read at the tap goes at once, with no read again.
    @Test func aCommandReadAtTheTapIsEndedWithoutReadingAgain() async throws {
        let chat = ChatReads(Self.turn(1, [Self.command("sleep 60", id: 45)]), then: nil)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(chat.readsAgain == 0)
    }

    /// No command by the read's deadline: the task listed is another
    /// turn's, or a daemon's, and nothing is pressed or said.
    @Test func noCommandAfterReadingAgainPressesNothing() async throws {
        let chat = ChatReads(Self.turn(1), then: Self.turn(1, [Self.command("npm run dev", daemon: true, id: 45)]))
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 1)
    }

    /// Nothing listed under the box or in the footer after the Esc: no task
    /// runs, so Chat does not read again.
    @Test func noTaskOnTheScreenReadsNothingAgain() async throws {
        let chat = ChatReads(Self.turn(1), then: Self.turn(1, [Self.command("sleep 60", id: 45)]))
        let pane = try AgyPane(
            reads: ["idle"], screens: ["idle": AgyTaskPanelTests.captured("agy-191-core-idle-after-tasks-200x113")],
            answers: [:])

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 0)
    }

    /// A read after the Esc that fails says nothing of what runs, so Chat
    /// still reads again, and the command it then lists is ended.
    @Test func aFailedReadAfterTheEscStillReadsAgain() async throws {
        let chat = ChatReads(Self.turn(1), then: Self.turn(1, [Self.command("sleep 60", id: 45)]))
        let pane = try Self.corePane(failing: [1])

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(chat.readsAgain == 1)
    }

    /// A command of a turn opened since the tap, or of another
    /// conversation Chat now follows, is not the stopped turn's.
    @Test(arguments: [(conversation: 1, entry: 50), (conversation: 2, entry: 40)])
    func anotherTurnsCommandIsLeftRunning(conversation: Int, entry: Int) async throws {
        let later = AgyBackgroundTaskStop.OpenTurn(
            conversation: conversation, firstEntry: ChatEntryID("agy:\(entry):user"),
            commands: [Self.command("sleep 60", id: entry + 5)])
        let chat = ChatReads(Self.turn(1), then: later)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed.isEmpty)
    }

    /// The open turn Chat read at the tap may be one an Esc that writes
    /// nothing ended, with a prompt from the terminal since: Chat reads again,
    /// and the turn that read shows is another, which the Esc stopped. The
    /// earlier turn's command, which Stop's notice may already have named,
    /// keeps running.
    @Test func aCommandOfATurnAPromptFromElsewhereEndedIsLeftRunning() async throws {
        let later = AgyBackgroundTaskStop.OpenTurn(conversation: 1, firstEntry: ChatEntryID("agy:50:user"), commands: [])
        let chat = ChatReads(Self.turn(1, [Self.command("sleep 60", id: 45)]), then: later, current: false)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 1)
    }

    /// No read that could place the open turn comes: nothing is pressed,
    /// and Stop says what may still run.
    @Test func aTapChatCannotPlaceLeavesItsCommandsWithANotice() async throws {
        let sleep = Self.command("sleep 60", id: 45)
        let chat = ChatReads(Self.turn(1, [sleep]), then: nil, current: false, readMakesCurrent: false)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(AgyBackgroundTaskStop.notice(for: [sleep])))
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 1)
    }

    /// The read again shows the tapped turn still open: its own command is
    /// ended with the commands known at the tap.
    @Test func aNotCurrentTapStillEndsItsOwnTurnsCommands() async throws {
        let chat = ChatReads(Self.turn(1, [Self.command("sleep 60", id: 45)]), then: nil, current: false)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(pane.typed == ["paste /tasks", "enter", "k", "esc"])
        #expect(chat.readsAgain == 1)
    }

    /// With no command known at the tap, a read that places the open turn
    /// as another ends the wait at once, and with it the send hold.
    @Test func aStaleTapEndsItsWaitAtOnce() async throws {
        let later = AgyBackgroundTaskStop.OpenTurn(conversation: 1, firstEntry: ChatEntryID("agy:50:user"), commands: [])
        let chat = ChatReads(Self.turn(1), then: later, current: false)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(nil))
        #expect(chat.wasEnough == true)
        #expect(pane.typed.isEmpty)
    }

    /// A read begun before the running turn's prompt can bring the earlier
    /// turn's late task: not current, it ends nothing, and Stop says one
    /// may still run.
    @Test func aLateCommandOfATurnChatCannotPlaceIsLeftRunning() async throws {
        let chat = ChatReads(
            Self.turn(1), then: Self.turn(1, [Self.command("sleep 60", id: 45)]), current: false,
            readMakesCurrent: false)
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == .some(AgyBackgroundTaskStop.unplacedNotice))
        #expect(pane.typed.isEmpty)
    }

    /// No command known at the tap, a task under the box after the Esc (or
    /// a read of it that failed), and a transcript that never becomes
    /// current, as over a stalled link (live): nothing is pressed, and Stop
    /// says a command may still run rather than ending silently.
    @Test(arguments: [Set<Int>(), [1]])
    func aTranscriptThatNeverBecomesCurrentEndsWithANotice(failing: Set<Int>) async throws {
        let chat = ChatReads(Self.turn(1), then: nil, current: false, readMakesCurrent: false)
        let pane = try Self.corePane(failing: failing)

        #expect(await Self.tap(chat, pane) == .some(AgyBackgroundTaskStop.unplacedNotice))
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 1)
    }

    /// The same over a transcript already current at the tap, from a read
    /// made in the turn before its command became a task: a read again that
    /// brings nothing, as over a stalled link, leaves that read current, and
    /// Stop still says a command may run rather than ending silently.
    @Test(arguments: [Set<Int>(), [1]])
    func aCurrentTranscriptNoReadAgainReachesEndsWithANotice(failing: Set<Int>) async throws {
        let chat = ChatReads(Self.turn(1), then: nil)
        let pane = try Self.corePane(failing: failing)

        #expect(await Self.tap(chat, pane) == .some(AgyBackgroundTaskStop.unplacedNotice))
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 1)
    }

    /// A send of Chat's still waiting for its record: the open turn may be
    /// the one before, so Stop builds nothing, whatever comes later.
    @Test func aSendAwaitingItsRecordBuildsNothing() async throws {
        let chat = ChatReads(Self.turn(1), then: Self.turn(1, [Self.command("sleep 60", id: 45)]))
        chat.awaitsRecord = true
        let pane = try Self.corePane()

        #expect(await Self.tap(chat, pane) == nil)
        #expect(pane.typed.isEmpty)
        #expect(chat.readsAgain == 0)
    }

    /// The open turn Chat read in `conversation`, opened by the prompt at
    /// step 40.
    private static func turn(_ conversation: Int, _ commands: [ChatBackgroundCommand] = []) -> AgyBackgroundTaskStop.OpenTurn {
        AgyBackgroundTaskStop.OpenTurn(
            conversation: conversation, firstEntry: ChatEntryID("agy:40:user"), commands: commands)
    }

    /// herdr-core's paints in agy's colors from Esc to the panel's close;
    /// reads `failing` names throw.
    private static func corePane(failing: Set<Int> = []) throws -> AgyPane {
        AgyPane(
            reads: ["idle"],
            screens: try [
                "idle": "agy-187-core-idle-background-task-after-esc-200x113", "popup": "agy-188-core-tasks-popup-200x114",
                "panel": "agy-189-core-tasks-panel-running-200x120", "killed": "agy-190-core-tasks-panel-after-k-200x120",
                "closed": "agy-191-core-idle-after-tasks-200x113",
            ].mapValues(AgyTaskPanelTests.captured),
            answers: [
                "idle: paste /tasks": "popup", "popup: enter": "panel", "panel: k": "killed", "killed: esc": "closed",
            ],
            failing: failing)
    }

    /// What a tap builds, run: nil when it builds nothing, else what it says.
    private static func tap(_ chat: ChatReads, _ pane: AgyPane) async -> String?? {
        guard
            let followThrough = AgyBackgroundTaskStop.followThrough(
                reading: chat.transcript, io: pane.io(typingChecksTheScreen: true), mayContinue: { true },
                clock: ManualClock().clock)
        else { return nil }
        return .some(await followThrough())
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

/// Chat's conversation as the follow-through reads it: the open turn at the
/// tap, and what a read again brings, or nothing new. The open turn read is
/// current at the tap unless `current` says not; a read again makes it so
/// unless `readMakesCurrent` says not.
@MainActor
private final class ChatReads {
    var awaitsRecord = false
    private(set) var readsAgain = 0
    /// What the follow-through's `until` said once the last read again ended.
    private(set) var wasEnough: Bool?
    private var turn: AgyBackgroundTaskStop.OpenTurn
    private let next: AgyBackgroundTaskStop.OpenTurn?
    private var isCurrent: Bool
    private let readMakesCurrent: Bool

    init(
        _ turn: AgyBackgroundTaskStop.OpenTurn, then next: AgyBackgroundTaskStop.OpenTurn?, current: Bool = true,
        readMakesCurrent: Bool = true
    ) {
        self.turn = turn
        self.next = next
        isCurrent = current
        self.readMakesCurrent = readMakesCurrent
    }

    var transcript: AgyBackgroundTaskStop.Transcript {
        AgyBackgroundTaskStop.Transcript(
            awaitsRecord: { [self] in awaitsRecord }, openTurn: { [self] in turn },
            isCurrent: { [self] in isCurrent },
            readAgain: { [self] _, isEnough in
                readsAgain += 1
                if let next { turn = next }
                if readMakesCurrent { isCurrent = true }
                let enough = isEnough()
                wasEnough = enough
                return next != nil || enough
            })
    }
}

/// agy's pane as Stop sees it: named screens, a typing that turns the one
/// shown into the next `answers` names (`"<shown>: <typed>"`), and the
/// first screens reads show before any typing, as a turn ending after Stop's
/// Esc. A typing nothing answers leaves the screen as it is. A screen
/// `drawing` names becomes the one it names after one read, as agy
/// finishing a frame; reads `failing` names (counted from 1) throw, and
/// each read can take `readTime` on a manual clock.
private final class AgyPane: @unchecked Sendable {
    private let lock = NSLock()
    private let screens: [String: ANSIScreen]
    private let answers: [String: String]
    private let drawing: [String: String]
    private let failing: Set<Int>
    private let readTime: (clock: ManualClock, duration: Duration)?
    private var upcoming: [String]
    private var current: String
    private var reads = 0
    private var log: [String] = []

    init(
        reads: [String], screens: [String: ANSIScreen], answers: [String: String], drawing: [String: String] = [:],
        failing: Set<Int> = [], readTime: (clock: ManualClock, duration: Duration)? = nil
    ) {
        self.screens = screens
        self.answers = answers
        self.drawing = drawing
        self.failing = failing
        self.readTime = readTime
        upcoming = reads
        current = reads.first ?? ""
    }

    var typed: [String] { lock.withLock { log } }
    var shown: String { lock.withLock { current } }
    var readCount: Int { lock.withLock { reads } }

    func read() throws -> ANSIScreen {
        if let readTime { readTime.clock.advance(readTime.duration) }
        return try lock.withLock {
            reads += 1
            if failing.contains(reads) { throw TransportError.channelFailed(detail: "agent.read failed") }
            if !upcoming.isEmpty { current = upcoming.removeFirst() }
            let shown = current
            if let drawn = drawing[shown] { current = drawn }
            return screens[shown] ?? ANSIScreen(rows: [])
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
            readScreen: { [self] in try read() },
            sendKeys: { [self] in try type(.keys($0), check: nil) },
            paste: { [self] in try type(.paste($0), check: nil) })
        if typingChecksTheScreen {
            io.typeWhileShowing = { [self] typing, check in try type(typing, check: check) }
        }
        return io
    }
}
