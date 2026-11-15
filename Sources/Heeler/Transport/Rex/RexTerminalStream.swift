import Foundation

/// One Rex terminal block's output for one view (ADR 0047): a data link, the
/// stream scanner, and the paint engine, run together. `next` hands out the
/// view's instructions in order, ending with `.ended`.
///
/// Before `start` or the first `next`, the route's control link must be
/// attached to the block's session with `session.attach`, and must stay
/// attached: Rex refuses tickets otherwise, and cancels the stream when the
/// client that opened it leaves. When the transport replaces its control
/// link, the new one needs the attach again before the stream starts over.
///
/// Endings the stream gets past on its own:
/// - A dropped connection is resumed on a new channel, once per connection.
///   Meanwhile no paint counts as exact.
/// - A refused resume, a cancelled provider, `try again later`, and the
///   like start a new stream from a new ticket, after `startOverDelay`. The
///   view keeps what it shows until the new stream's first paint, which
///   resets it.
/// - After `startOverAttempts` new streams in a row that never painted, or
///   that could not open, it ends with `.streamUnavailable`, or with
///   `.notAttached` when the last ticket was refused for want of an attach.
///
/// The view must read promptly. While no paint is being read, reading the
/// stream pauses once `queuedByteLimit` of instructions wait unread, which
/// holds the program's output back on the server. During a paint the stream
/// is read regardless, because the paint's exactness depends on seeing
/// output as it comes.
actor RexTerminalStream {
    typealias Sleep = WebSocketLink.Sleep

    struct Options: Sendable {
        var paint = RexTerminalPaint.Parameters()
        var link = RexDataLink.Options()
        /// Instruction bytes waiting for the view at which reading pauses.
        var queuedByteLimit = 1024 * 1024
        /// The deadline of each read a paint makes.
        var readDeadline: Duration = .seconds(30)
        /// New streams in a row, without a paint between, before giving up.
        var startOverAttempts = 3
        var startOverDelay: Duration = .seconds(1)
        /// Tries at a resume whose channel could not be opened. The RESUME
        /// itself goes out at most once.
        var resumeAttempts = 3
        var resumeDelay: Duration = .seconds(1)

        init() {}
    }

    struct Status: Sendable, Equatable {
        var isPainted = false
        var isDirty = false
        var paintCount = 0
        var exactPaintCount = 0
        /// Streams opened with a HELLO.
        var streamsOpened = 0
        var resumes = 0
        /// Snapshot bytes skipped, on the current stream.
        var skippedSnapshotBytes: UInt64 = 0
        /// Program output seen, on the current stream.
        var programBytes: UInt64 = 0
        var droppedReplayBytes: UInt64 = 0
        var droppedMessages = 0
    }

    let session: String
    let block: String
    private let route: RexDataRoute
    private let options: Options
    private let sleep: Sleep

    private var engine: RexTerminalPaint
    private var counters = Status()
    private var scannerProgress: (snapshot: UInt64, program: UInt64, dropped: Int) = (0, 0, 0)
    private var runTask: Task<Void, Never>?
    private var effectTasks: [UInt64: Task<Void, Never>] = [:]
    /// The connection being read, while there is one.
    private var link: RexDataLink?
    private var closing: Task<Void, Never>?
    private var finished = false

    private var queue: [RexTerminalInstruction] = []
    private var queueHead = 0
    private var queuedBytes = 0
    private var waiter: (id: UInt64, continuation: CheckedContinuation<RexTerminalInstruction?, Never>)?
    private var waiterIDs: UInt64 = 0
    private var roomWaiter: CheckedContinuation<Void, Never>?

    init(
        session: String, block: String, route: RexDataRoute, options: Options = Options(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.block = block
        self.route = route
        self.options = options
        self.sleep = sleep
        engine = RexTerminalPaint(parameters: options.paint)
    }

    var status: Status {
        var status = counters
        status.isPainted = engine.isPainted
        status.isDirty = engine.isDirty
        status.paintCount = engine.paintCount
        status.exactPaintCount = engine.exactPaintCount
        status.droppedReplayBytes = engine.droppedReplayBytes
        status.skippedSnapshotBytes = scannerProgress.snapshot
        status.programBytes = scannerProgress.program
        status.droppedMessages = scannerProgress.dropped
        return status
    }

    // MARK: The view's side

    /// Opens the stream, once.
    func start() {
        guard runTask == nil, !finished else { return }
        runTask = Task { await self.run() }
    }

    /// The next instruction, waiting for one; nil after `.ended` was handed
    /// out, or when the caller's task is cancelled. One reader at a time.
    func next() async -> RexTerminalInstruction? {
        start()
        if let instruction = dequeue() { return instruction }
        if finished || Task.isCancelled { return nil }
        if let previous = waiter {
            waiter = nil
            previous.continuation.resume(returning: nil)
        }
        waiterIDs += 1
        let id = waiterIDs
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = (id, continuation)
            }
        } onCancel: {
            Task { await self.waiterCancelled(id) }
        }
    }

    /// Ends the stream for good: its connection closes with 1000, which the
    /// server takes as the end. `.ended(.closedHere)` is the last instruction.
    func stop() async {
        finish(.closedHere)
        await closing?.value
    }

    private func waiterCancelled(_ id: UInt64) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }

    private func enqueue(_ instruction: RexTerminalInstruction) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: instruction)
            return
        }
        queue.append(instruction)
        queuedBytes += instruction.byteCount
    }

    private func dequeue() -> RexTerminalInstruction? {
        guard queueHead < queue.count else { return nil }
        let instruction = queue[queueHead]
        queueHead += 1
        queuedBytes -= instruction.byteCount
        if queueHead == queue.count {
            queue.removeAll(keepingCapacity: true)
            queueHead = 0
        } else if queueHead >= 64, queueHead * 2 >= queue.count {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
        if queuedBytes <= options.queuedByteLimit { makeRoom() }
        return instruction
    }

    private func makeRoom() {
        roomWaiter?.resume()
        roomWaiter = nil
    }

    private func waitForRoom() async {
        while !finished, queuedBytes > options.queuedByteLimit, !engine.isReading {
            await withCheckedContinuation { roomWaiter = $0 }
        }
    }

    // MARK: Ending

    private func finish(_ end: RexTerminalEnd) {
        guard !finished else { return }
        finished = true
        enqueue(.ended(end))
        for task in effectTasks.values { task.cancel() }
        effectTasks = [:]
        makeRoom()
        if let link {
            // Closing ends the read the run is waiting in.
            closing = Task { await link.close() }
        } else {
            runTask?.cancel()
        }
    }

    // MARK: The run

    private enum StreamOutcome {
        case finished
        case stop(RexDataEnding)
        case startOver(RexDataEnding?)
    }

    private func run() async {
        var failures = 0
        var lastEnding: RexDataEnding?
        var refusedForAttach = false
        while !finished {
            if failures > 0 {
                do { try await sleep(options.startOverDelay) } catch { return }
                if finished { return }
            }
            let opened: RexDataLink
            do {
                opened = try await RexDataLink.open(
                    session: session, block: block, route: route, options: options.link, sleep: sleep)
            } catch {
                if finished || error is CancellationError { return }
                if case RexDataLinkError.ticketUnavailable(.server(let failure)) = error {
                    if failure.kind == .notFound { return finish(.blockClosed) }
                    refusedForAttach = failure.kind == .conflict
                } else {
                    refusedForAttach = false
                }
                if case RexDataLinkError.ended(let ending) = error { lastEnding = ending }
                failures += 1
                if failures > options.startOverAttempts {
                    return finish(refusedForAttach ? .notAttached : .streamUnavailable(lastEnding))
                }
                continue
            }
            if finished {
                await opened.close()
                return
            }
            refusedForAttach = false
            counters.streamsOpened += 1
            cancelEffects()
            apply(engine.beginStream())
            let paints = engine.paintCount
            switch await pump(opened) {
            case .finished:
                return
            case .stop(let ending):
                return finish(ending == .blockClosed ? .blockClosed : .closedHere)
            case .startOver(let ending):
                lastEnding = ending
                failures = engine.paintCount > paints ? 1 : failures + 1
                if failures > options.startOverAttempts { return finish(.streamUnavailable(ending)) }
            }
        }
    }

    /// Reads one stream until it ends for good or needs starting over,
    /// resuming its connection when that drops.
    private func pump(_ opened: RexDataLink) async -> StreamOutcome {
        var current = opened
        link = current
        defer { link = nil }
        var scanner = RexStreamScanner(nonce: current.nonce)
        scannerProgress = (0, 0, 0)
        while !finished {
            let bytes: Data
            do {
                bytes = try await current.receive()
            } catch RexDataLinkError.ended(let ending) {
                if finished { return .finished }
                switch ending.recovery {
                case .stop:
                    return .stop(ending)
                case .startOver:
                    await current.disconnect()
                    return .startOver(ending)
                case .resume:
                    guard let resumed = await resume(current) else {
                        if finished { return .finished }
                        return .startOver(ending)
                    }
                    current = resumed
                    link = current
                    continue
                }
            } catch {
                await current.disconnect()
                return finished ? .finished : .startOver(nil)
            }
            let items = scanner.scan(bytes)
            scannerProgress = (scanner.skippedSnapshotBytes, scanner.programByteCount, scanner.droppedMessageCount)
            apply(engine.receive(items))
            await waitForRoom()
        }
        return .finished
    }

    /// A connection to go on with, or nil when only a new stream will do.
    private func resume(_ dropped: RexDataLink) async -> RexDataLink? {
        apply(engine.streamPaused())
        for attempt in 0..<max(1, options.resumeAttempts) {
            if attempt > 0 {
                do { try await sleep(options.resumeDelay) } catch { return nil }
            }
            if finished { return nil }
            do {
                let next = try await dropped.resume(over: route)
                if finished {
                    await next.close()
                    return nil
                }
                counters.resumes += 1
                apply(engine.streamResumed())
                return next
            } catch {
                // Only a channel that could not be opened, before the RESUME went out, is worth another try.
                if error is CancellationError { return nil }
                guard await dropped.canResume else { return nil }
            }
        }
        return nil
    }

    // MARK: Effects

    private func apply(_ effects: [RexTerminalPaint.Effect]) {
        for effect in effects where !finished {
            switch effect {
            case .emit(let instruction):
                if case .ended(let end) = instruction {
                    finish(end)
                } else {
                    enqueue(instruction)
                }
            case .read(let read, let id):
                effectTasks[id] = Task { [session, block, route, options] in
                    let answer = await Self.perform(
                        read, session: session, block: block, route: route, options: options)
                    self.answered(answer, id: id)
                }
            case .wait(let delay, let id):
                effectTasks[id] = Task { [sleep] in
                    do { try await sleep(delay) } catch { return }
                    self.waited(id: id)
                }
            }
        }
        // A paint being read needs the stream read meanwhile.
        if engine.isReading { makeRoom() }
    }

    private func answered(_ answer: RexTerminalAnswer, id: UInt64) {
        guard effectTasks.removeValue(forKey: id) != nil, !finished else { return }
        apply(engine.answered(answer, id: id))
    }

    private func waited(id: UInt64) {
        guard effectTasks.removeValue(forKey: id) != nil, !finished else { return }
        apply(engine.waited(id: id))
    }

    private func cancelEffects() {
        for task in effectTasks.values { task.cancel() }
        effectTasks = [:]
    }

    private static func perform(
        _ read: RexTerminalRead, session: String, block: String, route: RexDataRoute, options: Options
    ) async -> RexTerminalAnswer {
        do {
            let control = try await route.control()
            let pageBytes = RexTerminalPaint.pageBytes(
                asked: options.paint.pageBytes, messageLimit: control.maxMessageBytes)
            let call = RexTerminalReads.call(read, session: session, block: block, pageBytes: pageBytes)
            let response = try await control.call(call.method, payload: call.payload, deadline: options.readDeadline)
            return RexTerminalReads.answer(to: read, try response.result(JSONValue.self))
        } catch {
            return .failed
        }
    }
}

extension RexTerminalInstruction {
    /// The bytes it holds, for bounding what waits for the view.
    var byteCount: Int {
        switch self {
        case .paint(let bytes, _), .feed(let bytes): bytes.count
        default: 0
        }
    }
}
