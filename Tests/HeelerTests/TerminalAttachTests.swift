import Foundation
import GhosttyTerminal
import SwiftUI
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
        let stale = InMemoryTerminalViewport(columns: 33, rows: 20)

        bridge.beginSizeReportDeferral()
        await withCheckedContinuation { continuation in
            bridge.onViewport = { _ in continuation.resume() }
            bridge.resize(stale)
        }
        bridge.onViewport = nil
        bridge.provideAuthoritativeDeferredSize(columns: 33, rows: 14)
        bridge.finishSizeReportDeferral()
        try await waitForGridReportsToSettle { reportedGrids.count }
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
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
        bridge.isSizeReportCurrent = { columns, rows in
            columns == 33 && rows == 14
        }

        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 33, rows: 14)
        bridge.finishSizeReportDeferral()
        try await waitForGridReportsToSettle { reportedGrids.count }

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
        let settled = InMemoryTerminalViewport(columns: 33, rows: 14)

        bridge.beginSizeReportDeferral()
        bridge.resize(settled)
        bridge.finishSizeReportDeferral()
        try await waitForGridReportsToSettle { reportedGrids.count }
        #expect(reportedGrids == [ReportedGrid(columns: 33, rows: 14)])
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
            requestTimeout: .seconds(1))
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
                    requestTimeout: .seconds(1))
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
                    requestTimeout: .seconds(1))
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

        #expect(try await iterator.next() == first)
        #expect(try await iterator.next() == second)
        #expect(try await iterator.next() == nil)
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

    @MainActor
    private static func firstAccessibleFrame(in root: UIView, labeled label: String) -> CGRect? {
        // SwiftUI hosting nests accessibility containers arbitrarily deep, and
        // which runtime wraps a control in how many containers varies by OS
        // release — recurse through every container shape, not just UIViews.
        func visit(_ node: NSObject) -> CGRect? {
            if let view = node as? UIView {
                if view.accessibilityLabel == label, view.bounds.width > 0, view.bounds.height > 0 {
                    return view.convert(view.bounds, to: root)
                }
            } else if node.accessibilityLabel == label {
                let frame = node.accessibilityFrame
                if frame.width > 0, frame.height > 0 {
                    return root.convert(frame, from: nil)
                }
            }
            if let elements = node.accessibilityElements {
                for element in elements {
                    if let object = element as? NSObject, let frame = visit(object) {
                        return frame
                    }
                }
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<count {
                        if let object = node.accessibilityElement(at: index) as? NSObject,
                            let frame = visit(object)
                        {
                            return frame
                        }
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews {
                    if let frame = visit(subview) { return frame }
                }
            }
            return nil
        }
        return visit(root)
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

    /// A slow SSH writer must not let lossy momentum-scroll input hold
    /// reliable keyboard input hostage. Sixty rows model one ordinary flick;
    /// the 20 ms drain delay makes the old unbounded FIFO take about 1.2 s.
    @MainActor
    @Test func weakNetworkScrollBacklogDoesNotDelayKeyboardInput() async throws {
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        let session = TerminalAttachSession(
            output: { output },
            input: input,
            ender: { outputContinuation.finish() })
        let inputController = TerminalInputController()
        let generation = inputController.beginSession(
            writer: { session.send($0) },
            scroller: { sequence, rows in session.scroll(sequence, rows: rows) })
        defer { inputController.endSession(generation) }

        let marker = Data("x".utf8)
        var markerArrival: ContinuousClock.Instant?
        let writer = Task { @MainActor in
            while let item = await input.next() {
                switch item {
                case .keystrokes(let data):
                    if data == marker {
                        markerArrival = .now
                        return
                    }
                case .scroll:
                    try? await Task.sleep(for: .milliseconds(20))
                case .resize:
                    break
                }
            }
        }
        defer { writer.cancel() }

        var emitted = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { inputController.send($0) },
            onScroll: { sequence, rows in
                emitted += rows
                inputController.scroll(sequence, rows: rows)
            })
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(terminal.scrollTouch(translationY: 960) == 60)
        #expect(emitted == 60)

        let typedAt = ContinuousClock.now
        terminal.terminalSession.sendInput(marker)
        let arrivalDeadline = typedAt + .seconds(3)
        while markerArrival == nil, ContinuousClock.now < arrivalDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        let arrivedAt = try #require(markerArrival)
        let latency = typedAt.duration(to: arrivedAt)
        #expect(
            latency < .milliseconds(250),
            "keyboard input waited behind scroll backlog: \(latency)")
        await session.end()
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

    @MainActor
    @Test func attachStartsWithTheIOSInputMethodAndKeyboardSwitcher() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        #expect(terminal.keyboardMode == .text)
        #expect(terminal.inputView == nil)
        // The input row is app content (see `ShellTerminalInputRow`); an
        // accessory here would ride the keyboard and die with a mode switch.
        #expect(terminal.inputAccessoryView == nil)
    }

    @MainActor
    @Test func theInputRowNewLineInsertsWithoutSubmitting() async throws {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        let control = TerminalKeyboardControl()
        control.terminal = terminal

        control.sendNewLine()
        await Task.yield()
        #expect(sent == Data([0x0A]))

        sent.removeAll()
        terminal.setKeyboardMode(.controls)
        control.sendNewLine()
        await Task.yield()
        #expect(sent == Data([0x0A]))

        terminal.setLocalInputEnabled(false)
        control.sendNewLine()
        await Task.yield()
        #expect(sent == Data([0x0A]))
    }

    @MainActor
    @Test func pasteControlAndHardwarePasteUseTheReviewedPasteCallback() {
        var pastes: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onPaste: { text, _ in pastes.append(text) })

        terminal.requestPaste("one\n two")
        #expect(pastes == ["one\n two"])

        terminal.setLocalInputEnabled(false)
        terminal.requestPaste("blocked")
        #expect(pastes == ["one\n two"])

        // The input row's paste routes through the same reviewed path and
        // honours the same gate.
        let control = TerminalKeyboardControl()
        control.terminal = terminal
        control.paste("still blocked")
        #expect(pastes == ["one\n two"])
        terminal.setLocalInputEnabled(true)
        control.paste("routed")
        #expect(pastes == ["one\n two", "routed"])
    }

    @MainActor
    @Test func systemPasteControlLoadsTextFromItsItemProvider() async throws {
        var pastes: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onPaste: { text, _ in pastes.append(text) })

        terminal.paste(
            itemProviders: [NSItemProvider(object: "provider paste" as NSString)])
        let deadline = ContinuousClock.now + .seconds(2)
        while pastes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(pastes == ["provider paste"])
    }

    @MainActor
    @Test func keyboardPasteSynchronizesTheTextInputContext() {
        var events: [String] = []
        let clipboard = TerminalClipboard(
            string: { "keyboard suggestion" },
            hasStrings: { true })
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onPaste: { text, _ in events.append("paste:\(text)") },
            clipboard: clipboard)
        let inputDelegate = TextInputDelegateRecorder(events: { events.append($0) })
        terminal.inputDelegate = inputDelegate

        #expect(
            terminal.canPerformAction(
                #selector(UIResponderStandardEditActions.paste(_:)),
                withSender: nil))

        terminal.paste(nil)

        #expect(
            events == [
                "textWillChange",
                "paste:keyboard suggestion",
                "textDidChange",
            ])
    }

    @MainActor
    @Test func systemKeyboardBackspaceSynchronizesTheTextInputContext() async throws {
        var sent = Data()
        var events: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        let inputDelegate = TextInputDelegateRecorder(events: { events.append($0) })
        terminal.inputDelegate = inputDelegate

        // GhosttyTerminal 1.4.0 routes backspace through the core's key
        // encoder, which needs a live surface — and a surface needs a window.
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }
        try await waitForGhosttyContentLayer(in: terminal)

        terminal.terminalSession.sendInput(Data("abc".utf8))
        let insertDeadline = ContinuousClock.now + .seconds(1)
        while sent != Data("abc".utf8), ContinuousClock.now < insertDeadline {
            await Task.yield()
        }
        #expect(sent == Data("abc".utf8))
        sent.removeAll()
        events.removeAll()

        terminal.deleteBackward()
        let deleteDeadline = ContinuousClock.now + .seconds(1)
        while sent.isEmpty, ContinuousClock.now < deleteDeadline {
            await Task.yield()
        }

        #expect(sent == Data([0x7F]))
        #expect(
            events == [
                "textWillChange",
                "selectionWillChange",
                "selectionDidChange",
                "textDidChange",
            ])
        #expect(terminal.offset(
            from: terminal.beginningOfDocument,
            to: terminal.endOfDocument) == 2)
    }

    @MainActor
    @Test func pausedTerminalControlsDoNotEmitInput() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })

        terminal.setLocalInputEnabled(false)
        terminal.sendControlKey(.enter)
        await Task.yield()

        #expect(sent.isEmpty)
    }

    @MainActor
    @Test func terminalTouchPolicyKeepsKeyboardBehindTheCurrentInputRow() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)

        #expect(!terminal.canBecomeFirstResponder)
        #expect(
            terminal.gestureRecognizers?.contains { gesture in
                guard let pan = gesture as? UIPanGestureRecognizer else { return false }
                return pan.allowedTouchTypes.contains(
                    directTouch)
            } == true)
        #expect(
            terminal.gestureRecognizers?.contains { gesture in
                guard let tap = gesture as? UITapGestureRecognizer else { return false }
                return tap.isEnabled && tap.allowedTouchTypes.contains(directTouch)
            } == true)

        terminal.requestKeyboard()
        #expect(terminal.canBecomeFirstResponder)

        terminal.dismissKeyboard()
        #expect(!terminal.canBecomeFirstResponder)
    }

    /// UIKit resigns the first responder on its own — backgrounding the app,
    /// presenting a sheet — and restores it afterwards by asking the view to
    /// become first responder again. If those resigns also cleared the user's
    /// intent, the view would refuse, and the accessory bar would come back
    /// with no keyboard behind it and no way to type (the >20s-in-background
    /// report). Only an explicit dismiss ends the session.
    @MainActor
    @Test func aSystemResignLeavesTheKeyboardRecoverable() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.requestKeyboard()

        _ = terminal.resignFirstResponder()

        #expect(terminal.canBecomeFirstResponder)
    }

    /// Ghostty's `UITerminalView` raises the keyboard from `touchesBegan` and
    /// takes it down from `touchesEnded` — on any body touch. Once the user
    /// had raised the keyboard once, that turned every body tap into a
    /// keyboard toggle, bypassing the input-row policy entirely. Responder
    /// changes arriving mid-touch are Ghostty's and are refused; the same
    /// requests pass again once the touch ends (UIKit's restore path).
    @MainActor
    @Test func bodyTouchesCannotToggleTheKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        window.addSubview(terminal)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        terminal.requestKeyboard()
        #expect(terminal.isFirstResponder)

        // Ghostty's touchesEnded dismisses the keyboard after any body tap;
        // that resign lands mid-touch and must be refused.
        let touch = UITouch()
        terminal.touchesBegan([touch], with: nil)
        #expect(!terminal.resignFirstResponder())
        #expect(terminal.isFirstResponder)
        // A short backgrounding hides the keyboard but keeps the first
        // responder, and UIKit answers a re-assert on the current first
        // responder without consulting canBecomeFirstResponder. The override
        // swallows it mid-touch; the swallowed re-present itself is only
        // observable on a device, so this pins down status and return value.
        #expect(terminal.becomeFirstResponder())
        #expect(terminal.isFirstResponder)
        terminal.touchesEnded([touch], with: nil)

        // A UIKit-style resign outside any touch still goes through, keeping
        // sheets and backgrounding working.
        _ = terminal.resignFirstResponder()
        #expect(!terminal.isFirstResponder)

        // Ghostty's touchesBegan re-raises the keyboard on the next body tap;
        // with no user request driving it the surface refuses.
        terminal.touchesBegan([touch], with: nil)
        #expect(!terminal.becomeFirstResponder())
        terminal.touchesEnded([touch], with: nil)

        // Outside the touch, UIKit's restore-after-resign path still passes.
        #expect(terminal.canBecomeFirstResponder)
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

    /// Every chat-style agent TUI pins its input box to the bottom rows, but
    /// each parks the caret somewhere of its own, so the bottom quarter is
    /// the tool-agnostic floor the caret band cannot be.
    @Test func alternateScreenBottomQuarterIsAlwaysATapTarget() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: bounds)

        #expect(region == CGRect(x: 0, y: 540, width: 390, height: 180))
        #expect(TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: .zero).isNull)
    }

    @MainActor
    @Test func ghosttyCursorProvidesAVisibleKeyboardTapTarget() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        terminal.receive(Data("$ ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        #expect(!terminal.keyboardActivationRegion.isNull)
        #expect(terminal.bounds.contains(terminal.keyboardActivationRegion))
    }

    @MainActor
    @Test func renderedOutputReportsViewportTextToTheHost() async throws {
        var snapshots: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onViewportTextChanged: { snapshots.append($0) })
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        terminal.receive(
            Data("\u{001B}[2J\u{001B}[Hhttps://viewport.example/result\n".utf8))
        terminal.layoutIfNeeded()

        let deadline = ContinuousClock.now + .seconds(2)
        while !snapshots.contains(where: { $0.contains("https://viewport.example/result") }),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            snapshots.contains {
                $0.contains("https://viewport.example/result")
            })
    }

    /// The shell above is not what Attach actually shows: every agent is a
    /// full-screen TUI that takes the alternate screen and grabs the mouse, and
    /// the keyboard has exactly one entry point. If the cursor stopped yielding
    /// a caret under those modes the target would silently vanish, and the only
    /// symptom would be a user tapping a terminal that never answers.
    @MainActor
    @Test func aMouseGrabbingTUIStillOffersTheKeyboardTapTarget() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        // Alternate screen + SGR mouse tracking, then a prompt parked on a low
        // row: an agent's input box, in as few bytes as it takes.
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        terminal.receive(Data("\u{1B}[20;3H> ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        let region = terminal.keyboardActivationRegion
        #expect(!region.isNull)
        #expect(terminal.bounds.contains(region))
        // Reaches the visible prompt above the parked caret (#90), or the
        // single entry point is unhittable in practice.
        #expect(region.height >= TerminalKeyboardTapTarget.alternateScreenMinimumHeight)
        // Full width: the row is the target, not the glyph the cursor sits on.
        #expect(region.width == terminal.bounds.width)
    }

    /// #90 measured Claude Code's visible `>` prompt 16–40 pt above the parked
    /// caret, so the alternate screen keeps the caret anchor but triples the
    /// band to cover the whole bordered input box. The output area stays
    /// inert: #92's whole-screen activation answered every output-area tap
    /// with a keyboard nobody asked for.
    @MainActor
    @Test func aTUITapRaisesTheKeyboardOnlyAroundItsInputBox() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        // A TUI on the alternate screen with its prompt parked on row 20.
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[20;3H> ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        let region = terminal.keyboardActivationRegion
        let insideTheBand = CGPoint(x: 195, y: region.midY)
        let outputArea = CGPoint(x: 195, y: 20)
        // Chat TUIs pin the input box to the bottom rows; a tap there must
        // answer even when the caret band sits elsewhere.
        let bottomQuarter = CGPoint(x: 195, y: 700)
        #expect(!region.contains(outputArea))
        #expect(terminal.tapAction(at: insideTheBand) == .report(raisesKeyboard: true))
        #expect(terminal.tapAction(at: outputArea) == .report(raisesKeyboard: false))
        #expect(terminal.tapAction(at: bottomQuarter) == .report(raisesKeyboard: true))
    }

    /// The normal buffer keeps the old contract: scrollback is scrolled by
    /// touch, and a stray tap must not answer with a viewport resize.
    @MainActor
    @Test func theNormalBufferStillOnlyAnswersTheInputRow() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1049l".utf8))

        #expect(terminal.tapAction(at: CGPoint(x: 195, y: 120)) == .report(raisesKeyboard: false))
    }

    /// Tapping to stop a flick is the oldest gesture on the platform. Now that
    /// a tap can raise the keyboard, that tap must be spent on the halt alone —
    /// otherwise stopping a scroll costs you the bottom half of the screen.
    @MainActor
    @Test func theTapThatHaltsAFlickDoesNothingElse() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        terminal.receive(Data("\u{1B}[?1049h".utf8))

        terminal.startTouchScrollMomentum(velocityY: 2_000)
        #expect(terminal.isTouchScrollMomentumRunning)

        // The same tap that raises the keyboard in the test above.
        terminal.handleTap(at: CGPoint(x: 195, y: 120))

        #expect(!terminal.isTouchScrollMomentumRunning)
        #expect(!terminal.canBecomeFirstResponder)
    }

    @MainActor
    @Test func terminalTouchPanEmitsSemanticRemoteTUIMouseWheelInput() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows += rows
            })
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let enabledTouchPans: [UIPanGestureRecognizer] =
            terminal.gestureRecognizers?.compactMap { gesture in
                guard let pan = gesture as? UIPanGestureRecognizer,
                    pan.isEnabled,
                    pan.allowedTouchTypes.contains(directTouch)
                else { return nil }
                return pan
            } ?? []
        #expect(enabledTouchPans.count == 1)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(terminal.scrollTouch(translationY: 32) == 2)

        #expect(scrolledSequence == Data("\u{1B}[<64;40;12M".utf8))
        #expect(scrolledRows == 2)
    }

    /// The keyboard toggle rides the Agent strip, which outlives the keyboard,
    /// so it has to work both ways — and a dismissal has to leave the keyboard
    /// recoverable, or the toggle is a one-way trip out of typing.
    @MainActor
    @Test func theKeyboardToggleRaisesAndLowersTheTerminalsKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        window.addSubview(terminal)
        window.makeKeyAndVisible()
        let control = TerminalKeyboardControl()
        control.terminal = terminal

        #expect(!control.isKeyboardUp)
        control.toggleKeyboard()
        #expect(terminal.isFirstResponder)
        #expect(control.isKeyboardUp)

        control.toggleKeyboard()
        #expect(!terminal.isFirstResponder)
        #expect(!control.isKeyboardUp)

        control.toggleKeyboard()
        #expect(terminal.isFirstResponder)
    }

    /// An Agent switch rebuilds the terminal under the strip that survives it.
    /// A toggle still pointing at the replaced surface would raise a keyboard
    /// on a terminal that is no longer on screen.
    @MainActor
    @Test func theKeyboardToggleForgetsAReplacedTerminal() {
        let control = TerminalKeyboardControl()
        do {
            let replaced = TerminalScreenView.makeConfiguredTerminal()
            control.terminal = replaced
            #expect(control.terminal != nil)
        }
        #expect(control.terminal == nil)
        #expect(!control.isKeyboardUp)
        // Nothing to drive, and nothing to crash on.
        control.toggleKeyboard()
    }

    /// A SwiftUI update must not write back into the state that drove it.
    /// Reporting the viewport text from `updateUIView` fed the Attach Link
    /// index, whose observers include this very view, so every update queued
    /// the next one — measured on device at 18,871 updates in a few seconds,
    /// with the app wedged for as long as the terminal stayed on screen.
    /// Terminal output schedules its own snapshot (see
    /// `renderedOutputReportsViewportTextToTheHost`); nothing else may.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aSwiftUIUpdateDoesNotReportTheViewportBack() async throws {
        final class Counters {
            var updates = 0
            var reports = 0
        }
        struct Harness: View {
            let counters: Counters
            let keyboardControl: TerminalKeyboardControl
            let feed: TerminalByteFeed
            /// Some state the terminal is sized by, exactly as the keyboard
            /// inset is when the keyboard comes and goes.
            let fontSize: Float

            var body: some View {
                counters.updates += 1
                var screen = TerminalScreenView(feed: feed)
                screen.onViewportTextChanged = { _ in counters.reports += 1 }
                screen.keyboardControl = keyboardControl
                screen.fontSize = fontSize
                return screen
            }
        }

        let counters = Counters()
        let keyboardControl = TerminalKeyboardControl()
        let feed = TerminalByteFeed()
        func harness(fontSize: Float) -> Harness {
            Harness(
                counters: counters, keyboardControl: keyboardControl,
                feed: feed, fontSize: fontSize)
        }
        let controller = UIHostingController(rootView: harness(fontSize: 13))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        let rounds = 10
        for round in 1...rounds {
            controller.rootView = harness(fontSize: round.isMultiple(of: 2) ? 13 : 15)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
        }
        // Long enough for a snapshot one of those updates had scheduled to fire.
        try await Task.sleep(for: .milliseconds(200))

        // Every one of those rounds reached the terminal, and not one of them
        // asked it for its viewport.
        #expect(counters.updates > rounds)
        #expect(keyboardControl.terminal != nil, "the terminal never took an update")
        #expect(
            counters.reports == 0,
            "a SwiftUI update reported the viewport \(counters.reports) times")
    }

    /// A keyboard changing hands passes through several transient heights —
    /// both terminals' accessories ride it at once while it does. Forwarding
    /// each one to Ghostty and the remote PTY makes a full-screen TUI redraw
    /// per step, so only the settled geometry may escape the handoff.
    @MainActor
    @Test func aKeyboardHandoffCoalescesItsTransientGridsIntoOneResize() async throws {
        var reportedGrids: [(columns: Int, rows: Int)] = []
        // The terminal's own center, so a keyboard settling in a neighbouring
        // test cannot end the handoff inside the freeze window below (#157).
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append((columns, rows))
            },
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        try await waitForGridReportsToSettle { reportedGrids.count }
        let initialRows = try #require(reportedGrids.last?.rows)
        reportedGrids.removeAll()

        // The handoff itself: the replacement surface claims the keyboard as
        // it reaches the window, and freezes its grid until that settles.
        // This test drives the settle explicitly, so the wall-clock fallback
        // must stay out of it: on a loaded runner the steps below stretched
        // past its 500ms and it thawed the freeze mid-handoff (#225).
        terminal.keyboardTransitionFallbackDelay = 60
        terminal.removeFromSuperview()
        terminal.raisesKeyboardWhenReady = true
        host.view.addSubview(terminal)

        for height: CGFloat in [440, 520, 600] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }

        #expect(reportedGrids.isEmpty)
        terminal.finishKeyboardTransitionLayout()
        try await waitForGridReportsToSettle { reportedGrids.count }

        #expect(reportedGrids.count == 1)
        #expect(reportedGrids.last?.rows ?? 0 > initialRows)
    }

    /// The freeze must hold for as long as the handoff actually takes — a
    /// loaded CI runner stretched one past half a second and the transient
    /// grids escaped (#225). The stall here is the deterministic version of
    /// that runner.
    @MainActor
    @Test func aSlowKeyboardHandoffStillCoalescesIntoOneResize() async throws {
        var reportedGrids: [(columns: Int, rows: Int)] = []
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append((columns, rows))
            },
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        try await waitForGridReportsToSettle { reportedGrids.count }
        let initialRows = try #require(reportedGrids.last?.rows)
        reportedGrids.removeAll()

        terminal.keyboardTransitionFallbackDelay = 60
        terminal.removeFromSuperview()
        terminal.raisesKeyboardWhenReady = true
        host.view.addSubview(terminal)

        // A transient height, then a stall longer than the production
        // fallback, then another — the shape of the handoff on the runner
        // that leaked.
        terminal.frame.size.height = 440
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        terminal.frame.size.height = 600
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()

        #expect(reportedGrids.isEmpty)
        terminal.finishKeyboardTransitionLayout()
        try await waitForGridReportsToSettle { reportedGrids.count }

        #expect(reportedGrids.count == 1)
        #expect(reportedGrids.last?.rows ?? 0 > initialRows)
    }

    /// The freeze's other edge: a handoff whose settle signal never arrives
    /// must not stay frozen forever. The fallback thaws it after its delay,
    /// and the thaw itself still coalesces — one report, not one per
    /// transient.
    @MainActor
    @Test func anUnsettledHandoffThawsThroughTheFallbackInOneResize() async throws {
        var reportedGrids: [(columns: Int, rows: Int)] = []
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append((columns, rows))
            },
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        try await waitForGridReportsToSettle { reportedGrids.count }
        let initialRows = try #require(reportedGrids.last?.rows)
        reportedGrids.removeAll()

        terminal.keyboardTransitionFallbackDelay = 0.1
        terminal.removeFromSuperview()
        terminal.raisesKeyboardWhenReady = true
        host.view.addSubview(terminal)

        terminal.frame.size.height = 600
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()

        // No settle signal, no explicit finish — only the fallback ends this.
        try await waitForGridReportsToSettle { reportedGrids.count }

        #expect(reportedGrids.count == 1)
        #expect(reportedGrids.last?.rows ?? 0 > initialRows)
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
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// Removing the Chinese candidate row publishes a shorter positive frame
    /// before the system keyboard finishes hiding. The app-owned Tools dock
    /// must retain the complete measurement instead of adopting that transient
    /// height and exposing a gap.
    @MainActor
    @Test func toolsModeIgnoresCandidateRowTransitionFrames() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { frame in
            frame.height == 436 ? 402 : 365
        }
        let completeFrame = CGRect(x: 0, y: 554, width: 440, height: 436)
        let withoutCandidateRow = CGRect(x: 0, y: 591, width: 440, height: 399)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: completeFrame])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

        inset.pauseHeightCapture()
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: withoutCandidateRow])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 402)

        inset.resumeHeightCapture()
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: completeFrame])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)
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
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

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

    /// A scene transition can emit will-hide without a matching did-frame.
    /// The safety leash must release the hold, notify its owner, and reconcile
    /// a hide that never received a destination frame.
    @MainActor
    @Test func responderHandoffFallbackReleasesAnUnsettledFreeze() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        inset.responderHandoffFallbackDelay = .milliseconds(50)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

        var ownerHandoffID: UUID?
        var expiredHandoffID: UUID?
        let handoffID = inset.beginResponderHandoff(onFallback: { expiredID in
            expiredHandoffID = expiredID
            if ownerHandoffID == expiredID {
                ownerHandoffID = nil
            }
        })
        ownerHandoffID = handoffID
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))

        #expect(!inset.isHoldingHandoffHeight)
        #expect(expiredHandoffID == handoffID)
        #expect(ownerHandoffID == nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// Keyboard notifications are process-wide on iPad. A hide from another
    /// scene must not clear this scene's still-visible keyboard footprint.
    @MainActor
    @Test func responderHandoffFallbackUsesTheOwningWindowHeight() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        inset.responderHandoffFallbackDelay = .milliseconds(50)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

        _ = inset.beginResponderHandoff(currentHeight: { 402 })
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))

        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
        #expect(inset.lastPresentedHeight == 402)
    }

    /// Composer-to-Direct already has the destination terminal's bounded
    /// fallback. A second inset-owned timer starts earlier and can commit a
    /// transient hide before the terminal gets its final frame.
    @MainActor
    @Test func destinationOwnedFallbackKeepsTheInsetFrozen() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        inset.responderHandoffFallbackDelay = .milliseconds(50)
        inset.destinationResponderHandoffFallbackDelay = .milliseconds(200)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

        let handoffID = inset.beginDestinationOwnedResponderHandoff()
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))

        #expect(inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
        inset.endResponderHandoff(handoffID)
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
    }

    /// A destination can disappear before its weakly captured terminal timer
    /// fires. The inset owner has a later watchdog so that loss cannot leave
    /// the shared handoff token frozen forever.
    @MainActor
    @Test func destinationLossFallsBackThroughTheInsetOwner() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        inset.destinationResponderHandoffFallbackDelay = .milliseconds(50)

        center.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

        var expiredID: UUID?
        let handoffID = inset.beginDestinationOwnedResponderHandoff(
            currentHeight: { nil }
        ) { expiredID = $0 }
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))

        #expect(expiredID == handoffID)
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
    }

    @MainActor
    @Test func responderHandoffCancellationUsesTheOwningWindowHeight() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await Task.sleep(for: .milliseconds(120))

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
        let systemBeforeUIKitShows = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 402,
            presentation: .system)

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

    /// The cold Blocked-Send dock is a real view, not just a layout number:
    /// Enter and Esc have to be on screen and large enough to tap.
    @MainActor
    @Test func aColdToolsDockKeepsEnterAndEscapeTappable() async throws {
        let layout = AgentComposerKeyboardLayout(
            currentHeight: 0, lastPresentedHeight: 0,
            presentation: .tools)
        let width: CGFloat = 402
        let height = layout.availableToolsHeight
        let suiteName = "cold-tools-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.cancelled
        }
        let controller = UIHostingController(
            rootView: AgentToolsKeyboard(
                store: composer,
                context: TerminalKeysContext(
                    settings: TerminalSettings(
                        themes: TerminalThemeSettings(defaults: defaults),
                        zoom: TerminalZoomSettings(defaults: defaults),
                        fonts: TerminalFontSettings(defaults: defaults),
                        snippets: SnippetStore(defaults: defaults)),
                    manageSnippets: {}),
                height: height,
                quickKeysEnabled: true,
                sendQuickKey: { _ in }
            )
            .frame(width: width, height: height)
            .ignoresSafeArea())
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.frame = bounds
        let window = try await makeTestWindow(
            frame: bounds, rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        await Task.yield()

        #expect(controller.view.bounds.height == height)
        #expect(height >= 44 * 3)
        // iOS 26 simulators never materialize hosted SwiftUI accessibility
        // without an assistive client attached, so the frame probe below is
        // 27-only; the layout invariants above gate every runtime.
        guard #available(iOS 27, *) else { return }
        // Hosted SwiftUI materializes its accessibility tree a run-loop beat
        // after layout — poll instead of requiring it on the first pass.
        var frames: [String: CGRect] = [:]
        for _ in 0..<40 where frames.count < 2 {
            for label in ["Enter", "Escape"] where frames[label] == nil {
                frames[label] = Self.firstAccessibleFrame(
                    in: controller.view, labeled: label)
            }
            if frames.count < 2 {
                try await Task.sleep(nanoseconds: 50_000_000)
                controller.view.layoutIfNeeded()
            }
        }
        for label in ["Enter", "Escape"] {
            let frame = try #require(
                frames[label],
                "\(label) should be in the cold tools dock")
            let visible = controller.view.bounds.intersection(frame)
            #expect(visible.height >= 44, "\(label) frame was \(frame)")
            #expect(visible.width >= 44, "\(label) frame was \(frame)")
        }
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

        try await Task.sleep(for: .milliseconds(200))
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

    @Test func terminalControlKeyboardContainsOnlyUsefulMobileKeys() {
        #expect(
            TerminalControlKey.rows == [
                [.escape, .tab, .controlC, .controlD, .backspace],
                [.home, .pageUp, .up, .pageDown, .end],
                [.controlZ, .left, .down, .right, .enter],
            ])
        // Every row is the same width, so no key ends up wider than its
        // neighbours just because a row was left short.
        #expect(Set(TerminalControlKey.rows.map(\.count)).count == 1)
        // Rearranging the rows must not quietly drop a key on the floor.
        let placed = TerminalControlKey.rows.flatMap { $0 }
        #expect(placed.count == TerminalControlKey.allCases.count)
        for key in TerminalControlKey.allCases {
            #expect(placed.contains(key), "\(key) fell off the keyboard")
        }
    }

    @Test func terminalControlKeysEncodeExpectedBytes() {
        #expect(TerminalControlKey.escape.bytes(applicationCursor: false) == [0x1B])
        #expect(TerminalControlKey.tab.bytes(applicationCursor: false) == [0x09])
        #expect(TerminalControlKey.controlC.bytes(applicationCursor: false) == [0x03])
        #expect(TerminalControlKey.controlD.bytes(applicationCursor: false) == [0x04])
        #expect(TerminalControlKey.controlZ.bytes(applicationCursor: false) == [0x1A])
        #expect(TerminalControlKey.backspace.bytes(applicationCursor: false) == [0x7F])
        #expect(TerminalControlKey.enter.bytes(applicationCursor: false) == [0x0D])
        #expect(TerminalControlKey.up.bytes(applicationCursor: false) == [0x1B, 0x5B, 0x41])
        #expect(TerminalControlKey.up.bytes(applicationCursor: true) == [0x1B, 0x4F, 0x41])
        #expect(
            TerminalControlKey.pageUp.bytes(applicationCursor: false) == [
                0x1B, 0x5B, 0x35, 0x7E,
            ])
    }

    @Test func agentQuickKeysEncodeExpectedBytes() {
        #expect(
            AgentQuickKey.allCases == [
                .escape, .tab, .shiftTab, .shiftEnter, .left, .up, .down, .right,
                .enter, .backspace,
            ])
        #expect(AgentQuickKey.escape.bytes(applicationCursor: false) == [0x1B])
        #expect(AgentQuickKey.tab.bytes(applicationCursor: false) == [0x09])
        #expect(AgentQuickKey.shiftTab.bytes(applicationCursor: false) == [0x1B, 0x5B, 0x5A])
        #expect(AgentQuickKey.shiftEnter.bytes(applicationCursor: false) == [0x0A])
        #expect(AgentQuickKey.left.bytes(applicationCursor: false) == [0x1B, 0x5B, 0x44])
        #expect(AgentQuickKey.up.bytes(applicationCursor: true) == [0x1B, 0x4F, 0x41])
        #expect(AgentQuickKey.down.bytes(applicationCursor: false) == [0x1B, 0x5B, 0x42])
        #expect(AgentQuickKey.right.bytes(applicationCursor: false) == [0x1B, 0x5B, 0x43])
        #expect(AgentQuickKey.enter.bytes(applicationCursor: false) == [0x0D])
        #expect(AgentQuickKey.backspace.bytes(applicationCursor: false) == [0x7F])
        #expect(AgentQuickKey.shiftEnter.title == "⇧Enter")
        #expect(AgentQuickKey.enter.title == "Enter")
        #expect(AgentQuickKey.backspace.title == "Backspace")
        #expect(AgentQuickKey.enter.systemImageName == nil)
        #expect(AgentQuickKey.backspace.systemImageName == nil)
    }

    @MainActor
    @Test func agentQuickKeysBypassDisplayOnlyInputWithoutEnablingTyping() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        terminal.setLocalInputEnabled(false)

        terminal.sendControlKey(.enter)
        terminal.sendQuickKey(.shiftTab)
        terminal.receive(Data("\u{1B}[?1h".utf8))
        terminal.sendQuickKey(.up)
        await Task.yield()

        #expect(sent == Data([0x1B, 0x5B, 0x5A, 0x1B, 0x4F, 0x41]))
    }

    @MainActor
    @Test func terminalControlKeysFlowThroughTheGhosttySession() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })

        terminal.sendControlKey(.controlC)
        await Task.yield()
        #expect(sent == Data([0x03]))

        sent.removeAll()
        terminal.receive(Data("\u{1B}[?1h".utf8))
        terminal.sendControlKey(.up)
        await Task.yield()
        #expect(sent == Data([0x1B, 0x4F, 0x41]))
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

    @MainActor
    @Test func terminalSelectionRejectsOutOfBoundsAnchorRanges() {
        #expect(
            TerminalTextSelectionViewController.normalizedSelectionRange(
                NSRange(location: 2, length: 3), textLength: 8)
                == NSRange(location: 2, length: 3))
        #expect(
            TerminalTextSelectionViewController.normalizedSelectionRange(
                NSRange(location: 7, length: 4), textLength: 8)
                == NSRange(location: 0, length: 8))
        #expect(
            TerminalTextSelectionViewController.normalizedSelectionRange(
                nil, textLength: 8)
                == NSRange(location: 0, length: 8))
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

    @Test func attachExit127OnAnInjectableCommandStaysAChannelFailure() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 127, attachCommand: "/bin/sh /tmp/fake-attach.sh")
                == .channelFailed(detail: "attach channel: remote exit status 127"))
    }

    @Test func attachExit127OnAnAbsoluteHerdrStaysAChannelFailure() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 127,
                attachCommand: "/nonexistent/herdr agent attach")
                == .channelFailed(detail: "attach channel: remote exit status 127"))
    }

    @Test func attachNonzeroExitBesides127StaysAChannelFailure() {
        #expect(
            HeelerSSHTransport.attachChannelFailure(
                exitStatus: 23, attachCommand: "herdr agent attach")
                == .channelFailed(detail: "attach channel: remote exit status 23"))
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
                requestTimeout: .seconds(1))
            Issue.record("exit 127 should fail the attach pumps")
        } catch {
            #expect(String(describing: error) == "remoteExit(127)")
        }
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
    private let blockAfterReads: Bool
    private let remoteExitStatus: Int32
    private var didReadFirst = false
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        reads: [Data?],
        writeError: (any Error & Sendable)? = nil,
        blockAfterReads: Bool = false,
        remoteExitStatus: Int32 = 0
    ) {
        self.reads = reads
        self.writeError = writeError
        self.blockAfterReads = blockAfterReads
        self.remoteExitStatus = remoteExitStatus
    }

    func write(_: Data, timeout _: Duration) async throws {
        if let writeError { throw writeError }
    }

    func read(maximumBytes _: Int, timeout _: Duration) async throws -> Data? {
        guard !reads.isEmpty else {
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

@MainActor
private final class TextInputDelegateRecorder: NSObject, UITextInputDelegate {
    private let record: (String) -> Void

    init(events record: @escaping (String) -> Void) {
        self.record = record
    }

    func selectionWillChange(_: (any UITextInput)?) {
        record("selectionWillChange")
    }

    func selectionDidChange(_: (any UITextInput)?) {
        record("selectionDidChange")
    }

    func textWillChange(_: (any UITextInput)?) {
        record("textWillChange")
    }

    func textDidChange(_: (any UITextInput)?) {
        record("textDidChange")
    }

    @available(iOS 18.4, *)
    func conversationContext(_: UIConversationContext?, didChange _: (any UITextInput)?) {}
}
