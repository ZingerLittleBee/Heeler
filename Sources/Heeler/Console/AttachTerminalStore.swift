import Foundation
import Observation

/// Throwaway diagnostic instrument (build 101): records every byte chunk
/// fed into a terminal surface, tagged with surface, transport generation,
/// timestamp, and resize events, so a garbled iPhone render can be replayed
/// and attributed on the Mac. Remove once the render regression is found.
#if DEBUG
final class TerminalStreamCapture: @unchecked Sendable {
    static let shared = TerminalStreamCapture()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    private let cap = 24 * 1024 * 1024
    private static let stamp: String = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }()

    private var activeHandle: FileHandle? {
        lock.lock(); defer { lock.unlock() }
        if handle == nil, written < cap, let dir = FileManager
            .default
            .urls(for: .documentDirectory, in: .userDomainMask).first
        {
            let path = dir.appendingPathComponent("stream-\(Self.stamp).bin")
            FileManager.default.createFile(atPath: path.path, contents: nil)
            handle = try? FileHandle(forWritingTo: path)
        }
        return handle
    }

    func record(surfaceID: TerminalSurfaceID, generation: UInt64?, bytes: Data) {
        guard let h = activeHandle else { return }
        let sid = surfaceID.uuidValuePrefix
        let head = Data("[\(Self.stamp)] s=\(sid) g=\(generation.map(String.init) ?? "-") n=\(bytes.count)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        guard written < cap else { return }
        try? h.write(contentsOf: head)
        try? h.write(contentsOf: bytes)
        written += head.count + bytes.count
    }

    func recordEvent(surfaceID: TerminalSurfaceID, kind: String) {
        guard let h = activeHandle else { return }
        let head = Data("[\(Self.stamp)] s=\(surfaceID.uuidValuePrefix) EVENT=\(kind)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        try? h.write(contentsOf: head)
    }
}

extension TerminalSurfaceID {
    var uuidValuePrefix: String {
        String(value.uuidString.suffix(8))
    }
}
#endif
typealias TerminalSessionOperation =
    @MainActor @Sendable (TerminalAttachSession) async throws -> Void
typealias TerminalSessionRunner =
    @Sendable (TerminalAttachRequest, TerminalSessionHandler) async throws -> Void

/// How the attach channel was carried. Surfaces in the terminal chrome so
/// the user can see whether a session is riding mosh UDP or plain SSH.
enum TerminalSessionFlavor: String, Sendable {
    case mosh
    case ssh
}

struct TerminalSessionHandler: Sendable {
    private let operation: TerminalSessionOperation
    private let transportReady: @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void
    #if DEBUG
    private let traceEvents: AttachRestorationTraceEvents?
    #endif


    init(
        transportReady: @escaping @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void = { _, _ in },
        _ operation: @escaping TerminalSessionOperation
    ) {
        self.transportReady = transportReady
        self.operation = operation
        #if DEBUG
        traceEvents = nil
        #endif
    }

    #if DEBUG
    init(
        transportReady: @escaping @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void = { _, _ in },
        traceEvents: AttachRestorationTraceEvents,
        _ operation: @escaping TerminalSessionOperation
    ) {
        self.transportReady = transportReady
        self.traceEvents = traceEvents
        self.operation = operation
    }
    #endif

    @MainActor
    func transportDidBecomeReady(_ generation: UInt64, flavor: TerminalSessionFlavor = .ssh) {
        transportReady(generation, flavor)
    }

    #if DEBUG
    @MainActor
    func attachRequestDidStart() {
        traceEvents?.attachRequestDidStart()
    }

    @MainActor
    func attachChannelDidOpen() {
        traceEvents?.attachChannelDidOpen()
    }
    #endif

    @MainActor
    func run(_ session: TerminalAttachSession) async throws {
        try await operation(session)
    }

    /// One complete session lifetime with owned teardown: runs the handler,
    /// then ends the channel — on success and on every failure except a
    /// `terminalChannelAlreadyOpen` refusal. That refusal means this
    /// consumer never owned the session: another consumer holds the output,
    /// the transport has already refused only this reader, and `end()` here
    /// would reach through the shared channel and tear down the legitimate
    /// consumer's live terminal (#151). The refusal itself still propagates,
    /// so the offending surface shows it rather than swallowing it (#141).
    func runEndingSession(_ session: TerminalAttachSession) async throws {
        do {
            try await run(session)
        } catch TransportError.terminalChannelAlreadyOpen {
            throw TransportError.terminalChannelAlreadyOpen
        } catch {
            await session.end()
            throw error
        }
        await session.end()
    }
}

/// The identity of one terminal pipeline, and so of the SwiftUI surface built
/// on top of it.
///
/// Deliberately not `ObjectIdentifier(store)`. That is the store's *address*,
/// and the allocator hands a freed address straight back to the next
/// allocation of the same shape — 200 stores built and dropped in a row
/// produced two distinct `ObjectIdentifier`s between them. SwiftUI compares
/// against the identity it recorded at its *last render*, not against the
/// store that is currently live, so a store landing on an address any earlier
/// generation held presents an identity SwiftUI has already seen; it sees
/// nothing change, keeps the surface it already built, and never calls
/// `makeUIView` again. That call is the only place a feed acquires a sink, so
/// the replacement's bytes buffer forever behind a stale screen while the
/// session reads as live (#143).
struct TerminalSurfaceID: Hashable, Sendable {
    private let value = UUID()

    init() {}
}

/// Reconciles the two independently scheduled signals that identify a
/// foreground recovery's Transport. Readiness is projected before terminal
/// waiters resume, so either signal may arrive first. A decision is made only
/// after both belong to the same terminal pipeline.
struct TerminalRecoveryGenerationLatch {
    enum Decision: Equatable {
        case pending
        case acknowledge(UInt64)
        case replace(UInt64)
        case retain(UInt64)
    }

    private(set) var isActive = false
    private var pipelineID: TerminalSurfaceID?
    private var acquiredGeneration: UInt64?
    private var projectedGeneration: UInt64?

    mutating func begin(projectedGeneration: UInt64?) {
        guard !isActive else { return }
        isActive = true
        pipelineID = nil
        acquiredGeneration = nil
        self.projectedGeneration = projectedGeneration
    }

    mutating func bind(to pipelineID: TerminalSurfaceID) {
        guard isActive else { return }
        self.pipelineID = pipelineID
        acquiredGeneration = nil
    }

    mutating func recordProjection(_ generation: UInt64) -> Decision? {
        guard isActive else { return nil }
        projectedGeneration = max(projectedGeneration ?? generation, generation)
        return reconcile()
    }

    mutating func recordAcquisition(
        _ generation: UInt64,
        by pipelineID: TerminalSurfaceID
    ) -> Decision? {
        guard isActive, self.pipelineID == pipelineID else { return nil }
        acquiredGeneration = generation
        return reconcile()
    }

    mutating func clear(boundTo pipelineID: TerminalSurfaceID) {
        guard self.pipelineID == pipelineID else { return }
        clear()
    }

    mutating func clear() {
        isActive = false
        pipelineID = nil
        acquiredGeneration = nil
        projectedGeneration = nil
    }

    private mutating func reconcile() -> Decision {
        guard let acquiredGeneration, let projectedGeneration else {
            return .pending
        }
        defer { clear() }
        if projectedGeneration == acquiredGeneration {
            return .acknowledge(acquiredGeneration)
        }
        if projectedGeneration > acquiredGeneration {
            return .replace(projectedGeneration)
        }
        return .retain(acquiredGeneration)
    }
}

/// The Agent detail screen's session pipeline: a full interactive terminal
/// over the Host's terminal channel — raw PTY bytes into the view through a
/// `TerminalByteFeed`, keystrokes back out, geometry changes as SSH
/// window-change on the live channel.
///
/// Nothing starts until the terminal view's first size report (the PTY opens
/// with real cols/rows). A later resize never
/// restarts anything: it rides in-band, which is the whole point of the PTY.
/// One session per run; the remote attach exiting (the user detached inside
/// the TUI, the pane closed) surfaces as `.ended` with reattach offered.
@MainActor
@Observable
final class AttachTerminalStore {
    enum Status: Equatable {
        /// Waiting for the terminal view's first layout to report cols/rows.
        case waitingForSize
        /// Opening the attach channel, and waiting for the remote attach to
        /// say something. Nothing is on the terminal yet.
        case connecting
        /// The new PTY Attach has produced output and owns the current input writer.
        case live
        /// The session ended remotely (clean detach or channel death); the
        /// message is user-facing and `retry()` reattaches.
        case ended(String)
        /// `stop()` was called; terminal.
        case stopped
    }

    private(set) var status: Status = .waitingForSize
    /// The byte pipe the terminal view consumes.
    let feed = TerminalByteFeed()
    /// What the screen identifies this pipeline's surface by. Owned by the
    /// store and unique for its lifetime, so a replacement is always a
    /// different surface to SwiftUI.
    let surfaceID = TerminalSurfaceID()

    private let target: TerminalAttachTarget
    private let takeover: Bool
    private let input: TerminalInputController
    private let observeOutput: @MainActor @Sendable (Data) -> Void
    private let finishOutput: @MainActor @Sendable () -> Void
    private let transportReady: @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void
    private let runDidFinish: @MainActor @Sendable (TerminalSurfaceID) -> Void
    /// Opens and owns exclusive Host terminal access for one complete run,
    /// including explicit channel teardown.
    private let runTerminal: TerminalSessionRunner

    private var cols: Int?
    private var rows: Int?
    private(set) var transportGeneration: UInt64?
    /// How the most recent attach session was carried (mosh UDP or SSH PTY).
    /// The source of truth for the mosh upgrade path: the host-level
    /// capsule upgrades only sessions still riding SSH.
    private(set) var lastSessionFlavor: TerminalSessionFlavor = .ssh
    /// The Transport generation this pipeline actually acquired from its
    /// runner. Unlike `transportGeneration`, this is never seeded from a
    /// projection value before the terminal-ready seam has been crossed.
    private(set) var acquiredTransportGeneration: UInt64?
    private var stopRequested = false
    private var preservesPendingPasteOnStop = false
    private var session: TerminalAttachSession?
    private var inputGeneration: TerminalInputController.SessionGeneration?
    private var runTask: Task<Void, Never>?
    /// Set once an automatic mosh→SSH fallback has run for this store.
    /// Never reset by the fallback's own restart, so a failed invalidation
    /// cannot loop mosh against the same dead handshake.
    private var moshAutoFallbackUsed = false
    /// True only while the current `.ended` status was produced by
    /// ``TransportError/moshSessionFailed(detail:)`` — the Session Ended
    /// overlay uses it to offer "Use SSH Instead".
    private(set) var endedWithMoshFailure = false
    private let onMoshFailure: (@MainActor @Sendable () async -> Void)?
    #if DEBUG
    private(set) var restorationTrace = AttachRestorationTrace()

    func adoptRestorationTrace(_ trace: AttachRestorationTrace) {
        restorationTrace = trace
    }
    #endif

    init(
        target: TerminalAttachTarget, takeover: Bool = false,
        input: TerminalInputController = TerminalInputController(),
        transportGeneration: UInt64? = nil,
        observeOutput: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        finishOutput: @escaping @MainActor @Sendable () -> Void = {},
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void = {
            _, _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in },
        onMoshFailure: (@MainActor @Sendable () async -> Void)? = nil,
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.target = target
        self.takeover = takeover
        self.input = input
        self.transportGeneration = transportGeneration
        self.observeOutput = observeOutput
        self.finishOutput = finishOutput
        self.transportReady = transportReady
        self.runDidFinish = runDidFinish
        self.onMoshFailure = onMoshFailure
        self.runTerminal = runTerminal
    }

    convenience init(
        target: String, takeover: Bool = false,
        input: TerminalInputController = TerminalInputController(),
        transportGeneration: UInt64? = nil,
        observeOutput: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        finishOutput: @escaping @MainActor @Sendable () -> Void = {},
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void = {
            _, _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in },
        onMoshFailure: (@MainActor @Sendable () async -> Void)? = nil,
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.init(
            target: .agentPane(target),
            takeover: takeover,
            input: input,
            transportGeneration: transportGeneration,
            observeOutput: observeOutput,
            finishOutput: finishOutput,
            transportReady: transportReady,
            runDidFinish: runDidFinish,
            onMoshFailure: onMoshFailure,
            runTerminal: runTerminal)
    }

    /// The terminal view's geometry, reported on first layout and on every
    /// change (rotation, split view, keyboard). The first report opens the
    /// session; later changes ride the live channel as window-change.
    func viewDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        #if DEBUG
        TerminalStreamCapture.shared.recordEvent(surfaceID: surfaceID, kind: "resize \(self.cols)x\(self.rows)->\(cols)x\(rows)")
        #endif
        self.cols = cols
        self.rows = rows
        if runTask == nil {
            if status == .waitingForSize {
                #if DEBUG
                restorationTrace.emit(.initialResize, generation: transportGeneration)
                #endif
                start()
            }
            // .ended waits for retry(); .stopped is terminal.
        } else {
            session?.resize(cols: cols, rows: rows)
        }
    }

    /// Keystrokes from the terminal view, forwarded raw. Dropped while no
    /// session is live — there is nothing to type into yet.
    func send(_ keystrokes: Data) {
        input.send(keystrokes)
    }

    /// The app returned to the foreground.
    ///
    /// A short bounce asks the remote TUI to repaint without replacing the
    /// current session. Extended absences are recovered at the owner boundary
    /// instead, because this store cannot observe presentation and must not
    /// treat a byte handed to a sink object as proof that a frame was drawn.
    func didBecomeActive() {
        guard status == .live, let session, let cols, let rows, cols > 1 else { return }
        // A window-change only reaches the remote when the size actually
        // changes, so the nudge is a shrink followed by a restore. Both ride
        // the reliable input queue, in order, on the live channel; the
        // store's own geometry is untouched, so a later real resize still
        // compares against what the view last reported.
        session.resize(cols: cols - 1, rows: rows)
        session.resize(cols: cols, rows: rows)
    }

    /// Reattaches after the session ended remotely.
    func retry() {
        guard case .ended = status, runTask == nil else { return }
        // A user-driven reattach is a fresh consent to the mosh path: the
        // Host may have been fixed since the last handshake failed.
        moshAutoFallbackUsed = false
        start()
    }

    /// The Session Ended overlay's "Use SSH Instead": invalidates mosh for
    /// the Host (so the runner picks SSH), then reattaches. The automatic
    /// fallback budget stays spent — if mosh were somehow chosen again and
    /// failed, the overlay would come back rather than loop.
    func retryOverSSH() {
        guard case .ended = status else { return }
        moshAutoFallbackUsed = true
        let current = runTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            await current?.value
            guard !self.stopRequested else { return }
            await self.onMoshFailure?()
            self.start()
        }
    }

    /// True while a mosh-upgrade restart is scheduled for the live
    /// session. A second request must not schedule a second restart, and
    /// the dying run must not overwrite the Connecting status the
    /// scheduled restart already installed.
    private var moshUpgradeRestartScheduled = false

    /// The host-level mosh capsule's upgrade: the Host's probe proved
    /// mosh available, so the live SSH session is ended and the pipeline
    /// reattaches — the runner re-selects mosh for the fresh attach. Same
    /// spawned-restart shape as the automatic mosh-failure fallback: the
    /// restart is scheduled off this run task (a synchronous `start()`
    /// would be cleared by `run()`'s own `runTask = nil` teardown), one
    /// restart is ever in flight, and a session that stopped meanwhile
    /// stays stopped.
    func upgradeToMosh() {
        guard status == .live, runTask != nil, !stopRequested,
            !moshUpgradeRestartScheduled
        else { return }
        moshUpgradeRestartScheduled = true
        // Fresh consent to the mosh path, like a user-driven retry: the
        // upgrade is deliberate, so a spent automatic fallback must not
        // pin the reattach to SSH.
        moshAutoFallbackUsed = false
        status = .connecting
        let session = self.session
        let current = runTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            await session?.end()
            await current?.value
            guard !self.stopRequested else { return }
            self.moshUpgradeRestartScheduled = false
            self.start()
        }
    }

    /// Ends the session by explicit close (only `end()` runs the channel's
    /// teardown; abandoning the session does not) and waits for the teardown.
    /// Terminal: the detail screen creates a fresh store after a Host
    /// reconnect.
    ///
    /// The run task is also cancelled: before a session exists it can be
    /// queued for the Host's terminal channel, and teardown must abort that
    /// wait rather than sit behind whoever holds the channel — a stop must
    /// never depend on the channel becoming available.
    func stop(preservingPendingPaste: Bool = false) async {
        stopRequested = true
        preservesPendingPasteOnStop = preservingPendingPaste
        if let session {
            await session.end()
        }
        if let task = runTask {
            task.cancel()
            await task.value
        }
        status = .stopped
    }

    private func start() {
        status = .connecting
        endedWithMoshFailure = false
        runTask = Task { await self.run() }
    }

    /// One session lifetime: open at the current geometry, pump output until
    /// the stream ends, surface how it ended.
    private func run() async {
        defer {
            runTask = nil
            runDidFinish(surfaceID)
        }
        guard let cols, let rows else { return }
        let request = TerminalAttachRequest(
            target: target, takeover: takeover, cols: cols, rows: rows)
        let operation: TerminalSessionOperation = { [weak self] session in
            guard let self else {
                await session.end()
                return
            }
            try await self.consume(session, initialCols: cols, initialRows: rows)
        }
        let transportReady: @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void = { [weak self] generation, flavor in
            guard let self else { return }
            self.transportGeneration = generation
            self.acquiredTransportGeneration = generation
            self.lastSessionFlavor = flavor
            self.transportReady(self.surfaceID, generation, flavor)
            #if DEBUG
            self.restorationTrace.emit(.transportAcquired, generation: generation)
            #endif
        }
        #if DEBUG
        let handler = TerminalSessionHandler(
            transportReady: transportReady,
            traceEvents: AttachRestorationTraceEvents(
                trace: restorationTrace,
                generation: { [weak self] in self?.acquiredTransportGeneration }),
            operation)
        #else
        let handler = TerminalSessionHandler(transportReady: transportReady, operation)
        #endif
        do {
            try await runTerminal(request, handler)
        } catch {
            guard !stopRequested, !moshUpgradeRestartScheduled else { return }
            if case TransportError.moshSessionFailed = error {
                endedWithMoshFailure = true
                // The mosh attempt died after the banner: invalidate mosh
                // for the Host and restart once, so SSH takes over without
                // user action. The fallback restart is scheduled off this
                // run task — `start()` synchronously would be cleared by
                // this function's `runTask = nil` defer.
                if !moshAutoFallbackUsed, onMoshFailure != nil {
                    moshAutoFallbackUsed = true
                    status = .connecting
                    let current = runTask
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await current?.value
                        guard !self.stopRequested else { return }
                        await self.onMoshFailure?()
                        self.start()
                    }
                    return
                }
            }
            status = .ended(Self.message(for: error))
            return
        }
        guard !stopRequested, !moshUpgradeRestartScheduled else { return }
        status = .ended("The session ended.")
    }

    private func consume(
        _ session: TerminalAttachSession,
        initialCols: Int,
        initialRows: Int
    ) async throws {
        defer { finishOutput() }
        if stopRequested {
            await session.end()
            return
        }
        self.session = session
        let inputGeneration = input.beginSession(
            writer: { data in session.send(data) },
            scroller: { sequence, rows in
                session.scroll(sequence, rows: rows)
            })
        self.inputGeneration = inputGeneration
        if let latestCols = cols, let latestRows = rows,
            latestCols != initialCols || latestRows != initialRows
        {
            // The view resized while the channel was coming up; catch the
            // remote PTY up to the latest geometry.
            session.resize(cols: latestCols, rows: latestRows)
        }

        do {
            for try await bytes in session.output {
                // Live when the new PTY Attach produces output, not when the
                // channel opens: the transport withholds the login shell's
                // noise, so an open channel with no output yet is still
                // connecting. This does not prove that a renderer presented
                // the bytes on screen.
                if status == .connecting {
                    status = .live
                }
                #if DEBUG
                restorationTrace.emit(.firstOutputBytes, generation: acquiredTransportGeneration)
                TerminalStreamCapture.shared.record(
                    surfaceID: surfaceID, generation: acquiredTransportGeneration, bytes: bytes)
                #endif
                observeOutput(bytes)
                feed.write(bytes)
            }
        } catch {
            finishSession(inputGeneration)
            throw error
        }
        #if DEBUG
        TerminalStreamCapture.shared.recordEvent(surfaceID: surfaceID, kind: "stream-end")
        #endif
        finishSession(inputGeneration)
    }

    private func finishSession(_ inputGeneration: TerminalInputController.SessionGeneration) {
        self.session = nil
        input.endSession(
            inputGeneration,
            preservingPendingPaste: preservesPendingPasteOnStop)
        if self.inputGeneration == inputGeneration {
            self.inputGeneration = nil
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.terminalChannelAlreadyOpen:
            "Another terminal is already open on this Host."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.moshSessionFailed(let detail):
            "The mosh session failed: \(detail)"
        case TransportError.herdrBinaryNotFound:
            TransportError.herdrBinaryNotFound.presentation.message
        default:
            "The session failed: \(error)"
        }
    }
}
