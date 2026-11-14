import Foundation

/// Follows a Rex server's inventory on one control link (ADR 0048): attaches
/// to every session, reads what `RexInventoryBook` asks for with a few reads
/// in flight at most, applies the link's events, and publishes the inventory
/// once every session's structure has settled, and again as it changes. A
/// burst of changes publishes once it settles; a change to a terminal's
/// details alone publishes once no details read is left.
///
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
    /// own events, so titles, programs and directories stay current.
    static let eventScope = "all"

    private let link: RexControlLink
    private let maxReadsInFlight: Int
    private let publish: @Sendable (RexInventory) -> Void
    private var book: RexInventoryBook
    private var listing: Task<Void, Never>?
    private var reads: [UInt64: Task<Void, Never>] = [:]
    private var nextRead: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var published: RexInventory?
    private var ending: Ending?
    private var waiter: CheckedContinuation<Ending, Never>?

    /// Whether an inventory was published on this link.
    var hasPublished: Bool { published != nil }

    /// `carrying` is what the last link knew of each terminal, shown until
    /// this one reads it again. `publish` hears each inventory in order.
    init(
        link: RexControlLink, carrying: [RexPaneAddress: RexTerminalDetails] = [:], maxReadsInFlight: Int = 4,
        publish: @escaping @Sendable (RexInventory) -> Void
    ) {
        self.link = link
        self.maxReadsInFlight = max(1, maxReadsInFlight)
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
        listing?.cancel()
        for read in reads.values { read.cancel() }
        reads = [:]
        waiter?.resume(returning: reason)
        waiter = nil
    }

    // MARK: Events

    private func receive(_ update: RexControlUpdate) {
        guard ending == nil else { return }
        switch update {
        case .event(let event):
            book.apply(event)
        case .sequenceBroken:
            book.sequenceBroke()
        }
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
            let response = try await link.call("session.attach_all", payload: AttachAll(eventScope: Self.eventScope))
            guard let entries = RexInventoryWire.sessions(try response.result(JSONValue.self)) else {
                finish(.refused(.malformedResponse(String(localized: "Rex's session list could not be read."))))
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

    private func readStructure(of sessionID: String) async throws {
        let target = SessionTarget(sessionID: sessionID)
        let view: RexInventoryBook.Answer<RexInventoryWire.View?>
        let listing: RexInventoryBook.Answer<[RexInventoryWire.ListedBlock]?>
        do {
            let viewResponse = try await link.call("session.view", payload: target)
            view = .init(value: try? RexInventoryWire.view(viewResponse.result(JSONValue.self)), seq: viewResponse.seq)
            let listResponse = try await link.call("session.list_blocks", payload: target)
            listing = .init(
                value: try? RexInventoryWire.blocks(listResponse.result(JSONValue.self)), seq: listResponse.seq)
        } catch RexControlError.server(let failure) {
            guard ending == nil else { return }
            if failure.saysSessionIsGone {
                book.sessionGone(sessionID)
            } else {
                book.structureReadFailed(sessionID)
            }
            return
        }
        guard ending == nil else { return }
        book.structureRead(sessionID, view: view, listing: listing)
    }

    /// Each half that the server refuses or Heeler cannot read is left as it
    /// was: a later event says it again.
    private func readDetails(of address: RexPaneAddress) async throws {
        let target = BlockTarget(sessionID: address.sessionID, blockID: address.blockID)
        var title: RexInventoryBook.Answer<String?>?
        var process: RexInventoryBook.Answer<RexInventoryWire.Process>?
        do {
            let response = try await link.call(RexInventoryWire.terminalMethod("title"), payload: target)
            if let value = try? response.result(JSONValue.self) {
                title = .init(value: RexInventoryWire.title(value), seq: response.seq)
            }
        } catch RexControlError.server {}
        do {
            let response = try await link.call(RexInventoryWire.terminalMethod("process"), payload: target)
            if let value = try? response.result(JSONValue.self) {
                process = .init(value: RexInventoryWire.process(value), seq: response.seq)
            }
        } catch RexControlError.server {}
        guard ending == nil else { return }
        book.detailsRead(address, title: title, process: process)
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
        guard structureChanged || book.isDetailSettled else { return }
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
