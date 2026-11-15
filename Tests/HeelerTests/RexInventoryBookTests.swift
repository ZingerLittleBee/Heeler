import Foundation
import Testing

@testable import Heeler

/// What a Rex server's inventory reads as, and how events and answers keep it
/// current in order: no answer undoes a newer event or answer, a burst of
/// changes costs one read and the one after it, and sessions that come and go
/// during reads come out right (ADR 0048). Fixtures are invented, in the
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
