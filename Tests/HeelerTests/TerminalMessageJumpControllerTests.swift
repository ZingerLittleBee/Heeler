import Foundation
import Testing

@testable import Heeler

@Suite("Terminal message jump controller")
@MainActor
struct TerminalMessageJumpControllerTests {
    @Test("finds a match several steps away")
    func findsMatchSeveralStepsAway() async {
        let harness = JumpHarness(script: ["a", "b", "c", "MATCH", "e"], matchExact: "MATCH")
        harness.seedFrame("start")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(harness.stepCalls.count == 4)
        #expect(harness.stepCalls.allSatisfy { $0.direction == .older && $0.rows == 6 })
    }

    @Test("entry frame already matches walks past it to the next")
    func walksPastEntryMatch() async {
        let harness = JumpHarness(script: ["MSG1-still", "plain", "MSG2"]) { $0.contains("MSG") }
        harness.seedFrame("MSG1")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(harness.stepCalls.count == 3)
        #expect(harness.lastDeliveredFrame == "MSG2")
    }

    @Test("identical frames reach end at unchangedFramesBeforeEnd")
    func reachedEndOnIdenticalFrames() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2
        configuration.maxSteps = 10

        let harness = JumpHarness(
            script: ["same", "same", "same"],
            configuration: configuration,
            matchExact: "never"
        )
        harness.seedFrame("same")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.count == 2)
    }

    @Test("exhausts exactly at maxSteps when frames keep changing")
    func exhaustsAtMaxSteps() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 3
        configuration.unchangedFramesBeforeEnd = 5

        let harness = JumpHarness(
            script: ["1", "2", "3", "4", "5"],
            configuration: configuration,
            matchExact: "never"
        )
        harness.seedFrame("0")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .exhausted)
        #expect(harness.stepCalls.count == 3)
    }

    @Test("cancel mid-jump returns cancelled and stops stepping")
    func cancelMidJump() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 20
        configuration.frameSettleTimeout = .seconds(60)

        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { try await Task.sleep(for: $0) }
        )
        harness.seedFrame("start")

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.older)
        }

        await waitUntil { harness.stepCalls.count == 1 }
        #expect(harness.controller.isRunning)

        harness.controller.cancel()
        let outcome = await jumpTask.value

        #expect(outcome == .cancelled)
        #expect(harness.stepCalls.count == 1)
        #expect(!harness.controller.isRunning)
    }

    @Test("settle timeout with no frame counts toward reachedEnd")
    func settleTimeoutCountsAsUnchanged() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2
        configuration.maxSteps = 10
        configuration.frameSettleTimeout = .milliseconds(1)

        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { _ in }
        )
        harness.seedFrame("frozen")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.count == 2)
    }

    @Test("extra frameDidChange calls between steps do not desynchronise")
    func burstFramesDoNotDesynchronise() async {
        let driver = BurstJumpDriver(
            bursts: [
                ["noise-a", "noise-b", "1"],
                ["noise-c", "TARGET"],
            ],
            matches: { $0 == "TARGET" }
        )
        driver.seedFrame("0")

        let outcome = await driver.controller.jump(.older)

        #expect(outcome == .found)
        #expect(driver.stepCount == 2)
    }

    @Test("returnToLive ignores matches and stops on unchanged frames")
    func returnToLiveIgnoresMatches() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2

        // live-2 repeats once after the first live-2 observation, which is
        // unchangedCount=1; the harness re-delivers the last frame for the
        // next step to hit unchangedFramesBeforeEnd=2.
        let harness = JumpHarness(
            script: ["live-1", "live-2", "live-2"],
            configuration: configuration
        ) { _ in true }
        harness.seedFrame("start")

        let outcome = await harness.controller.returnToLive()

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.count == 4)
        #expect(harness.stepCalls.allSatisfy { $0.direction == .newer })
    }

    @Test("isRunning is true during jump and false after including cancel")
    func isRunningLifecycle() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.frameSettleTimeout = .seconds(60)

        let harness = JumpHarness(
            script: ["x"],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { try await Task.sleep(for: $0) }
        )
        harness.seedFrame("start")
        #expect(!harness.controller.isRunning)

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.newer)
        }
        await waitUntil { harness.controller.isRunning }
        #expect(harness.controller.isRunning)

        harness.controller.cancel()
        let outcome = await jumpTask.value
        #expect(outcome == .cancelled)
        #expect(!harness.controller.isRunning)
    }

    @Test("second jump while running is refused without interrupting the first")
    func refusesReentrancy() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.frameSettleTimeout = .seconds(60)

        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { try await Task.sleep(for: $0) }
        )
        harness.seedFrame("start")

        let first = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await waitUntil { harness.stepCalls.count == 1 }

        let second = await harness.controller.jump(.newer)
        #expect(second == .cancelled)
        #expect(harness.stepCalls.count == 1)

        harness.controller.cancel()
        let firstOutcome = await first.value
        #expect(firstOutcome == .cancelled)
    }
}

// MARK: - Harness

@MainActor
private final class BurstJumpDriver {
    private var bursts: [[String]]
    private var controllerStorage: TerminalMessageJumpController!
    private(set) var stepCount = 0

    var controller: TerminalMessageJumpController { controllerStorage }

    init(
        bursts: [[String]],
        matches: @escaping @MainActor (String) -> Bool
    ) {
        self.bursts = bursts
        controllerStorage = TerminalMessageJumpController(
            step: { [weak self] _, _ in
                self?.deliverNextBurst()
            },
            matches: matches,
            sleep: { _ in }
        )
    }

    func seedFrame(_ text: String) {
        controller.frameDidChange(text)
    }

    private func deliverNextBurst() {
        stepCount += 1
        guard !bursts.isEmpty else { return }
        let burst = bursts.removeFirst()
        for frame in burst {
            controller.frameDidChange(frame)
        }
    }
}

@MainActor
private final class JumpHarness {
    struct StepCall {
        var direction: TerminalMessageJumpController.Direction
        var rows: Int
    }

    private(set) var stepCalls: [StepCall] = []
    private(set) var lastDeliveredFrame: String?
    private let script: [String]
    private var scriptIndex = 0
    private let deliverFrames: Bool
    private var controllerStorage: TerminalMessageJumpController!

    var controller: TerminalMessageJumpController { controllerStorage }

    init(
        script: [String],
        configuration: TerminalMessageJumpController.Configuration = .init(),
        matchExact: String? = nil,
        deliverFrames: Bool = true,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        matches: (@MainActor (String) -> Bool)? = nil
    ) {
        self.script = script
        self.deliverFrames = deliverFrames

        let matchPredicate: @MainActor (String) -> Bool
        if let matches {
            matchPredicate = matches
        } else if let matchExact {
            matchPredicate = { $0 == matchExact }
        } else {
            matchPredicate = { _ in false }
        }

        controllerStorage = TerminalMessageJumpController(
            configuration: configuration,
            step: { [weak self] direction, rows in
                self?.noteStep(direction: direction, rows: rows)
            },
            matches: matchPredicate,
            sleep: sleep
        )
    }

    func seedFrame(_ text: String) {
        controller.frameDidChange(text)
    }

    private func noteStep(
        direction: TerminalMessageJumpController.Direction,
        rows: Int
    ) {
        stepCalls.append(StepCall(direction: direction, rows: rows))
        guard deliverFrames else { return }
        let frame: String
        if scriptIndex < script.count {
            frame = script[scriptIndex]
            scriptIndex += 1
        } else if let last = lastDeliveredFrame {
            frame = last
        } else {
            frame = ""
        }
        lastDeliveredFrame = frame
        controller.frameDidChange(frame)
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !predicate() {
        if DispatchTime.now().uptimeNanoseconds > deadline {
            Issue.record("timed out waiting for condition")
            return
        }
        await Task.yield()
    }
}
