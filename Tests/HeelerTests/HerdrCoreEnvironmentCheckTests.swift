import Foundation
import Testing

@testable import Heeler

/// The leaked-environment check through the Host session, over the real framed
/// transport and link, with the exec and the core scripted.
/// `scripts/test-herdr-core-environment-check.py` runs the script itself.
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreEnvironmentCheckTests {
    private final class Reader: @unchecked Sendable {
        private var updates: AsyncStream<HerdrCoreHostSessionUpdate>.Iterator
        private var answers: AsyncStream<Void>.Iterator

        init(_ session: HerdrCoreHostSession) {
            updates = session.updates.makeAsyncIterator()
            answers = session.leakedEnvironmentUpdates.makeAsyncIterator()
        }

        func nextSnapshot() async {
            while let update = await updates.next() {
                if case .snapshot = update { return }
            }
        }

        func next() async -> HerdrCoreHostSessionUpdate? {
            await updates.next()
        }

        func nextStatus() async -> EventsSessionStatus? {
            while let update = await updates.next() {
                if case .status(let status) = update { return status }
            }
            return nil
        }

        /// The next time the check answers.
        func nextAnswer() async {
            _ = await answers.next()
        }
    }

    private let clock = ManualClock()

    private func session(on host: ScriptedCoreHost) -> HerdrCoreHostSession {
        HerdrCoreHostSession(
            connect: {
                await host.setConnected(true)
                return host.transport()
            },
            keepalive: nil,
            sleep: clock.parkedSleep(for:))
    }

    private func reads(_ host: ScriptedCoreHost) async -> Int {
        await host.log.filter { $0 == "process-read" }.count
    }

    @Test func theRequestAsksForNamesAndNeverForAValue() {
        let request = HerdrCoreEnvironmentCheck.request(pid: 9001)
        #expect(request.pids == ["9001"])
        #expect(request.valuesOf.isEmpty)
        #expect(!request.readsStart && !request.readsOpenFiles)
        #expect(request.namesWithPrefix == ["HERDR_"])
        #expect(Set(request.namesOf) == [
            "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SKIP_PROMPT_HISTORY", "CLAUDECODE", "TMUX", "STY", "ZELLIJ",
            "CURSOR_TRACE_ID", "VSCODE_GIT_ASKPASS_MAIN", "CODEX_THREAD_ID", "OMPCODE", "PI_PROGRAM_STATUS",
        ])
    }

    @Test func theCheckRunsAfterHelloInOneExecAgainstTheStatusPid() async throws {
        let host = ScriptedCoreHost(
            processRead: .names(["TMUX", "CLAUDE_CODE_CHILD_SESSION"]), channel: .core(.init(pid: 9001)))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()

        await reader.nextAnswer()
        #expect(session.currentLeakedEnvironment == ["TMUX", "CLAUDE_CODE_CHILD_SESSION"])

        let log = await host.log
        let opened = try #require(log.firstIndex(of: "open \(ScriptedCoreHost.socketPath)"))
        let read = try #require(log.firstIndex(of: "process-read"))
        #expect(opened < read)
        #expect(await reads(host) == 1)
        #expect(await host.methods.contains("server.status"))
        let script = try #require(await host.scripts.last)
        #expect(script.contains("\ne 9001\n"))
        // Linux's and macOS's ways of asking for a value.
        #expect(!script.contains("W[\""))
        #expect(script.contains("qw();"))
        await session.end()
    }

    @Test func aFreshSnapshotOnTheSameLinkRunsNoSecondExec() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init()))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        await reader.nextSnapshot()
        await reader.nextAnswer()

        await host.setProcessRead(.names([]))
        await session.resubscribe()
        await reader.nextSnapshot()
        await reader.nextAnswer()

        #expect(await reads(host) == 1)
        #expect(await host.sockets.count == 1)
        #expect(session.currentLeakedEnvironment == ["TMUX"])
        await session.end()
    }

    @Test func aNewLinkChecksAgainAndACoreRestartedCleanlyClearsIt() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init(pid: 100)))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        await reader.nextSnapshot()
        await reader.nextAnswer()
        #expect(session.currentLeakedEnvironment == ["TMUX"])
        let firstSocket = try #require(await host.socket)

        await host.setChannel(.core(.init(pid: 200)))
        await host.setProcessRead(.names([]))
        await firstSocket.deliverEndOfFile()
        await reader.nextSnapshot()
        await reader.nextAnswer()

        #expect(session.currentLeakedEnvironment.isEmpty)
        #expect(await reads(host) == 2)
        let script = try #require(await host.scripts.last)
        #expect(script.contains("\ne 200\n"))
        await session.end()
    }

    @Test func aCheckThatFindsNothingUsableLeavesTheHostConnectedAndNamesNothing() async throws {
        let failures: [ScriptedCoreHost.ProcessRead] = [
            .unreadable,
            .exits(status: 1, stdout: ""),
            .exits(status: 0, stdout: "TMUX=/tmp/from-a-banner\n"),
            .throwsError(.timedOut),
            .throwsError(.channelFailed(detail: "refused")),
            .throwsError(.hostFeatureUnavailable(feature: "herdr-core Hosts")),
        ]
        for failure in failures {
            let host = ScriptedCoreHost(
                processRead: failure, channel: .core(.init(terminals: [.object([
                    "address": .string("t1"), "cwd": .string("/work"), "state": .string("live"),
                    "pid": .number(7),
                ])])))
            let session = session(on: host)
            let reader = Reader(session)
            await session.resume()
            #expect(await reader.nextStatus() == .connecting)
            #expect(await reader.nextStatus() == .connected)
            await reader.nextSnapshot()
            await reader.nextAnswer()
            #expect(session.currentLeakedEnvironment.isEmpty, "\(failure)")

            // The link is the one it was, and still carries events.
            try await host.deliverEvent(
                Data(
                    #"{"jsonrpc":"2.0","method":"event","params":{"seq":1,"type":"size","terminal":"t1","data":{"cols":90,"rows":30}}}"#
                        .utf8))
            #expect(await reader.next() == .event(.size(terminal: "t1", columns: 90, rows: 30)), "\(failure)")
            #expect(await host.log.filter { $0 == "close" }.isEmpty, "\(failure)")
            #expect(await host.sockets.count == 1, "\(failure)")
            await session.end()
        }
    }

    @Test func aStatusPidTheReaderRefusesRunsNoExec() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init(pid: 0)))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        await reader.nextAnswer()
        #expect(session.currentLeakedEnvironment.isEmpty)
        #expect(await reads(host) == 0)
        await session.end()
    }

    @Test func theConnectionDoesNotWaitForTheCheck() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init()))
        await host.holdProcessReads()
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()

        #expect(await reader.nextStatus() == .connecting)
        #expect(await reader.nextStatus() == .connected)
        await reader.nextSnapshot()
        #expect(session.currentLeakedEnvironment.isEmpty)

        await host.releaseProcessReads()
        await reader.nextAnswer()
        #expect(session.currentLeakedEnvironment == ["TMUX"])
        await session.end()
    }

    @Test func leavingConnectedForgetsWhatTheCheckFound() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init()))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        await reader.nextSnapshot()
        await reader.nextAnswer()
        #expect(session.currentLeakedEnvironment == ["TMUX"])

        await session.suspend()
        #expect(session.currentLeakedEnvironment.isEmpty)
        await session.end()
    }

    @Test func anAnswerFromALinkThatEndedIsNotBelieved() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init(pid: 100)))
        await host.holdProcessReads()
        let transport = host.transport()
        _ = try await transport.hello()
        let stale = Task { await transport.leakedEnvironmentNames() }
        await host.waitForProcessRead(count: 1)

        await host.setChannel(.core(.init(pid: 200)))
        await host.setProcessRead(.names([]))
        let firstSocket = try #require(await host.socket)
        await firstSocket.deliverEndOfFile()
        while await host.sockets.count < 2 {
            _ = try await transport.hello()
            await Task.yield()
        }
        let current = Task { await transport.leakedEnvironmentNames() }
        await host.waitForProcessRead(count: 2)
        await host.releaseProcessReads()

        #expect(await stale.value == nil)
        #expect(await current.value == [])
        try await transport.close()
    }

    @Test func noLinkMeansNoCheckAndOpensNone() async throws {
        let host = ScriptedCoreHost(processRead: .names(["TMUX"]), channel: .core(.init()))
        let transport = host.transport()
        #expect(await transport.leakedEnvironmentNames() == nil)
        #expect(await host.log.isEmpty)
    }
}
