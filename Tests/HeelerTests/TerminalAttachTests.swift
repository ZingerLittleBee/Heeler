import Foundation
import GhosttyTerminal
import HeelerSSH
import Synchronization
import Testing
import UIKit

@testable import Heeler

/// The attach exec command (#11): the command sent as the PTY channel's exec
/// request. It must `exec` the attach process (so its exit ends the channel),
/// pin the herdr CLI to the Host's socket via `HERDR_SOCKET_PATH` (a
/// named-session target is "not found" on the default socket), quote the
/// target and socket safely, and refuse targets that cannot be quoted safely.
@Suite("Terminal attach")
struct TerminalAttachTests {
    private enum WriterProbeError: Error {
        case rejectedResize
    }

    private enum FakeAttachChannelError: Error {
        case rejectedWrite
    }

    private struct ReportedGrid: Equatable {
        let columns: Int
        let rows: Int
    }

    /// A pre-handoff resize can still be inside Ghostty's IO pipeline when the
    /// keyboard freeze begins, then arrive as if it belonged to the handoff.
    /// The settled surface grid must replace that stale deferred value.
    @MainActor
    @Test func aSettledSurfaceGridOverridesAStaleDeferredResize() async throws {
        var reportedGrids: [ReportedGrid] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(ReportedGrid(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)
        let stale = InMemoryTerminalViewport(columns: 33, rows: 20)

        bridge.beginSizeReportDeferral()
        await withCheckedContinuation { continuation in
            bridge.onViewport = { _ in continuation.resume() }
            bridge.resize(stale)
        }
        bridge.onViewport = nil
        bridge.provideAuthoritativeDeferredSize(columns: 33, rows: 14)
        bridge.finishSizeReportDeferral()
        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 33, rows: 14))
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
    }

    /// A freeze can thaw having learned no grid at all — nothing measured the
    /// surface while it held. That is a lifecycle outcome, not silence: the
    /// Host is told nothing and the next ordinary report speaks for it. The
    /// thaw has to say so, because a caller watching resize reports alone
    /// cannot tell it from a freeze that never ended (#263).
    @MainActor
    @Test func aThawWithNothingMeasuredForwardsNoGridAndSaysSo() async throws {
        var reportedGrids: [ReportedGrid] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(ReportedGrid(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        #expect(bridge.gridReportPhase == .deferring)
        bridge.finishSizeReportDeferral()

        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == nil)
        #expect(bridge.gridReportPhase == .live)
        #expect(reportedGrids.isEmpty)

        // Live again: the report that arrives next is the Host's first.
        await withCheckedContinuation { continuation in
            bridge.onViewport = { _ in continuation.resume() }
            bridge.resize(InMemoryTerminalViewport(columns: 33, rows: 14))
        }
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
    }

    /// A cancelled freeze forwards nothing: there was no settled grid, only a
    /// handoff that stopped happening.
    @MainActor
    @Test func aCancelledFreezeForwardsNoGrid() async throws {
        var reportedGrids: [ReportedGrid] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(ReportedGrid(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 33, rows: 14)
        bridge.cancelSizeReportDeferral()

        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == nil)
        #expect(reportedGrids.isEmpty)
    }

    /// Ghostty can publish the engine resize after the surface delegate has
    /// already supplied the settled fallback. A stale grid is rejected
    /// against the live surface, and its matching final callback is consumed
    /// as the fallback's duplicate rather than resizing the Host twice.
    @MainActor
    @Test func aSettledFallbackRejectsLateStaleAndDuplicateResizes() async throws {
        var reportedGrids: [ReportedGrid] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(ReportedGrid(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)
        bridge.isSizeReportCurrent = { columns, rows in
            columns == 33 && rows == 14
        }

        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 33, rows: 14)
        bridge.finishSizeReportDeferral()
        try await phases.thawedGrid()

        await withCheckedContinuation { continuation in
            bridge.onViewport = { _ in continuation.resume() }
            bridge.resize(InMemoryTerminalViewport(columns: 33, rows: 20))
            bridge.resize(InMemoryTerminalViewport(columns: 33, rows: 14))
        }
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
    }

    /// Thawing cannot overtake a post-freeze resize whose main-actor delivery
    /// is still queued, or the deferred final grid is silently lost.
    @MainActor
    @Test func aHandoffThawWaitsForItsQueuedResize() async throws {
        var reportedGrids: [ReportedGrid] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(ReportedGrid(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)
        let settled = InMemoryTerminalViewport(columns: 33, rows: 14)

        bridge.beginSizeReportDeferral()
        bridge.resize(settled)
        bridge.finishSizeReportDeferral()
        // The queued resize has not landed yet, so the thaw is still waiting
        // on it — the phase says so rather than the caller having to infer it.
        #expect(bridge.gridReportPhase == .flushing)
        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 33, rows: 14))
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
    }

    /// The barrier every freeze assertion here rests on, held to its own
    /// contract.
    ///
    /// A transition can land in the gap between "has it happened yet?" and
    /// "wake me when it does". `onWaitAboutToRegister` *is* that gap: the
    /// recorder calls it after the wait has searched its history and before
    /// the wait's waiter exists, so this thaw is published there by call
    /// position and not by which job an executor happens to run first.
    ///
    /// A recorder that answers the two questions in separate jobs has, by
    /// construction, registered nothing when this runs — `record` buffers the
    /// thaw against a waiter that does not exist — and never reads the buffer
    /// again from behind its registration. That recorder waits the thaw out
    /// to its deadline and reports a freeze that thawed correctly as a
    /// timeout, which is the failure this whole barrier exists to end.
    @MainActor
    @Test func aThawPublishedAsTheWaitBeginsIsStillClaimed() async throws {
        var reportedGrids: [ReportedGrid] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(ReportedGrid(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 33, rows: 14)
        phases.onWaitAboutToRegister = { bridge.finishSizeReportDeferral() }

        // The thaw is already history by the time this wait can suspend, and
        // the wait still has to come back with it rather than with a deadline.
        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 33, rows: 14))
        #expect(bridge.gridReportPhase == .live)
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
    }

    /// The same gap, from the other side: a wait whose phase never comes must
    /// still end at its deadline, and say which phase the freeze stopped at.
    /// A barrier that claimed a buffered transition it should not have, or
    /// resumed twice, shows up here rather than as a hang.
    @MainActor
    @Test func aPhaseThatNeverArrivesEndsAtItsDeadlineNamingThePhase() async throws {
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: nil,
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        // `.deferring` is in the history and `.live` never follows it, so the
        // wait below has nothing to claim and nothing to wake it.
        await #expect(throws: GridReportPhaseNeverReachedError.self) {
            try await phases.thawedGrid(within: .milliseconds(50))
        }
        #expect(phases.phases == [.deferring])
        #expect(bridge.gridReportPhase == .deferring)
    }

    @Test func attachOutputPumpWithholdsStartupChatterUntilTheHandshake() async throws {
        let chatter = Data("ssh rc startup chatter\r\n".utf8)
        let terminalFrame = Data("TUI".utf8)
        let channel = FakeAttachPTYChannel(
            reads: [chatter, AttachBootstrapHandshake.marker + terminalFrame, nil])
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()

        let cleanEnd = try await HeelerSSHTransport.runAttachPumps(
            channel: channel,
            input: input,
            output: source.gate,
            requestTimeout: .seconds(1),
            dropsStartupProbe: true)
        source.gate.finish()

        var iterator = source.output.makeAsyncIterator()
        #expect(cleanEnd)
        #expect(try await iterator.next() == terminalFrame)
        #expect(try await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func inputFailureFlushesWithheldStartupDiagnosticExactlyOnce() async throws {
        let diagnostic = Data("ssh rc rejected the attach command\r\n".utf8)
        let channel = FakeAttachPTYChannel(
            reads: [diagnostic],
            writeError: FakeAttachChannelError.rejectedWrite,
            blockAfterReads: true)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()
        let pump = Task {
            do {
                _ = try await HeelerSSHTransport.runAttachPumps(
                    channel: channel,
                    input: input,
                    output: source.gate,
                    requestTimeout: .seconds(1),
                    dropsStartupProbe: true)
                return "clean"
            } catch {
                return String(describing: error)
            }
        }

        await channel.waitUntilFirstRead()
        input.send(Data("x".utf8))
        let failure = await pump.value
        source.gate.finish()

        var iterator = source.output.makeAsyncIterator()
        #expect(failure.contains("input"))
        #expect(try await iterator.next() == diagnostic)
        #expect(try await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitCancellationDropsWithheldStartupChatter() async throws {
        let chatter = Data("ssh rc startup chatter\r\n".utf8)
        let channel = FakeAttachPTYChannel(
            reads: [chatter],
            blockAfterReads: true)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()
        let pump = Task {
            do {
                _ = try await HeelerSSHTransport.runAttachPumps(
                    channel: channel,
                    input: input,
                    output: source.gate,
                    requestTimeout: .seconds(1),
                    dropsStartupProbe: true)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await channel.waitUntilFirstRead()
        pump.cancel()
        #expect(await pump.value)
        source.gate.finish()

        var iterator = source.output.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }

    @Test func explicitEndDiscardsUnreadAndLaterLibSSH2Output() async throws {
        let source = HeelerSSHAttachOutputGate.makeStream()
        var iterator = source.output.makeAsyncIterator()

        source.gate.yield(Data("before-end".utf8))
        source.gate.beginExplicitEnd()
        source.gate.yield(Data("after-end".utf8))
        source.gate.finish()

        #expect(try await iterator.next() == nil)
    }

    @Test func cleanLibSSH2ExitDrainsAcceptedOutputBeforeFinishing() async throws {
        let source = HeelerSSHAttachOutputGate.makeStream()
        var iterator = source.output.makeAsyncIterator()
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        source.gate.yield(first)
        source.gate.yield(second)
        source.gate.finish()

        var drained = Data()
        while let chunk = try await iterator.next() {
            drained.append(chunk)
        }
        #expect(drained == first + second)
    }

    /// How an Attach output consumer finished, flattened so one `#expect`
    /// can separate "refused", "handed an ended stream", and "still hanging".
    private enum AttachConsumerOutcome: Equatable, Sendable {
        case drained([Data])
        case failed(String)
    }

    /// A second concurrent reader of one Attach session is a mistake in the
    /// UI layer — a departing SwiftUI iterator that outlived its view is the
    /// shape this app already shipped once (#97) — and killing the process
    /// over it is worse than the mistake (#137). The extra reader is refused
    /// where it stands, and the legitimate reader carries on.
    @Test(.timeLimit(.minutes(1)))
    func aSecondAttachOutputConsumerIsRefusedAndLeavesTheFirstRunning() async throws {
        let source = HeelerSSHAttachOutputGate.makeStream()
        let gate = source.gate
        let stream = source.output

        let first = Task { () -> AttachConsumerOutcome in
            var seen: [Data] = []
            do {
                for try await bytes in stream { seen.append(bytes) }
                return .drained(seen)
            } catch {
                return .failed(String(describing: error))
            }
        }
        let parked = await Self.waitForParkedConsumer(gate)
        #expect(parked, "the first consumer never parked on the gate")

        let second = Task { () -> AttachConsumerOutcome in
            var iterator = stream.makeAsyncIterator()
            do {
                guard let bytes = try await iterator.next() else { return .drained([]) }
                return .drained([bytes])
            } catch {
                return .failed(String(describing: error))
            }
        }
        let refusal = await Self.outcome(of: second)
        #expect(
            refusal == .failed(String(describing: TransportError.terminalChannelAlreadyOpen)),
            """
            the extra consumer must be refused, not trapped, ended, or left \
            hanging: \(String(describing: refusal))
            """)

        // Refusing it must leave the first consumer's registration alone:
        // it is still parked, and everything sent afterwards reaches it.
        #expect(
            gate.hasParkedConsumerForTesting,
            "refusing the extra consumer cleared the first consumer's waiter")
        let afterRefusal = Data("after-the-refusal".utf8)
        let stillFlowing = Data("still-flowing".utf8)
        gate.yield(afterRefusal)
        gate.yield(stillFlowing)
        gate.finish()
        let served = await Self.outcome(of: first)
        #expect(
            served == .drained([afterRefusal, stillFlowing]),
            """
            the first consumer must keep receiving output unaffected: \
            \(String(describing: served))
            """)
    }

    /// Buffered output still belongs to the task that first consumed this
    /// stream. A later task must not be able to take a ready chunk simply
    /// because the legitimate consumer is between reads (#153).
    @Test(.timeLimit(.minutes(1)))
    func aSecondAttachOutputConsumerIsRefusedWhileBytesAreStillBuffered() async throws {
        let source = HeelerSSHAttachOutputGate.makeStream()
        let gate = source.gate
        let stream = source.output
        let firstChunk = Data("chunk-a".utf8)
        let secondChunk = Data("chunk-b".utf8)

        gate.yield(firstChunk)

        // The first read establishes the legitimate consumer before more
        // output is buffered. This ordering catches a claim that is reset by
        // a later yield as well as a missing claim.
        var firstIterator = stream.makeAsyncIterator()
        let firstSeen = try await firstIterator.next()
        gate.yield(secondChunk)
        gate.finish()

        let second = Task { () -> AttachConsumerOutcome in
            var iterator = stream.makeAsyncIterator()
            do {
                guard let bytes = try await iterator.next() else { return .drained([]) }
                return .drained([bytes])
            } catch {
                return .failed(String(describing: error))
            }
        }
        let refusal = await Self.outcome(of: second)
        #expect(
            refusal == .failed(String(describing: TransportError.terminalChannelAlreadyOpen)),
            """
            a second consumer must be refused while bytes are buffered, not \
            handed one of them: \(String(describing: refusal))
            """)

        let secondSeen = try await firstIterator.next()
        let trailer = try await firstIterator.next()
        #expect(
            [firstSeen, secondSeen, trailer] == [firstChunk, secondChunk, nil],
            """
            the first consumer must receive every buffered byte in order: \
            \([firstSeen, secondSeen, trailer].map { $0.map { String(decoding: $0, as: UTF8.self) } })
            """)
    }

    /// A second consumer whose task is already cancelled reaches for the
    /// stream through cancellation handlers that run before any claim check
    /// can refuse it (#164): the unfolding stream's own handler clears the
    /// produce storage its iterators share, and the gate's handler is
    /// installed by every reader ahead of `next()`'s body. Neither door may
    /// end the legitimate consumer: sessions hand each reader its own
    /// stream, and the gate only honours a cancellation from its claimant.
    @Test(.timeLimit(.minutes(1)))
    func anAlreadyCancelledSecondConsumerCannotEndTheFirst() async throws {
        let gate = HeelerSSHAttachOutputGate()
        let session = TerminalAttachSession(
            output: gate.makeOutput,
            input: TerminalAttachInputQueue()
        ) {}

        let first = Task { () -> AttachConsumerOutcome in
            var seen: [Data] = []
            do {
                for try await bytes in session.output { seen.append(bytes) }
                return .drained(seen)
            } catch {
                return .failed(String(describing: error))
            }
        }
        let parked = await Self.waitForParkedConsumer(gate)
        #expect(parked, "the first consumer never parked on the gate")

        let second = Task { () -> AttachConsumerOutcome in
            // Reads only once its own task is already cancelled, so every
            // cancellation handler fires ahead of the read instead of
            // racing it.
            while !Task.isCancelled { await Task.yield() }
            var iterator = session.output.makeAsyncIterator()
            do {
                guard let bytes = try await iterator.next() else { return .drained([]) }
                return .drained([bytes])
            } catch {
                return .failed(String(describing: error))
            }
        }
        second.cancel()
        let refusal = await Self.outcome(of: second)
        #expect(
            refusal == .drained([]),
            """
            an already-cancelled extra consumer must end quietly with nil, \
            never with output: \(String(describing: refusal))
            """)

        // Its cancellation must not have reached the first consumer: the
        // waiter is still parked, and later output still arrives. Two
        // chunks, deliberately: a poisoned shared stream still hands over
        // the one read already in flight and only then ends, so a single
        // chunk cannot tell survival from silent early termination.
        #expect(
            gate.hasParkedConsumerForTesting,
            "the cancelled extra consumer cleared the first consumer's waiter")
        let afterCancellation = Data("after-the-cancellation".utf8)
        let stillFlowing = Data("still-flowing".utf8)
        gate.yield(afterCancellation)
        gate.yield(stillFlowing)
        gate.finish()
        let served = await Self.outcome(of: first)
        #expect(
            served == .drained([afterCancellation, stillFlowing]),
            """
            the first consumer must keep receiving output unaffected: \
            \(String(describing: served))
            """)
    }

    /// The ownership guard on the gate's cancellation path must not cost the
    /// claimant its own cancellation: cancelling the task that reads the
    /// stream still ends its iteration promptly.
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheClaimantsTaskStillEndsItsIteration() async throws {
        let source = HeelerSSHAttachOutputGate.makeStream()
        let gate = source.gate
        let stream = source.output

        let claimant = Task { () -> AttachConsumerOutcome in
            var seen: [Data] = []
            do {
                for try await bytes in stream { seen.append(bytes) }
                return .drained(seen)
            } catch {
                return .failed(String(describing: error))
            }
        }
        let parked = await Self.waitForParkedConsumer(gate)
        #expect(parked, "the claimant never parked on the gate")

        claimant.cancel()
        let ending = await Self.outcome(of: claimant)
        #expect(
            ending == .drained([]),
            """
            cancelling the claimant must end its own iteration without \
            error: \(String(describing: ending))
            """)
    }

    /// Polls until a consumer is registered on the gate, so the test enters
    /// the double-consumer window deterministically rather than by sleeping.
    private static func waitForParkedConsumer(
        _ gate: HeelerSSHAttachOutputGate,
        within limit: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if gate.hasParkedConsumerForTesting { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Awaits a consumer under a deadline and reports `nil` when it never
    /// settles. A bare `await task.value` would let a mutation that parks a
    /// consumer forever wedge the whole run instead of failing this test.
    private static func outcome(
        of task: Task<AttachConsumerOutcome, Never>,
        within limit: Duration = .seconds(5)
    ) async -> AttachConsumerOutcome? {
        let settled = Mutex<AttachConsumerOutcome?>(nil)
        let recorder = Task {
            let value = await task.value
            settled.withLock { $0 = value }
        }
        defer { recorder.cancel() }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let value = settled.withLock({ $0 }) { return value }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func writerPropagatesResizeFailure() async {
        let input = TerminalAttachInputQueue()
        input.resize(cols: 120, rows: 40)

        await #expect(throws: WriterProbeError.self) {
            try await input.pump(
                write: { _ in },
                resize: { _, _ in throw WriterProbeError.rejectedResize })
        }
    }

    /// An acknowledged write answers when the writer has written it, in the
    /// order of everything else in the queue.
    @Test func anAcknowledgedWriteReturnsOnceWrittenAndInOrder() async throws {
        let input = TerminalAttachInputQueue()
        let (written, onWrite) = AsyncStream.makeStream(of: Data.self)
        let (releases, release) = AsyncStream.makeStream(of: Void.self)
        let pump = Task {
            var nextRelease = releases.makeAsyncIterator()
            try await input.pump(
                write: { data in
                    onWrite.yield(data)
                    await nextRelease.next()
                },
                resize: { _, _ in })
        }
        defer { pump.cancel() }

        input.send(Data("a".utf8))
        let acknowledged = Task { try await input.sendAcknowledged(Data("b".utf8)) }
        var seen = written.makeAsyncIterator()
        #expect(await seen.next() == Data("a".utf8))
        release.yield()
        #expect(await seen.next() == Data("b".utf8))
        release.yield()
        try await acknowledged.value
        input.finish()
    }

    @Test func anAcknowledgedWriteThrowsWhatTheWriterThrew() async {
        let input = TerminalAttachInputQueue()
        let pump = Task {
            try await input.pump(
                write: { _ in throw TransportError.coreMutationOutcomeUnknown }, resize: { _, _ in })
        }
        defer { pump.cancel() }
        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await input.sendAcknowledged(Data("a".utf8))
        }
    }

    /// Bytes no writer will take: queued behind a write that failed, or sent
    /// after the session ended, hear so rather than wait.
    @Test func anAcknowledgedWriteThatNeverLeftSaysSo() async {
        let input = TerminalAttachInputQueue()
        let (entered, onEnter) = AsyncStream.makeStream(of: Void.self)
        let (fails, fail) = AsyncStream.makeStream(of: Void.self)
        let pump = Task {
            var nextFailure = fails.makeAsyncIterator()
            try await input.pump(
                write: { _ in
                    onEnter.yield()
                    await nextFailure.next()
                    throw WriterProbeError.rejectedResize
                },
                resize: { _, _ in })
        }
        defer { pump.cancel() }

        let writing = Task { try await input.sendAcknowledged(Data("a".utf8)) }
        var didEnter = entered.makeAsyncIterator()
        await didEnter.next()
        let queued = Task { try await input.sendAcknowledged(Data("b".utf8)) }
        // The second write has joined the queue once this one follows it.
        await Task.yield()
        fail.yield()

        await #expect(throws: WriterProbeError.self) { try await writing.value }
        await #expect(throws: TerminalAttachInputError.self) { try await queued.value }
        await #expect(throws: TerminalAttachInputError.sessionEnded) {
            try await input.sendAcknowledged(Data("c".utf8))
        }
    }

    @Test func anAcknowledgedWriteAfterFinishIsRefused() async {
        let input = TerminalAttachInputQueue()
        input.finish()
        await #expect(throws: TerminalAttachInputError.sessionEnded) {
            try await input.sendAcknowledged(Data("a".utf8))
        }
    }

    @Test func reliableInputDiscardsPendingScrollMomentum() async {
        let input = TerminalAttachInputQueue()
        let scroll = Data("scroll".utf8)
        let key = Data("x".utf8)

        input.scroll(scroll, rows: 60)
        input.send(key)

        #expect(await input.next() == .keystrokes(key))
        input.finish()
        #expect(await input.next() == nil)
    }

    @Test func scrollDirectionChangeReplacesPendingMomentum() async {
        let input = TerminalAttachInputQueue()
        let older = Data("older".utf8)
        let newer = Data("newer".utf8)

        input.scroll(older, rows: 8)
        input.scroll(newer, rows: 2)

        #expect(await input.next() == .scroll(newer + newer))
        input.finish()
    }

    @Test func scrollBacklogIsBoundedAndWrittenInSmallBatches() async {
        let input = TerminalAttachInputQueue()
        let sequence = Data("wheel".utf8)
        let batch = sequence + sequence + sequence

        input.scroll(sequence, rows: 60)

        for _ in 0..<4 {
            #expect(await input.next() == .scroll(batch))
        }
        input.finish()
        #expect(await input.next() == nil)
    }

    @Test func coalescedScrollKeepsItsOriginalExpiry() async {
        let clock = Mutex(ContinuousClock.now)
        let input = TerminalAttachInputQueue(now: { clock.withLock { $0 } })
        defer { input.finish() }
        let wheel = Data("wheel".utf8)
        input.scroll(wheel, rows: 5)
        clock.withLock { $0 += .milliseconds(199) }
        input.scroll(wheel, rows: 2)
        #expect(await input.next() == .scroll(wheel + wheel + wheel))

        // Neither coalescing nor sending a batch may renew the remaining rows.
        clock.withLock { $0 += .milliseconds(1) }
        input.scroll(wheel, rows: 2)
        #expect(await input.next() == .scroll(wheel + wheel))
    }

    @Test func responderGateRefusesGhosttysTouchDrivenChanges() {
        var gate = TerminalKeyboardResponderGate()
        gate.beginUserDrivenChange(wantsKeyboard: true)
        gate.endUserDrivenChange()

        gate.directTouchesBegan(1)
        #expect(!gate.mayBecomeFirstResponder)
        #expect(!gate.mayResignFirstResponder)

        gate.directTouchesEnded(1)
        #expect(gate.mayBecomeFirstResponder)
        #expect(gate.mayResignFirstResponder)
    }

    /// The input-row tap and the accessory's dismiss button both fire while
    /// their own touch may still be active, so user-driven changes pass the
    /// gate mid-touch.
    @Test func responderGatePassesUserDrivenChangesMidTouch() {
        var gate = TerminalKeyboardResponderGate()
        gate.directTouchesBegan(1)

        gate.beginUserDrivenChange(wantsKeyboard: true)
        #expect(gate.mayBecomeFirstResponder)
        gate.endUserDrivenChange()

        gate.beginUserDrivenChange(wantsKeyboard: false)
        #expect(gate.mayResignFirstResponder)
        gate.endUserDrivenChange()

        #expect(!gate.mayBecomeFirstResponder)
    }

    @Test func keyboardTapTargetCoversOnlyTheCurrentInputRow() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.region(
            caretRect: CGRect(x: 72, y: 650, width: 9, height: 20),
            in: bounds)

        #expect(region == CGRect(x: 0, y: 638, width: 390, height: 44))
        #expect(region.contains(CGPoint(x: 20, y: 660)))
        #expect(!region.contains(CGPoint(x: 20, y: 500)))
    }

    /// The alternate-screen band stays caret-centred, just three times as
    /// tall — wide enough for the whole bordered input box #90 measured.
    @Test func alternateScreenTapTargetTriplesTheCaretBand() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.region(
            caretRect: CGRect(x: 72, y: 400, width: 9, height: 20),
            in: bounds,
            minimumHeight: TerminalKeyboardTapTarget.alternateScreenMinimumHeight)

        #expect(region == CGRect(x: 0, y: 344, width: 390, height: 132))
    }

    @Test func keyboardTapTargetKeepsItsMinimumHeightAtTheViewportEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.region(
            caretRect: CGRect(x: 72, y: 700, width: 9, height: 20),
            in: bounds,
            minimumHeight: TerminalKeyboardTapTarget.alternateScreenMinimumHeight)

        #expect(region == CGRect(x: 0, y: 588, width: 390, height: 132))
    }

    /// Every chat-style agent TUI pins its input box to the bottom rows, but
    /// each parks the caret somewhere of its own, so the bottom quarter is
    /// the tool-agnostic floor the caret band cannot be.
    @Test func alternateScreenBottomQuarterIsAlwaysATapTarget() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: bounds)

        #expect(region == CGRect(x: 0, y: 540, width: 390, height: 180))
        #expect(TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: .zero).isNull)
    }

    /// A dismissal is the case that has to be exact, so it does not wait on
    /// anything: SwiftUI's own avoidance retracted in two stages, the second
    /// landing a third of a second after the keyboard had gone, which cost the
    /// terminal a second reflow, a second PTY resize, and a visibly late TUI
    /// redraw.
    @MainActor
    @Test func aDismissalDropsTheKeyboardInsetInOneStep() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        // Past the presentation's coalescing window, however slow the runner.
        try #require(await Self.eventually { inset.height == 402 })
        #expect(inset.lastPresentedHeight == 402)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// A hardware keyboard attaching while the Composer is focused hides the
    /// software keyboard without resigning first responder, so the Composer
    /// stays `.system`. The pin to the last presented height must follow
    /// that genuine dismissal to zero, or the detail keeps a keyboard-sized
    /// empty band; the next presentation restores the pin.
    @MainActor
    @Test func aConfirmedDismissalReleasesTheSystemPinUntilTheNextPresentation() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { frame in
            frame.height == 403 ? 383 : 48.5
        }
        let fullFrame = CGRect(x: 0, y: 973, width: 1032, height: 403)

        try await Self.present(fullFrame, on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 383 })
        #expect(Self.systemContentInset(inset) == 383)

        // The sequence captured on the iPad simulator when the hardware
        // keyboard reconnects: the assistant bar's frame, then will-hide.
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 1307.5, width: 1032, height: 68.5)])
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 383)
        // Unconfirmed: a transient will-hide still keeps the pin.
        #expect(inset.isConfirmingDismissal)
        #expect(Self.systemContentInset(inset) == 383)

        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(Self.systemContentInset(inset) == 0)
        #expect(inset.lastPresentedHeight == 383)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: fullFrame])
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(!inset.isConfirmingDismissal)
        #expect(Self.systemContentInset(inset) == 383)
        try #require(await clock.pass(TerminalKeyboardInset.coalesceDelay))
        try #require(await Self.eventually { inset.height == 383 })
        #expect(Self.systemContentInset(inset) == 383)
    }

    /// Swapping input views (Tools→iOS) publishes a will-hide immediately
    /// followed by a will-show. That hide must not release the pin, or the
    /// terminal dips to zero for a frame and resizes twice.
    @MainActor
    @Test func aWillHideAnsweredByAPresentationKeepsTheSystemPin() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 383 }
        let frame = CGRect(x: 0, y: 973, width: 1032, height: 403)

        try await Self.present(frame, on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 383 })
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.isConfirmingDismissal)
        try #require(await clock.parks(for: TerminalKeyboardInset.dismissalConfirmationDelay))
        try await Self.present(frame, on: center, clock: clock)

        // The presentation cancelled the only timer that could confirm.
        #expect(!inset.isConfirmingDismissal)
        try #require(await Self.eventually { inset.height == 383 })
        #expect(clock.advance(TerminalKeyboardInset.dismissalConfirmationDelay) == 0)
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(Self.systemContentInset(inset) == 383)
    }

    /// Composer Tools installs a zero-height input view, so UIKit really hides
    /// the keyboard and the dismissal is confirmed. Returning to the system
    /// keyboard expects it again: the pre-show pin must come back before
    /// UIKit's frame arrives, and lapse if nothing presents (hardware
    /// keyboard attached).
    @MainActor
    @Test func expectingTheSoftwareKeyboardRestoresThePinUntilItFailsToPresent() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 383 }

        try await Self.presentThenHide(inset, center: center, clock: clock)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })

        inset.expectSoftwareKeyboard()
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(Self.systemContentInset(inset) == 383)

        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(Self.systemContentInset(inset) == 0)
    }

    /// Direct Input measured the keyboard, a hardware keyboard reconnects
    /// (will-hide, terminal still first responder), and the user selects the
    /// Composer before the dismissal is confirmed. The handoff freeze must
    /// carry that dismissal and settle it when its fallback expires, even
    /// though UIKit posts no second hide inside the handoff.
    @MainActor
    @Test func aHideBeforeAHandoffIsSettledByItsFallback() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 383 }
        try await Self.presentThenHide(inset, center: center, clock: clock)

        var expiredID: UUID?
        let handoffID = inset.beginResponderHandoff(currentHeight: { 0 }) {
            expiredID = $0
        }
        // The Composer takes first responder, but with a hardware keyboard
        // no frame settles it.
        inset.acceptResponderHandoff(handoffID)
        #expect(!inset.isConfirmingDismissal)
        #expect(!inset.isSoftwareKeyboardDismissed)
        // Composer's `.system` pin still holds while the freeze is active.
        #expect(Self.systemContentInset(inset) == 383)

        try #require(await clock.pass(TerminalKeyboardInset.responderHandoffFallbackDelay))
        try #require(await Self.eventually { expiredID == handoffID })
        #expect(!inset.isHoldingHandoffHeight)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(inset.height == 0)
        #expect(Self.systemContentInset(inset) == 0)
    }

    /// A confirmation that expires while a handoff is holding must not be
    /// dropped: the cancel path settles it against the window measurement.
    @MainActor
    @Test func aConfirmationExpiringWhileHoldingIsSettledOnCancel() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 383 }
        try await Self.presentThenHide(inset, center: center, clock: clock)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })

        let handoffID = inset.beginResponderHandoff()
        // Composer takes focus inside the freeze and expects the keyboard;
        // with a hardware keyboard nothing presents.
        inset.expectSoftwareKeyboard()
        #expect(inset.isConfirmingDismissal)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { !inset.isConfirmingDismissal })
        #expect(inset.isHoldingHandoffHeight)
        #expect(!inset.isSoftwareKeyboardDismissed)

        inset.cancelResponderHandoff(handoffID, currentHeight: { 0 })
        #expect(!inset.isHoldingHandoffHeight)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(Self.systemContentInset(inset) == 0)
    }

    /// Ending a handoff (the destination's settle or its own timeout) with no
    /// second hide still settles a carried dismissal: against the window's
    /// zero height, or, without a window, against the frozen zero inset. A
    /// keyboard measured up again restores the inset instead.
    @MainActor
    @Test(arguments: [CGFloat?.some(0), nil, 383])
    func endingAHandoffWithoutASecondHideSettlesTheCarriedDismissal(
        measured: CGFloat?
    ) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 383 }
        try await Self.presentThenHide(inset, center: center, clock: clock)

        // Entry precondition, checked in the same synchronous section as
        // the begin: the dismissal is still pending, not already confirmed.
        try #require(inset.isConfirmingDismissal)
        try #require(!inset.isSoftwareKeyboardDismissed)
        let handoffID = inset.beginDestinationOwnedResponderHandoff()
        #expect(!inset.isConfirmingDismissal)
        inset.endResponderHandoff(handoffID, currentHeight: { measured })
        #expect(!inset.isHoldingHandoffHeight)

        if measured == 383 {
            #expect(inset.height == 383)
            #expect(!inset.isConfirmingDismissal)
            #expect(!inset.isSoftwareKeyboardDismissed)
            #expect(Self.systemContentInset(inset) == 383)
        } else {
            #expect(inset.height == 0)
            // The end re-armed the confirmation the begin had carried.
            #expect(inset.isConfirmingDismissal)
            #expect(!inset.isSoftwareKeyboardDismissed)
            try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
            try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
            #expect(Self.systemContentInset(inset) == 0)
        }
    }

    /// After a confirmed dismissal nothing is owed, yet the software keyboard
    /// can come back during a Direct-to-Composer freeze (a hardware keyboard
    /// detaches mid-transfer). Its frame is discarded while holding, so every
    /// exit must adopt the keyboard the window measures, or the Composer
    /// stays below a visible keyboard.
    @MainActor
    @Test(arguments: ["end", "cancel", "fallback"])
    func aKeyboardPresentedDuringAHandoffAfterAConfirmedDismissalIsAdoptedOnExit(
        exit: String
    ) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 383 }
        try await Self.presentThenHide(inset, center: center, clock: clock)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(!inset.isConfirmingDismissal)

        let handoffID =
            exit == "end"
            ? inset.beginDestinationOwnedResponderHandoff(currentHeight: { 383 })
            : inset.beginResponderHandoff(currentHeight: { 383 })
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 973, width: 1032, height: 403)])
        // Discarded by the freeze.
        #expect(inset.height == 0)
        #expect(inset.isSoftwareKeyboardDismissed)

        switch exit {
        case "end":
            inset.endResponderHandoff(handoffID, currentHeight: { 383 })
        case "cancel":
            inset.cancelResponderHandoff(handoffID, currentHeight: { 383 })
        default:
            try #require(await clock.pass(TerminalKeyboardInset.responderHandoffAcceptanceDelay))
            try #require(await Self.eventually { !inset.isHoldingHandoffHeight })
        }

        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 383)
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(!inset.isConfirmingDismissal)
        #expect(Self.systemContentInset(inset) == 383)
    }

    /// A hardware keyboard detaching while the Composer keeps focus: the
    /// software keyboard presents with no handoff and no new expectation,
    /// after the focus-time hide was already confirmed. The presentation
    /// must clear the confirmed dismissal and apply its height.
    @MainActor
    @Test func aPresentationAfterAConfirmedHardwareKeyboardDismissalAppliesItsHeight()
        async throws
    {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(
            center: center, clock: clock, measure: Self.iPadProPortraitCoverage)

        try await Self.focusWithHardwareKeyboard(inset, center: center, clock: clock)

        let softwareKeyboard = CGRect(x: 0, y: 973, width: 1032, height: 403)
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: softwareKeyboard])
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: softwareKeyboard])
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(!inset.isConfirmingDismissal)
        try #require(await clock.pass(TerminalKeyboardInset.coalesceDelay))
        try #require(await Self.eventually { inset.height == 383 })
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(Self.systemContentInset(inset) == 383)
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: .system).contentInset == 383)
    }

    /// The order the iPad simulator's own log recorded for the regression:
    /// after the focus-time hide was confirmed, detaching the hardware
    /// keyboard posted `willShow` with the keyboard's size but an origin at
    /// the screen's bottom edge, while the keyboard layout guide already
    /// covered 403 pt. That frame measures zero and is dropped; the did-show
    /// has to settle against the window, or the Composer (and a Shell
    /// Terminal) stays under a visible keyboard.
    @MainActor
    @Test func aPresentationPublishedBelowTheScreenSettlesAgainstTheWindowOnDidShow()
        async throws
    {
        let center = NotificationCenter()
        let clock = ManualClock()
        var windowKeyboardHeight: CGFloat? = 0
        let inset = Self.makeInset(
            center: center, clock: clock,
            measure: Self.iPadProPortraitCoverage,
            measureWindowKeyboard: { windowKeyboardHeight })

        try await Self.focusWithHardwareKeyboard(inset, center: center, clock: clock)

        windowKeyboardHeight = 383
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 1376, width: 1032, height: 403)])
        #expect(inset.height == 0)
        #expect(inset.isSoftwareKeyboardDismissed)

        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == 383)
        #expect(inset.lastPresentedHeight == 383)
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(!inset.isConfirmingDismissal)
        #expect(Self.systemContentInset(inset) == 383)
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: .system).contentInset == 383)
    }

    /// The did-show reconciliation is only for a dropped presentation. A
    /// measured frame stays authoritative over the layout guide, and a
    /// below-screen frame answered by a will-hide is a dismissal.
    @MainActor
    @Test func aDidShowLeavesMeasuredPresentationsAndDismissalsAlone() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        var windowKeyboardHeight: CGFloat? = 300
        let inset = Self.makeInset(
            center: center, clock: clock,
            measure: Self.iPadProPortraitCoverage,
            measureWindowKeyboard: { windowKeyboardHeight })

        try await Self.present(
            CGRect(x: 0, y: 973, width: 1032, height: 403), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 383 })
        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == 383)

        windowKeyboardHeight = 383
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 1376, width: 1032, height: 403)])
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.isConfirmingDismissal)
    }

    /// Back from the Notification Center, an iPhone kept a frame covering the
    /// bottom of the window with no keyboard on screen and nothing after it.
    /// The scene's activation settles the inset against the window.
    @MainActor
    @Test func activationDismissesAHeightTheWindowShowsNoKeyboardFor() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
        let inset = Self.makeInset(
            center: center, clock: clock,
            measure: {
                TerminalKeyboardInset.insetHeight(
                    covered: phone.intersection($0).height, bottomSafeArea: 34)
            },
            measureWindowKeyboard: { 0 })

        try await Self.present(
            CGRect(x: 0, y: 781, width: 402, height: 328), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 59 })
        #expect(inset.keyboardRideTarget > 0)

        center.post(name: UIScene.didActivateNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.keyboardRideTarget == 0)
        #expect(inset.isConfirmingDismissal)
    }

    /// Focusing the Composer with a hardware keyboard attached, as the iPad
    /// simulator publishes it: a zero-height frame at the bottom edge, then
    /// will-hide, confirmed.
    @MainActor
    private static func focusWithHardwareKeyboard(
        _ inset: TerminalKeyboardInset, center: NotificationCenter, clock: ManualClock
    ) async throws {
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 1376, width: 1032, height: 0)])
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        try #require(await clock.pass(TerminalKeyboardInset.dismissalConfirmationDelay))
        try #require(await eventually { inset.isSoftwareKeyboardDismissed })
        #expect(systemContentInset(inset) == 0)
    }

    /// `coveredHeight(of:in:)` for a full-screen portrait iPad Pro 13-inch
    /// window: 1032 x 1376 pt with a 20 pt bottom safe area.
    @MainActor
    private static func iPadProPortraitCoverage(_ frame: CGRect) -> CGFloat? {
        let window = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        return TerminalKeyboardInset.insetHeight(
            covered: window.intersection(frame).height, bottomSafeArea: 20)
    }

    @MainActor
    private static func presentThenHide(
        _ inset: TerminalKeyboardInset, center: NotificationCenter, clock: ManualClock
    ) async throws {
        try await present(
            CGRect(x: 0, y: 973, width: 1032, height: 403), on: center, clock: clock)
        try #require(await eventually { inset.height == 383 })
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.isConfirmingDismissal)
    }

    /// A terminal destination's own handoff timeout, which the Agent passes
    /// on when the terminal accepts.
    private static let terminalLeash = HeelerTerminalView.keyboardTransitionFallbackDelay

    /// An inset whose timers all wait on `clock`, so only the test moves
    /// time: a deadline it does not pass never fires, however slow the
    /// runner.
    @MainActor
    private static func makeInset(
        center: NotificationCenter,
        clock: ManualClock,
        measure: @escaping @MainActor (CGRect) -> CGFloat?,
        measureWindowKeyboard: (@MainActor () -> CGFloat?)? = nil
    ) -> TerminalKeyboardInset {
        TerminalKeyboardInset(
            notificationCenter: center,
            measure: measure,
            measureWindowKeyboard: measureWindowKeyboard,
            sleep: clock.parkedSleep(for:),
            handoffSleep: clock.parkedSleep(for:))
    }

    /// Presents a keyboard ending at `frame` and passes the presentation's
    /// coalesce. The height lands once the inset's timer runs.
    @MainActor
    private static func present(
        _ frame: CGRect, on center: NotificationCenter, clock: ManualClock
    ) async throws {
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
        try #require(await clock.pass(TerminalKeyboardInset.coalesceDelay))
    }

    @MainActor
    private static func systemContentInset(_ inset: TerminalKeyboardInset) -> CGFloat {
        AgentComposerKeyboardLayout(
            currentHeight: inset.height,
            lastPresentedHeight: inset.lastPresentedHeight,
            presentation: .system,
            softwareKeyboardDismissed: inset.isSoftwareKeyboardDismissed
        ).contentInset
    }

    /// Polls instead of sleeping a fixed time, so a loaded runner cannot
    /// outlast a hard-coded margin.
    @MainActor
    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        var budget = PollBudget(timeout)
        while budget.hasTimeLeft {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }
        return condition()
    }

    /// Removing the Chinese candidate row publishes a shorter positive frame
    /// before the system keyboard finishes hiding. The app-owned Tools dock
    /// must retain the complete measurement instead of adopting that transient
    /// height and exposing a gap.
    @MainActor
    @Test func toolsModeIgnoresCandidateRowTransitionFrames() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { frame in
            frame.height == 436 ? 402 : 365
        }
        let completeFrame = CGRect(x: 0, y: 554, width: 440, height: 436)
        let withoutCandidateRow = CGRect(x: 0, y: 591, width: 440, height: 399)

        try await Self.present(completeFrame, on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 402 })

        inset.pauseHeightCapture()
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: withoutCandidateRow])
        // The shorter frame is dropped as it arrives: nothing rides it, and
        // no coalesce waits to land it.
        #expect(inset.keyboardRideTarget == 402)
        #expect(clock.advance(TerminalKeyboardInset.coalesceDelay) == 0)
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 402)

        inset.resumeHeightCapture()
        try await Self.present(completeFrame, on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 402 })
    }

    /// A presentation moves the ride at once and the height only after its
    /// coalesce. Switching to Tools inside that window lands the presentation
    /// instead of dropping it, so the dock keeps the keyboard that was on
    /// screen and the ride stays with the height.
    @MainActor
    @Test func pausingCaptureLandsAPresentationStillCoalescing() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { frame in
            frame.height == 436 ? 402 : 365
        }
        let completeFrame = CGRect(x: 0, y: 554, width: 440, height: 436)
        let withoutCandidateRow = CGRect(x: 0, y: 591, width: 440, height: 399)

        try await Self.present(withoutCandidateRow, on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 365 })

        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: completeFrame])
        try #require(await clock.parks(for: TerminalKeyboardInset.coalesceDelay))
        #expect(inset.keyboardRideTarget == 402)
        #expect(inset.height == 365)

        inset.pauseHeightCapture()
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)
        #expect(inset.keyboardRideTarget == 402)
    }

    /// Moving a visible system keyboard between Composer and Direct Input can
    /// emit a transient hide followed by a smaller frame. Neither may move the
    /// app-owned chrome before the destination responder settles.
    @MainActor
    @Test func responderHandoffKeepsTheKeyboardInsetAtItsSettledHeight() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { frame in
            frame.height == 436 ? 402 : 365
        }
        let completeFrame = CGRect(x: 0, y: 554, width: 440, height: 436)
        let transientFrame = CGRect(x: 0, y: 591, width: 440, height: 399)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: completeFrame])
        try #require(await Self.eventually { inset.height == 402 })

        let handoffID = inset.beginResponderHandoff()
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: transientFrame])

        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)

        inset.endResponderHandoff(UUID())
        #expect(inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)

        inset.endResponderHandoff(handoffID)
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// Composer autocorrect raises a candidate bar that Direct Input never
    /// shows, so the keyboard changes height while it changes hands. Its
    /// resized frame lands inside the freeze and is dropped; the settle must
    /// adopt the keyboard the window measures, or the input chrome keeps the
    /// candidate bar's gap (or sits under the taller keyboard) until the next
    /// presentation. A matching keyboard keeps the frozen height.
    @MainActor
    @Test(arguments: [CGFloat(375), 402, 429])
    func endingAHandoffAdoptsTheSettledKeyboardHeight(measured: CGFloat) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 402 }
        try await Self.present(
            CGRect(x: 0, y: 554, width: 440, height: 436), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 402 })

        let handoffID = inset.beginDestinationOwnedResponderHandoff()
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 581, width: 440, height: 409)])
        #expect(inset.height == 402)

        inset.endResponderHandoff(handoffID, currentHeight: { measured })
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == measured)
        #expect(inset.lastPresentedHeight == measured)
        #expect(!inset.isConfirmingDismissal)
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(Self.systemContentInset(inset) == measured)
    }

    /// A scene transition can emit will-hide without a matching did-frame.
    /// The Composer has no timeout of its own once it accepts, so the owner's
    /// fallback must release the hold, notify its owner, and reconcile a hide
    /// that never received a destination frame. With no window to measure,
    /// the hide is trusted either side of acceptance, as it would be with no
    /// handoff.
    @MainActor
    @Test(arguments: [true, false])
    func responderHandoffFallbackReleasesAnUnsettledFreeze(accepted: Bool) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 402 }

        try await Self.present(
            CGRect(x: 0, y: 554, width: 440, height: 436), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 402 })

        var ownerHandoffID: UUID?
        var expiredHandoffID: UUID?
        let handoffID = inset.beginResponderHandoff(onFallback: { expiredID in
            expiredHandoffID = expiredID
            if ownerHandoffID == expiredID {
                ownerHandoffID = nil
            }
        })
        ownerHandoffID = handoffID
        if accepted {
            inset.acceptResponderHandoff(handoffID)
        }
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try #require(await clock.pass(
            accepted
                ? TerminalKeyboardInset.responderHandoffFallbackDelay
                : TerminalKeyboardInset.responderHandoffAcceptanceDelay))
        try #require(await Self.eventually { expiredHandoffID == handoffID })

        #expect(!inset.isHoldingHandoffHeight)
        #expect(ownerHandoffID == nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// Keyboard notifications are process-wide on iPad. A hide from another
    /// scene must not clear this scene's still-visible keyboard footprint.
    @MainActor
    @Test func responderHandoffFallbackUsesTheOwningWindowHeight() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 402 }

        try await Self.present(
            CGRect(x: 0, y: 554, width: 440, height: 436), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 402 })

        let handoffID = inset.beginResponderHandoff(currentHeight: { 402 })
        inset.acceptResponderHandoff(handoffID)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try #require(await clock.pass(TerminalKeyboardInset.responderHandoffFallbackDelay))
        try #require(await Self.eventually { !inset.isHoldingHandoffHeight })

        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// The owner's guard from the switch only waits for the destination to
    /// accept. On a slow main thread that can take over a second, longer than
    /// the destination's own timeout, and the destination is then still
    /// settling: a release there exposes the transient frames the freeze
    /// holds back (a will-hide applies zero at once) and drops the settle
    /// that measures the keyboard the destination kept (#634). Accepting
    /// hands the timing to the destination: the terminal's own leash, and
    /// for the Composer, which has none, the owner's fallback from then on.
    @MainActor
    @Test(arguments: ["Composer to Direct Input", "Direct Input to Composer"])
    func anAcceptedDestinationKeepsTheFreezeUntilItSettles(handoff: String) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 294 }
        try await Self.present(
            CGRect(x: 0, y: 546, width: 402, height: 328), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 294 })

        var expiredID: UUID?
        let toDirectInput = handoff == "Composer to Direct Input"
        let handoffID: UUID
        if toDirectInput {
            handoffID = inset.beginDestinationOwnedResponderHandoff(currentHeight: { 267 }) {
                expiredID = $0
            }
        } else {
            handoffID = inset.beginResponderHandoff(currentHeight: { 267 }) { expiredID = $0 }
        }
        // The request reaches the destination a moment before the switch's
        // guard would expire.
        let acceptance = TerminalKeyboardInset.responderHandoffAcceptanceDelay
        try #require(await clock.parks(for: acceptance))
        clock.advance(acceptance - .milliseconds(1))
        if toDirectInput {
            inset.acceptResponderHandoff(handoffID, destinationTimeout: Self.terminalLeash)
        } else {
            inset.acceptResponderHandoff(handoffID)
        }
        try #require(await clock.parks(
            for: toDirectInput
                ? Self.terminalLeash + TerminalKeyboardInset.destinationResponderHandoffGrace
                : TerminalKeyboardInset.responderHandoffFallbackDelay))
        // Past the switch's guard, UIKit publishes a transient hide.
        #expect(clock.advance(.milliseconds(2)) == 0, "the switch's guard outlived the acceptance")
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)

        #expect(expiredID == nil)
        #expect(inset.isHoldingHandoffHeight)
        #expect(inset.height == 294)

        // The destination's settle still ends the handoff, on the keyboard
        // it kept.
        inset.endResponderHandoff(handoffID, currentHeight: { 267 })
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 267)
        #expect(!inset.isConfirmingDismissal)
        #expect(!inset.isSoftwareKeyboardDismissed)
    }

    /// The Composer's request can reach it late too. Its timeout starts when
    /// it accepts, not at the switch, so a slow request does not undo the
    /// switch before the Composer could take the keyboard.
    @MainActor
    @Test func theComposersTimeoutStartsWhenItAccepts() async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 267 }
        try await Self.present(
            CGRect(x: 0, y: 573, width: 402, height: 301), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 267 })

        var expiredID: UUID?
        let handoffID = inset.beginResponderHandoff(currentHeight: { 294 }) {
            expiredID = $0
        }
        // The request arrives a moment before the guard that waits for it
        // expires, long past the Composer's own timeout from the switch.
        let acceptance = TerminalKeyboardInset.responderHandoffAcceptanceDelay
        let timeout = TerminalKeyboardInset.responderHandoffFallbackDelay
        try #require(await clock.parks(for: acceptance))
        #expect(clock.advance(acceptance - .milliseconds(1)) == 0)
        #expect(expiredID == nil)
        #expect(inset.isHoldingHandoffHeight)

        inset.acceptResponderHandoff(handoffID)
        try #require(await clock.parks(for: timeout))
        // Past the switch's guard, which the acceptance replaced.
        #expect(clock.advance(timeout - .milliseconds(1)) == 0)
        #expect(inset.isHoldingHandoffHeight)
        #expect(clock.advance(.milliseconds(1)) == 1)
        try #require(await Self.eventually { expiredID == handoffID })
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 294)
    }

    /// A destination can disappear before it reports an outcome: before it
    /// ever received the request, or after accepting it, when its weakly
    /// captured timeout can no longer fire. The owner's guard catches both,
    /// past the destination's own timeout once it accepted, so that loss
    /// cannot leave the shared handoff token frozen forever.
    @MainActor
    @Test(arguments: ["before accepting", "after accepting"])
    func destinationLossFallsBackThroughTheInsetOwner(lost: String) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in 402 }
        try await Self.present(
            CGRect(x: 0, y: 554, width: 440, height: 436), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == 402 })

        var expiredID: UUID?
        let handoffID = inset.beginDestinationOwnedResponderHandoff(
            currentHeight: { nil }
        ) { expiredID = $0 }
        let guardDelay: Duration
        if lost == "after accepting" {
            inset.acceptResponderHandoff(handoffID, destinationTimeout: Self.terminalLeash)
            guardDelay = Self.terminalLeash + TerminalKeyboardInset.destinationResponderHandoffGrace
        } else {
            guardDelay = TerminalKeyboardInset.responderHandoffAcceptanceDelay
        }
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try #require(await clock.parks(for: guardDelay))
        #expect(clock.advance(guardDelay - .milliseconds(1)) == 0)
        #expect(inset.isHoldingHandoffHeight)
        clock.advance(.milliseconds(1))
        try #require(await Self.eventually { expiredID == handoffID })

        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
    }

    /// The keyboard can change height inside the freeze (the Composer's
    /// candidate bar going or coming, #629), and a destination that accepted
    /// can still be lost before it settles. The frame that changed it was
    /// discarded while holding, so the fallback adopts the keyboard the
    /// window measures, as the destination's settle would have.
    @MainActor
    @Test(arguments: ["destination watchdog", "owner fallback"])
    func aFallbackAdoptsTheKeyboardTheWindowMeasures(fallback: String) async throws {
        let center = NotificationCenter()
        // Composer to Direct Input drops the candidate bar; the way back
        // raises it.
        let (frozen, measured): (CGFloat, CGFloat) =
            fallback == "owner fallback" ? (267, 294) : (294, 267)
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { _ in frozen }
        try await Self.present(
            CGRect(x: 0, y: 546, width: 402, height: 328), on: center, clock: clock)
        try #require(await Self.eventually { inset.height == frozen })

        var expiredID: UUID?
        let handoffID: UUID
        let guardDelay: Duration
        if fallback == "owner fallback" {
            handoffID = inset.beginResponderHandoff(currentHeight: { measured }) {
                expiredID = $0
            }
            inset.acceptResponderHandoff(handoffID)
            guardDelay = TerminalKeyboardInset.responderHandoffFallbackDelay
        } else {
            handoffID = inset.beginDestinationOwnedResponderHandoff(
                currentHeight: { measured }
            ) { expiredID = $0 }
            inset.acceptResponderHandoff(handoffID, destinationTimeout: Self.terminalLeash)
            guardDelay = Self.terminalLeash + TerminalKeyboardInset.destinationResponderHandoffGrace
        }
        try #require(await clock.pass(guardDelay))
        try #require(await Self.eventually { expiredID == handoffID })

        #expect(!inset.isHoldingHandoffHeight)
        try #require(await Self.eventually { inset.height == measured })
        #expect(inset.lastPresentedHeight == measured)
        #expect(!inset.isSoftwareKeyboardDismissed)
    }

    /// A presentation moves the ride at once and the height only after its
    /// coalesce. A handoff that begins inside that window drops the
    /// coalesce, so the ride returns to the height the freeze holds. An end
    /// that measures that same height then moves nothing; a ride left on the
    /// dropped frame kept the Agent switcher off the keyboard by the
    /// difference, 27pt above it (#634). A cancel lands the presentation the
    /// freeze cut short instead, ride and height together, as it would have
    /// landed without the handoff.
    @MainActor
    @Test(arguments: ["end", "cancel"])
    func aHandoffInsideAPresentationCoalesceKeepsTheRideWithTheHeight(
        exit: String
    ) async throws {
        let center = NotificationCenter()
        let clock = ManualClock()
        let inset = Self.makeInset(center: center, clock: clock) { frame in
            frame.height == 328 ? 294 : 267
        }
        func present(height: CGFloat) {
            center.post(
                name: UIResponder.keyboardWillShowNotification, object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                        x: 0, y: 874 - height, width: 402, height: height),
                    UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                ])
        }
        present(height: 328)
        try #require(await clock.pass(TerminalKeyboardInset.coalesceDelay))
        try #require(await Self.eventually { inset.height == 294 })
        #expect(inset.keyboardRideRaise == 294)

        present(height: 301)
        #expect(inset.keyboardRideRaise == 267)
        #expect(inset.height == 294)
        try #require(await clock.parks(for: TerminalKeyboardInset.coalesceDelay))
        // An end measures the destination's keyboard, here the frozen
        // height; a cancel leaves the outgoing responder's.
        let settled: CGFloat = exit == "end" ? 294 : 267
        let handoffID = inset.beginResponderHandoff(currentHeight: { settled })
        if exit == "end" {
            inset.endResponderHandoff(handoffID, currentHeight: { settled })
        } else {
            inset.cancelResponderHandoff(handoffID, currentHeight: { settled })
        }

        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == settled)
        #expect(inset.keyboardRideRaise == settled)
        // The dropped coalesce does not land later either.
        #expect(clock.advance(TerminalKeyboardInset.coalesceDelay) == 0)
        #expect(inset.height == settled)
        #expect(inset.keyboardRideRaise == settled)
    }

    @MainActor
    @Test func responderHandoffCancellationUsesTheOwningWindowHeight() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try #require(await Self.eventually { inset.height == 402 })

        let handoffID = inset.beginResponderHandoff()
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        inset.cancelResponderHandoff(handoffID, currentHeight: { 402 })

        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)
    }

    @Test func agentKeyboardReplacementKeepsTheTerminalInsetStable() {
        let system = AgentComposerKeyboardLayout(
            currentHeight: 402, lastPresentedHeight: 402,
            presentation: .system)
        let toolsBeforeUIKitHides = AgentComposerKeyboardLayout(
            currentHeight: 402, lastPresentedHeight: 402,
            presentation: .tools)
        let toolsAfterUIKitHides = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 402,
            presentation: .tools)
        // The pre-show pin holds only while the dismissal is unconfirmed;
        // see aConfirmedDismissalReleasesTheSystemPinUntilTheNextPresentation.
        let systemBeforeUIKitShows = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 402,
            presentation: .system, softwareKeyboardDismissed: false)

        #expect(system == AgentComposerKeyboardLayout(
            currentHeight: 402, lastPresentedHeight: 402,
            presentation: .hidden))
        #expect(toolsBeforeUIKitHides.contentInset == 402)
        #expect(system.availableToolsHeight == 402)
        #expect(systemBeforeUIKitShows.contentInset == 402)
        #expect([
            system, toolsBeforeUIKitHides, toolsAfterUIKitHides,
            systemBeforeUIKitShows,
        ].map(\.contentInset) == [402, 402, 402, 402])
    }

    /// Blocked Send presents tools before any software keyboard has been
    /// measured. A zero dock would hide Enter/Esc; the layout must still
    /// reserve a usable height and lift Composer by the same amount.
    @Test func toolsPresentationUsesAMinimumHeightWhenTheKeyboardWasNeverMeasured() {
        let cold = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 0,
            presentation: .tools)
        #expect(cold.availableToolsHeight == AgentComposerKeyboardLayout.minimumToolsHeight)
        #expect(cold.contentInset == AgentComposerKeyboardLayout.minimumToolsHeight)
        #expect(cold.availableToolsHeight > 0)

        let hidden = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 0,
            presentation: .hidden)
        #expect(hidden.contentInset == 0)
        #expect(hidden.availableToolsHeight == 0)

        let measured = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 402,
            presentation: .tools)
        #expect(measured.availableToolsHeight == 402)
        #expect(measured.contentInset == 402)
    }

    /// A real measurement below the cold fallback (landscape, 224pt controls
    /// keyboard) must stay exact in both modes. Clamping it up to 260 would
    /// move Composer and resize Ghostty's grid.
    @Test func aMeasuredHeightBelowTheFallbackKeepsTheSystemFootprintInTools() {
        let measured: CGFloat = 224
        #expect(measured < AgentComposerKeyboardLayout.minimumToolsHeight)
        let system = AgentComposerKeyboardLayout(
            currentHeight: measured, lastPresentedHeight: measured,
            presentation: .system)
        let toolsWhileKeyboardIsUp = AgentComposerKeyboardLayout(
            currentHeight: measured, lastPresentedHeight: measured,
            presentation: .tools)
        let toolsAfterUIKitHides = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: measured,
            presentation: .tools)

        #expect(system.contentInset == measured)
        #expect(toolsWhileKeyboardIsUp.contentInset == measured)
        #expect(toolsAfterUIKitHides.contentInset == measured)
        #expect(toolsWhileKeyboardIsUp.availableToolsHeight == measured)
        #expect(toolsAfterUIKitHides.availableToolsHeight == measured)
        #expect(system.contentInset == toolsWhileKeyboardIsUp.contentInset)
        #expect(system.contentInset == toolsAfterUIKitHides.contentInset)
    }

    /// UIKit measures the input accessory after the keyboard itself, so a
    /// presentation can arrive as two frames. The terminal must not resize
    /// twice on the way up either.
    @MainActor
    @Test func aPresentationsFollowUpFrameFoldsIntoTheFirst() async throws {
        let center = NotificationCenter()
        var measured: [CGFloat] = [314, 402]
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in
            measured.isEmpty ? nil : measured.removeFirst()
        }
        var observedHeights: [CGFloat] = []
        let observation = Task { @MainActor in
            var last = inset.height
            while !Task.isCancelled {
                if inset.height != last {
                    last = inset.height
                    observedHeights.append(last)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { observation.cancel() }

        let frame = CGRect(x: 0, y: 554, width: 440, height: 436)
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])

        // Until the observer has seen the final height, not a fixed wait: a
        // busy runner can hold the coalesced apply past any fixed sleep.
        try #require(await Self.eventually { observedHeights.last == 402 })
        #expect(inset.height == 402)
        #expect(observedHeights == [402], "the terminal resized more than once: \(observedHeights)")
    }

    /// The keyboard's frame is measured from the bottom of the screen; the
    /// terminal stops at the home indicator. Not subtracting that safe area
    /// left a strip of background between the last row and the toolbar.
    @Test func theKeyboardInsetExcludesTheHomeIndicatorSafeArea() {
        #expect(TerminalKeyboardInset.insetHeight(covered: 436, bottomSafeArea: 34) == 402)
        #expect(TerminalKeyboardInset.insetHeight(covered: 436, bottomSafeArea: 0) == 436)
        #expect(TerminalKeyboardInset.insetHeight(covered: 20, bottomSafeArea: 34) == 0)
    }

    @Test func agentQuickKeysKeepTheirLabels() {
        #expect(AgentQuickKey.shiftEnter.title == "⇧Enter")
        #expect(AgentQuickKey.enter.title == "Enter")
        #expect(AgentQuickKey.backspace.title == "Backspace")
        #expect(AgentQuickKey.enter.systemImageName == nil)
        #expect(AgentQuickKey.backspace.systemImageName == nil)
    }

    @Test func terminalModeTrackerHandlesSplitAndRepeatedModeChanges() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data([0x1B, 0x5B]))
        tracker.receive(Data([0x3F, 0x31, 0x68]))
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("noise\u{1B}[?1lmore\u{1B}[?1h".utf8))
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("\u{1B}[?1l".utf8))
        #expect(!tracker.usesApplicationCursorKeys)
    }

    @Test func terminalModeTrackerEncodesMouseAndAlternateScreenScrolling() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?1049h\u{1B}[?1002;1006h".utf8))

        #expect(tracker.isAlternateScreen)
        #expect(tracker.tracksMouse)
        #expect(tracker.usesSGRMouseEncoding)
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: true,
                columns: 80,
                rows: 24)
                == Data("\u{1B}[<64;40;12M".utf8))
        // A pointer aims the report at its own cell.
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: false,
                columns: 80,
                rows: 24,
                at: (column: 5, row: 3))
                == Data("\u{1B}[<65;5;3M".utf8))

        tracker.receive(Data("\u{1B}[?1002;1006l".utf8))
        #expect(!tracker.tracksMouse)
        #expect(!tracker.usesSGRMouseEncoding)
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: false,
                columns: 80,
                rows: 24)
                == Data([0x1B, 0x5B, 0x42]))

        tracker.receive(Data("\u{1B}[?1049l".utf8))
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: true,
                columns: 80,
                rows: 24) == nil)
    }

    @Test func touchScrollAccumulatorPreservesSubrowMovementAndDirectionChanges() {
        var accumulator = TerminalTouchScrollAccumulator()

        #expect(accumulator.rows(for: 7, pointsPerRow: 16) == 0)
        #expect(accumulator.rows(for: 10, pointsPerRow: 16) == 1)
        #expect(accumulator.rows(for: -15, pointsPerRow: 16) == 0)
        #expect(accumulator.rows(for: -2, pointsPerRow: 16) == -1)
    }

    @Test func injectableAttachCommandRidesThrough() throws {
        // Tests substitute a script at the environment boundary, like the
        // wake command.
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "/bin/sh /tmp/fake-attach.sh",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        #expect(
            command == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$2\"; "
                + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
                + "exec /bin/sh /tmp/fake-attach.sh \"$1\"' attach "
                + "'w1:p1' '/tmp/fake.sock'")
    }

    @Test func execUsesTheSocketScopeAndTakeoverFlag() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(
                target: "w1:p1",
                takeover: true,
                cols: 80,
                rows: 24),
            socketPath: "/home/u/.config/herdr/sessions/dev/herdr.sock")

        #expect(
            command == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$2\"; "
                + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
                + "exec herdr agent attach \"$1\" --takeover' attach "
                + "'w1:p1' '/home/u/.config/herdr/sessions/dev/herdr.sock'")
        // An exec request, not a line typed into a shell: no trailing newline.
        #expect(!command.hasSuffix("\n"))
    }

    @Test func terminalTargetSelectsTerminalAttachWithTheSameBootstrapAndSocketScope() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .terminal("terminal-123"),
                takeover: true,
                cols: 80,
                rows: 24),
            socketPath: "/home/u/.config/herdr/sessions/dev/herdr.sock")

        #expect(command.contains(HerdrHostPath.pathExport))
        #expect(command.contains("export HERDR_SOCKET_PATH=\"$2\""))
        #expect(command.contains(AttachBootstrapHandshake.markerPrintfFormat))
        #expect(command.contains("exec herdr terminal attach \"$1\" --takeover"))
        #expect(command.contains("'terminal-123'"))
        #expect(!command.contains("exec herdr agent attach"))
    }

    @Test(arguments: [
        "", "w1'p1", #"w1\p1"#, "w1\np1", "w1\rp1", "w1\u{1B}p1",
    ])
    func unquotableTargetsAreRefused(target: String) {
        // A Pane id with quotes or control characters could only come from a
        // hostile server; refusing beats handing it a shell.
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.attachExecCommand(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: target, cols: 80, rows: 24),
                socketPath: "/tmp/fake.sock")
        }
    }

    @Test func unquotableSocketPathsAreRefused() {
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.attachExecCommand(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
                socketPath: "/tmp/it's-a.sock")
        }
    }

    /// The attach exec path must emit the handshake marker immediately before
    /// `herdr agent attach`. Without it, the pure gate tests below can pass
    /// while production still lacks the marker that opens it (#166).
    @Test func attachExecCommandWiresTheBootstrapHandshakeMarker() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        let markerPrintf = "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\";"
        #expect(command.contains(markerPrintf))
        // Marker is the last thing before exec of attach, not after it.
        let printfRange = try #require(command.range(of: markerPrintf))
        let execRange = try #require(command.range(of: "exec herdr agent attach"))
        #expect(printfRange.upperBound <= execRange.lowerBound)
    }

    @Test func attachExit127OnBareHerdrIsAMissingBinary() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 127, attachCommand: "herdr agent attach")
                == .herdrBinaryNotFound)
    }

    @Test func attachExit127OnAnInjectableCommandStaysAnAttachExit() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 127, attachCommand: "/bin/sh /tmp/fake-attach.sh")
                == .attachExited(status: 127, output: nil))
    }

    @Test func attachExit127OnAnAbsoluteHerdrStaysAnAttachExit() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 127,
                attachCommand: "/nonexistent/herdr agent attach")
                == .attachExited(status: 127, output: nil))
    }

    @Test func attachNonzeroExitBesides127IsAnAttachExitWithItsOutput() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 1,
                output: "herdr: lost connection to server: server closed connection",
                attachCommand: "herdr agent attach")
                == .attachExited(
                    status: 1,
                    output: "herdr: lost connection to server: server closed connection"))
    }

    /// A bare `herdr` that is missing stays the PATH problem even when the
    /// shell said so on the way out (#206).
    @Test func attachExit127OnBareHerdrIgnoresTheShellsOutput() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 127,
                output: "sh: 1: exec: herdr: not found",
                attachCommand: "herdr agent attach")
                == .herdrBinaryNotFound)
    }

    /// Today's full ordinary-terminal string, so the endpoint branch cannot
    /// drift it.
    @Test func terminalAttachWithoutAnEndpointKeepsItsFullString() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .terminal("terminal-123"),
                takeover: true,
                cols: 80,
                rows: 24),
            socketPath: "/home/u/.config/herdr/sessions/dev/herdr.sock")

        #expect(
            command == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$2\"; "
                + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
                + "exec herdr terminal attach \"$1\" --takeover' attach "
                + "'terminal-123' '/home/u/.config/herdr/sessions/dev/herdr.sock'")
    }

    private static let endpointSocketPath =
        "/Users/ada/Library/Application Support/Example/herdr/herdr.sock"
    private static let endpointLauncherPath =
        "/Users/ada/Library/Application Support/Example/bin/herdr"

    private func endpointLauncher() throws -> HerdrLauncher {
        try #require(
            HerdrLauncher(
                executablePath: Self.endpointLauncherPath,
                socketPath: Self.endpointSocketPath))
    }

    /// A herdr endpoint (ADR 0023) attaches through its own launcher: no PATH
    /// export, the launcher is `$3`, and the injected command is ignored.
    @Test func endpointAgentAttachRunsTheLauncher() throws {
        let launcher = try endpointLauncher()
        let command = try HeelerSSHTransport.attachExecCommand(
            agentAttachCommand: "/bin/sh /tmp/fake-attach.sh",
            terminalAttachCommand: "/bin/sh /tmp/fake-terminal.sh",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: Self.endpointSocketPath,
            launcher: launcher)

        #expect(
            command == "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
                + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
                + "exec \"$3\" agent attach \"$1\"' attach 'w1:p1' "
                + "'/Users/ada/Library/Application Support/Example/herdr/herdr.sock' "
                + "'/Users/ada/Library/Application Support/Example/bin/herdr'")
    }

    @Test func endpointTerminalAttachRunsTheLauncherWithTakeover() throws {
        let launcher = try endpointLauncher()
        let command = try HeelerSSHTransport.attachExecCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .terminal("terminal-123"),
                takeover: true,
                cols: 80,
                rows: 24),
            socketPath: Self.endpointSocketPath,
            launcher: launcher)

        #expect(
            command == "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
                + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
                + "exec \"$3\" terminal attach \"$1\" --takeover' attach 'terminal-123' "
                + "'/Users/ada/Library/Application Support/Example/herdr/herdr.sock' "
                + "'/Users/ada/Library/Application Support/Example/bin/herdr'")
        #expect(!command.contains(HerdrHostPath.pathExport))
    }

    @Test func endpointAttachKeepsTheTargetAndSocketValidation() throws {
        let launcher = try endpointLauncher()
        for target in ["", "w1'p1", #"w1\p1"#, "w1\np1"] {
            #expect(throws: TransportError.self) {
                _ = try HeelerSSHTransport.attachExecCommand(
                    attachCommand: "herdr agent attach",
                    request: TerminalAttachRequest(target: target, cols: 80, rows: 24),
                    socketPath: Self.endpointSocketPath,
                    launcher: launcher)
            }
        }
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.attachExecCommand(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
                socketPath: "/tmp/it's/herdr/herdr.sock",
                launcher: launcher)
        }
    }

    @Test func endpointAttachExit126Or127IsAMissingLauncher() throws {
        let launcher = try endpointLauncher()
        for exitStatus: Int32 in [126, 127] {
            #expect(
                HeelerSSHTransport.attachFailure(
                    HeelerSSHAttachPumpError.remoteExit(exitStatus, output: "not found"),
                    attachCommand: "herdr agent attach",
                    launcher: launcher)
                    == .herdrLauncherNotFound(path: Self.endpointLauncherPath))
        }
        #expect(
            HeelerSSHTransport.attachFailure(
                HeelerSSHAttachPumpError.remoteExit(23, output: "no such pane"),
                attachCommand: "herdr agent attach", launcher: launcher)
                == .attachExited(status: 23, output: "no such pane"))
    }

    @Test func attachPumpsReportARemoteExitStatus() async throws {
        let channel = FakeAttachPTYChannel(reads: [nil], remoteExitStatus: 127)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()

        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: input,
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: true)
            Issue.record("exit 127 should fail the attach pumps")
        } catch HeelerSSHAttachPumpError.remoteExit(let status, let output) {
            #expect(status == 127)
            #expect(output == nil)
        }
    }

    /// An old herdr earlier on the SSH PATH draws its frame, leaves the
    /// alternate screen, prints why it lost the server, and exits 1. The
    /// failure quotes that line, and the terminal still got every byte (#431).
    @Test func attachPumpsQuoteHerdrsLastLineOnANonzeroExit() async throws {
        let frame = Data("\u{1B}[?1049h\u{1B}[2Jsecret frame".utf8)
        let farewell = Data(
            "\u{1B}[?1049l\u{1B}[31mherdr: lost connection to server: server closed connection\u{1B}[0m\r\n"
                .utf8)
        let channel = FakeAttachPTYChannel(
            reads: [AttachBootstrapHandshake.marker + frame, farewell, nil],
            remoteExitStatus: 1)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()

        var thrown: (any Error)?
        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: input,
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: true)
            Issue.record("exit 1 should fail the attach pumps")
        } catch {
            thrown = error
        }
        source.gate.finish()

        let error = try #require(thrown)
        let expected = "herdr: lost connection to server: server closed connection"
        guard case .remoteExit(1, let output)? = error as? HeelerSSHAttachPumpError else {
            Issue.record("unexpected pump failure: \(error)")
            return
        }
        #expect(output == expected)
        #expect(
            HeelerSSHTransport.attachFailure(error, attachCommand: "herdr agent attach")
                == .attachExited(status: 1, output: expected))
        var iterator = source.output.makeAsyncIterator()
        var drained = Data()
        while let chunk = try await iterator.next() {
            drained.append(chunk)
        }
        #expect(drained == frame + farewell)
    }

    /// A command that dies before the handshake is quoted from the startup
    /// diagnostic the gate hands back.
    @Test func attachPumpsQuoteAStartupFailureBeforeTheHandshake() async throws {
        let diagnostic = Data("bash: /etc/profile.d/x.sh: Permission denied\r\n".utf8)
        let channel = FakeAttachPTYChannel(reads: [diagnostic, nil], remoteExitStatus: 2)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()

        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: input,
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: true)
            Issue.record("exit 2 should fail the attach pumps")
        } catch HeelerSSHAttachPumpError.remoteExit(let status, let output) {
            #expect(status == 2)
            #expect(output == "bash: /etc/profile.d/x.sh: Permission denied")
        }
        source.gate.finish()

        var iterator = source.output.makeAsyncIterator()
        #expect(try await iterator.next() == diagnostic)
        #expect(try await iterator.next() == nil)
    }

    /// With no marker, herdr never ran and the filter is not involved: the
    /// startup diagnostic reaches the terminal and the failure as it always
    /// did, probe-shaped bytes included.
    @Test func aStartupFailureBeforeTheHandshakeKeepsProbeShapedBytes() async throws {
        let diagnostic = HerdrAttachOutput.probe
            + Data("bash: /etc/profile.d/x.sh: Permission denied\r\n".utf8)
        let channel = FakeAttachPTYChannel(reads: [diagnostic, nil], remoteExitStatus: 2)
        let source = HeelerSSHAttachOutputGate.makeStream()

        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: TerminalAttachInputQueue(),
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: true)
            Issue.record("exit 2 should fail the attach pumps")
        } catch HeelerSSHAttachPumpError.remoteExit(let status, let output) {
            #expect(status == 2)
            #expect(output == "bash: /etc/profile.d/x.sh: Permission denied")
        }
        source.gate.finish()

        #expect(try await Self.joined(source.output) == diagnostic)
    }

    /// herdr 0.9.4 sets the terminal up, probe included, before its
    /// handshake, so a handshake failure arrives wrapped in the alternate
    /// screen. The failure still quotes herdr's last line, and the terminal
    /// gets everything but the probe, however the reads split it.
    @Test func herdr094sHandshakeFailureIsStillQuoted() async throws {
        let expected = #"Error: Custom { kind: Other, error: "lost connection to server: server closed connection" }"#
        var unexpected: [String] = []
        let deliveries = Self.deliveries(
            of: AttachBootstrapHandshake.marker + HerdrAttachOutput.herdr094LostServer)
        for delivery in deliveries {
            let channel = FakeAttachPTYChannel(
                reads: delivery.reads.map(Optional.some) + [nil],
                remoteExitStatus: 1)
            let source = HeelerSSHAttachOutputGate.makeStream()
            var quoted: String?
            do {
                _ = try await HeelerSSHTransport.runAttachPumps(
                    channel: channel,
                    input: TerminalAttachInputQueue(),
                    output: source.gate,
                    requestTimeout: .seconds(1),
                    dropsStartupProbe: true)
            } catch HeelerSSHAttachPumpError.remoteExit(1, let output) {
                quoted = output
            }
            source.gate.finish()
            let output = try await Self.joined(source.output)
            if quoted != expected || output != HerdrAttachOutput.herdr094LostServerWithoutProbe {
                unexpected.append(delivery.name)
            }
        }
        #expect(unexpected == [], "\(unexpected.count) of \(deliveries.count): \(unexpected.prefix(3))")
    }

    /// The Windows controller reports its own reason as a `TransportError`;
    /// Attach hands it on as is instead of nesting its debug description in
    /// another channel failure.
    @Test func aTransportErrorFromTheChannelReachesTheCallerUnwrapped() async throws {
        let reason = TransportError.channelFailed(detail: "terminal controller: gone")
        let channel = FakeAttachPTYChannel(reads: [], readError: reason)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()

        var thrown: (any Error)?
        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: input,
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: false)
            Issue.record("a read failure should fail the attach pumps")
        } catch {
            thrown = error
        }
        source.gate.finish()

        let error = try #require(thrown)
        #expect(
            HeelerSSHTransport.attachFailure(error, attachCommand: "herdr agent attach")
                == reason)
        #expect(
            HeelerSSHTransport.attachFailure(reason, attachCommand: "herdr agent attach")
                == reason)
    }

    /// SSH failures take the Transport's operation mapping, not their case
    /// name; one the mapping leaves unclassified names only the side that
    /// failed.
    @Test func attachIOFailuresTakeTheTransportsSSHMapping() {
        let command = "herdr agent attach"
        #expect(
            HeelerSSHTransport.attachFailure(
                HeelerSSHAttachPumpError.output(SSHError.connectionInvalidated),
                attachCommand: command)
                == .sshUnreachable(detail: "The SSH connection is no longer reusable."))
        #expect(
            HeelerSSHTransport.attachFailure(
                HeelerSSHAttachPumpError.input(SSHError.timedOut),
                attachCommand: command)
                == .timedOut)
        #expect(
            HeelerSSHTransport.attachFailure(
                HeelerSSHAttachPumpError.output(SSHError.channelFailed),
                attachCommand: command)
                == .channelFailed(detail: "attach channel failed"))
        #expect(
            HeelerSSHTransport.attachFailure(
                HeelerSSHAttachPumpError.input(SSHError.connectionFailed),
                attachCommand: command)
                == .channelFailed(detail: "attach input failed"))
        #expect(
            HeelerSSHTransport.attachFailure(
                HeelerSSHAttachPumpError.input(FakeAttachChannelError.rejectedWrite),
                attachCommand: command)
                == .channelFailed(detail: "attach input: rejectedWrite"))
    }

    /// A dead SSH connection under a live terminal marks the Transport
    /// disconnected, as any other operation's failure does; a remote exit or
    /// an ordinary channel failure leaves the connection alone.
    @Test func attachIOFailuresOnADeadConnectionInvalidateIt() {
        #expect(
            HeelerSSHTransport.invalidatesConnection(
                HeelerSSHAttachPumpError.output(SSHError.connectionInvalidated)))
        #expect(
            HeelerSSHTransport.invalidatesConnection(
                HeelerSSHAttachPumpError.input(SSHError.connectionInvalidated)))
        #expect(HeelerSSHTransport.invalidatesConnection(SSHError.connectionInvalidated))
        #expect(
            !HeelerSSHTransport.invalidatesConnection(
                HeelerSSHAttachPumpError.output(SSHError.channelFailed)))
        #expect(
            !HeelerSSHTransport.invalidatesConnection(
                HeelerSSHAttachPumpError.remoteExit(1, output: nil)))
        #expect(
            !HeelerSSHTransport.invalidatesConnection(
                HeelerSSHAttachPumpError.output(
                    TransportError.channelFailed(detail: "terminal controller: gone"))))
    }

    @Test func diagnosticQuotesHerdrsLineAfterItLeavesTheAlternateScreen() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(Data("chatter before the TUI\r\n".utf8))
        diagnostic.record(Data("\u{1B}[?1049h\u{1B}[Hpassword: hunter2\r\n".utf8))
        diagnostic.record(Data("\u{1B}[?1049l".utf8))
        diagnostic.record(
            Data("herdr: lost connection to server: server closed connection\r\n".utf8))
        #expect(diagnostic.line == "herdr: lost connection to server: server closed connection")
    }

    @Test func diagnosticPrefersClapsErrorLineOverItsHelpHint() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(
            Data(
                ("\u{1B}[1m\u{1B}[31merror:\u{1B}[0m unrecognized subcommand 'terminal'\n\n"
                    + "Usage: herdr [OPTIONS] [COMMAND]\n\n"
                    + "For more information, try '--help'.\n").utf8))
        #expect(diagnostic.line == "error: unrecognized subcommand 'terminal'")
    }

    @Test func diagnosticSkipsTheRustBacktraceNote() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(
            Data(
                ("thread 'main' panicked at src/client.rs:42:9:\n"
                    + "called `Result::unwrap()` on an `Err` value: BrokenPipe\n"
                    + "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n")
                    .utf8))
        #expect(diagnostic.line == "called `Result::unwrap()` on an `Err` value: BrokenPipe")
    }

    @Test func diagnosticQuotesNothingFromInsideTheAlternateScreen() {
        for mode in ["1049", "1047", "47", "1006;1049"] {
            var diagnostic = AttachExitDiagnostic()
            diagnostic.record(Data("error: before the screen\r\n".utf8))
            diagnostic.record(Data("\u{1B}[?\(mode)h".utf8))
            diagnostic.record(Data("error: token sk-live-123 on screen\r\n".utf8))
            #expect(diagnostic.line == nil, "mode \(mode)")
        }
    }

    @Test func diagnosticQuotesTheLastLineWhenTheScreenWasNeverEntered() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(Data("first line\r\nsecond line\r\n\r\n".utf8))
        #expect(diagnostic.line == "second line")
    }

    @Test func diagnosticFollowsAModeSwitchSplitAcrossChunks() {
        let output = Data(
            "\u{1B}[?1049hscreen\u{1B}[?1049lherdr: server went away\n".utf8)
        for split in 1..<output.count {
            var diagnostic = AttachExitDiagnostic()
            diagnostic.record(Data(output.prefix(split)))
            diagnostic.record(Data(output.suffix(from: split)))
            #expect(diagnostic.line == "herdr: server went away", "split at \(split)")
        }
        var stillInside = AttachExitDiagnostic()
        stillInside.record(Data("before\n\u{1B}[?10".utf8))
        stillInside.record(Data("49hsecret".utf8))
        #expect(stillInside.line == nil)
    }

    @Test func diagnosticStripsEscapesControlsAndBidiFormatting() {
        let output =
            "\u{1B}]0;title\u{07}\u{1B}]8;;https://x\u{1B}\\herdr:\u{1B}[1m boom\u{1B}[0m"
            + "\u{1B}P1$r0m\u{1B}\\\u{1B}_apc\u{1B}\\\u{1B}(B\u{08}\u{9B}\u{85}"
            + " \u{202E}evil\u{202C}\u{2066}\u{200F}\u{061C}done\n"
        #expect(AttachExitDiagnostic.line(fromOutput: output) == "herdr: boom evildone")
    }

    @Test func diagnosticKeepsOnlyTheTailOfALongStream() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(Data("error: an early line that scrolls away\n".utf8))
        let filler = Data(String(repeating: "progress line\n", count: 1_000).utf8)
        #expect(filler.count > 2 * AttachExitDiagnostic.maximumRetainedBytes)
        diagnostic.record(filler)
        diagnostic.record(Data("final words\n".utf8))
        #expect(diagnostic.line == "final words")
    }

    /// Output from before the TUI is not "since the last leave": a stale
    /// error line printed before the screen loses to herdr's later farewell,
    /// even one without an error prefix.
    @Test func diagnosticForgetsOutputFromBeforeTheScreen() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(Data("error: stale warning\r\n".utf8))
        diagnostic.record(Data("\u{1B}[?1049hscreen".utf8))
        diagnostic.record(Data("\u{1B}[?1049l".utf8))
        diagnostic.record(Data("Connection closed\r\n".utf8))
        #expect(diagnostic.line == "Connection closed")
    }

    /// Once the tail is trimmed, its first line is a fragment cut mid-way and
    /// is never quoted, even when it is the only line left.
    @Test func diagnosticNeverQuotesTheFragmentLeftByTrimming() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(Data(String(repeating: "x", count: 9_000).utf8))
        diagnostic.record(Data("\n".utf8))
        #expect(diagnostic.line == nil)
    }

    @Test func diagnosticTruncatesALongLineWithAnEllipsis() {
        let long = String(repeating: "x", count: 300)
        let line = AttachExitDiagnostic.line(fromOutput: "herdr: \(long)\n")
        #expect(line?.count == AttachExitDiagnostic.maximumLineLength)
        #expect(line?.hasPrefix("herdr: xxx") == true)
        #expect(line?.hasSuffix("x…") == true)
    }

    @Test func diagnosticHasNoLineForWhitespaceOnlyOutput() {
        var diagnostic = AttachExitDiagnostic()
        diagnostic.record(Data(" \t\r\n\u{1B}[0m\r\n  ".utf8))
        #expect(diagnostic.line == nil)
        #expect(AttachExitDiagnostic().line == nil)
    }

    @Test func gateWithholdsStartupChatterUntilTheHandshake() {
        var gate = AttachBootstrapGate()
        // Literal escape text in startup chatter has no ESC bytes, so it cannot
        // open the gate.
        let noise = Data(
            ("ssh rc startup chatter\r\n"
                + #"literal printf "\033_heeler-attach\033\134" text"#
                + "\r\n").utf8)
        #expect(gate.admit(noise).isEmpty)
        #expect(!gate.isOpen)

        let opened = gate.admit(AttachBootstrapHandshake.marker + Data("\u{1B}[2JTUI".utf8))
        #expect(gate.isOpen)
        #expect(opened == Data("\u{1B}[2JTUI".utf8))
        // Open for good: no rescanning, no second handshake.
        #expect(gate.admit(Data("more".utf8)) == Data("more".utf8))
        #expect(gate.flush().isEmpty)
    }

    @Test func gateMatchesAHandshakeSplitAcrossChunks() {
        var gate = AttachBootstrapGate()
        let marker = AttachBootstrapHandshake.marker
        for index in 1..<marker.count {
            var split = AttachBootstrapGate()
            #expect(split.admit(Data(marker.prefix(index))).isEmpty)
            #expect(split.admit(Data(marker.suffix(from: index)) + Data("go".utf8))
                == Data("go".utf8))
        }
        // And byte by byte, the worst case a slow link can produce.
        for byte in marker {
            #expect(gate.admit(Data([byte])).isEmpty)
        }
        #expect(gate.isOpen)
    }

    @Test func gateHandsBackTheStartupDiagnosticWhenTheHandshakeNeverCame() {
        var gate = AttachBootstrapGate()
        let failure = Data("ssh rc startup failure\r\n".utf8)
        #expect(gate.admit(failure).isEmpty)
        #expect(gate.flush() == failure)
        #expect(gate.flush().isEmpty)
    }

    @Test func gateBoundsTheWithheldNoiseWithoutLosingTheHandshake() {
        var gate = AttachBootstrapGate()
        let flood = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        #expect(gate.admit(flood).isEmpty)
        // A copy, so the bound can be read without spending the gate.
        var counted = gate
        #expect(counted.flush().count <= AttachBootstrapGate.maximumWithheldBytes)
        // Trimming must not eat a marker that straddles the boundary.
        let marker = AttachBootstrapHandshake.marker
        #expect(gate.admit(Data(marker.prefix(3))).isEmpty)
        #expect(gate.admit(Data(marker.suffix(from: 3)) + Data("tui".utf8)) == Data("tui".utf8))
    }

    /// herdr 0.9.4's direct attach probes the terminal 138 bytes after the
    /// marker and types an answer that comes back late into the Pane (#451).
    /// The probe never reaches the terminal, however the reads split it, and
    /// nothing else changes: what is left is herdr 0.9.3's preamble, byte for
    /// byte.
    @Test func herdr094sStartupProbeNeverReachesTheTerminal() async throws {
        typealias Output = HerdrAttachOutput
        let marker = AttachBootstrapHandshake.marker
        var deliveries = Self.deliveries(of: marker + Output.herdr094)
        // How herdr 0.9.4's preamble arrived in the recordings: the probe at
        // the end of a read, and the probe alone.
        deliveries.append(
            Delivery(
                name: "recorded reads, probe last",
                reads: [
                    marker, Output.mouseReset, Output.alternateScreen,
                    Data([Output.mouseReset, Output.colorSchemeReportsOff, Output.probe].joined()),
                    Output.mouseReset + Output.inputModes, Output.firstFrame,
                ]))
        deliveries.append(
            Delivery(
                name: "recorded reads, probe alone",
                reads: [
                    marker, Output.mouseReset, Output.alternateScreen,
                    Output.mouseReset + Output.colorSchemeReportsOff, Output.probe,
                    Output.mouseReset + Output.inputModes, Output.firstFrame,
                ]))

        try await expectEveryDelivery(deliveries, yields: Output.herdr093, dropsStartupProbe: true)
    }

    /// herdr's client shell writes the same probe with the kitty keyboard
    /// query between its two halves. That shape never reaches the terminal
    /// either, however the reads split it.
    @Test func theClientShellsStartupProbeNeverReachesTheTerminal() async throws {
        typealias Output = HerdrAttachOutput
        let stream = Data(
            [
                AttachBootstrapHandshake.marker, Output.mouseReset, Output.alternateScreen,
                Output.mouseReset, Output.colorSchemeReportsOff, Output.clientShellProbe,
                Output.mouseReset, Output.inputModes, Output.firstFrame,
            ].joined())
        try await expectEveryDelivery(
            Self.deliveries(of: stream), yields: Output.herdr093, dropsStartupProbe: true)
    }

    /// herdr 0.9.3 writes no probe, and its output reaches the terminal byte
    /// for byte, including a mode reset that a read cuts right where it
    /// stops looking like the probe.
    @Test func herdr093sOutputReachesTheTerminalUnchanged() async throws {
        let stream = AttachBootstrapHandshake.marker + HerdrAttachOutput.herdr093
        let cut = AttachBootstrapHandshake.marker.count + Data("\u{1B}[?1006l\u{1B}[?1016".utf8).count
        let deliveries = Self.deliveries(of: stream) + [
            Delivery(
                name: "a read ending in ESC[?1016, then one starting with l",
                reads: [Data(stream.prefix(cut)), Data(stream.dropFirst(cut))]),
        ]
        try await expectEveryDelivery(
            deliveries, yields: HerdrAttachOutput.herdr093, dropsStartupProbe: true)
    }

    /// Only the first probe is herdr's. Whatever follows it, another probe, a
    /// DECRQM for some other mode or a lone DA1, reaches the terminal.
    @Test func everythingAfterTheProbeReachesTheTerminal() async throws {
        let later = HerdrAttachOutput.probe + Data("\u{1B}[?2026$p".utf8) + Data("\u{1B}[c".utf8)
        try await expectEveryDelivery(
            Self.deliveries(of: AttachBootstrapHandshake.marker + HerdrAttachOutput.herdr094 + later),
            yields: HerdrAttachOutput.herdr093 + later, dropsStartupProbe: true)
    }

    /// Another DECRQM and a lone DA1 ahead of the probe are not the probe:
    /// they reach the terminal, and the probe after them is still dropped.
    @Test func otherQueriesAheadOfTheProbeReachTheTerminal() async throws {
        let earlier = Data("\u{1B}[?2026$p".utf8) + Data("\u{1B}[c".utf8)
        try await expectEveryDelivery(
            Self.deliveries(of: AttachBootstrapHandshake.marker + earlier + HerdrAttachOutput.herdr094),
            yields: earlier + HerdrAttachOutput.herdr093, dropsStartupProbe: true)
    }

    /// herdr writes its probe within the first 4 KiB after the marker. One
    /// that starts after them belongs to whatever runs in the Pane and
    /// reaches the terminal, however the reads split it.
    @Test func aProbeStartingPastTheFirst4KiBReachesTheTerminal() async throws {
        let session = Data(repeating: UInt8(ascii: "x"), count: 4096) + HerdrAttachOutput.probe
        try await expectEveryDelivery(
            Self.deliveries(of: AttachBootstrapHandshake.marker + session),
            yields: session, dropsStartupProbe: true)
    }

    /// What counts is where the probe starts: one whose first byte is the
    /// window's last is still dropped, though it ends past the window.
    @Test func aProbeStartingOnTheWindowsLastByteIsDropped() async throws {
        let filler = Data(repeating: UInt8(ascii: "x"), count: 4095)
        let tail = Data("after".utf8)
        let stream = AttachBootstrapHandshake.marker + filler + HerdrAttachOutput.probe + tail
        try await expectEveryDelivery(
            Self.deliveries(of: stream), yields: filler + tail, dropsStartupProbe: true)
    }

    /// The filter holds back the start of what may be a probe until the next
    /// read settles it. A stream that ends cleanly there hands those bytes
    /// on rather than dropping them.
    @Test func aPartialProbeStillHeldWhenTheStreamEndsReachesTheTerminal() async throws {
        let session = Self.sessionEndingInAPartialProbe
        try await expectEveryDelivery(
            Self.deliveries(of: AttachBootstrapHandshake.marker + session),
            yields: session, dropsStartupProbe: true)
    }

    /// A nonzero exit hands the held bytes on as well.
    @Test func aPartialProbeStillHeldReachesTheTerminalOnANonzeroExit() async throws {
        let session = Self.sessionEndingInAPartialProbe
        let channel = FakeAttachPTYChannel(
            reads: [AttachBootstrapHandshake.marker + session, nil],
            remoteExitStatus: 1)
        let source = HeelerSSHAttachOutputGate.makeStream()

        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: TerminalAttachInputQueue(),
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: true)
            Issue.record("exit 1 should fail the attach pumps")
        } catch HeelerSSHAttachPumpError.remoteExit(let status, _) {
            #expect(status == 1)
        }
        source.gate.finish()

        #expect(try await Self.joined(source.output) == session)
    }

    /// So does an input failure, which stops the output pump mid-stream.
    @Test(.timeLimit(.minutes(1)))
    func aPartialProbeStillHeldReachesTheTerminalWhenInputFails() async throws {
        let session = Self.sessionEndingInAPartialProbe
        let channel = FakeAttachPTYChannel(
            reads: [AttachBootstrapHandshake.marker + session],
            writeError: FakeAttachChannelError.rejectedWrite,
            blockAfterReads: true)
        let input = TerminalAttachInputQueue()
        let source = HeelerSSHAttachOutputGate.makeStream()
        let pump = Task {
            do {
                _ = try await HeelerSSHTransport.runAttachPumps(
                    channel: channel,
                    input: input,
                    output: source.gate,
                    requestTimeout: .seconds(1),
                    dropsStartupProbe: true)
                return false
            } catch HeelerSSHAttachPumpError.input(_) {
                return true
            } catch {
                return false
            }
        }

        await channel.waitUntilFirstRead()
        input.send(Data("x".utf8))
        #expect(await pump.value)
        source.gate.finish()

        #expect(try await Self.joined(source.output) == session)
    }

    /// And so does a failed read.
    @Test func aPartialProbeStillHeldReachesTheTerminalWhenAReadFails() async throws {
        let session = Self.sessionEndingInAPartialProbe
        let channel = FakeAttachPTYChannel(
            reads: [AttachBootstrapHandshake.marker + session],
            readError: SSHError.channelFailed)
        let source = HeelerSSHAttachOutputGate.makeStream()

        do {
            _ = try await HeelerSSHTransport.runAttachPumps(
                channel: channel,
                input: TerminalAttachInputQueue(),
                output: source.gate,
                requestTimeout: .seconds(1),
                dropsStartupProbe: true)
            Issue.record("a read failure should fail the attach pumps")
        } catch HeelerSSHAttachPumpError.output(_) {}
        source.gate.finish()

        #expect(try await Self.joined(source.output) == session)
    }

    /// The native Windows terminal controller never writes the probe, so its
    /// pumps run with the option off and pass those bytes through like any
    /// others.
    @Test func withTheProbeOptionOffTheOutputPassesUntouched() async throws {
        let marker = AttachBootstrapHandshake.marker
        try await expectEveryDelivery(
            Self.deliveries(of: marker + HerdrAttachOutput.herdr094),
            yields: HerdrAttachOutput.herdr094, dropsStartupProbe: false)
    }

    /// One way a channel can hand over a stream, named for failure messages.
    private struct Delivery {
        let name: String
        let reads: [Data]
    }

    /// `stream` in one read, at every two-way split, and byte by byte.
    private static func deliveries(of stream: Data) -> [Delivery] {
        var deliveries = [Delivery(name: "whole", reads: [stream])]
        for cut in 1..<stream.count {
            deliveries.append(
                Delivery(
                    name: "split at \(cut)",
                    reads: [Data(stream.prefix(cut)), Data(stream.suffix(from: cut))]))
        }
        deliveries.append(Delivery(name: "byte by byte", reads: stream.map { Data([$0]) }))
        return deliveries
    }

    /// Expects the terminal to get `expected` from every delivery, and names
    /// the first deliveries that differ.
    private func expectEveryDelivery(
        _ deliveries: [Delivery], yields expected: Data, dropsStartupProbe: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var mismatches: [String] = []
        for delivery in deliveries {
            let output = try await terminalBytes(
                from: delivery.reads, dropsStartupProbe: dropsStartupProbe)
            if output != expected { mismatches.append(delivery.name) }
        }
        #expect(
            mismatches == [], "\(mismatches.count) of \(deliveries.count): \(mismatches.prefix(3))",
            sourceLocation: sourceLocation)
    }

    /// Every byte the terminal is handed when the attach output arrives as
    /// `reads` and the attach then ends cleanly.
    private func terminalBytes(from reads: [Data], dropsStartupProbe: Bool) async throws -> Data {
        let channel = FakeAttachPTYChannel(reads: reads.map(Optional.some) + [nil])
        let source = HeelerSSHAttachOutputGate.makeStream()
        let cleanEnd = try await HeelerSSHTransport.runAttachPumps(
            channel: channel,
            input: TerminalAttachInputQueue(),
            output: source.gate,
            requestTimeout: .seconds(1),
            dropsStartupProbe: dropsStartupProbe)
        source.gate.finish()
        #expect(cleanEnd)
        return try await Self.joined(source.output)
    }

    /// Everything a finished output stream carried.
    private static func joined(_ output: AsyncThrowingStream<Data, any Error>) async throws -> Data {
        var bytes = Data()
        for try await chunk in output {
            bytes.append(chunk)
        }
        return bytes
    }

    /// herdr 0.9.4's preamble up to where its probe starts, then the client
    /// shell's longer probe without its last byte: the 15 bytes the filter
    /// holds back, left at the end.
    private static let sessionEndingInAPartialProbe =
        HerdrAttachOutput.mouseReset + HerdrAttachOutput.alternateScreen
        + HerdrAttachOutput.mouseReset + HerdrAttachOutput.colorSchemeReportsOff
        + HerdrAttachOutput.clientShellProbe.dropLast()

    @Test func sessionDropsEmptyKeystrokeWrites() async {
        // An empty write must not ride down the channel as an empty
        // SSH_MSG_CHANNEL_DATA.
        let transport = ScriptedTransport()
        let session = try? await transport.attachTerminal(
            TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
        session?.send(Data())
        session?.send(Data("x".utf8))
        await session?.end()
        let inputs = await transport.attachInputs
        #expect(inputs == [.keystrokes(Data("x".utf8))])
    }
}

private actor FakeAttachPTYChannel: HeelerSSHAttachChannel {
    private var reads: [Data?]
    private let writeError: (any Error & Sendable)?
    private let readError: (any Error & Sendable)?
    private let blockAfterReads: Bool
    private let remoteExitStatus: Int32
    private var didReadFirst = false
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        reads: [Data?],
        writeError: (any Error & Sendable)? = nil,
        readError: (any Error & Sendable)? = nil,
        blockAfterReads: Bool = false,
        remoteExitStatus: Int32 = 0
    ) {
        self.reads = reads
        self.writeError = writeError
        self.readError = readError
        self.blockAfterReads = blockAfterReads
        self.remoteExitStatus = remoteExitStatus
    }

    func write(_: Data, timeout _: Duration) async throws {
        if let writeError { throw writeError }
    }

    func read(maximumBytes _: Int, timeout _: Duration) async throws -> Data? {
        guard !reads.isEmpty else {
            if let readError { throw readError }
            if blockAfterReads {
                try await Task.sleep(for: .seconds(60))
            }
            return nil
        }
        let bytes = reads.removeFirst()
        if !didReadFirst {
            didReadFirst = true
            let waiters = firstReadWaiters
            firstReadWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }
        return bytes
    }

    func resize(columns _: Int, rows _: Int, timeout _: Duration) async throws {}

    func exitStatus(timeout _: Duration) async throws -> Int32 { remoteExitStatus }

    func waitUntilFirstRead() async {
        guard !didReadFirst else { return }
        await withCheckedContinuation { continuation in
            firstReadWaiters.append(continuation)
        }
    }
}

/// herdr's direct-attach output after Heeler's bootstrap marker (#451). The
/// preambles match recordings made through Heeler's attach command against
/// isolated servers, herdr 0.9.4's `terminal attach` and `agent attach` and
/// herdr 0.9.3's `terminal attach`, byte for byte up to the first frame's
/// text, which is made up.
private enum HerdrAttachOutput {
    /// Every mouse mode off. herdr writes it three times on the way in.
    static let mouseReset = Data(
        ("\u{1B}[?1006l\u{1B}[?1016l\u{1B}[?1015l\u{1B}[?1005l"
            + "\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?9l").utf8)
    static let alternateScreen = Data("\u{1B}[?1049h".utf8)
    static let colorSchemeReportsOff = Data("\u{1B}[?2031l".utf8)
    /// herdr 0.9.4's startup probe: a DECRQM for SGR pixel mouse, then DA1.
    static let probe = Data("\u{1B}[?1016$p\u{1B}[c".utf8)
    /// The probe of herdr's client shell, which also queries the kitty
    /// keyboard flags.
    static let clientShellProbe = Data("\u{1B}[?1016$p\u{1B}[?u\u{1B}[c".utf8)
    /// Mouse capture and bracketed paste on, line wrap off.
    static let inputModes = Data(
        ("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1015h\u{1B}[?1006h"
            + "\u{1B}[?2004h\u{1B}[?7l").utf8)
    /// A synchronized update that hides the cursor, closes any hyperlink,
    /// clears the screen, homes the cursor and resets the colours, then text.
    static let firstFrame = Data(
        ("\u{1B}[?2026h\u{1B}[?25l\u{1B}]8;;\u{1B}\\\u{1B}[2J\u{1B}[1;1H"
            + "\u{1B}[0;39;49mframe text").utf8)

    /// herdr 0.9.4. The probe starts 138 bytes in.
    static let herdr094 = Data(
        [
            mouseReset, alternateScreen, mouseReset, colorSchemeReportsOff, probe,
            mouseReset, inputModes, firstFrame,
        ].joined())
    /// herdr 0.9.3 writes the same preamble without the probe.
    static let herdr093 = Data(
        [
            mouseReset, alternateScreen, mouseReset, colorSchemeReportsOff,
            mouseReset, inputModes, firstFrame,
        ].joined())

    /// herdr 0.9.4's `terminal attach` when the server closes the connection
    /// during the handshake, recorded against a stand-in server: the setup
    /// and probe come first, then the terminal is restored and herdr exits 1
    /// with the error below.
    static let herdr094LostServer = Data(
        [
            mouseReset, alternateScreen, mouseReset, colorSchemeReportsOff, probe,
            mouseReset, inputModes, restore, lostServer,
        ].joined())
    /// `herdr094LostServer` as the terminal gets it: everything but the
    /// probe.
    static let herdr094LostServerWithoutProbe = Data(
        [
            mouseReset, alternateScreen, mouseReset, colorSchemeReportsOff,
            mouseReset, inputModes, restore, lostServer,
        ].joined())
    /// Line wrap on, focus reports and bracketed paste off, every mouse mode
    /// off, the main screen back, the cursor shown and its shape reset.
    private static let restore = Data(
        [
            Data("\u{1B}[?7h\u{1B}[?1004l\u{1B}[?2004l".utf8),
            mouseReset,
            Data("\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l".utf8),
            Data("\u{1B}[?1049l\u{1B}[?25h\u{1B}[0 q".utf8),
        ].joined())
    private static let lostServer = Data(
        (#"Error: Custom { kind: Other, error: "lost connection to server: server closed connection" }"#
            + "\r\n").utf8)
}
