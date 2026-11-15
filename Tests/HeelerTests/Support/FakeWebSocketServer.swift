import Foundation
import HeelerSSH

@testable import Heeler

/// A WebSocket server at the far end of the in-memory duplex channel a
/// `WebSocketLink` reads and writes. Tests answer the upgrade, send unmasked
/// frames, and read back each frame the client wrote, unmasked, with the key
/// it was masked with. Time never passes on its own.
actor FakeWebSocketServer: HeelerSSHAPIChannel {
    struct UpgradeRequest: Sendable {
        let requestLine: String
        /// Values by lowercased field name.
        let fields: [String: [String]]

        func field(_ name: String) -> String? {
            fields[name.lowercased()]?.first
        }
    }

    private enum Inbound {
        case bytes(Data)
        case endOfFile
        case readTimeout
    }

    private var inbound: [Inbound] = []
    private var reader: CheckedContinuation<Data?, any Error>?
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []

    private var requestBytes = Data()
    private(set) var upgradeRequest: UpgradeRequest?
    private var decoder = WebSocketFrameDecoder(role: .server)
    private var frameCursor = 0

    /// Every frame the client wrote, in order.
    private(set) var frames: [WebSocketFrame] = []
    /// Set when the client wrote something that is not a frame a client may send.
    private(set) var clientViolation: WebSocketViolation?
    private(set) var isClosed = false
    /// Calls to `read`, to tell a reader that stopped from one still reading.
    private(set) var readCount = 0
    /// Calls to `write`, including ones that failed.
    private(set) var writeCount = 0
    private var writeFailure: (any Error)?
    private var writesHeld = false

    // MARK: HeelerSSHAPIChannel

    /// Yields mid-write, as a real channel does between packets. A failing
    /// write lets the first half through, as a partial write would.
    func write(_ data: Data, timeout: Duration) async throws {
        writeCount += 1
        signalChange()
        while writesHeld, !isClosed { await waitForChange() }
        guard !isClosed else { throw SSHError.cancelled }
        let middle = data.startIndex + data.count / 2
        record(data.subdata(in: data.startIndex..<middle))
        if let writeFailure {
            self.writeFailure = nil
            throw writeFailure
        }
        await Task.yield()
        guard !isClosed else { throw SSHError.cancelled }
        record(data.subdata(in: middle..<data.endIndex))
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        readCount += 1
        signalChange()
        if let next = try takeInbound(maximumBytes: maximumBytes) { return next }
        guard !isClosed else { throw SSHError.cancelled }
        let chunk: Data? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader = continuation
            }
        } onCancel: {
            Task { await self.failRead(SSHError.cancelled) }
        }
        guard let chunk, chunk.count > maximumBytes else { return chunk }
        inbound.insert(.bytes(chunk.subdata(in: maximumBytes..<chunk.count)), at: 0)
        return chunk.subdata(in: 0..<maximumBytes)
    }

    func close(timeout: Duration) async throws {
        isClosed = true
        failRead(SSHError.cancelled)
        signalChange()
    }

    // MARK: The server's side

    func nextUpgradeRequest() async -> UpgradeRequest {
        while true {
            if let upgradeRequest { return upgradeRequest }
            await waitForChange()
        }
    }

    /// Answers the upgrade with 101, the right accept value and `subprotocol`
    /// (the requested one by default), plus `extraFields`. `trailing` follows
    /// the header in the same read.
    func acceptUpgrade(subprotocol: String? = nil, extraFields: [String] = [], trailing: Data = Data()) async {
        let request = await nextUpgradeRequest()
        let key = request.field("Sec-WebSocket-Key") ?? ""
        let chosen = subprotocol ?? request.field("Sec-WebSocket-Protocol") ?? ""
        let lines =
            [
                "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
                "Sec-WebSocket-Accept: \(WebSocketHandshake.acceptValue(forKey: key))",
                "Sec-WebSocket-Protocol: \(chosen)",
            ] + extraFields
        deliver(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + trailing)
    }

    func deliver(_ bytes: Data) {
        push(.bytes(bytes))
    }

    /// Sends a frame as a server does, unmasked.
    func send(_ frame: WebSocketFrame) {
        deliver(frame.encoded(maskKey: nil))
    }

    func send(text: String) {
        send(WebSocketFrame(opcode: .text, payload: Data(text.utf8)))
    }

    func send(binary: Data) {
        send(WebSocketFrame(opcode: .binary, payload: binary))
    }

    func sendClose(_ code: WebSocketCloseCode?, reason: String = "") {
        send(WebSocketFrame.close(code, reason: reason))
    }

    func deliverEndOfFile() {
        push(.endOfFile)
    }

    /// The real channel's read poll: `SSHError.timedOut` with nothing arrived.
    func deliverReadTimeout() {
        push(.readTimeout)
    }

    /// Bytes delivered that the client has not read yet.
    var unreadByteCount: Int {
        inbound.reduce(0) { total, item in
            if case .bytes(let bytes) = item { return total + bytes.count }
            return total
        }
    }

    /// The next write fails with `error` after half its bytes went out.
    func failNextWrite(with error: any Error = SSHError.channelFailed) {
        writeFailure = error
    }

    /// While held, a write that has begun does not reach the wire.
    func holdWrites() {
        writesHeld = true
    }

    func releaseWrites() {
        writesHeld = false
        signalChange()
    }

    // MARK: What the client wrote

    /// The next frame the client wrote, in order.
    func nextFrame() async -> WebSocketFrame {
        while frameCursor >= frames.count { await waitForChange() }
        frameCursor += 1
        return frames[frameCursor - 1]
    }

    /// The next frame the client wrote, or nil once the channel closed with
    /// every frame read.
    func nextFrameUnlessClosed() async -> WebSocketFrame? {
        while frameCursor >= frames.count {
            if isClosed { return nil }
            await waitForChange()
        }
        frameCursor += 1
        return frames[frameCursor - 1]
    }

    func waitForWrites(_ count: Int) async {
        while writeCount < count { await waitForChange() }
    }

    func waitUntilClosed() async {
        while !isClosed { await waitForChange() }
    }

    /// Returns once the client's reader is waiting for bytes with nothing unread.
    func waitForPendingRead() async {
        while reader == nil { await waitForChange() }
    }

    // MARK: Internals

    private func record(_ bytes: Data) {
        if upgradeRequest == nil {
            requestBytes.append(bytes)
            guard let end = requestBytes.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(decoding: requestBytes[requestBytes.startIndex..<end.lowerBound], as: UTF8.self)
            var lines = header.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst()
            var fields: [String: [String]] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].lowercased(), default: []].append(
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            upgradeRequest = UpgradeRequest(requestLine: requestLine, fields: fields)
            decoder.append(Data(requestBytes[end.upperBound...]))
        } else {
            decoder.append(bytes)
        }
        do throws(WebSocketViolation) {
            while clientViolation == nil, let frame = try decoder.next(payloadLimit: .max) {
                frames.append(frame)
            }
        } catch {
            clientViolation = error
        }
        signalChange()
    }

    private func push(_ item: Inbound) {
        guard let reader else {
            inbound.append(item)
            signalChange()
            return
        }
        self.reader = nil
        switch item {
        case .bytes(let bytes): reader.resume(returning: bytes)
        case .endOfFile: reader.resume(returning: nil)
        case .readTimeout: reader.resume(throwing: SSHError.timedOut)
        }
        signalChange()
    }

    /// The outer nil means nothing is queued; the inner nil means end of file.
    private func takeInbound(maximumBytes: Int) throws -> Data?? {
        guard !inbound.isEmpty else { return nil }
        switch inbound.removeFirst() {
        case .endOfFile:
            return .some(nil)
        case .readTimeout:
            throw SSHError.timedOut
        case .bytes(let bytes):
            guard bytes.count > maximumBytes else { return bytes }
            inbound.insert(.bytes(bytes.subdata(in: maximumBytes..<bytes.count)), at: 0)
            return bytes.subdata(in: 0..<maximumBytes)
        }
    }

    private func failRead(_ error: any Error) {
        guard let reader else { return }
        self.reader = nil
        reader.resume(throwing: error)
    }

    private func waitForChange() async {
        await withCheckedContinuation { changeWaiters.append($0) }
    }

    private func signalChange() {
        let waiters = changeWaiters
        changeWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

extension FakeWebSocketServer {
    static let testSubprotocol = "heeler.test.v1"

    /// A link that finished its upgrade with a fresh server. Deadlines run on
    /// `clock`, which only moves when the test says so.
    static func open(
        options: WebSocketLink.Options = WebSocketLink.Options(), clock: ManualClock = ManualClock()
    ) async throws -> (server: FakeWebSocketServer, link: WebSocketLink) {
        let server = FakeWebSocketServer()
        async let link = WebSocketLink.connect(
            over: server, path: "/api/test", subprotocol: testSubprotocol, options: options,
            sleep: clock.parkedSleep(for:))
        await server.acceptUpgrade()
        return (server, try await link)
    }
}
