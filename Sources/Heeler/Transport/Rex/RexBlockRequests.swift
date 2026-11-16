import Foundation
import Synchronization

/// The order input to one Rex block leaves this side in (ADR 0052): Rex may
/// apply requests out of order while several are out, so an open terminal
/// view's input and Chat's take turns at each block, first come first
/// served, and whoever holds a block's lane has the only input request to it
/// in flight.
final class RexBlockLanes: Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var held: Set<RexPaneAddress> = []
        var waiters: [RexPaneAddress: [Waiter]] = [:]
    }

    private let state = Mutex(State())

    /// Returns once the caller holds `address`'s lane, which it then leaves
    /// with `leave`. Throws `CancellationError`, holding nothing, when the
    /// caller is cancelled first.
    func enter(_ address: RexPaneAddress) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let entered = state.withLock { state -> Bool? in
                    // Checked under the lock the cancellation handler takes,
                    // so a cancellation never misses the waiter.
                    if Task.isCancelled { return nil }
                    guard state.held.contains(address) else {
                        state.held.insert(address)
                        return true
                    }
                    state.waiters[address, default: []].append(Waiter(id: id, continuation: continuation))
                    return false
                }
                switch entered {
                case true?: continuation.resume()
                case nil: continuation.resume(throwing: CancellationError())
                case false?: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard var waiting = state.waiters[address], let index = waiting.firstIndex(where: { $0.id == id })
                else { return nil }
                let waiter = waiting.remove(at: index)
                state.waiters[address] = waiting.isEmpty ? nil : waiting
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands the lane to the next caller waiting for it, if any.
    func leave(_ address: RexPaneAddress) {
        let next = state.withLock { state -> Waiter? in
            guard var waiting = state.waiters[address], !waiting.isEmpty else {
                state.held.remove(address)
                return nil
            }
            let next = waiting.removeFirst()
            state.waiters[address] = waiting.isEmpty ? nil : waiting
            return next
        }
        next?.continuation.resume()
    }

    /// Callers waiting for `address`'s lane, which tests wait on.
    func waiting(at address: RexPaneAddress) -> Int {
        state.withLock { $0.waiters[address]?.count ?? 0 }
    }
}

/// What Chat may ask of one Rex block on the Host's control link (ADR 0055):
/// reads of its foreground process, modes, size and text, and input through
/// the block's lane, shared with an open terminal view's input.
///
/// It is pinned to the server instance, the SSH connection and the control
/// client it was made on, as an open terminal's own requests are: once
/// another answers, a read throws and input is not sent. It opens no data
/// link, never asks for a size, never attaches to a session and never takes
/// or gives back a block: the requests it can make are the ones below. Input
/// goes one request at a time, each waiting for its answer, and a request
/// that left is never sent again.
struct RexBlockRequests: Sendable {
    /// A read of the block. Nothing else is read through here.
    enum Read: Sendable, Equatable {
        /// The foreground process, as the inventory reads it.
        case process
        /// Its terminal modes and which screen shows.
        case modes
        /// Its grid.
        case size
        /// Its text as `vt` with soft wraps kept as rows: the first
        /// `maxBytes`, and the id and length of the whole when it is longer.
        /// No extras, unless `kittyKeyboard` asks for the kitty keyboard flags
        /// at its end.
        case format(maxBytes: Int, kittyKeyboard: Bool = false)
        /// `maxBytes` of a longer text from `offset`, in bytes.
        case blobRead(id: Int, offset: Int, maxBytes: Int)

        var name: String {
            switch self {
            case .process: "process"
            case .modes: "modes"
            case .size: "size"
            case .format: "format"
            case .blobRead: "blob_read"
            }
        }
    }

    /// What became of input.
    enum Sending: Sendable, Equatable {
        /// Every request was answered.
        case sent
        /// The block got none of it: nothing left this side, or the server
        /// refused the first request, with its reason.
        case notSent(RexServerError?)
        /// Some of it may have arrived: a request had no answer, or one after
        /// the first was refused or could not leave. Nothing after it went.
        case unknown
    }

    let address: RexPaneAddress
    /// The server the requests keep to.
    let server: RexServerStatus
    /// The largest request the control link accepts, in bytes.
    let maxMessageBytes: Int
    fileprivate let lanes: RexBlockLanes
    fileprivate let ask: @Sendable (_ method: String, _ payload: JSONValue) async throws -> JSONValue
    fileprivate let deliver: @Sendable (_ method: String, _ payload: JSONValue) async -> RexDelivery

    init(
        address: RexPaneAddress, server: RexServerStatus, maxMessageBytes: Int, lanes: RexBlockLanes,
        ask: @escaping @Sendable (_ method: String, _ payload: JSONValue) async throws -> JSONValue,
        deliver: @escaping @Sendable (_ method: String, _ payload: JSONValue) async -> RexDelivery
    ) {
        self.address = address
        self.server = server
        self.maxMessageBytes = maxMessageBytes
        self.lanes = lanes
        self.ask = ask
        self.deliver = deliver
    }

    /// The result of `read`. Throws `RexControlError` (`.server` for the
    /// server's refusal, such as a block that closed), `TransportError` once
    /// the connection it was made on is gone, or `CancellationError`.
    func read(_ read: Read) async throws -> JSONValue {
        var payload: [String: JSONValue] = [
            "session_id": .string(address.sessionID), "block_id": .string(address.blockID),
        ]
        switch read {
        case .process, .modes, .size:
            break
        case .format(let maxBytes, let kittyKeyboard):
            var args: [String: JSONValue] = [
                "format": .string("vt"), "unwrap": .bool(false), "max_bytes": .number(Double(maxBytes)),
            ]
            if kittyKeyboard { args["extra_kitty_keyboard"] = .bool(true) }
            payload["args"] = .object(args)
        case .blobRead(let id, let offset, let maxBytes):
            payload["args"] = .object([
                "id": .number(Double(id)), "offset": .number(Double(offset)), "max_bytes": .number(Double(maxBytes)),
            ])
        }
        return try await ask(RexInventoryWire.terminalMethod(read.name), .object(payload))
    }

    /// Sends `pieces` to the block in its lane, one request at a time, each
    /// once. Text goes to the terminal's `write`, a paste as `block.event`
    /// for the server to frame as the program's modes say; no other event
    /// goes. `confirm` runs first, holding the lane, so nothing of the
    /// block's other input comes between it and the first request: what it
    /// throws is thrown, and nothing is sent.
    func send(
        _ pieces: [RexTerminalInputPiece], confirming confirm: @Sendable () async throws -> Void = {}
    ) async throws -> Sending {
        guard pieces.allSatisfy(Self.isInput) else { return .notSent(nil) }
        do {
            try await lanes.enter(address)
        } catch {
            return .notSent(nil)
        }
        defer { lanes.leave(address) }
        try await confirm()
        var answered = 0
        for piece in pieces {
            let request = RexTerminalAttach.request(for: piece, at: address)
            switch await deliver(request.method, request.payload) {
            case .answered:
                answered += 1
            case .refused(let failure):
                return answered == 0 ? .notSent(failure) : .unknown
            case .notSent:
                return answered == 0 ? .notSent(nil) : .unknown
            case .unknown:
                return .unknown
            }
        }
        return .sent
    }

    /// The most JSON one text write may carry, as an open terminal's.
    var textBudget: Int {
        maxMessageBytes - 1024 - 6 * (address.sessionID.utf8.count + address.blockID.utf8.count)
    }

    /// Whether `text` fits one paste request under the control link's
    /// limit: a paste is never cut, and a request past the limit would
    /// close the whole link.
    func fitsOnePaste(_ text: String) -> Bool {
        let request = RexTerminalAttach.request(for: .paste(text), at: address)
        let probe = JSONValue.object([
            "type": .string("request"), "id": .string("h\(UInt64.max)"), "method": .string(request.method),
            "payload": request.payload,
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let bytes = try? encoder.encode(probe).count else { return false }
        return bytes <= maxMessageBytes
    }

    private static func isInput(_ piece: RexTerminalInputPiece) -> Bool {
        switch piece {
        case .text, .paste: true
        case .event: false
        }
    }
}
