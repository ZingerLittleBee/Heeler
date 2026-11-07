import Foundation
import HeelerSSH

/// One framed connection to a core: a plain `hello` line, then frames that
/// carry channel-0 RPC and every stream over one duplex channel.
///
/// One writer task sends frames in order, so bytes never interleave, and the
/// reader task always drains, so a stalled consumer never holds up channel-0
/// replies or other streams: each stream's unread bytes are bounded by the
/// credit it has not returned. A stream's first DATA can arrive before the
/// reply that names its channel, so frames are kept by channel from the start.
///
/// Ending is explicit: call `close()`. A link that dies on its own tears down
/// the same way: pending calls fail, streams finish after their buffered bytes,
/// and a mutation already handed to the writer reports outcome unknown. Nothing
/// is ever replayed.
actor HerdrCoreLink {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let maximumHelloLineBytes = 1024 * 1024
    /// Streams whose opening reply has not arrived yet. A core only opens one
    /// per request, so more than this is a core that is not following the protocol.
    static let maximumUnclaimedChannels = 64
    private static let readChunkBytes = 64 * 1024
    private static let readPoll: Duration = .seconds(1)
    private static let minimumWriteTimeout: Duration = .seconds(30)
    private static let slowestWriteBytesPerSecond = 64 * 1024
    /// A frame this long holds the writer for a while on a slow link. What queues
    /// behind it has not had its turn, and the write's own timeout bounds that wait.
    private static let longFrameBytes = 1024 * 1024
    private static let closeTimeout: Duration = .seconds(2)
    private static let helloID = "hello"

    private enum Ending {
        case closed
        case failed(any Error)

        var callFailure: any Error {
            switch self {
            case .closed: TransportError.cancelled
            case .failed(let error): error
            }
        }
    }

    private struct Reply {
        let result: JSONValue
        let streamChannel: UInt32?
    }

    private struct PendingCall {
        let continuation: CheckedContinuation<Reply, any Error>
        let isMutation: Bool
        let opensStream: Bool
        let creditsWhenConsumed: Bool
        let deadline: Duration
        var timer: Task<Void, Never>
        var dispatched = false
        /// It has outlived its deadline behind a long frame.
        var waitedBehindLongFrame = false
    }

    private struct Outbound {
        let bytes: Data
        var callID: String?
        var completion: CheckedContinuation<Void, any Error>?
    }

    private struct StreamState {
        var chunks: [Data] = []
        var credit = HerdrCoreFrame.initialCredit
        var waiter: CheckedContinuation<Data?, any Error>?
        var claimed = false
        var serverClosed = false
        /// The stream's consumer says what it has taken, so reading returns no
        /// credit, and the link closing under it is not a clean end.
        var creditsWhenConsumed = false
    }

    private let channel: any HeelerSSHAPIChannel
    private let sleep: Sleep

    /// What arrived before the `hello` reply's newline; nil once frames began.
    private var plainInput: Data? = Data()
    private var decoder = HerdrCoreFrameDecoder()

    private var nextRequestID: UInt64 = 0
    private var pending: [String: PendingCall] = [:]
    /// Abandoned calls that may yet name a channel, which must then be closed.
    private var abandonedStreamOpens: Set<String> = []

    private var outbox: [Outbound] = []
    private var inFlight: Outbound?
    private var writerWaiter: CheckedContinuation<Outbound?, Never>?

    private var streams: [UInt32: StreamState] = [:]
    /// Channels that ended here: what still arrives on them is dropped.
    private var retired: Set<UInt32> = []

    private var ending: Ending?
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// From this link's `hello`. A link never reopens, so it is the one core.
    private var coreID = ""

    private init(channel: any HeelerSSHAPIChannel, sleep: @escaping Sleep) {
        self.channel = channel
        self.sleep = sleep
    }

    /// Switches a fresh channel to frames and checks the core. A core that
    /// fails the check closes the channel and throws `HerdrCoreUpdateRequired`.
    static func connect(
        over channel: any HeelerSSHAPIChannel,
        helloDeadline: Duration = .seconds(10),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) async throws -> (link: HerdrCoreLink, info: HerdrCoreServerInfo) {
        let link = HerdrCoreLink(channel: channel, sleep: sleep)
        do {
            return (link, try await link.handshake(deadline: helloDeadline))
        } catch {
            await link.close()
            throw error
        }
    }

    /// How long one write may take: a whole frame has to cross a slow link.
    static func writeTimeout(forBytes count: Int) -> Duration {
        max(minimumWriteTimeout, .seconds(count / slowestWriteBytesPerSecond))
    }

    /// False once the link ended, on its own or by `close()`. It never reopens.
    var isOpen: Bool { ending == nil }

    // MARK: Calls

    /// One channel-0 call. Its reply is matched by id in any order. Past its
    /// deadline it throws `.timedOut`, or `.coreMutationOutcomeUnknown` for a
    /// mutation already handed to the writer; the link stays up and the late
    /// reply is dropped.
    func call(
        _ method: String, params: JSONValue = .object([:]), deadline: Duration, isMutation: Bool = false
    ) async throws -> JSONValue {
        try await request(
            method, params: params, deadline: deadline, isMutation: isMutation, opensStream: false,
            creditsWhenConsumed: false
        ).result
    }

    /// A call whose reply names a new channel, as `terminal.attach` does.
    /// `creditsWhenConsumed` moves the stream's credit from each read to the
    /// consumer's `consumed(_:)`.
    func openStream(
        _ method: String, params: JSONValue, deadline: Duration, isMutation: Bool = false,
        creditsWhenConsumed: Bool = false
    ) async throws -> (result: JSONValue, stream: HerdrCoreLinkStream) {
        let reply = try await request(
            method, params: params, deadline: deadline, isMutation: isMutation, opensStream: true,
            creditsWhenConsumed: creditsWhenConsumed)
        guard let channel = reply.streamChannel else {
            throw TransportError.malformedResponse(String(localized: "herdr-core: \(method) named no channel."))
        }
        return (reply.result, HerdrCoreLinkStream(channel: channel, link: self))
    }

    func serverStatus(deadline: Duration) async throws -> HerdrCoreServerStatus {
        try HerdrCoreServerStatus(result: await call("server.status", deadline: deadline))
    }

    /// Subscribes to every Terminal's events on a channel of their own, with
    /// a fresh cursor from this subscribe's snapshot.
    func subscribeEvents(deadline: Duration) async throws -> HerdrCoreEventStream {
        let (result, stream) = try await openStream(
            "events.subscribe", params: .object([:]), deadline: deadline)
        do {
            return HerdrCoreEventStream(
                snapshot: try HerdrCoreSnapshot(result: result), coreID: coreID, source: stream)
        } catch {
            await stream.close()
            throw error
        }
    }

    /// Tears the link down and closes the channel. Idempotent.
    func close() async {
        tearDown(.closed)
        await closeTask?.value
    }

    private func handshake(deadline: Duration) async throws -> HerdrCoreServerInfo {
        readerTask = Task { await runReader() }
        writerTask = Task { await runWriter() }
        let line = try HerdrCoreServerInfo.helloRequestLine(id: Self.helloID)
        let reply = try await exchange(
            id: Self.helloID, bytes: Data(line.utf8), deadline: deadline,
            isMutation: false, opensStream: false, creditsWhenConsumed: false)
        let info = try HerdrCoreServerInfo(hello: reply.result)
        coreID = info.coreID
        return info
    }

    private func request(
        _ method: String, params: JSONValue, deadline: Duration, isMutation: Bool, opensStream: Bool,
        creditsWhenConsumed: Bool
    ) async throws -> Reply {
        nextRequestID += 1
        let id = String(nextRequestID)
        // Frames delimit channel-0 messages, so the line's newline stays behind.
        let line = try HerdrCoreWire.requestLine(id: id, method: method, params: params)
        let payload = Data(line.utf8).dropLast()
        let bytes: Data
        do {
            bytes = try HerdrCoreFrame(channel: 0, kind: .data, payload: Data(payload)).encoded()
        } catch {
            throw TransportError.channelFailed(
                detail: String(localized: "The herdr-core request exceeds the frame limit."))
        }
        return try await exchange(
            id: id, bytes: bytes, deadline: deadline, isMutation: isMutation, opensStream: opensStream,
            creditsWhenConsumed: creditsWhenConsumed)
    }

    private func exchange(
        id: String, bytes: Data, deadline: Duration, isMutation: Bool, opensStream: Bool,
        creditsWhenConsumed: Bool
    ) async throws -> Reply {
        if let ending { throw ending.callFailure }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = PendingCall(
                    continuation: continuation, isMutation: isMutation, opensStream: opensStream,
                    creditsWhenConsumed: creditsWhenConsumed, deadline: deadline,
                    timer: armTimer(id: id, deadline: deadline))
                enqueue(Outbound(bytes: bytes, callID: id))
            }
        } onCancel: {
            Task { await self.cancelCall(id) }
        }
    }

    private func armTimer(id: String, deadline: Duration) -> Task<Void, Never> {
        Task { [sleep] in
            do { try await sleep(deadline) } catch { return }
            self.expireCall(id)
        }
    }

    /// A keepalive queued behind a long frame must not read that wait as a lost link.
    private func expireCall(_ id: String) {
        guard var call = pending[id] else { return }
        if !call.dispatched, let inFlight, inFlight.bytes.count >= Self.longFrameBytes {
            call.waitedBehindLongFrame = true
            call.timer = armTimer(id: id, deadline: call.deadline)
            pending[id] = call
            return
        }
        pending[id] = nil
        abandon(call, id: id, with: TransportError.timedOut)
    }

    private func cancelCall(_ id: String) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timer.cancel()
        abandon(call, id: id, with: CancellationError())
    }

    private func abandon(_ call: PendingCall, id: String, with error: any Error) {
        if !call.dispatched {
            outbox.removeAll { $0.callID == id }
        } else if call.opensStream {
            abandonedStreamOpens.insert(id)
        }
        call.continuation.resume(
            throwing: call.dispatched && call.isMutation ? TransportError.coreMutationOutcomeUnknown : error)
    }

    // MARK: Streams

    fileprivate func read(channel: UInt32) async throws -> Data? {
        if Task.isCancelled {
            closeStream(channel)
            throw CancellationError()
        }
        guard var state = streams[channel] else {
            if case .failed(let error) = ending { throw error }
            return nil
        }
        if !state.chunks.isEmpty {
            let chunk = state.chunks.removeFirst()
            if ending == nil, !state.serverClosed, !state.creditsWhenConsumed {
                state.credit += chunk.count
                enqueueCredit(chunk.count, channel: channel)
            }
            streams[channel] = state
            return chunk
        }
        if let ending {
            retire(channel)
            if case .failed(let error) = ending { throw error }
            if state.creditsWhenConsumed { throw TransportError.cancelled }
            return nil
        }
        if state.serverClosed {
            retire(channel)
            return nil
        }
        guard state.waiter == nil else {
            throw TransportError.channelFailed(detail: String(localized: "A herdr-core stream has one reader."))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    closeStream(channel)
                    return
                }
                streams[channel]?.waiter = continuation
            }
        } onCancel: {
            Task { await self.cancelRead(channel: channel) }
        }
    }

    /// Returns credit for bytes a `creditsWhenConsumed` stream's consumer took.
    fileprivate func returnCredit(_ count: Int, channel: UInt32) {
        guard count > 0, ending == nil, var state = streams[channel], !state.serverClosed else { return }
        state.credit += count
        streams[channel] = state
        enqueueCredit(count, channel: channel)
    }

    fileprivate func send(_ frame: HerdrCoreFrame) async throws {
        let bytes = try frame.encoded()
        if let ending { throw ending.callFailure }
        guard let state = streams[frame.channel], !state.serverClosed else {
            throw TransportError.channelFailed(detail: String(localized: "The herdr-core channel is closed."))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enqueue(Outbound(bytes: bytes, completion: continuation))
        }
    }

    /// Ends a stream from this side. The core's CLOSE answer and any DATA
    /// already on the wire are dropped when they arrive.
    fileprivate func closeStream(_ channel: UInt32) {
        guard !retired.contains(channel) else { return }
        let state = streams[channel]
        retire(channel)
        state?.waiter?.resume(returning: nil)
        guard ending == nil, state?.serverClosed != true else { return }
        enqueueFrame(HerdrCoreFrame(channel: channel, kind: .close))
    }

    private func cancelRead(channel: UInt32) {
        if let waiter = streams[channel]?.waiter {
            streams[channel]?.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
        closeStream(channel)
    }

    private func retire(_ channel: UInt32) {
        streams[channel] = nil
        retired.insert(channel)
    }

    private func enqueueCredit(_ count: Int, channel: UInt32) {
        guard let bytes = UInt32(exactly: count) else { return }
        enqueueFrame(HerdrCoreFrame.credit(channel: channel, bytes: bytes))
    }

    private func enqueueFrame(_ frame: HerdrCoreFrame) {
        guard let bytes = try? frame.encoded() else { return }
        enqueue(Outbound(bytes: bytes))
    }

    // MARK: Writer

    private func enqueue(_ item: Outbound) {
        if let writerWaiter {
            self.writerWaiter = nil
            begin(item)
            writerWaiter.resume(returning: item)
        } else {
            outbox.append(item)
        }
    }

    private func begin(_ item: Outbound) {
        inFlight = item
        guard let id = item.callID, var call = pending[id] else { return }
        call.dispatched = true
        if call.waitedBehindLongFrame {
            // A full deadline for the core to answer, which it had no chance to yet.
            call.timer.cancel()
            call.timer = armTimer(id: id, deadline: call.deadline)
        }
        pending[id] = call
    }

    private func nextOutbound() async -> Outbound? {
        guard ending == nil else { return nil }
        if !outbox.isEmpty {
            let item = outbox.removeFirst()
            begin(item)
            return item
        }
        return await withCheckedContinuation { writerWaiter = $0 }
    }

    private func writeFinished() {
        let item = inFlight
        inFlight = nil
        item?.completion?.resume()
    }

    private func runWriter() async {
        while let item = await nextOutbound() {
            do {
                try await channel.write(item.bytes, timeout: Self.writeTimeout(forBytes: item.bytes.count))
            } catch {
                // A partial write has already broken the framing for good.
                tearDown(.failed(Self.linkFailure(error)))
                return
            }
            writeFinished()
        }
    }

    // MARK: Reader

    private func runReader() async {
        while ending == nil {
            let chunk: Data?
            do {
                chunk = try await channel.read(maximumBytes: Self.readChunkBytes, timeout: Self.readPoll)
            } catch SSHError.timedOut {
                continue
            } catch {
                tearDown(.failed(Self.linkFailure(error)))
                return
            }
            guard let chunk else {
                tearDown(.failed(TransportError.channelFailed(detail: Self.closedDetail)))
                return
            }
            ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        var frames = chunk
        if var plain = plainInput {
            plain.append(chunk)
            guard let split = HerdrCoreFrameDecoder.splitHelloLine(plain) else {
                plainInput = plain
                if plain.count > Self.maximumHelloLineBytes {
                    tearDown(.failed(TransportError.malformedResponse(
                        String(localized: "herdr-core: The hello reply is too long."))))
                }
                return
            }
            plainInput = nil
            handleReply(split.line)
            frames = split.rest
        }
        decoder.append(frames)
        do {
            while ending == nil, let frame = try decoder.next() { route(frame) }
        } catch {
            tearDown(.failed(TransportError.malformedResponse("herdr-core: \(error)")))
        }
    }

    private func route(_ frame: HerdrCoreFrame) {
        guard frame.channel != 0 else {
            if frame.kind == .data { handleReply(frame.payload) }
            return
        }
        switch frame.kind {
        case .data: receive(frame.payload, channel: frame.channel)
        case .close: receiveClose(channel: frame.channel)
        case .credit, .resize, .focus, .facts: break
        }
    }

    private func handleReply(_ payload: Data) {
        guard let id = HerdrCoreWire.responseID(from: payload) else { return }
        if abandonedStreamOpens.remove(id) != nil {
            closeLateStream(payload: payload, id: id)
            return
        }
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timer.cancel()
        do {
            let result = try HerdrCoreServerInfo.result(from: payload, id: id)
            let streamChannel =
                call.opensStream
                ? try claimStream(from: result, creditsWhenConsumed: call.creditsWhenConsumed) : nil
            call.continuation.resume(returning: Reply(result: result, streamChannel: streamChannel))
        } catch {
            call.continuation.resume(throwing: error)
        }
    }

    /// Nobody will read a stream whose opening call gave up. Left open, a
    /// viewer would stay on the Terminal and could keep setting its size.
    private func closeLateStream(payload: Data, id: String) {
        guard let result = try? HerdrCoreWire.result(from: payload, id: id),
            let channel = Self.channel(in: result)
        else { return }
        closeStream(channel)
    }

    private func claimStream(from result: JSONValue, creditsWhenConsumed: Bool) throws -> UInt32 {
        guard let channel = Self.channel(in: result), !retired.contains(channel) else {
            throw TransportError.malformedResponse(
                String(localized: "herdr-core: The reply names no usable channel."))
        }
        var state = streams[channel] ?? StreamState()
        state.claimed = true
        state.creditsWhenConsumed = creditsWhenConsumed
        streams[channel] = state
        return channel
    }

    private static func channel(in result: JSONValue) -> UInt32? {
        guard let number = HerdrCoreWire.integer(result["channel"]), number > 0 else { return nil }
        return UInt32(exactly: number)
    }

    private func receive(_ payload: Data, channel: UInt32) {
        guard !retired.contains(channel), var state = streamForArrival(channel) else { return }
        state.credit -= payload.count
        guard state.credit >= 0 else {
            tearDown(.failed(TransportError.malformedResponse(
                String(localized: "herdr-core: A stream exceeded its credit."))))
            return
        }
        if let waiter = state.waiter {
            state.waiter = nil
            if !state.creditsWhenConsumed {
                state.credit += payload.count
                enqueueCredit(payload.count, channel: channel)
            }
            streams[channel] = state
            waiter.resume(returning: payload)
        } else {
            state.chunks.append(payload)
            streams[channel] = state
        }
    }

    private func receiveClose(channel: UInt32) {
        guard !retired.contains(channel), var state = streamForArrival(channel) else { return }
        state.serverClosed = true
        if let waiter = state.waiter {
            retire(channel)
            waiter.resume(returning: nil)
        } else {
            streams[channel] = state
        }
    }

    /// The channel's state, new if its opening reply has not arrived yet.
    /// Nil when the core has opened more channels than it was asked for.
    private func streamForArrival(_ channel: UInt32) -> StreamState? {
        if let state = streams[channel] { return state }
        guard streams.values.count(where: { !$0.claimed }) < Self.maximumUnclaimedChannels else {
            tearDown(.failed(TransportError.malformedResponse(
                String(localized: "herdr-core: Too many unrequested channels."))))
            return nil
        }
        return StreamState()
    }

    // MARK: Teardown

    private func tearDown(_ reason: Ending) {
        guard ending == nil else { return }
        ending = reason
        let failure = reason.callFailure
        let calls = pending.values
        pending = [:]
        abandonedStreamOpens = []
        for call in calls {
            call.timer.cancel()
            call.continuation.resume(
                throwing: call.dispatched && call.isMutation ? TransportError.coreMutationOutcomeUnknown : failure)
        }
        // Bytes that may have left: their outcome is unknown. Bytes still queued never left.
        inFlight?.completion?.resume(throwing: TransportError.coreMutationOutcomeUnknown)
        inFlight = nil
        for item in outbox { item.completion?.resume(throwing: failure) }
        outbox = []
        writerWaiter?.resume(returning: nil)
        writerWaiter = nil
        for (channel, state) in streams {
            if let waiter = state.waiter {
                retire(channel)
                if case .failed(let error) = reason {
                    waiter.resume(throwing: error)
                } else if state.creditsWhenConsumed {
                    waiter.resume(throwing: TransportError.cancelled)
                } else {
                    waiter.resume(returning: nil)
                }
            } else if !state.claimed {
                retire(channel)
            }
        }
        readerTask?.cancel()
        writerTask?.cancel()
        closeTask = Task { [channel] in try? await channel.close(timeout: Self.closeTimeout) }
    }

    /// What a link says when its channel reached the end of its stream. A
    /// plain token, not copy: `HerdrCoreSSHTransport` matches on it, and
    /// `TransportError.displayedChannelDetail(_:)` localizes it where it is shown.
    static let closedDetail = "The herdr-core link closed."

    private static func linkFailure(_ error: any Error) -> any Error {
        if error is TransportError { return error }
        return TransportError.channelFailed(
            detail: String(localized: "The herdr-core link failed: \(String(describing: error))"))
    }
}

/// A stream channel on a link. One task reads it. Reading returns CREDIT for
/// the bytes it hands out, never earlier, so the core stops sending to a
/// consumer that stops reading; a stream opened with `creditsWhenConsumed`
/// returns it from `consumed(_:)` instead. A cancelled read closes the channel.
struct HerdrCoreLinkStream: HerdrCoreEventBytes {
    let channel: UInt32
    private let link: HerdrCoreLink

    fileprivate init(channel: UInt32, link: HerdrCoreLink) {
        self.channel = channel
        self.link = link
    }

    /// The next bytes, or nil once the channel ended. Bytes that arrived before
    /// the end come first; a link failure throws after them.
    func read() async throws -> Data? {
        try await link.read(channel: channel)
    }

    /// Sends input as DATA once it is the writer's turn. After a link failure
    /// bytes that may have left throw `.coreMutationOutcomeUnknown`.
    func write(_ bytes: Data) async throws {
        try await link.send(HerdrCoreFrame(channel: channel, kind: .data, payload: bytes))
    }

    func resize(columns: Int, rows: Int) async throws {
        try await link.send(try HerdrCoreFrame.resize(channel: channel, columns: columns, rows: rows))
    }

    /// Sends a viewer's focus change.
    func focus(gained: Bool) async throws {
        try await link.send(HerdrCoreFrame.focus(channel: channel, gained: gained))
    }

    /// Sends what a viewer's own terminal looks like.
    func facts(_ payload: Data) async throws {
        try await link.send(HerdrCoreFrame(channel: channel, kind: .facts, payload: payload))
    }

    /// The consumer took `count` bytes of a `creditsWhenConsumed` stream.
    func consumed(_ count: Int) async {
        await link.returnCredit(count, channel: channel)
    }

    /// Sends CLOSE unless the channel already ended. Idempotent.
    func close() async {
        await link.closeStream(channel)
    }
}
