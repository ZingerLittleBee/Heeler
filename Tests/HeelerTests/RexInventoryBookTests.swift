import Foundation
import Testing

@testable import Heeler

/// What a Rex server's inventory reads as, and how events and answers keep it
/// current in order: no answer undoes a newer event or answer, a burst of
/// changes costs one read and the one after it, and sessions that come and go
/// during reads come out right (ADR 0050). Fixtures are invented, in the
/// shapes Rex 0.1.0-preview.14 was seen to answer.
@Suite("Rex inventory book")
struct RexInventoryBookTests {
    private let studio = FakeRexWorld.studio()
    private static let terminal = RexInventoryWire.terminalCreator

    private func event(_ seq: UInt64, _ body: RexEventBody, session: String? = "session:studio") -> RexControlEvent {
        RexControlEvent(seq: seq, sessionID: session, body: body)
    }

    private func address(_ blockID: String, session: String = "session:studio") -> RexPaneAddress {
        RexPaneAddress(sessionID: session, blockID: blockID)
    }

    /// A book that listed `sessions` at `seq` and read each one's structure there.
    private func settled(
        _ sessions: [FakeRexWorld.Session], seq: UInt64 = 0, carrying: [RexPaneAddress: RexTerminalDetails] = [:]
    ) -> RexInventoryBook {
        var book = RexInventoryBook(carrying: carrying)
        book.beginListing()
        book.listed(sessions.map { .init(id: $0.id, label: $0.label) }, seq: seq)
        _ = book.takeReads(limit: sessions.count)
        for session in sessions { answer(&book, session, seq: seq) }
        return book
    }

    private func answer(_ book: inout RexInventoryBook, _ session: FakeRexWorld.Session, seq: UInt64) {
        book.structureRead(
            session.id, view: .init(value: RexInventoryWire.view(FakeRexWorld.view(session)), seq: seq),
            listing: .init(value: RexInventoryWire.blocks(FakeRexWorld.listing(session)), seq: seq))
    }

    private func structureReads(_ book: inout RexInventoryBook) -> [RexInventoryBook.Read] {
        book.takeReads(limit: 8).filter {
            if case .structure = $0 { true } else { false }
        }
    }

    private func titleEvent(_ seq: UInt64, _ blockID: String, _ title: String) -> RexControlEvent {
        event(seq, .blockEvent(blockID: blockID, creatorName: Self.terminal, name: "title_changed", payload: ["title": .string(title)]))
    }

    // MARK: Reading order

    /// Two windows, a split, a floating layer, a detached terminal and a block
    /// that is not a terminal: terminals in reading order, the notes left out,
    /// and the labels Rex gives new blocks and windows read as none.
    @Test func aSessionListsItsTerminalsInReadingOrder() throws {
        var book = RexInventoryBook()
        book.beginListing()
        book.listed([.init(id: studio.id, label: "studio")], seq: 0)
        #expect(book.takeReads(limit: 4) == [.structure(sessionID: studio.id)])
        #expect(!book.isStructureSettled)
        answer(&book, studio, seq: 0)
        #expect(book.isStructureSettled)

        let session = try #require(book.inventory.sessions.first)
        #expect(book.inventory.sessions.count == 1)
        #expect(session.label == "studio")
        #expect(session.activeWindowID == "window:0000-0000-0000-00000000b0b0")
        #expect(session.windows.map(\.label) == ["editor", nil])
        #expect(session.windows.map { $0.terminals.map(\.blockID) } == [["block:left", "block:right"], ["block:solo", "block:float"]])
        #expect(session.detached.map(\.blockID) == ["block:detached"])
        #expect(session.terminals.map(\.label) == ["left", nil, nil, "scratch", nil])
        #expect(session.terminals.allSatisfy { $0.owner == "client:00000000-0000-7000-8000-0000000000aa" })
        // Details are read for terminals only, in the same order.
        #expect(
            book.takeReads(limit: 8)
                == ["block:left", "block:right", "block:solo", "block:float", "block:detached"].map {
                    .details(address($0))
                })
        #expect(!book.isDetailSettled)
    }

    /// A block whose label was cleared carries the label Rex makes from its
    /// id, which reads as unnamed; the same words on another block's id are
    /// the user's.
    @Test func aClearedBlockLabelReadsAsUnnamed() {
        var session = studio
        var cleared = FakeRexWorld.Block("block:00000000-0000-7000-8000-0000c0ffee01")
        cleared.label = "Block c0ffee01"
        var named = FakeRexWorld.Block("block:00000000-0000-7000-8000-0000c0ffee02")
        named.label = "Block c0ffee01"
        session.detached = [cleared, named]
        let book = settled([session])
        #expect(book.inventory.sessions.first?.detached.map(\.label) == [nil, "Block c0ffee01"])
    }

    /// No more reads are in flight than the limit, structure first.
    @Test func readsStayWithinTheLimit() {
        var book = RexInventoryBook()
        let other = FakeRexWorld.studio(id: "session:other", label: "other")
        book.beginListing()
        book.listed([.init(id: studio.id, label: "studio"), .init(id: other.id, label: "other")], seq: 0)
        #expect(book.takeReads(limit: 1) == [.structure(sessionID: studio.id)])
        #expect(book.takeReads(limit: 1) == [])
        answer(&book, studio, seq: 0)
        #expect(book.takeReads(limit: 2) == [.structure(sessionID: other.id), .details(address("block:left"))])
        #expect(book.takeReads(limit: 2) == [])
        book.detailsRead(address("block:left"), title: nil, process: nil)
        #expect(book.takeReads(limit: 2) == [.details(address("block:right"))])
    }

    /// A read whose session or terminal went while it was in flight still
    /// counts against the limit until its answer comes back.
    @Test func readsOfWhatWentStayWithinTheLimit() {
        var book = RexInventoryBook()
        let other = FakeRexWorld.studio(id: "session:other", label: "other")
        let third = FakeRexWorld.studio(id: "session:third", label: "third")
        book.beginListing()
        book.listed([studio, other, third].map { .init(id: $0.id, label: $0.label) }, seq: 0)
        #expect(book.takeReads(limit: 2) == [.structure(sessionID: studio.id), .structure(sessionID: other.id)])
        book.apply(event(1, .sessionDestroyed(sessionID: studio.id), session: nil))
        #expect(book.takeReads(limit: 2) == [])
        answer(&book, studio, seq: 0)
        #expect(book.takeReads(limit: 2) == [.structure(sessionID: third.id)])
        answer(&book, other, seq: 0)
        #expect(book.takeReads(limit: 2) == [.details(address("block:left", session: other.id))])

        // A terminal closed while its details are read holds its place too.
        book.apply(event(2, .blockClosed(blockID: "block:left"), session: other.id))
        #expect(book.takeReads(limit: 2) == [])
        book.detailsRead(address("block:left", session: other.id), title: nil, process: nil)
        #expect(book.takeReads(limit: 2) == [.structure(sessionID: other.id)])
    }

    @Test func detailsFillTheirTerminal() throws {
        var book = settled([studio])
        _ = book.takeReads(limit: 8)
        book.detailsRead(
            address("block:left"), title: .init(value: "make test", seq: 0),
            process: .init(value: .init(program: "make", directory: "/home/dev/app"), seq: 0))
        let left = try #require(book.inventory.sessions.first?.terminals.first)
        #expect(left.details == RexTerminalDetails(title: "make test", program: "make", directory: "/home/dev/app"))
        #expect(!book.isDetailSettled)
        for blockID in ["block:right", "block:solo", "block:float", "block:detached"] {
            book.detailsRead(address(blockID), title: nil, process: nil)
        }
        #expect(book.isDetailSettled)
    }

    /// What the last link knew shows until this one reads it again.
    @Test func carriedDetailsShowUntilRead() throws {
        let carried = RexTerminalDetails(title: "carried", program: "zsh", directory: "/home/dev")
        var book = settled([studio], carrying: [address("block:left"): carried])
        #expect(book.inventory.sessions.first?.terminals.first?.details == carried)
        _ = book.takeReads(limit: 8)
        book.detailsRead(address("block:left"), title: .init(value: nil, seq: 0), process: nil)
        #expect(book.inventory.sessions.first?.terminals.first?.details.title == nil)
        #expect(book.inventory.sessions.first?.terminals.first?.details.program == "zsh")
    }

    // MARK: Events

    /// Every event that changes a session's layout reads its structure again.
    @Test(arguments: [
        RexEventBody.sessionViewChanged(revision: 4),
        .sessionViewChanged(revision: nil),
        .windowCreated(windowID: "window:new", label: "new"),
        .windowClosed(windowID: "window:0000-0000-0000-00000000a0a0"),
        .windowLabelChanged(windowID: "window:0000-0000-0000-00000000a0a0", label: "renamed"),
        .activeWindowChanged(windowID: "window:0000-0000-0000-00000000a0a0"),
        .blockCreated(blockID: "block:new"),
        .blockClosed(blockID: "block:right"),
        .unreadable(name: "session_view_changed"),
    ])
    func aLayoutEventReadsTheStructureAgain(body: RexEventBody) {
        var book = settled([studio])
        #expect(structureReads(&book) == [])
        book.apply(event(1, body))
        #expect(!book.isStructureSettled)
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
    }

    /// A move, a float, a detach and a split each arrive as a view change
    /// alone, and the read after it says where each terminal went.
    @Test func aReadAfterAViewChangeMovesTerminals() throws {
        var book = settled([studio])
        var moved = studio
        // The detached terminal joins the first window; the floating one is detached.
        let detached = moved.detached.removeFirst()
        moved.windows[0].layers[0].blocks.append(detached)
        moved.windows[0].layers[0].layout = .split(.block("block:left"), .split(.block("block:right"), .block(detached.id)))
        let float = moved.windows[1].layers.removeLast().blocks[0]
        moved.detached = [float]
        moved.revision = 4
        book.apply(event(1, .sessionViewChanged(revision: 4)))
        _ = structureReads(&book)
        answer(&book, moved, seq: 1)

        let session = try #require(book.inventory.sessions.first)
        #expect(session.windows.map { $0.terminals.map(\.blockID) } == [["block:left", "block:right", "block:detached"], ["block:solo"]])
        #expect(session.detached.map(\.blockID) == ["block:float"])
        #expect(book.isStructureSettled)
    }

    /// A view change the view already shows, revisions arriving out of order,
    /// asks for nothing.
    @Test func aRevisionTheViewHasReadsNothing() {
        var book = settled([studio])
        book.apply(event(1, .sessionViewChanged(revision: 3)))
        book.apply(event(2, .sessionViewChanged(revision: 2)))
        #expect(structureReads(&book) == [])
        #expect(book.isStructureSettled)
    }

    /// A closed terminal leaves at once, before any read.
    @Test func aClosedTerminalLeavesAtOnce() throws {
        var book = settled([studio])
        book.apply(event(1, .blockClosed(blockID: "block:right")))
        let session = try #require(book.inventory.sessions.first)
        #expect(!session.terminals.map(\.blockID).contains("block:right"))
    }

    @Test func labelsAndOwnersChangeWithoutARead() throws {
        var book = settled([studio])
        book.apply(event(1, .sessionLabelChanged(label: "renamed")))
        book.apply(event(2, .blockOwnerChanged(blockID: "block:left", owner: nil, previousOwner: "client:a", reason: "lost")))
        #expect(structureReads(&book) == [])
        let session = try #require(book.inventory.sessions.first)
        #expect(session.label == "renamed")
        #expect(session.terminals.first?.owner == nil)
    }

    /// A terminal's own events keep its title, program and directory current;
    /// another creator's events and other names change nothing.
    @Test func blockEventsKeepDetailsCurrent() throws {
        var book = settled([studio])
        book.apply(titleEvent(1, "block:left", "vim notes.md"))
        book.apply(
            event(2, .blockEvent(
                blockID: "block:left", creatorName: Self.terminal, name: "process_changed",
                payload: ["generation": 3, "foreground": ["name": "vim", "cwd": "/home/dev/notes"]])))
        book.apply(event(3, .blockEvent(blockID: "block:left", creatorName: "com.example.notes", name: "title_changed", payload: ["title": "x"])))
        book.apply(event(4, .blockEvent(blockID: "block:left", creatorName: Self.terminal, name: "bell", payload: nil)))
        let left = try #require(book.inventory.sessions.first?.terminals.first)
        #expect(left.details == RexTerminalDetails(title: "vim notes.md", program: "vim", directory: "/home/dev/notes"))
        book.apply(
            event(5, .blockEvent(
                blockID: "block:left", creatorName: Self.terminal, name: "process_changed",
                payload: ["generation": 4, "foreground": .null])))
        #expect(book.inventory.sessions.first?.terminals.first?.details.program == nil)
        #expect(structureReads(&book) == [])
    }

    private func statusEvent(
        _ seq: UInt64, _ blockID: String, id: String = "", _ state: String, owner: Int = 77
    ) -> RexControlEvent {
        event(seq, .blockEvent(
            blockID: blockID, creatorName: Self.terminal, name: "program_status_changed",
            payload: [
                "id": .string(id),
                "record": [
                    "state": .string(state), "app": "codex", "owner": ["pid": .number(Double(owner)), "name": "codex"],
                    "updated_at": .string("2026-11-16T12:00:\(seq < 10 ? "0" : "")\(seq)+00:00"),
                ],
                "reason": "report",
            ]))
    }

    private func statusRemoved(_ seq: UInt64, _ blockID: String, ids: [String], reason: String) -> RexControlEvent {
        event(seq, .blockEvent(
            blockID: blockID, creatorName: Self.terminal, name: "program_status_removed",
            payload: ["ids": .array(ids.map { .string($0) }), "reason": .string(reason)]))
    }

    /// A terminal's root Program Status follows its events: a report replaces
    /// it, a removal that names the root drops it whatever the reason, and a
    /// program's child records change nothing (ADR 0054). The foreground an
    /// event names keeps its process id, first argument and script.
    @Test func programStatusEventsKeepTheRootRecord() throws {
        var book = settled([studio])
        book.apply(
            event(1, .blockEvent(
                blockID: "block:left", creatorName: Self.terminal, name: "process_changed",
                payload: ["foreground": ["pid": 77, "name": "codex", "argv0": "codex", "cwd": "/home/dev/app"]])))
        book.apply(statusEvent(2, "block:left", "working"))
        func left() throws -> RexTerminalDetails {
            try #require(book.inventory.sessions.first?.terminals.first).details
        }
        #expect(try left().processID == 77)
        #expect(try left().argv0 == "codex")
        let working = RexProgramStatus(
            state: "working", app: "codex", ownerProcessID: 77, ownerName: "codex",
            updatedAt: "2026-11-16T12:00:02+00:00")
        #expect(try left().status?.isSameReport(as: working) == true)

        book.apply(statusEvent(3, "block:left", id: "build", "error"))
        book.apply(statusRemoved(4, "block:left", ids: ["build"], reason: "child_exited"))
        #expect(try left().status?.state == "working")

        book.apply(statusEvent(5, "block:left", "blocked"))
        #expect(try left().status?.state == "blocked")
        book.apply(statusRemoved(6, "block:left", ids: ["", "build"], reason: "foreground"))
        #expect(try left().status == nil)
        #expect(structureReads(&book) == [])
    }

    /// A status read answered before a report does not undo it; one answered
    /// after it replaces it, and an answer with no root record clears it.
    @Test func aStatusAnswerOlderThanAReportDoesNotUndoIt() throws {
        var book = settled([studio])
        _ = book.takeReads(limit: 8)
        book.apply(statusEvent(5, "block:left", "working"))
        book.detailsRead(
            address("block:left"), title: nil, process: nil,
            status: .init(value: RexProgramStatus(state: "idle"), seq: 4))
        #expect(book.inventory.sessions.first?.terminals.first?.details.status?.state == "working")

        book.listed([.init(id: studio.id, label: "studio")], seq: 6)
        _ = book.takeReads(limit: 8)
        book.detailsRead(address("block:left"), title: nil, process: nil, status: .init(value: nil, seq: 6))
        #expect(book.inventory.sessions.first?.terminals.first?.details.status == nil)
    }

    /// A Program Status is a claim about now, so a new link does not carry the
    /// last one's: an Agent reads Unknown until this link reads it. Its
    /// foreground is carried, as its title is.
    @Test func carriedDetailsLeaveTheStatusBehind() throws {
        let carried = RexTerminalDetails(
            title: "codex", program: "codex", directory: "/home/dev", processID: 77, argv0: "codex",
            status: RexProgramStatus(state: "working", app: "codex", ownerProcessID: 77, ownerName: "codex"))
        let book = settled([studio], carrying: [address("block:left"): carried])
        let left = try #require(book.inventory.sessions.first?.terminals.first)
        #expect(left.details.program == "codex")
        #expect(left.details.processID == 77)
        #expect(left.details.status == nil)
    }

    /// The link counts the turns its events show ending, as ADR 0046 counts a
    /// tmux Pane's: working or blocked to done for the same program. The same
    /// done again, idle to done, another program's done and a removal count
    /// nothing, and the stretch goes on through all of them. A read answering
    /// the record the link holds keeps the stretch; one answering another
    /// starts a new one, since what came between went unheard.
    @Test func theLinkCountsTheTurnsItsEventsShowEnding() throws {
        var book = settled([studio])
        func status() throws -> RexProgramStatus {
            try #require(book.inventory.sessions.first?.terminals.first?.details.status)
        }
        func follow() throws -> RexStatusFollow { try #require(try status().follow) }
        book.apply(statusEvent(1, "block:left", "working"))
        let stretch = try follow()
        #expect(stretch.finishedTurns == 0)
        book.apply(statusEvent(2, "block:left", "done"))
        #expect(try follow() == RexStatusFollow(id: stretch.id, finishedTurns: 1))
        book.apply(statusEvent(3, "block:left", "done"))
        #expect(try follow() == RexStatusFollow(id: stretch.id, finishedTurns: 1))
        #expect(try status().updatedAt == "2026-11-16T12:00:03+00:00")
        book.apply(statusEvent(4, "block:left", "idle"))
        book.apply(statusEvent(5, "block:left", "done"))
        #expect(try follow().finishedTurns == 1)
        book.apply(statusEvent(6, "block:left", "blocked"))
        book.apply(statusEvent(7, "block:left", "done"))
        #expect(try follow().finishedTurns == 2)
        book.apply(statusEvent(8, "block:left", "working"))
        book.apply(statusEvent(9, "block:left", "done", owner: 78))
        #expect(try follow().finishedTurns == 2)
        book.apply(statusRemoved(10, "block:left", ids: [""], reason: "clear"))
        book.apply(statusEvent(11, "block:left", "working"))
        book.apply(statusEvent(12, "block:left", "done"))
        #expect(try follow() == RexStatusFollow(id: stretch.id, finishedTurns: 3))

        func read(_ state: String, at seq: UInt64) {
            book.listed([.init(id: studio.id, label: "studio")], seq: seq)
            _ = book.takeReads(limit: 8)
            let answer = RexProgramStatus(
                state: state, app: "codex", ownerProcessID: 77, ownerName: "codex",
                updatedAt: "2026-11-16T12:00:\(seq)+00:00")
            book.detailsRead(address("block:left"), title: nil, process: nil, status: .init(value: answer, seq: seq))
        }
        read("done", at: 12)
        #expect(try follow() == RexStatusFollow(id: stretch.id, finishedTurns: 3))
        read("done", at: 13)
        let next = try follow()
        #expect(next.id != stretch.id)
        #expect(next.finishedTurns == 0)

        // A link's first read starts its first stretch.
        var fresh = settled([studio])
        _ = fresh.takeReads(limit: 8)
        fresh.detailsRead(
            address("block:left"), title: nil, process: nil,
            status: .init(value: RexProgramStatus(state: "done", updatedAt: "2026-11-16T12:00:13+00:00"), seq: 1))
        #expect(fresh.inventory.sessions.first?.terminals.first?.details.status?.follow?.finishedTurns == 0)
    }

    /// The method's answer and the events read alike: only the root record,
    /// its app or the app it takes from a parent, its owner, and when Rex
    /// took it.
    @Test func theRootRecordIsReadFromAnAnswer() {
        let answer: JSONValue = [
            "records": [
                ["state": "done", "effective_app": "claude-code", "owner": ["pid": 9, "name": "9.9.9"],
                 "updated_at": "2026-11-16T12:16:31.95597+08:00"],
                ["id": "task", "state": "working", "app": "codex"],
            ]
        ]
        #expect(
            RexInventoryWire.rootStatus(answer)
                == RexProgramStatus(
                    state: "done", app: "claude-code", ownerProcessID: 9, ownerName: "9.9.9",
                    updatedAt: "2026-11-16T12:16:31.95597+08:00"))
        #expect(RexInventoryWire.rootStatus(["records": [["id": "task", "state": "working"]]]) == nil)
        #expect(RexInventoryWire.rootStatus(["records": []]) == nil)
        #expect(RexInventoryWire.rootStatus(["records": [["state": "idle"]]]) == RexProgramStatus(state: "idle"))
    }

    /// Claude Code's record stays at working once its turn has ended while
    /// commands it left in the background run, and says how many. That record
    /// reads done; what a running turn says, another program's record and
    /// another state read as reported.
    @Test(arguments: [
        ("working", "claude-code", "1 shell still running", "done"),
        ("working", "claude-code", "2 shells still running", "done"),
        ("working", "Claude-Code", "1 shell still running", "done"),
        ("working", "claude-code", "Check the server is still running", "working"),
        ("working", "claude-code", "still running", "working"),
        ("working", "claude-code", nil, "working"),
        ("working", "codex", "1 shell still running", "working"),
        ("working", nil, "1 shell still running", "working"),
        ("blocked", "claude-code", "1 shell still running", "blocked"),
    ] as [(String, String?, String?, String)])
    func aClaudeCodeRecordWaitingOnlyOnBackgroundCommandsReadsDone(
        reported: String, app: String?, message: String?, read: String
    ) {
        var record: [String: JSONValue] = ["state": .string(reported)]
        if let app { record["app"] = .string(app) }
        if let message { record["msg"] = .string(message) }
        #expect(RexInventoryWire.rootStatus(["records": [.object(record)]])?.state == read)
        #expect(RexInventoryWire.changedStatus(["id": "", "record": .object(record)])?.state == read)
    }

    /// No event says a detached terminal's label changed, so a session with
    /// detached terminals can be read again on demand; one with none is not.
    @Test func onlySessionsWithDetachedTerminalsAreReadAgain() throws {
        var placedOnly = FakeRexWorld.studio(id: "session:placed", label: "placed")
        placedOnly.detached = []
        var book = settled([studio, placedOnly])
        for read in book.takeReads(limit: 16) {
            guard case .details(let address) = read else { continue }
            book.detailsRead(address, title: nil, process: nil)
        }
        #expect(book.takeReads(limit: 16) == [])

        book.rereadDetached()
        #expect(!book.isStructureSettled)
        #expect(book.takeReads(limit: 16) == [.structure(sessionID: studio.id)])
        var renamed = studio
        renamed.detached[0].label = "deploy"
        answer(&book, renamed, seq: 0)
        #expect(book.isStructureSettled)
        #expect(book.inventory.sessions.first?.detached.map(\.label) == ["deploy"])
    }

    // MARK: Order

    /// A details answer started before an event does not undo the event, and
    /// one started after it does replace it.
    @Test func anAnswerOlderThanAnEventDoesNotUndoIt() throws {
        var book = settled([studio])
        _ = book.takeReads(limit: 8)
        book.apply(titleEvent(5, "block:left", "newer"))
        book.detailsRead(address("block:left"), title: .init(value: "older", seq: 4), process: nil)
        #expect(book.inventory.sessions.first?.terminals.first?.details.title == "newer")

        book.apply(titleEvent(6, "block:left", "event"))
        book.apply(event(7, .sessionViewChanged(revision: nil)))
        book.listed([.init(id: studio.id, label: "studio")], seq: 7)
        _ = book.takeReads(limit: 8)
        book.detailsRead(address("block:left"), title: .init(value: "answer", seq: 7), process: nil)
        #expect(book.inventory.sessions.first?.terminals.first?.details.title == "answer")
    }

    /// A structure answer that still lists a terminal closed after it began
    /// does not bring the terminal back.
    @Test func aStructureAnswerOlderThanACloseKeepsTheTerminalClosed() throws {
        var book = settled([studio])
        book.apply(event(1, .sessionViewChanged(revision: 4)))
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        book.apply(event(2, .blockClosed(blockID: "block:right")))
        var stale = studio
        stale.revision = 4
        answer(&book, stale, seq: 1)
        #expect(book.inventory.sessions.first?.terminals.map(\.blockID).contains("block:right") == false)
        // The close came after that answer, so the structure is read again.
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
    }

    /// A listing newer than the view may place a terminal the view does not
    /// show yet. It is not shown as detached; the events that placed it read
    /// the structure again, and that read shows it in its window.
    @Test func aTerminalPlacedAfterTheViewIsNotDetached() throws {
        var book = settled([studio])
        book.apply(event(1, .sessionViewChanged(revision: 4)))
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        var older = studio
        older.revision = 4
        var newer = studio
        newer.revision = 5
        newer.windows[0].layers[0].blocks.append(FakeRexWorld.Block("block:new"))
        newer.windows[0].layers[0].layout = .split(.block("block:left"), .split(.block("block:right"), .block("block:new")))
        book.structureRead(
            studio.id, view: .init(value: RexInventoryWire.view(FakeRexWorld.view(older)), seq: 1),
            listing: .init(value: RexInventoryWire.blocks(FakeRexWorld.listing(newer)), seq: 3))

        #expect(book.isStructureSettled)
        var session = try #require(book.inventory.sessions.first)
        #expect(session.detached.map(\.blockID) == ["block:detached"])
        #expect(!session.terminals.map(\.blockID).contains("block:new"))

        book.apply(event(2, .blockCreated(blockID: "block:new")))
        book.apply(event(3, .sessionViewChanged(revision: 5)))
        #expect(!book.isStructureSettled)
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        answer(&book, newer, seq: 3)
        session = try #require(book.inventory.sessions.first)
        #expect(session.windows.first?.terminals.map(\.blockID) == ["block:left", "block:right", "block:new"])
        #expect(session.detached.map(\.blockID) == ["block:detached"])
    }

    /// A session whose view could not be read on its first read is neither
    /// shown empty nor left out at once: it stays unsettled until it is read
    /// again.
    @Test func aSessionWhoseFirstReadFailedIsReadAgainBeforeItSettles() {
        var book = RexInventoryBook()
        book.beginListing()
        book.listed([.init(id: studio.id, label: "studio")], seq: 0)
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        let again = book.structureRead(studio.id, view: .init(value: nil, seq: 0), listing: .init(value: nil, seq: 0))
        #expect(again)
        #expect(!book.isStructureSettled)
        #expect(structureReads(&book).isEmpty)

        book.retryRead(studio.id)
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        answer(&book, studio, seq: 0)
        #expect(book.isStructureSettled)
        #expect(book.inventory.sessions.map(\.id) == [studio.id])
    }

    /// After its attempts a session that never reads settles unread, so the
    /// rest of the inventory shows, and the periodic read tries it again.
    @Test func aSessionThatNeverReadsSettlesAfterItsAttempts() {
        var book = RexInventoryBook()
        book.beginListing()
        book.listed([.init(id: studio.id, label: "studio")], seq: 0)
        for attempt in 1...RexInventoryBook.firstReadAttempts {
            #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
            let again = book.structureRead(
                studio.id, view: .init(value: nil, seq: 0), listing: .init(value: nil, seq: 0))
            #expect(again == (attempt < RexInventoryBook.firstReadAttempts))
            book.retryRead(studio.id)
        }
        #expect(book.isStructureSettled)
        #expect(book.inventory.sessions.isEmpty)

        book.rereadDetached()
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        answer(&book, studio, seq: 0)
        #expect(book.inventory.sessions.map(\.id) == [studio.id])
    }

    /// An answer older than the view already held is not applied.
    @Test func anOlderViewDoesNotReplaceANewerOne() throws {
        var book = settled([studio])
        var newer = studio
        newer.revision = 9
        newer.windows[0].label = "newer"
        answer(&book, newer, seq: 10)
        var older = studio
        older.revision = 5
        older.windows[0].label = "older"
        answer(&book, older, seq: 8)
        #expect(book.inventory.sessions.first?.windows.first?.label == "newer")
    }

    /// A burst of view changes while a read is in flight costs that read and
    /// one more, whose answer covers them all.
    @Test func aBurstOfChangesCostsOneReadAndTheOneAfter() {
        var book = settled([studio])
        book.apply(event(1, .sessionViewChanged(revision: 4)))
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        for seq in 2...6 { book.apply(event(UInt64(seq), .sessionViewChanged(revision: seq + 3))) }
        #expect(structureReads(&book) == [])
        var first = studio
        first.revision = 4
        answer(&book, first, seq: 1)
        #expect(!book.isStructureSettled)
        #expect(structureReads(&book) == [.structure(sessionID: studio.id)])
        var last = studio
        last.revision = 9
        answer(&book, last, seq: 6)
        #expect(structureReads(&book) == [])
        #expect(book.isStructureSettled)
    }

    // MARK: Sessions coming and going

    /// Events that arrive while the list is read wait for it; those it
    /// already covers are skipped.
    @Test func eventsDuringTheListWaitForIt() throws {
        var book = RexInventoryBook()
        book.beginListing()
        book.apply(event(1, .sessionCreated(sessionID: studio.id, label: "studio"), session: nil))
        book.apply(event(2, .sessionCreated(sessionID: "session:late", label: "late"), session: nil))
        #expect(book.takeReads(limit: 8) == [])
        book.listed([.init(id: studio.id, label: "studio")], seq: 1)
        #expect(
            book.takeReads(limit: 8) == [.structure(sessionID: studio.id), .structure(sessionID: "session:late")])
    }

    /// A session destroyed while its read is in flight stays gone when the
    /// answer lands, and one the server no longer knows is dropped.
    @Test func sessionsDestroyedDuringReadsStayGone() {
        let other = FakeRexWorld.studio(id: "session:other", label: "other")
        var book = RexInventoryBook()
        book.beginListing()
        book.listed([.init(id: studio.id, label: "studio"), .init(id: other.id, label: "other")], seq: 0)
        _ = book.takeReads(limit: 8)
        book.apply(event(1, .sessionDestroyed(sessionID: studio.id), session: nil))
        answer(&book, studio, seq: 0)
        book.sessionGone(other.id)
        #expect(book.inventory.sessions.isEmpty)
        #expect(book.isStructureSettled)
        // An event from the destroyed session brings nothing back.
        book.apply(event(2, .sessionViewChanged(revision: 9), session: studio.id))
        #expect(book.inventory.sessions.isEmpty)
        #expect(book.takeReads(limit: 8) == [])
    }

    @Test func aSessionCreatedLaterIsReadAndMoves() throws {
        let other = FakeRexWorld.studio(id: "session:other", label: "other")
        var book = settled([studio])
        book.apply(event(1, .sessionCreated(sessionID: other.id, label: "other"), session: nil))
        #expect(structureReads(&book) == [.structure(sessionID: other.id)])
        #expect(!book.isStructureSettled)
        answer(&book, other, seq: 1)
        #expect(book.inventory.sessions.map(\.id) == [studio.id, other.id])
        book.apply(event(2, .sessionMoved(sessionID: other.id, beforeSessionID: studio.id), session: nil))
        #expect(book.inventory.sessions.map(\.id) == [other.id, studio.id])
    }

    /// A session with no terminal is not listed.
    @Test func aSessionWithoutTerminalsIsNotListed() {
        var empty = studio
        empty.windows = [FakeRexWorld.Window(id: "window:notes", label: "notes", layers: [
            FakeRexWorld.Layer(layout: .block("block:notes"), blocks: [.notes("block:notes")])
        ])]
        empty.detached = []
        let book = settled([empty])
        #expect(book.inventory.sessions.isEmpty)
        #expect(book.isStructureSettled)
    }

    /// Missing events, or a server-wide event that could not be read, read
    /// the list again, and with it every session and terminal.
    @Test func aBrokenSequenceReadsEverythingAgain() {
        var book = settled([studio])
        _ = book.takeReads(limit: 8)
        for blockID in ["block:left", "block:right", "block:solo", "block:float", "block:detached"] {
            book.detailsRead(address(blockID), title: nil, process: nil)
        }
        book.apply(event(1, .unreadable(name: "session_created"), session: nil))
        #expect(book.needsListing)
        book.beginListing()
        book.listed([.init(id: studio.id, label: "studio")], seq: 5)
        #expect(book.takeReads(limit: 1) == [.structure(sessionID: studio.id)])
        answer(&book, studio, seq: 5)
        #expect(book.takeReads(limit: 8).count == 5)

        book.sequenceBroke()
        #expect(book.needsListing)
        #expect(!book.isStructureSettled)
    }
}
