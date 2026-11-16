import Foundation
import Testing

@testable import Heeler

/// Done per device on a Rex Host (ADR 0054): a finished turn is named by the
/// report that ended it, the link's count says whether a turn ended between
/// two reports it heard, and a report's time says whether anything was
/// reported across links. Times, process ids and links are invented.
@MainActor
@Suite("Rex turn state")
struct RexTurnStateTests {
    private func report(
        _ state: String, at second: Int, on link: UUID? = nil, turns: Int = 0,
        owner: (pid: Int, name: String) = (77, "codex"), app: String? = "codex"
    ) -> RexProgramStatus {
        RexProgramStatus(
            state: state, app: app, ownerProcessID: owner.pid, ownerName: owner.name,
            updatedAt: "2026-11-16T12:00:\(second < 10 ? "0" : "")\(second)+00:00",
            follow: link.map { RexStatusFollow(id: $0, finishedTurns: turns) })
    }

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "rex-done-\(UUID().uuidString)"))
    }

    /// A done reads Done until this device looks at the Agent, then Idle. The
    /// same done reported again ends nothing while the link heard every report
    /// between, and an idle after it neither; the next finished turn reads
    /// Done again, even when the inventory that brings it missed its working.
    @Test func aDoneReadsDoneUntilLookedAtAndAgainForTheNextTurn() {
        let link = UUID()
        var state = RexTurnState()
        state.note(report("working", at: 1, on: link), kind: "codex")
        #expect(!state.isDone)
        state.note(report("done", at: 2, on: link, turns: 1), kind: "codex")
        #expect(state.isDone)

        state.markSeen()
        #expect(!state.isDone)
        state.note(report("done", at: 3, on: link, turns: 1), kind: "codex")
        #expect(!state.isDone)
        state.note(report("idle", at: 4, on: link, turns: 1), kind: "codex")
        #expect(!state.isDone)

        state.note(report("working", at: 5, on: link, turns: 1), kind: "codex")
        #expect(!state.isDone)
        state.note(report("done", at: 6, on: link, turns: 2), kind: "codex")
        #expect(state.isDone)
        state.markSeen()
        // Working, then done, while one structure read held the inventory back.
        state.note(report("done", at: 9, on: link, turns: 3), kind: "codex")
        #expect(state.isDone)
    }

    /// Working, blocked and error take a finished turn back, as on the other
    /// kinds; looking at an Agent with no finished turn marks nothing, so the
    /// turn that ends after it was closed reads Done.
    @Test func workingTakesAFinishedTurnBack() {
        let link = UUID()
        var state = RexTurnState()
        state.note(report("working", at: 1, on: link), kind: "codex")
        state.markSeen()
        state.note(report("done", at: 2, on: link, turns: 1), kind: "codex")
        #expect(state.isDone)
        for (second, word) in [(3, "working"), (4, "blocked"), (5, "error")] {
            state.note(report(word, at: second, on: link, turns: 1), kind: "codex")
            #expect(!state.isDone)
        }
    }

    /// Rex drops a working or blocked record while its program is out of the
    /// foreground, so a program back in it that reports done at once brings
    /// the link no count: a done after the working or blocked known here still
    /// finished that turn, and the same done again finishes none.
    @Test(arguments: ["working", "blocked"])
    func aDoneAfterARemovedRecordFinishesTheTurn(state word: String) {
        let link = UUID()
        var state = RexTurnState()
        state.note(report(word, at: 1, on: link), kind: "codex")
        state.note(report("done", at: 5, on: link), kind: "codex")
        #expect(state.isDone)
        state.markSeen()
        state.note(report("done", at: 6, on: link), kind: "codex")
        #expect(!state.isDone)
    }

    /// First sight, as of a Host just added or a launch with nothing kept:
    /// a done finished a turn and reads Done, as on the other kinds, while an
    /// idle reads Idle, as Rex keeps no count that says it ever worked.
    @Test(arguments: [("done", true), ("idle", false), ("working", false), ("blocked", false), ("error", false)])
    func firstSightOfARecord(state word: String, readsDone: Bool) {
        var state = RexTurnState()
        state.note(report(word, at: 1, on: UUID()), kind: "codex")
        #expect(state.isDone == readsDone)
        // An Agent on screen at first sight sees it.
        state.markSeen()
        #expect(!state.isDone)
    }

    /// Another link reads what the last one held: a record whose time has not
    /// moved is the one known, Done or seen. A done whose time moved while no
    /// link heard it counts as a finished turn: a new turn and the same done
    /// made again look alike then.
    @Test func acrossLinksTheTimeSaysWhatChanged() {
        var seen = RexTurnState()
        seen.note(report("done", at: 2, on: UUID(), turns: 1), kind: "codex")
        seen.markSeen()
        let next = UUID()
        seen.note(report("done", at: 2, on: next), kind: "codex")
        #expect(!seen.isDone)
        // On the new link, the same done again ends nothing.
        seen.note(report("done", at: 3, on: next), kind: "codex")
        #expect(!seen.isDone)
        // Reports this device never heard: the record cannot tell.
        seen.note(report("done", at: 8, on: UUID()), kind: "codex")
        #expect(seen.isDone)

        var unseen = RexTurnState()
        unseen.note(report("done", at: 2, on: UUID(), turns: 1), kind: "codex")
        unseen.note(report("done", at: 2, on: UUID()), kind: "codex")
        #expect(unseen.isDone)

        // Working when last heard, idle or done now: that turn finished.
        var away = RexTurnState()
        away.note(report("working", at: 1, on: UUID()), kind: "codex")
        away.note(report("done", at: 5, on: UUID()), kind: "codex")
        #expect(away.isDone)
    }

    /// A program not known to report done finishes a turn going from working
    /// to idle, as on the other kinds; a known one's idle, or the idle of one
    /// that has reported done, finishes none.
    @Test func idleFinishesATurnOnlyForAProgramNotKnownToReportDone() {
        let link = UUID()
        var opencode = RexTurnState()
        opencode.note(report("working", at: 1, on: link, app: "opencode"), kind: "opencode")
        opencode.note(report("idle", at: 2, on: link, app: "opencode"), kind: "opencode")
        #expect(opencode.isDone)

        var codex = RexTurnState()
        codex.note(report("working", at: 1, on: link), kind: "codex")
        codex.note(report("idle", at: 2, on: link), kind: "codex")
        #expect(!codex.isDone)

        var reporter = RexTurnState()
        reporter.note(report("working", at: 1, on: link, app: "opencode"), kind: "opencode")
        reporter.note(report("done", at: 2, on: link, turns: 1, app: "opencode"), kind: "opencode")
        reporter.markSeen()
        reporter.note(report("working", at: 3, on: link, turns: 1, app: "opencode"), kind: "opencode")
        reporter.note(report("idle", at: 4, on: link, turns: 1, app: "opencode"), kind: "opencode")
        #expect(!reporter.isDone)
    }

    /// A report from another foreground is another program's: its finished
    /// turn is not the one this device looked at, whatever its time, and a
    /// terminal whose Agent left takes its Done with it.
    @Test func anotherProgramsTurnIsNeverTheOneLookedAt() {
        let link = UUID()
        for owner in [(pid: 78, name: "codex"), (pid: 77, name: "2.1.316")] {
            var state = RexTurnState()
            state.note(report("done", at: 2, on: link, turns: 1), kind: "codex")
            state.markSeen()
            state.note(report("done", at: 2, on: link, turns: 1, owner: owner), kind: "codex")
            #expect(state.isDone)
        }

        var left = RexTurnState()
        left.note(report("done", at: 2, on: link, turns: 1), kind: "codex")
        left.noteNoAgent()
        #expect(!left.isDone)
        left.note(report("done", at: 2, on: link, turns: 1), kind: "codex")
        #expect(!left.isDone)
    }

    /// The memory lives on this device: it survives a relaunch, goes with
    /// terminals the server no longer lists, with another server instance and
    /// with its Host.
    @Test func theMemorySurvivesARelaunchAndGoesWithItsTerminalsAndHost() throws {
        let defaults = try suite()
        let host = UUID()
        let memory = HerdrCoreHostMemory(defaults: defaults)
        memory.noteCore("instance-0001", for: host)
        memory.updateRexTurnState(of: "a", for: host) { $0.note(report("done", at: 2, on: UUID()), kind: "codex") }
        memory.updateRexTurnState(of: "b", for: host) { state in
            state.note(report("done", at: 2, on: UUID()), kind: "codex")
            state.markSeen()
        }

        let relaunched = HerdrCoreHostMemory(defaults: defaults)
        relaunched.noteCore("instance-0001", for: host)
        #expect(relaunched.rexTurnStates(for: host).mapValues(\.isDone) == ["a": true, "b": false])

        relaunched.retainRexPanes(["b"], for: host)
        #expect(Set(relaunched.rexTurnStates(for: host).keys) == ["b"])
        relaunched.noteCore("instance-0002", for: host)
        #expect(relaunched.rexTurnStates(for: host).isEmpty)

        relaunched.updateRexTurnState(of: "c", for: host) {
            $0.note(report("done", at: 2, on: UUID()), kind: "codex")
        }
        relaunched.retainHosts([])
        #expect(HerdrCoreHostMemory(defaults: defaults).rexTurnStates(for: host).isEmpty)
    }
}
