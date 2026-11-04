import Foundation
import Testing

@testable import Heeler

/// The wrapper every bounded Host script runs in: a remote watchdog that ends
/// the exec's process group and reports its feature's timeout marker. Nothing
/// here runs a shell; the fixture end-to-end tests do that.
@Suite("Bounded host script")
struct BoundedHostScriptTests {
    private static func text(_ script: Data) -> String {
        String(decoding: script, as: UTF8.self)
    }

    /// The Changes wrapper's source text from before Chat shared it, with a
    /// fixed script, bound and marker filled in. Changes keeps sending
    /// exactly these bytes.
    @Test func changesWrapsItsScriptExactlyAsBefore() {
        let wrapped = HeelerSSHTransport.boundedScript(
            Data("printf 'body'\n".utf8), remoteSeconds: 10,
            timeoutMarker: "__HEELER_GIT_TIMEOUT_F00D__")
        let expected = """
            {
            (
                sleep 10 3>&-
                printf '\\n%s\\n' '__HEELER_GIT_TIMEOUT_F00D__' >&3
                kill -KILL 0
            ) </dev/null >/dev/null 3>&2 2>/dev/null &
            __heeler_git_watchdog=$!
            (
            printf 'body'

            ) </dev/null
            __heeler_git_status=$?
            {
                kill -KILL "$__heeler_git_watchdog"
                wait "$__heeler_git_watchdog"
            } >/dev/null 2>&1
            exit "$__heeler_git_status"
            } </dev/null

            """
        #expect(Self.text(wrapped) == expected)
        #expect(wrapped == Data(expected.utf8))
    }

    /// Only the watchdog prints a marker, and it prints the one its caller
    /// passed, so a Changes timeout and a Chat timeout each read as their
    /// own error.
    @Test func eachFeatureNamesItsOwnTimeoutMarker() {
        let script = Data("true\n".utf8)
        let changesMarker = "__HEELER_GIT_TIMEOUT_A__"
        let chatMarker = "__HEELER_OC_TIMEOUT_B__"
        let changes = Self.text(HeelerSSHTransport.boundedScript(
            script, remoteSeconds: 10, timeoutMarker: changesMarker))
        let chat = Self.text(HeelerSSHTransport.boundedScript(
            script, remoteSeconds: 8, timeoutMarker: chatMarker))

        #expect(changes.contains("""
                sleep 10 3>&-
                printf '\\n%s\\n' '\(changesMarker)' >&3

            """))
        #expect(chat.contains("""
                sleep 8 3>&-
                printf '\\n%s\\n' '\(chatMarker)' >&3

            """))
        #expect(changes.ranges(of: changesMarker).count == 1)
        #expect(chat.ranges(of: chatMarker).count == 1)
        #expect(!changes.contains("_OC_TIMEOUT_"))
        #expect(!chat.contains("_GIT_TIMEOUT_"))
    }

    // MARK: The lane

    /// A run past its deadline keeps its lane until its exec drains, so the
    /// next Chat query never runs beside it on the Host.
    @Test(.timeLimit(.minutes(1)))
    func aLaneHoldsTheNextRunUntilTheLastOneDrains() async throws {
        let lane = GitExecGate()
        let exec = ScriptedTransportCallGate()
        let log = LaneLog()
        await #expect(throws: AsyncDeadlineError.timedOut) {
            try await HeelerSSHTransport.runInLane(deadline: .milliseconds(50), lane: lane) {
                // Detached like the exec, so awaiting it ignores the
                // deadline's cancellation.
                let execution = Task.detached {
                    await exec.waitUntilOpen()
                    await log.append("first drained")
                }
                await execution.value
            }
        }
        await exec.waitForEntry()
        let second = Task {
            try await HeelerSSHTransport.runInLane(deadline: .seconds(30), lane: lane) {
                await log.append("second started")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.entries.isEmpty)

        await exec.open()
        try await second.value
        #expect(await log.entries == ["first drained", "second started"])
    }

    /// A run that times out while it waits leaves the lane: its operation
    /// never starts, and the run behind it goes next.
    @Test(.timeLimit(.minutes(1)))
    func aTimedOutWaiterLeavesTheLane() async throws {
        let lane = GitExecGate()
        let exec = ScriptedTransportCallGate()
        let log = LaneLog()
        let first = Task {
            try await HeelerSSHTransport.runInLane(deadline: .seconds(30), lane: lane) {
                await exec.waitUntilOpen()
                await log.append("first")
            }
        }
        await exec.waitForEntry()
        await #expect(throws: AsyncDeadlineError.timedOut) {
            try await HeelerSSHTransport.runInLane(deadline: .milliseconds(50), lane: lane) {
                await log.append("timed out")
            }
        }
        let third = Task {
            try await HeelerSSHTransport.runInLane(deadline: .seconds(30), lane: lane) {
                await log.append("third")
            }
        }

        await exec.open()
        try await first.value
        try await third.value
        #expect(await log.entries == ["first", "third"])
    }

    /// Changes runs without a lane: a second read never waits for the first.
    @Test(.timeLimit(.minutes(1)))
    func withoutALaneRunsDoNotWait() async throws {
        let exec = ScriptedTransportCallGate()
        let log = LaneLog()
        let first = Task {
            try await HeelerSSHTransport.runInLane(deadline: .seconds(30), lane: nil) {
                await exec.waitUntilOpen()
                await log.append("first")
            }
        }
        await exec.waitForEntry()
        try await HeelerSSHTransport.runInLane(deadline: .seconds(30), lane: nil) {
            await log.append("second")
        }
        #expect(await log.entries == ["second"])

        await exec.open()
        try await first.value
        #expect(await log.entries == ["second", "first"])
    }

    private actor LaneLog {
        private(set) var entries: [String] = []

        func append(_ entry: String) { entries.append(entry) }
    }
}
