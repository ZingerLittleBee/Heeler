import Foundation

/// Follows a Rex server's inventory on one control link (ADR 0050): attaches
/// to every session, reads what `RexInventoryBook` asks for with a few reads
/// in flight at most, applies the link's events, and publishes the inventory
/// once every session's structure has settled, and again as it changes. A
/// burst of changes publishes once it settles; a change to a terminal's
/// details alone publishes once no details read is left, except a change to
/// its Program Status, which publishes as soon as it is read or reported
/// (ADR 0054). A session with
/// detached terminals is read again on an interval, since no event says when
/// one of their labels changes.
///
/// Each read waits as long as the link keeps receiving, within a limit, since
/// its answer may queue behind a terminal redraw's pages on the same link.
/// It follows until the link ends, a read stalls past its deadline, or the
/// server refuses to attach. It never ends the link: whoever opened the link
/// decides between resuming its client and starting afresh.
actor RexInventoryFollower {
    enum Ending: Sendable, Equatable {
        case linkEnded(RexControlEnding)
        /// A read outlasted its deadline. The link is still open, and in doubt.
        case stalled
        /// The server refused to attach, or answered in a way Heeler cannot read.
        case refused(TransportError)
        case cancelled
    }

    /// Which events to attach for: every session's structure and its blocks'
    /// own events, so titles, programs, directories and Program Statuses stay
    /// current. Session events alone carry none of a block's (ADR 0054).
    static let eventScope = "all"

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let link: RexControlLink
    private let maxReadsInFlight: Int
    private let readDeadline: RexDeliveryDeadline
    private let firstReadRetryDelay: Duration
    private let detachedRereadInterval: Duration?
    private let sleep: Sleep
    private let publish: @Sendable (RexInventory) -> Void
    private let observe: @Sendable (RexControlUpdate) -> Void
    private var book: RexInventoryBook
    private var listing: Task<Void, Never>?
    private var reads: [UInt64: Task<Void, Never>] = [:]
    private var nextRead: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var rereadTask: Task<Void, Never>?
    private var retries: [String: Task<Void, Never>] = [:]
    private var published: RexInventory?
    private var ending: Ending?
    private var waiter: CheckedContinuation<Ending, Never>?

    /// Whether an inventory was published on this link.
    var hasPublished: Bool { published != nil }

    /// `carrying` is what the last link knew of each terminal, shown until
    /// this one reads it again. `detachedRereadInterval` is how often sessions
    /// with detached terminals are read again; nil never. `readDeadline` is
    /// how long each read waits for its answer. `firstReadRetryDelay` is how
    /// long a session whose first structure read failed waits before it is
    /// read again (`RexInventoryBook.structureRead`). `observe` hears each
    /// update from the link as it arrives, for whatever else follows a block's
    /// events, and before the inventory applies it. `publish` hears each
    /// inventory in order.
    init(
        link: RexControlLink, carrying: [RexPaneAddress: RexTerminalDetails] = [:], maxReadsInFlight: Int = 4,
        readDeadline: RexDeliveryDeadline = .sharedLinkRead, firstReadRetryDelay: Duration = .seconds(2),
        detachedRereadInterval: Duration? = .seconds(60), sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        observe: @escaping @Sendable (RexControlUpdate) -> Void = { _ in },
        publish: @escaping @Sendable (RexInventory) -> Void
    ) {
        self.link = link
        self.maxReadsInFlight = max(1, maxReadsInFlight)
        self.readDeadline = readDeadline
        self.firstReadRetryDelay = firstReadRetryDelay
        self.detachedRereadInterval = detachedRereadInterval
        self.sleep = sleep
        self.observe = observe
        self.publish = publish
        book = RexInventoryBook(carrying: carrying)
    }

    /// Follows until the link ends or the follow cannot go on, and says why.
    func run() async -> Ending {
        let events = link.events
        eventTask = Task { [weak self] in
            do {
                for try await update in events {
                    await self?.receive(update)
                }
                await self?.finish(.linkEnded(.closedHere))
            } catch RexControlError.linkEnded(let reason) {
                await self?.finish(.linkEnded(reason))
            } catch {
                await self?.finish(.linkEnded(.linkLost))
            }
        }
        startListing()
        if let interval = detachedRereadInterval {
            rereadTask = Task { [weak self, sleep] in
                while !Task.isCancelled {
                    do { try await sleep(interval) } catch { return }
                    await self?.rereadDetached()
                }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let ending {
                    continuation.resume(returning: ending)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.finish(.cancelled) }
        }
    }

    private func finish(_ reason: Ending) {
        guard ending == nil else { return }
        ending = reason
        eventTask?.cancel()
        rereadTask?.cancel()
        listing?.cancel()
        for read in reads.values { read.cancel() }
        reads = [:]
        for retry in retries.values { retry.cancel() }
        retries = [:]
        waiter?.resume(returning: reason)
        waiter = nil
    }

    // MARK: Events

    private func receive(_ update: RexControlUpdate) {
        guard ending == nil else { return }
        observe(update)
        switch update {
        case .event(let event):
            book.apply(event)
        case .sequenceBroken:
            book.sequenceBroke()
        }
        advance()
    }

    private func rereadDetached() {
        guard ending == nil else { return }
        book.rereadDetached()
        advance()
    }

    // MARK: Reads

    private func startListing() {
        guard ending == nil, listing == nil else { return }
        book.beginListing()
        listing = Task { await self.list() }
    }

    private func list() async {
        do {
            let response = try await link.call(
                "session.attach_all", payload: AttachAll(eventScope: Self.eventScope), waiting: readDeadline)
            guard let entries = RexInventoryWire.sessions(try response.result(JSONValue.self)) else {
                finish(.refused(.rexAnswerUnreadable(String(localized: "Rex's session list could not be read."))))
                return
            }
            listing = nil
            book.listed(entries, seq: response.seq)
            advance()
        } catch {
            listing = nil
            switch error {
            case RexControlError.server(let failure):
                finish(.refused(TransportError(rexControl: .server(failure))))
            case RexControlError.unreadableResult(let method):
                finish(.refused(TransportError(rexControl: .unreadableResult(method: method))))
            default:
                stop(after: error)
            }
        }
    }

    /// Lists again when the book needs it, sends what it asks for, and
    /// publishes what settled.
    private func advance() {
        guard ending == nil else { return }
        if book.needsListing, listing == nil {
            startListing()
            return
        }
        for read in book.takeReads(limit: maxReadsInFlight) {
            nextRead &+= 1
            let id = nextRead
            reads[id] = Task { await self.perform(read, id: id) }
        }
        publishIfSettled()
    }

    private func perform(_ read: RexInventoryBook.Read, id: UInt64) async {
        defer { reads[id] = nil }
        do {
            switch read {
            case .structure(let sessionID):
                try await readStructure(of: sessionID)
            case .details(let address):
                try await readDetails(of: address)
            }
        } catch {
            stop(after: error)
            return
        }
        advance()
    }

    /// A half the server refuses or Heeler cannot read comes back with no
    /// value; one that says the session is gone ends the read there.
    private func readStructure(of sessionID: String) async throws {
        let view = try await readHalf("session.view", of: sessionID, reading: RexInventoryWire.view)
        let listing =
            view == nil ? nil : try await readHalf("session.list_blocks", of: sessionID, reading: RexInventoryWire.blocks)
        guard ending == nil else { return }
        guard let view, let listing else {
            book.sessionGone(sessionID)
            return
        }
        if book.structureRead(sessionID, view: view, listing: listing) { retryLater(sessionID) }
    }

    /// Nil when the server says the session is gone.
    private func readHalf<Value>(
        _ method: String, of sessionID: String, reading: (JSONValue) -> Value?
    ) async throws -> RexInventoryBook.Answer<Value?>? {
        do {
            let response = try await link.call(method, payload: SessionTarget(sessionID: sessionID), waiting: readDeadline)
            return .init(value: (try? response.result(JSONValue.self)).flatMap(reading), seq: response.seq)
        } catch RexControlError.server(let failure) {
            return failure.saysSessionIsGone ? nil : .init(value: nil, seq: 0)
        }
    }

    private func retryLater(_ sessionID: String) {
        retries[sessionID]?.cancel()
        retries[sessionID] = Task { [weak self, sleep, delay = firstReadRetryDelay] in
            do { try await sleep(delay) } catch { return }
            await self?.retry(sessionID)
        }
    }

    private func retry(_ sessionID: String) {
        retries[sessionID] = nil
        guard ending == nil else { return }
        book.retryRead(sessionID)
        advance()
    }

    /// Each part that the server refuses or Heeler cannot read is left as it
    /// was: a later event says it again.
    private func readDetails(of address: RexPaneAddress) async throws {
        let target = BlockTarget(sessionID: address.sessionID, blockID: address.blockID)
        var title: RexInventoryBook.Answer<String?>?
        var process: RexInventoryBook.Answer<RexInventoryWire.Process>?
        var status: RexInventoryBook.Answer<RexProgramStatus?>?
        do {
            let response = try await link.call(
                RexInventoryWire.terminalMethod("title"), payload: target, waiting: readDeadline)
            if let value = try? response.result(JSONValue.self) {
                title = .init(value: RexInventoryWire.title(value), seq: response.seq)
            }
        } catch RexControlError.server {}
        do {
            let response = try await link.call(
                RexInventoryWire.terminalMethod("process"), payload: target, waiting: readDeadline)
            if let value = try? response.result(JSONValue.self) {
                process = .init(value: RexInventoryWire.process(value), seq: response.seq)
            }
        } catch RexControlError.server {}
        do {
            let response = try await link.call(
                RexInventoryWire.terminalMethod("program_status"), payload: target, waiting: readDeadline)
            if let value = try? response.result(JSONValue.self) {
                status = .init(value: RexInventoryWire.rootStatus(value), seq: response.seq)
            }
        } catch RexControlError.server {}
        guard ending == nil else { return }
        book.detailsRead(address, title: title, process: process, status: status)
    }

    /// A read that failed for the link's sake ends the follow.
    private func stop(after error: any Error) {
        switch error {
        case RexControlError.linkEnded(let reason):
            finish(.linkEnded(reason))
        case RexControlError.deadlineExceeded:
            finish(.stalled)
        case is CancellationError:
            finish(.cancelled)
        default:
            finish(.refused(TransportError(rexFollowing: error)))
        }
    }

    // MARK: Publishing

    private func publishIfSettled() {
        guard ending == nil, book.isStructureSettled else { return }
        let inventory = book.inventory
        guard inventory != published else { return }
        let structureChanged = published.map { $0.withoutDetails != inventory.withoutDetails } ?? true
        // A status does not wait for the other terminals' reads: on a new
        // link each Agent reads Unknown only until its own read answers.
        let statusChanged = published.map { $0.programStatuses != inventory.programStatuses } ?? true
        guard structureChanged || statusChanged || book.isDetailSettled else { return }
        published = inventory
        publish(inventory)
    }

    // MARK: Payloads

    private struct AttachAll: Encodable, Sendable {
        let eventScope: String

        enum CodingKeys: String, CodingKey {
            case eventScope = "event_scope"
        }
    }

    private struct SessionTarget: Encodable, Sendable {
        let sessionID: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
    }

    private struct BlockTarget: Encodable, Sendable {
        let sessionID: String
        let blockID: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case blockID = "block_id"
        }
    }
}

extension RexServerError {
    /// The session asked about is gone.
    var saysSessionIsGone: Bool {
        code == "session_not_found" || (kind == .notFound && code != "method_not_found")
    }
}

extension TransportError {
    /// Any other failure while following, as the user reads it.
    fileprivate init(rexFollowing error: any Error) {
        switch error {
        case let error as RexControlError: self = TransportError(rexControl: error)
        case let error as TransportError: self = error
        default: self = .channelFailed(detail: String(describing: error))
        }
    }
}
