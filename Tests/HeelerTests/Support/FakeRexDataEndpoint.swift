import Foundation
import HeelerSSH

@testable import Heeler

/// The tickets a fake Rex server's `data.connect` hands out, shared by the
/// control fake that issues them and the data endpoint that redeems them.
/// Tickets are invented bytes, never a real server's.
final class FakeRexTicketBook: @unchecked Sendable {
    struct Target: Sendable, Equatable {
        let session: String
        let block: String
        /// The control client that asked: each client has its own stream of a block.
        let client: String?
    }

    private struct Issued {
        let bytes: [UInt8]
        let target: Target
        var used = false
    }

    private let lock = NSLock()
    private var issued: [Issued] = []
    private var failures: [FakeRexServer.Answer] = []
    private var payloads: [JSONValue] = []

    /// Answers `data.connect` on `server` from now on, with tickets for
    /// `client`, the one `server` welcomed.
    func install(on server: FakeRexServer, client: String? = FakeRexServer.Welcome().clientID) async {
        await server.answer("data.connect") { [self] request in answer(request, client: client) }
    }

    /// The next `data.connect` calls fail with these, in order.
    func fail(with answers: [FakeRexServer.Answer]) {
        lock.withLock { failures += answers }
    }

    /// Every ticket handed out, as `data.connect` wrote it.
    var ticketTexts: [String] {
        lock.withLock { issued.map { Self.text($0.bytes) } }
    }

    /// The payload of every `data.connect` call.
    var requests: [JSONValue] {
        lock.withLock { payloads }
    }

    /// Who a ticket was for, once; nil for one never issued or already used.
    func redeem(_ bytes: [UInt8]) -> Target? {
        lock.withLock {
            guard let index = issued.firstIndex(where: { $0.bytes == bytes }), !issued[index].used else { return nil }
            issued[index].used = true
            return issued[index].target
        }
    }

    private func answer(_ request: FakeRexServer.Request, client: String?) -> FakeRexServer.Answer {
        lock.withLock {
            payloads.append(request.payload ?? .null)
            if !failures.isEmpty { return failures.removeFirst() }
            guard let session = request.payload?["session_id"]?.stringValue,
                let block = request.payload?["block_id"]?.stringValue
            else { return .error(code: "bad_request", message: "missing target", status: 400) }
            let number = issued.count
            let bytes = (0..<16).map { UInt8(truncatingIfNeeded: 0xA5 ^ (number &* 16 &+ $0 &* 3)) }
            issued.append(Issued(bytes: bytes, target: Target(session: session, block: block, client: client)))
            return .result(["ticket": .string(Self.text(bytes))])
        }
    }

    /// base64url with no padding, as Rex writes a ticket.
    static func text(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A Rex server's data endpoint (`/api/data`), shaped after what Rex
/// 0.1.0-preview.14 (API revision 12) was seen to do: each channel a route
/// opens is a `FakeWebSocketServer` this endpoint serves. It redeems HELLO
/// tickets from a `FakeRexTicketBook`, welcomes with a nonce and a token,
/// refuses as scripted or as Rex would, and checks a RESUME's byte count
/// against what it delivered: fewer is refused with 3, more with 5, and any
/// refused RESUME leaves the stream unusable. A HELLO for a block whose
/// stream for the same client still has a live connection is refused with 2.
/// Tests write the stream's bytes and end its connections. Nothing here is a
/// captured snapshot; nonces and tokens are invented.
actor FakeRexDataEndpoint {
    /// What the next connection gets instead of being served as Rex would.
    enum Script: Sendable {
        case refuseUpgrade(status: Int)
        /// A REJECT with `reason`, then a close frame.
        case refuse(reason: UInt8, close: WebSocketCloseCode = .policyViolation)
        /// Reads the handshake and never answers it.
        case stayQuiet
        /// Ends the connection with no answer before the upgrade, as Rex
        /// ends one that stayed silent too long before upgrading.
        case closeBeforeUpgrade
    }

    /// One handshake as the endpoint read it. Never the credential itself.
    struct Handshake: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case hello
            case resume(count: UInt64)
            case unreadable
        }

        enum Outcome: Sendable, Equatable {
            case welcomed(stream: Int)
            case refused(reason: UInt8)
            case unanswered
        }

        let kind: Kind
        /// The size of the binary message, or 0 for another kind of frame.
        let byteCount: Int
        let outcome: Outcome
    }

    private struct Stream {
        let target: FakeRexTicketBook.Target
        let nonce: UInt64
        var token: [UInt8]
        var tokenGeneration: Int
        /// Stream bytes delivered to connections so far.
        var sent: UInt64 = 0
        var connection: FakeWebSocketServer?
        /// Refused a RESUME, or ended: nothing resumes it.
        var unusable = false
        /// The connection went half-open: it counts as live, and nothing the
        /// client sends on it arrives, until a RESUME replaces it.
        var stranded = false
    }

    static let rejectReason = "data handshake rejected"
    static let retentionMilliseconds: UInt32 = 60_000

    nonisolated let tickets: FakeRexTicketBook
    private var streams: [Stream] = []
    private var scripts: [Script] = []
    private let nonces: [UInt64]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Channels routes opened, in order.
    private(set) var channels: [FakeWebSocketServer] = []
    private(set) var handshakes: [Handshake] = []
    /// Close frames clients sent after a WELCOME, in order.
    private(set) var clientCloses: [WebSocketClose] = []

    init(tickets: FakeRexTicketBook = FakeRexTicketBook(), nonces: [UInt64] = [0x1D2C_3B4A_5968_7786]) {
        self.tickets = tickets
        self.nonces = nonces
    }

    /// A route whose tickets come from `control`, and whose channels this
    /// endpoint serves.
    nonisolated func route(control: RexControlLink) -> RexDataRoute {
        RexDataRoute(control: { control }, openChannel: { await self.connect() })
    }

    /// The next connections get these, in order, before any is served as Rex would.
    func script(_ next: Script...) {
        scripts += next
    }

    func connect() -> any HeelerSSHAPIChannel {
        let channel = FakeWebSocketServer()
        channels.append(channel)
        let script = scripts.isEmpty ? nil : scripts.removeFirst()
        Task { await self.serve(channel, script: script) }
        signalChange()
        return channel
    }

    // MARK: The test's side

    var streamCount: Int { streams.count }

    func waitForStreams(_ count: Int) async {
        while streams.count < count { await waitForChange() }
    }

    func waitForHandshakes(_ count: Int) async {
        while handshakes.count < count { await waitForChange() }
    }

    func waitForClientCloses(_ count: Int) async {
        while clientCloses.count < count { await waitForChange() }
    }

    func nonce(of stream: Int) -> UInt64 {
        streams[stream].nonce
    }

    func sentByteCount(of stream: Int) -> UInt64 {
        streams[stream].sent
    }

    /// Delivers `bytes` on the stream's current connection as binary
    /// messages, cut before each offset in `cuts`.
    func send(_ bytes: Data, on stream: Int = 0, cuts: [Int] = []) async {
        guard let connection = streams[stream].connection else { return }
        var start = 0
        for cut in cuts.sorted() + [bytes.count] where cut > start && cut <= bytes.count {
            await connection.send(binary: bytes.subdata(in: start..<cut))
            start = cut
        }
        streams[stream].sent += UInt64(bytes.count)
    }

    /// Closes the stream's current connection with a close frame.
    func close(stream: Int = 0, code: WebSocketCloseCode, reason: String = "") async {
        guard let connection = streams[stream].connection else { return }
        streams[stream].connection = nil
        if code.rawValue == RexDataEnding.blockClosedCode { streams[stream].unusable = true }
        await connection.sendClose(code, reason: reason)
    }

    /// The stream's current connection goes half-open, as under an SSH
    /// connection that died without either end hearing: the server still
    /// counts it as live, so the same client's HELLO for the block is refused
    /// with 2, and a close frame the client sends on it never arrives (it is
    /// still answered, so the client is not kept waiting). A RESUME of the
    /// stream replaces it, welcomed or refused.
    func strand(stream: Int = 0) {
        streams[stream].stranded = true
    }

    /// Ends the stream's current connection with no close frame.
    func drop(stream: Int = 0) async {
        guard let connection = streams[stream].connection else { return }
        streams[stream].connection = nil
        await connection.deliverEndOfFile()
    }

    // MARK: Serving

    private func serve(_ channel: FakeWebSocketServer, script: Script?) async {
        if case .closeBeforeUpgrade = script {
            await channel.deliverEndOfFile()
            return
        }
        if case .refuseUpgrade(let status) = script {
            _ = await channel.nextUpgradeRequest()
            await channel.deliver(Data("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        await channel.acceptUpgrade()
        guard let frame = await channel.nextFrameUnlessClosed() else { return }
        let bytes = frame.opcode == .binary ? [UInt8](frame.payload) : []
        let kind: Handshake.Kind =
            switch (bytes.first, bytes.count) {
            case (RexDataProtocol.helloType, 17): .hello
            case (RexDataProtocol.resumeType, 25): .resume(count: Self.littleEndian(bytes[17..<25]))
            default: .unreadable
            }
        switch script {
        case .stayQuiet:
            record(Handshake(kind: kind, byteCount: bytes.count, outcome: .unanswered))
            return
        case .refuse(let reason, let close):
            await refuse(channel, kind: kind, byteCount: bytes.count, reason: reason, close: close)
            return
        case .refuseUpgrade, .closeBeforeUpgrade, nil:
            break
        }
        switch kind {
        case .hello:
            await hello(Array(bytes[1...16]), on: channel)
        case .resume(let count):
            await resume(token: Array(bytes[1...16]), count: count, on: channel)
        case .unreadable:
            await refuse(channel, kind: kind, byteCount: bytes.count, reason: 5, close: .protocolError)
        }
    }

    private func hello(_ ticket: [UInt8], on channel: FakeWebSocketServer) async {
        guard let target = tickets.redeem(ticket) else {
            return await refuse(channel, kind: .hello, byteCount: 17, reason: 1)
        }
        for index in streams.indices where streams[index].target == target {
            if streams[index].stranded {
                return await refuse(channel, kind: .hello, byteCount: 17, reason: 2)
            }
            if let connection = streams[index].connection, !(await connection.isClosed) {
                return await refuse(channel, kind: .hello, byteCount: 17, reason: 2)
            }
            // A new stream replaces the block's dropped one.
            streams[index].unusable = true
        }
        let index = streams.count
        let nonce = index < nonces.count ? nonces[index] : nonces[0] &+ UInt64(index)
        let stream = Stream(target: target, nonce: nonce, token: Self.token(index, 0), tokenGeneration: 0)
        // The stream is the test's to write to only once its WELCOME is out.
        await Self.welcome(token: stream.token, nonce: nonce, on: channel)
        streams.append(stream)
        streams[index].connection = channel
        record(Handshake(kind: .hello, byteCount: 17, outcome: .welcomed(stream: index)))
        listen(channel)
    }

    private func resume(token: [UInt8], count: UInt64, on channel: FakeWebSocketServer) async {
        let kind = Handshake.Kind.resume(count: count)
        guard let index = streams.firstIndex(where: { $0.token == token }) else {
            return await refuse(channel, kind: kind, byteCount: 25, reason: 1)
        }
        // A RESUME replaces a half-open connection whatever its answer.
        streams[index].stranded = false
        let sent = streams[index].sent
        var refusal: UInt8?
        if streams[index].unusable || count < sent {
            refusal = 3
        } else if count > sent {
            refusal = 5
        }
        if let refusal {
            streams[index].unusable = true
            return await refuse(channel, kind: kind, byteCount: 25, reason: refusal)
        }
        streams[index].tokenGeneration += 1
        streams[index].token = Self.token(index, streams[index].tokenGeneration)
        await Self.welcome(token: streams[index].token, nonce: streams[index].nonce, on: channel)
        streams[index].connection = channel
        record(Handshake(kind: kind, byteCount: 25, outcome: .welcomed(stream: index)))
        listen(channel)
    }

    private static func welcome(token: [UInt8], nonce: UInt64, on channel: FakeWebSocketServer) async {
        var message: [UInt8] = [RexDataProtocol.welcomeType] + token + [0, 0, 0]
        message += (0..<4).map { UInt8(truncatingIfNeeded: retentionMilliseconds >> ($0 * 8)) }
        message += (0..<8).map { UInt8(truncatingIfNeeded: nonce >> ($0 * 8)) }
        await channel.send(binary: Data(message))
    }

    private func refuse(
        _ channel: FakeWebSocketServer, kind: Handshake.Kind, byteCount: Int, reason: UInt8,
        close: WebSocketCloseCode = .policyViolation
    ) async {
        await channel.send(binary: Data([RexDataProtocol.rejectType, reason]))
        await channel.sendClose(close, reason: Self.rejectReason)
        record(Handshake(kind: kind, byteCount: byteCount, outcome: .refused(reason: reason)))
    }

    /// Reads what the client sends after a WELCOME, and answers its close
    /// frame as a server does.
    private func listen(_ channel: FakeWebSocketServer) {
        Task {
            while let frame = await channel.nextFrameUnlessClosed() {
                guard frame.opcode == .close else { continue }
                let close = (try? WebSocketClose(payload: frame.payload)) ?? WebSocketClose(code: .noStatusReceived)
                self.clientClosed(close, on: channel)
                await channel.sendClose(close.code.mayBeSent ? close.code : nil)
                return
            }
        }
    }

    private func clientClosed(_ close: WebSocketClose, on channel: FakeWebSocketServer) {
        let index = streams.firstIndex(where: { $0.connection === channel })
        if let index, streams[index].stranded { return }
        clientCloses.append(close)
        guard let index else { return }
        streams[index].connection = nil
        if close.code == .normalClosure { streams[index].unusable = true }
        signalChange()
    }

    private func record(_ handshake: Handshake) {
        handshakes.append(handshake)
        signalChange()
    }

    private static func token(_ stream: Int, _ generation: Int) -> [UInt8] {
        (0..<16).map { UInt8(truncatingIfNeeded: 0x3C &+ stream &* 40 &+ generation &* 7 &+ $0) }
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func waitForChange() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func signalChange() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

/// Hand-built pieces of a terminal stream (`rex.data.terminal.v1`).
enum FakeRexStream {
    /// A stand-in for the snapshot that opens a stream: `GHOSTSNP` and
    /// filler, never a real one. With `decoys`, the filler holds sequences
    /// that look like the stream's own messages but are not: another nonce,
    /// this nonce with a digit more, and cut-off prefixes.
    static func snapshot(byteCount: Int = 512, decoys nonce: UInt64? = nil) -> Data {
        var bytes = Data("GHOSTSNP".utf8)
        if let nonce {
            bytes += message(#"{"type":"resize","cols":1,"rows":1}"#, nonce: nonce &+ 1)
            bytes += Data([0x1B]) + Data("_rex1;\(nonce)0;".utf8)
            bytes += Data([0x1B, 0x1B, 0x5F]) + Data("rex1;".utf8)
            bytes += Data([0x1B]) + Data("_rex1;\(String(nonce).dropLast());".utf8)
            bytes += Data([0x1B, 0x5C, 0x00, 0x1B])
        }
        var seed: UInt32 = 0x2468_ACE1
        while bytes.count < byteCount {
            seed = seed &* 1_103_515_245 &+ 12345
            // No ESC in the filler, so only the decoys above look like messages.
            let byte = UInt8(truncatingIfNeeded: seed >> 16)
            bytes.append(byte == 0x1B ? 0x1C : byte)
        }
        return bytes
    }

    /// One of the stream's own messages: `ESC _ rex1;<nonce>;<json> ESC \`.
    static func message(_ json: String, nonce: UInt64) -> Data {
        Data([0x1B]) + Data("_rex1;\(nonce);".utf8) + Data(json.utf8) + Data([0x1B, 0x5C])
    }

    static func resize(columns: Int, rows: Int, nonce: UInt64, owner: String? = "client:fake-owner") -> Data {
        let ownerJSON = owner.map { #""\#($0)""# } ?? "null"
        return message(
            #"{"type":"resize","cols":\#(columns),"rows":\#(rows),"cell_width_px":9,"cell_height_px":18,"owner":\#(ownerJSON)}"#,
            nonce: nonce)
    }

    static func theme(nonce: UInt64) -> Data {
        message(
            ##"{"type":"theme","foreground":"#d0d0d0","background":"#101010","cursor":null,"palette":["1=aa2020"],"scheme":"dark"}"##,
            nonce: nonce)
    }

    static func childExited(code: Int, nonce: UInt64) -> Data {
        message(#"{"type":"child_exited","exit_code":\#(code)}"#, nonce: nonce)
    }
}

/// Answers a terminal block's reads on a `FakeRexServer` as Rex
/// 0.1.0-preview.14 (API revision 12) shaped them: `modes`, `title`, and the
/// `vt` redraw from `format`, paged through `blob_read` past `max_bytes`.
/// The redraw is whatever the test sets, not a real one.
final class FakeRexTerminalReads: @unchecked Sendable {
    static let blobID = 1

    private let lock = NSLock()
    private var redraw: Data
    private var title: String
    private var wraparound: Bool
    private var calls: [String] = []

    init(redraw: String, title: String = "shell", wraparound: Bool = true) {
        self.redraw = Data(redraw.utf8)
        self.title = title
        self.wraparound = wraparound
    }

    /// The short names of the reads made, in order.
    var methods: [String] {
        lock.withLock { calls }
    }

    func set(redraw: String) {
        lock.withLock { self.redraw = Data(redraw.utf8) }
    }

    func install(on server: FakeRexServer) async {
        for name in ["modes", "format", "blob_read", "title"] {
            await server.answer(RexInventoryWire.terminalMethod(name)) { [self] request in answer(name, request) }
        }
    }

    private func answer(_ name: String, _ request: FakeRexServer.Request) -> FakeRexServer.Answer {
        lock.withLock {
            calls.append(name)
            let args = request.payload?["args"]
            switch name {
            case "modes":
                return .result([
                    "screen": "primary",
                    "modes": [["name": "wraparound", "number": 7, "ansi": false, "set": .bool(wraparound)]],
                ])
            case "title":
                return .result(["title": .string(title)])
            case "format":
                let limit = Self.integer(args?["max_bytes"]) ?? .max
                let end = min(redraw.count, limit)
                var result: [String: JSONValue] = [
                    "content": .string(String(decoding: redraw.prefix(end), as: UTF8.self)),
                    "total": .number(Double(redraw.count)),
                ]
                if end < redraw.count {
                    result["id"] = .number(Double(Self.blobID))
                } else {
                    result["eof"] = true
                }
                return .result(.object(result))
            case "blob_read":
                let offset = Self.integer(args?["offset"]) ?? 0
                let limit = Self.integer(args?["max_bytes"]) ?? .max
                let start = min(offset, redraw.count)
                let end = start + min(redraw.count - start, limit)
                return .result([
                    "id": .number(Double(Self.blobID)),
                    "data": .string(String(decoding: redraw[start..<end], as: UTF8.self)),
                    "total": .number(Double(redraw.count)), "eof": .bool(end == redraw.count),
                ])
            default:
                return .error(code: "method_not_found", message: name, status: 404)
            }
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value else { return nil }
        return Int(number)
    }
}
