import Foundation
import Testing

@testable import Heeler

@Suite("Perf trace")
struct PerfTraceTests {
    @Test("a frame is late once it is half a frame overdue")
    func hitchThreshold() {
        let frame = 1.0 / 60
        #expect(PerfFrameClock.hitch(gap: frame, frame: frame) == nil)
        // Timer jitter is not a dropped frame.
        #expect(PerfFrameClock.hitch(gap: frame * 1.4, frame: frame) == nil)
        let dropped = PerfFrameClock.hitch(gap: frame * 2, frame: frame)
        #expect(dropped.map { abs($0 - frame) < 1e-9 } == true)
        let stalled = PerfFrameClock.hitch(gap: 0.25, frame: frame)
        #expect(stalled.map { abs($0 - (0.25 - frame)) < 1e-9 } == true)
    }

    @Test("time away from the app is not a late frame")
    func hitchIgnoresTimeAway() {
        #expect(PerfFrameClock.hitch(gap: PerfFrameClock.longestGap + 1, frame: 1.0 / 60) == nil)
        #expect(PerfFrameClock.hitch(gap: 0, frame: 1.0 / 60) == nil)
        #expect(PerfFrameClock.hitch(gap: 1, frame: 0) == nil)
    }

    @Test("a ledger totals each span and keeps its longest run")
    func ledgerTotals() {
        var ledger = PerfFrameLedger()
        #expect(ledger.isEmpty)
        ledger.record(span: "apply", seconds: 0.004)
        ledger.record(span: "apply", seconds: 0.010)
        ledger.record(span: "rebuild", seconds: 0.020)
        ledger.count("body")
        ledger.count("body", 3)

        #expect(!ledger.isEmpty)
        #expect(ledger.counts == ["body": 4])
        #expect(
            ledger.spanTotals(limit: 8) == [
                PerfSpanTotal(n: "rebuild", c: 1, ms: 20, max: 20),
                PerfSpanTotal(n: "apply", c: 2, ms: 14, max: 10),
            ])
        // The most expensive span survives a short list.
        #expect(ledger.spanTotals(limit: 1).map(\.n) == ["rebuild"])
    }

    @Test("a window is the sum of its frames")
    func ledgerMerge() {
        var frame = PerfFrameLedger()
        frame.record(span: "apply", seconds: 0.125)
        frame.count("body", 2)
        var window = PerfFrameLedger()
        window.record(span: "apply", seconds: 0.5)
        window.count("cell")

        window.merge(frame)
        window.merge(frame)

        #expect(window.spans["apply"] == PerfFrameLedger.Total(count: 3, seconds: 0.75, longest: 0.5))
        #expect(window.counts == ["body": 4, "cell": 1])
        frame.removeAll()
        #expect(frame.isEmpty)
    }

    @Test("a stack reads from where the thread was, without the handler's frames")
    func stackDropsHandlerFrames() {
        let sample = PerfMainThreadSampler.Sample(overdue: 0.05, pc: 9, frames: [1, 2, 3, 4])
        let names: [UInt: String] = [
            1: "Heeler.debug.dylib handler+12",
            2: "libsystem_platform.dylib _sigtramp+56",
            3: "Heeler.debug.dylib caller+8",
            4: "UIKitCore UIApplicationMain+100",
            9: "Heeler.debug.dylib leaf+4",
        ]
        let stack = PerfMainThreadSampler.symbolicated(sample) { names[$0] ?? "?" }
        #expect(
            stack == [
                "Heeler.debug.dylib leaf+4", "Heeler.debug.dylib caller+8", "UIKitCore UIApplicationMain+100",
            ])
    }

    @Test("a deep stack keeps both ends and says what it left out")
    func deepStackKeepsBothEnds() {
        let kept = PerfMainThreadSampler.innermostKept + PerfMainThreadSampler.outermostKept
        let sample = PerfMainThreadSampler.Sample(overdue: 0.05, pc: 0, frames: Array(1...UInt(kept + 180)))
        let stack = PerfMainThreadSampler.symbolicated(sample) { String($0) }
        #expect(stack.count == kept + 1)
        #expect(stack.first == "1")
        #expect(stack[PerfMainThreadSampler.innermostKept] == "… 180 frames")
        #expect(stack.last == String(kept + 180))

        let whole = PerfMainThreadSampler.Sample(overdue: 0.05, pc: 0, frames: Array(1...UInt(kept)))
        #expect(PerfMainThreadSampler.symbolicated(whole) { String($0) }.count == kept)
    }

    @Test("a record encodes only the fields it set")
    func recordEncoding() throws {
        var record = PerfRecord(time: 0, kind: "hitch")
        record.ms = PerfRecord.milliseconds(0.0501234)
        record.scroll = true
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(Set(object.keys) == ["t", "k", "ms", "scroll"])
        #expect(object["ms"] as? Double == 50.12)
    }
}
