import Foundation

/// What one control link knows of a Rex server's sessions, and what it still
/// has to read (ADR 0050). Pure: `RexInventoryFollower` sends the reads it
/// asks for and hands back their answers and the link's events.
///
/// An answer's seq says how far the connection's event stream had got when
/// the server took the request up, so an event numbered above it is newer than
/// the answer and one at or below it is already in it. A session's
/// structure (its view and its block listing) is read again after any event
/// that changed it, one read in flight per session, so a burst of events costs
/// one read and the one after it. No answer replaces what an event or answer
/// newer than it already said. A terminal's details are read once per link and
/// then follow its own events, and its Program Status carries how the link
/// followed it (`RexStatusFollow`), which counts the turns the events show
/// ending, as no published inventory can: one may stand for several reports.
struct RexInventoryBook {
    enum Read: Hashable, Sendable {
        /// A session's view, then its block listing.
        case structure(sessionID: String)
        /// A terminal's title, its foreground process, then its Program Status.
        case details(RexPaneAddress)
    }

    /// One answer and the seq it came with.
    struct Answer<Value> {
        let value: Value
        let seq: UInt64
    }

    private struct SessionRecord {
        var label: String
        var labelSeq: UInt64 = 0
        var view: RexInventoryWire.View?
        var viewSeq: UInt64 = 0
        var listing: [RexInventoryWire.ListedBlock]?
        var listingSeq: UInt64 = 0
        /// The newest event that changed the structure.
        var wantedSeq: UInt64 = 0
        /// How far the structure is known: what the last read's answers covered.
        var heldSeq: UInt64 = 0
        /// A read is due whatever the seqs say: the session is new, or what
        /// changed it could not be read.
        var forced = true
        var reading = false
        /// `wantedSeq` when the read in flight started.
        var readFromSeq: UInt64 = 0
        /// A read finished, or failed, at least once.
        var hasSettled = false
        /// Reads that left the view unread before the session first settled.
        var failedFirstReads = 0
        /// A failed first read waits for `retryRead` before it goes again.
        var awaitingRetry = false
        var closedBlocks: Set<String> = []
        var owners: [String: (owner: String?, seq: UInt64)] = [:]

        var needsRead: Bool { !reading && !awaitingRetry && (forced || wantedSeq > heldSeq) }

        mutating func noteOwner(_ block: RexInventoryWire.BlockFacts, seq: UInt64) {
            guard seq >= owners[block.id]?.seq ?? 0 else { return }
            owners[block.id] = (block.owner, seq)
        }
    }

    private struct DetailRecord {
        var details: RexTerminalDetails
        var titleSeq: UInt64 = 0
        var processSeq: UInt64 = 0
        var statusSeq: UInt64 = 0
        var wanted = true
        var reading = false
        /// How this link has followed the root record; nil until it first
        /// read or heard it.
        var follow: RexStatusFollow?

        /// A report this link heard: its stretch goes on, and counts a
        /// finished turn when the report takes the program's record from
        /// working or blocked to done. A removal heard goes on with it too.
        mutating func noteReport(_ status: RexProgramStatus?) {
            var follow = follow ?? RexStatusFollow()
            if let held = details.status, let status, status.state == "done",
                held.state == "working" || held.state == "blocked", held.isSameProgram(as: status)
            {
                follow.finishedTurns += 1
            }
            hold(status, following: follow)
        }

        /// A read's answer. One that is not the record this link held may
        /// follow reports it never heard, so it starts another stretch.
        mutating func noteRead(_ status: RexProgramStatus?) {
            let held = details.status
            let isHeld =
                switch (held, status) {
                case (nil, nil): true
                case (let held?, let status?): held.isSameReport(as: status)
                default: false
                }
            hold(status, following: isHeld ? follow ?? RexStatusFollow() : RexStatusFollow())
        }

        private mutating func hold(_ status: RexProgramStatus?, following follow: RexStatusFollow) {
            self.follow = follow
            details.status = status.map { status in
                var status = status
                status.follow = follow
                return status
            }
        }
    }

    private var order: [String] = []
    private var sessions: [String: SessionRecord] = [:]
    private var destroyed: Set<String> = []
    private var details: [RexPaneAddress: DetailRecord] = [:]
    /// What the last link knew of each terminal, shown until this one reads
    /// it. A Program Status is not carried: an Agent's status is this link's
    /// own read, or Unknown until it answers (ADR 0054).
    private let carried: [RexPaneAddress: RexTerminalDetails]
    /// The seq the session list was read at; nil while it is being read, when
    /// events wait in `pending`.
    private var listedSeq: UInt64?
    private var pending: [RexControlEvent] = []
    /// Reads handed out whose answer has not come back. Counted apart from the
    /// records, since an event can drop a record while its read is in flight.
    private var readsInFlight = 0

    /// The session list needs reading again: an event that changed it could
    /// not be read, or events went missing.
    private(set) var needsListing = true

    /// Reads of a session whose view never read before it settles unread.
    static let firstReadAttempts = 3

    init(carrying carried: [RexPaneAddress: RexTerminalDetails] = [:]) {
        self.carried = carried.mapValues { details in
            var details = details
            details.status = nil
            return details
        }
    }

    // MARK: The session list

    /// The session list is being read: events wait until it is answered.
    mutating func beginListing() {
        needsListing = false
        listedSeq = nil
    }

    /// The session list as `session.attach_all` answered it. Sessions it does
    /// not name are gone. Every session's structure and every terminal's
    /// details are read again, since events may have gone missing before it.
    mutating func listed(_ entries: [RexInventoryWire.SessionEntry], seq: UInt64) {
        listedSeq = seq
        let named = Set(entries.map(\.id))
        for id in order where !named.contains(id) { forget(id) }
        order = []
        for entry in entries where !destroyed.contains(entry.id) {
            order.append(entry.id)
            if sessions[entry.id] == nil {
                sessions[entry.id] = SessionRecord(label: entry.label)
            } else {
                sessions[entry.id]?.forced = true
            }
            if let labelSeq = sessions[entry.id]?.labelSeq, seq >= labelSeq {
                sessions[entry.id]?.label = entry.label
                sessions[entry.id]?.labelSeq = seq
            }
        }
        for address in details.keys { details[address]?.wanted = true }
        let waiting = pending
        pending = []
        for event in waiting where event.seq > seq { apply(event) }
    }

    /// Events went missing: the list is read again, and with it everything else.
    mutating func sequenceBroke() {
        needsListing = true
    }

    /// Each session with a detached terminal reads its structure again. Rex
    /// raises no event when a detached block's label changes, so only a read
    /// shows it. So does a session whose view could never be read. A session
    /// whose read is in flight reads once more after it.
    mutating func rereadDetached() {
        for id in order {
            guard let record = sessions[id] else { continue }
            let unread = record.hasSettled && record.view == nil
            guard unread || session(id, record)?.detached.isEmpty == false else { continue }
            sessions[id]?.forced = true
        }
    }

    // MARK: Events

    mutating func apply(_ event: RexControlEvent) {
        guard let listedSeq else {
            pending.append(event)
            return
        }
        guard event.seq > listedSeq else { return }
        let seq = event.seq
        switch event.body {
        case .sessionCreated(let id, let label):
            guard !destroyed.contains(id), sessions[id] == nil else { return }
            sessions[id] = SessionRecord(label: label ?? "", labelSeq: seq)
            order.append(id)
        case .sessionDestroyed(let id):
            destroyed.insert(id)
            forget(id)
        case .sessionMoved(let id, let before):
            guard let index = order.firstIndex(of: id) else { return }
            order.remove(at: index)
            let target = before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
            order.insert(id, at: target)
        case .unreadable where event.sessionID == nil:
            needsListing = true
        default:
            guard let sessionID = event.sessionID else { return }
            applySessionEvent(event.body, to: sessionID, seq: seq)
        }
    }

    private mutating func applySessionEvent(_ body: RexEventBody, to sessionID: String, seq: UInt64) {
        guard !destroyed.contains(sessionID) else { return }
        if sessions[sessionID] == nil {
            // An event of a session the list did not name yet: read it whole.
            sessions[sessionID] = SessionRecord(label: "")
            order.append(sessionID)
        }
        switch body {
        case .sessionLabelChanged(let label):
            guard seq > sessions[sessionID]?.labelSeq ?? 0 else { return }
            sessions[sessionID]?.label = label ?? ""
            sessions[sessionID]?.labelSeq = seq
        case .sessionViewChanged(let revision):
            // Revisions may arrive out of order; one the view already has changes nothing.
            if let revision, let held = sessions[sessionID]?.view?.revision, revision <= held { return }
            want(sessionID, seq)
        case .windowCreated, .windowClosed, .windowLabelChanged, .activeWindowChanged, .blockCreated:
            want(sessionID, seq)
        case .blockClosed(let blockID):
            sessions[sessionID]?.closedBlocks.insert(blockID)
            details[RexPaneAddress(sessionID: sessionID, blockID: blockID)] = nil
            want(sessionID, seq)
        case .blockOwnerChanged(let blockID, let owner, _, _):
            guard seq > sessions[sessionID]?.owners[blockID]?.seq ?? 0 else { return }
            sessions[sessionID]?.owners[blockID] = (owner, seq)
        case .blockEvent(let blockID, let creator, let name, let payload):
            guard creator == nil || creator == RexInventoryWire.terminalCreator,
                sessions[sessionID]?.closedBlocks.contains(blockID) != true
            else { return }
            let address = RexPaneAddress(sessionID: sessionID, blockID: blockID)
            switch name {
            case "title_changed":
                updateDetails(of: address) { record in
                    guard seq > record.titleSeq else { return }
                    record.details.title = RexInventoryWire.title(payload)
                    record.titleSeq = seq
                }
            case "process_changed":
                updateDetails(of: address) { record in
                    guard seq > record.processSeq else { return }
                    record.details.noteForeground(RexInventoryWire.process(payload))
                    record.processSeq = seq
                }
            case "program_status_changed" where RexInventoryWire.changesRootStatus(payload):
                updateDetails(of: address) { record in
                    guard seq > record.statusSeq else { return }
                    record.noteReport(RexInventoryWire.changedStatus(payload))
                    record.statusSeq = seq
                }
            case "program_status_removed" where RexInventoryWire.removesRootStatus(payload):
                updateDetails(of: address) { record in
                    guard seq > record.statusSeq else { return }
                    record.noteReport(nil)
                    record.statusSeq = seq
                }
            default:
                break
            }
        case .unreadable:
            sessions[sessionID]?.forced = true
        case .sessionCreated, .sessionDestroyed, .sessionMoved:
            break
        }
    }

    private mutating func want(_ sessionID: String, _ seq: UInt64) {
        guard let wanted = sessions[sessionID]?.wantedSeq, seq > wanted else { return }
        sessions[sessionID]?.wantedSeq = seq
    }

    private mutating func updateDetails(of address: RexPaneAddress, _ change: (inout DetailRecord) -> Void) {
        var record = details[address] ?? DetailRecord(details: carried[address] ?? RexTerminalDetails())
        change(&record)
        details[address] = record
    }

    private mutating func forget(_ sessionID: String) {
        sessions[sessionID] = nil
        order.removeAll { $0 == sessionID }
        details = details.filter { $0.key.sessionID != sessionID }
    }

    // MARK: Reads

    /// The reads to send now, at most `limit` in flight in all: each session's
    /// structure ahead of any terminal's details. Each one returned counts as
    /// in flight until its answer or failure is handed back, even when its
    /// session or terminal has gone meanwhile.
    mutating func takeReads(limit: Int) -> [Read] {
        guard listedSeq != nil else { return [] }
        var reads: [Read] = []
        defer { readsInFlight += reads.count }
        var inFlight = readsInFlight
        for id in order where inFlight < limit {
            guard var record = sessions[id], record.needsRead else { continue }
            record.reading = true
            record.forced = false
            record.readFromSeq = record.wantedSeq
            sessions[id] = record
            reads.append(.structure(sessionID: id))
            inFlight += 1
        }
        guard inFlight < limit else { return reads }
        // A terminal's details are read once its session's structure shows it.
        for address in shownAddresses() where inFlight < limit {
            var record = details[address] ?? DetailRecord(details: carried[address] ?? RexTerminalDetails())
            guard record.wanted, !record.reading else { continue }
            record.wanted = false
            record.reading = true
            details[address] = record
            reads.append(.details(address))
            inFlight += 1
        }
        return reads
    }

    /// A structure read's answers. A nil view or listing could not be read,
    /// or the server refused it.
    ///
    /// Returns true when the session's view has still never been read and
    /// fewer than `firstReadAttempts` reads were made: the session stays
    /// unsettled, so no inventory shows it as empty or leaves it out, and is
    /// read again once `retryRead` says so. After that many it settles
    /// unread, and `rereadDetached` reads it again.
    @discardableResult
    mutating func structureRead(
        _ sessionID: String, view: Answer<RexInventoryWire.View?>, listing: Answer<[RexInventoryWire.ListedBlock]?>
    ) -> Bool {
        readEnded()
        guard var record = sessions[sessionID] else { return false }
        record.reading = false
        if let newView = view.value, view.seq >= record.viewSeq,
            newView.revision >= record.view?.revision ?? Int.min
        {
            record.view = newView
            record.viewSeq = view.seq
            if view.seq >= record.labelSeq, let label = newView.label {
                record.label = label
                record.labelSeq = view.seq
            }
            for window in newView.windows {
                for block in window.blocks { record.noteOwner(block, seq: view.seq) }
            }
        }
        if let newListing = listing.value, listing.seq >= record.listingSeq {
            record.listing = newListing
            record.listingSeq = listing.seq
            for block in newListing { record.noteOwner(block.facts, seq: listing.seq) }
        }
        if record.view == nil, !record.hasSettled {
            record.failedFirstReads += 1
            if record.failedFirstReads < Self.firstReadAttempts {
                record.forced = true
                record.awaitingRetry = true
                sessions[sessionID] = record
                return true
            }
        }
        record.hasSettled = true
        if view.value == nil || listing.value == nil {
            // An answer that did not read is not asked again until something changes.
            record.heldSeq = max(record.heldSeq, record.readFromSeq)
        } else {
            record.heldSeq = max(record.heldSeq, min(view.seq, listing.seq))
        }
        sessions[sessionID] = record
        return false
    }

    /// A session whose first read left its view unread may be read again.
    mutating func retryRead(_ sessionID: String) {
        sessions[sessionID]?.awaitingRetry = false
    }

    /// A structure read's answer: the server no longer knows the session.
    mutating func sessionGone(_ sessionID: String) {
        readEnded()
        destroyed.insert(sessionID)
        forget(sessionID)
    }

    /// A details read's answers; nil for one that failed.
    mutating func detailsRead(
        _ address: RexPaneAddress, title: Answer<String?>?, process: Answer<RexInventoryWire.Process>?,
        status: Answer<RexProgramStatus?>? = nil
    ) {
        readEnded()
        guard var record = details[address] else { return }
        record.reading = false
        if let title, title.seq >= record.titleSeq {
            record.details.title = title.value
            record.titleSeq = title.seq
        }
        if let process, process.seq >= record.processSeq {
            record.details.noteForeground(process.value)
            record.processSeq = process.seq
        }
        if let status, status.seq >= record.statusSeq {
            record.noteRead(status.value)
            record.statusSeq = status.seq
        }
        details[address] = record
    }

    /// One read handed out came back. Answers to reads never handed out, as
    /// tests give, count nothing.
    private mutating func readEnded() {
        readsInFlight = max(0, readsInFlight - 1)
    }

    // MARK: What it knows

    /// The session list is read, and every session's structure is as current
    /// as the events say, with no read of it in flight.
    var isStructureSettled: Bool {
        guard listedSeq != nil, !needsListing else { return false }
        return order.allSatisfy { id in
            guard let record = sessions[id] else { return true }
            return record.hasSettled && !record.reading && !record.needsRead
        }
    }

    /// No terminal's details wait for a read or its answer.
    var isDetailSettled: Bool {
        let shown = Set(shownAddresses())
        return !details.values.contains(where: \.reading)
            && shown.allSatisfy { address in details[address].map { !$0.wanted } ?? false }
    }

    var inventory: RexInventory {
        RexInventory(sessions: order.compactMap { id in sessions[id].flatMap { session(id, $0) } })
    }

    /// Whether nothing has said what holds the terminal at `address`: no
    /// foreground is known, and the read that would name one is due or on its
    /// way. A read that came back naming none leaves it at that.
    private func awaitsForeground(at address: RexPaneAddress) -> Bool {
        guard let record = details[address] else { return carried[address]?.program == nil }
        return record.details.program == nil && (record.wanted || record.reading)
    }

    private func shownAddresses() -> [RexPaneAddress] {
        order.flatMap { id -> [RexPaneAddress] in
            guard let record = sessions[id], let session = session(id, record) else { return [] }
            return session.terminals.map { RexPaneAddress(sessionID: id, blockID: $0.blockID) }
        }
    }

    /// A session as its last answers and later events show it; nil until
    /// anything of its structure was read, and for a session with no terminal.
    private func session(_ id: String, _ record: SessionRecord) -> RexInventory.Session? {
        guard record.view != nil || record.listing != nil else { return nil }
        func terminal(_ facts: RexInventoryWire.BlockFacts) -> RexInventory.Terminal? {
            guard facts.isTerminal, !record.closedBlocks.contains(facts.id) else { return nil }
            let address = RexPaneAddress(sessionID: id, blockID: facts.id)
            var shown = details[address]?.details ?? carried[address] ?? RexTerminalDetails()
            shown.awaitsForeground = awaitsForeground(at: address)
            return RexInventory.Terminal(
                blockID: facts.id, label: facts.customLabel,
                owner: record.owners[facts.id].map(\.owner) ?? facts.owner, details: shown)
        }
        let windows = (record.view?.windows ?? []).map { window in
            RexInventory.Window(id: window.id, label: window.customLabel, terminals: window.blocks.compactMap(terminal))
        }
        let placed = Set((record.view?.windows ?? []).flatMap { $0.blocks.map(\.id) })
        // A block is detached when the listing says so. One the listing places
        // in a window the held view does not show yet is newer than that view,
        // and shows once a view that places it is read: the events that placed
        // it ask for that read. With no view read at all, every listed block
        // shows, detached, rather than none.
        let detached = (record.listing ?? [])
            .filter { ($0.windowID == nil || record.view == nil) && !placed.contains($0.facts.id) }
            .compactMap { terminal($0.facts) }
        let session = RexInventory.Session(
            id: id, label: record.label, activeWindowID: record.view?.activeWindowID, windows: windows,
            detached: detached)
        return session.terminals.isEmpty ? nil : session
    }
}
