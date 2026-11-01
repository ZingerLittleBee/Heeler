import Foundation
import HeelerSSH

@testable import Heeler

/// A scripted core at the far end of the duplex SSH API channel. Tests deliver
/// bytes and read back exactly what the client wrote: first the plain `hello`
/// line, then frames. Time never passes on its own; deadlines belong to the
/// manual clock.
actor FakeCoreSocket: HeelerSSHAPIChannel, WindowsTerminalExecChannel {
    private enum Inbound {
        case bytes(Data)
        case endOfFile
        case readTimeout
    }

    private var inbound: [Inbound] = []
    private var reader: CheckedContinuation<Data?, any Error>?
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []

    private var writtenPlain = Data()
    private var sawPlainLine = false
    private var plainLine: Data?
    private var decoder = HerdrCoreFrameDecoder()
    private var requestCursor = 0

    private(set) var writtenFrames: [HerdrCoreFrame] = []
    private(set) var writeFailure: HerdrCoreFrameError?
    private(set) var isClosed = false
    private var writesHeld = false
    private var writesReachedHold = 0

    // MARK: HeelerSSHAPIChannel

    /// Yields mid-write, as a real channel does between packets, so two
    /// writers that overlap corrupt what the decoder here sees.
    func write(_ data: Data, timeout: Duration) async throws {
        if writesHeld { writesReachedHold += 1 }
        signalChange()
        while writesHeld, !isClosed { await waitForChange() }
        guard !isClosed else { throw SSHError.cancelled }
        let middle = data.startIndex + data.count / 2
        record(data.subdata(in: data.startIndex..<middle))
        await Task.yield()
        record(data.subdata(in: middle..<data.endIndex))
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
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

    func exitStatus(timeout: Duration) async throws -> Int32 { 0 }

    // MARK: The core's side

    func deliver(_ bytes: Data) {
        push(.bytes(bytes))
    }

    func deliver(_ frame: HerdrCoreFrame) throws {
        push(.bytes(try frame.encoded()))
    }

    func deliverEndOfFile() {
        push(.endOfFile)
    }

    /// The real channel's read poll: `SSHError.timedOut` with nothing arrived.
    func deliverReadTimeout() {
        push(.readTimeout)
    }

    /// While held, a write that has begun does not reach the wire.
    func holdWrites() {
        writesHeld = true
    }

    func releaseWrites() {
        writesHeld = false
        signalChange()
    }

    /// Returns once a write has begun and is being held.
    func waitForHeldWrite() async {
        while writesReachedHold == 0 { await waitForChange() }
    }

    // MARK: What the client wrote

    func nextWrittenLine() async -> Data {
        while true {
            if let plainLine { return plainLine }
            await waitForChange()
        }
    }

    /// The next channel-0 request the client wrote, in order.
    func nextRequest() async -> (id: String, method: String, params: JSONValue) {
        while true {
            let requests = writtenFrames.filter { $0.channel == 0 && $0.kind == .data }
            if requestCursor < requests.count {
                let frame = requests[requestCursor]
                requestCursor += 1
                let request = (try? JSONDecoder().decode(JSONValue.self, from: frame.payload)) ?? .null
                return (
                    request["id"]?.stringValue ?? "", request["method"]?.stringValue ?? "",
                    request["params"] ?? .null
                )
            }
            await waitForChange()
        }
    }

    func frames(channel: UInt32, kind: HerdrCoreFrameKind) -> [HerdrCoreFrame] {
        writtenFrames.filter { $0.channel == channel && $0.kind == kind }
    }

    func creditTotal(channel: UInt32) -> Int {
        frames(channel: channel, kind: .credit).reduce(0) { total, frame in
            total + frame.payload.reversed().reduce(0) { $0 << 8 | Int($1) }
        }
    }

    func requestCount() -> Int {
        writtenFrames.filter { $0.channel == 0 && $0.kind == .data }.count
    }

    func waitForFrame(channel: UInt32, kind: HerdrCoreFrameKind) async -> HerdrCoreFrame {
        while true {
            if let frame = frames(channel: channel, kind: kind).first { return frame }
            await waitForChange()
        }
    }

    /// What the client wrote on `channel` so far, each DATA frame as text.
    func dataWritten(channel: UInt32) -> [String] {
        frames(channel: channel, kind: .data).map { String(decoding: $0.payload, as: UTF8.self) }
    }

    /// Returns once `count` DATA frames have reached the wire on `channel`.
    func waitForData(channel: UInt32, count: Int) async {
        while frames(channel: channel, kind: .data).count < count { await waitForChange() }
    }

    func waitForCredit(channel: UInt32, total: Int) async {
        while creditTotal(channel: channel) < total { await waitForChange() }
    }

    func waitUntilClosed() async {
        while !isClosed { await waitForChange() }
    }

    // MARK: Reply builders

    static func replyFrame(id: String, result: JSONValue) throws -> HerdrCoreFrame {
        HerdrCoreFrame(
            channel: 0, kind: .data,
            payload: try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
            ])))
    }

    func reply(to id: String, result: JSONValue = .object([:])) throws {
        try deliver(Self.replyFrame(id: id, result: result))
    }

    func replyError(to id: String, kind: String) throws {
        try deliver(
            HerdrCoreFrame(
                channel: 0, kind: .data,
                payload: try JSONEncoder().encode(JSONValue.object([
                    "jsonrpc": .string("2.0"), "id": .string(id),
                    "error": .object([
                        "code": .number(-32000), "message": .string(kind),
                        "data": .object(["kind": .string(kind), "hint": .string("")]),
                    ]),
                ]))))
    }

    // MARK: Internals

    private func record(_ bytes: Data) {
        if sawPlainLine {
            decoder.append(bytes)
        } else {
            writtenPlain.append(bytes)
            if let split = HerdrCoreFrameDecoder.splitHelloLine(writtenPlain) {
                sawPlainLine = true
                plainLine = split.line
                decoder.append(split.rest)
            }
        }
        do {
            while let frame = try decoder.next() { writtenFrames.append(frame) }
        } catch {
            writeFailure = error as? HerdrCoreFrameError
        }
        signalChange()
    }

    private func push(_ item: Inbound) {
        guard let reader else {
            inbound.append(item)
            return
        }
        self.reader = nil
        switch item {
        case .bytes(let bytes): reader.resume(returning: bytes)
        case .endOfFile: reader.resume(returning: nil)
        case .readTimeout: reader.resume(throwing: SSHError.timedOut)
        }
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
