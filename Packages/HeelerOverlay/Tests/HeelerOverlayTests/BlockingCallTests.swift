import Foundation
import Testing

@testable import HeelerOverlay

@Suite("Blocking native calls")
struct BlockingCallTests {
    @Test func returnsTheResultWhenItArrivesInTime() async throws {
        let value = try await BlockingCall.run(name: "test", timeout: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func timesOutAndHandsALateResultToAbandon() async throws {
        let abandoned = Recorder()
        let gaveUp = Recorder()
        let started = ContinuousClock.now

        await #expect(throws: OverlayError.timedOut) {
            _ = try await BlockingCall.run(
                name: "test",
                timeout: .milliseconds(50),
                onGiveUp: { gaveUp.record(1) },
                abandon: { abandoned.record($0) }
            ) { () -> Int in
                usleep(1_000_000)
                return 7
            }
        }
        #expect(ContinuousClock.now - started < .milliseconds(800))
        #expect(gaveUp.values == [1])
        #expect(await abandoned.waitForValue() == 7)
    }

    @Test func cancellationResumesPromptly() async throws {
        let abandoned = Recorder()
        let task = Task {
            try await BlockingCall.run(
                name: "test",
                timeout: nil,
                abandon: { abandoned.record($0) }
            ) { () -> Int in
                usleep(300_000)
                return 9
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: OverlayError.cancelled) {
            _ = try await task.value
        }
        #expect(await abandoned.waitForValue() == 9)
    }

    @Test func deadlinePauseStopsAtTheDeadline() async throws {
        let deadline = OverlayDeadline(after: .milliseconds(30))
        await #expect(throws: OverlayError.timedOut) {
            while true { try await deadline.pause(.milliseconds(10)) }
        }
        #expect(deadline.remaining == .zero)
        #expect(Duration.milliseconds(1500).milliseconds == 1500)
        #expect(Duration.seconds(2).nanoseconds == 2_000_000_000)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func waitForValue(timeout: Duration = .seconds(3)) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let first = values.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return values.first
    }
}
