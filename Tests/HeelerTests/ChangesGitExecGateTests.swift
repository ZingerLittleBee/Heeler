import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Changes git exec gate", .timeLimit(.minutes(1)))
struct ChangesGitExecGateTests {
    private static func store(_ transport: ScriptedTransport, gate: GitExecGate?) -> ChangesStore {
        ChangesStore(
            directory: { "/home/dev/src/app" },
            read: { try await transport.readChanges($0) },
            readPatch: { try await transport.readFilePatch($0) },
            listUntrackedDirectory: { try await transport.listUntrackedDirectory($0) },
            gate: gate)
    }

    @Test func twoStoresOnOneHostShareOneExecAndTheWaiterShowsLoading() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let gate = GitExecGate()
        let first = Self.store(transport, gate: gate)
        let second = Self.store(transport, gate: gate)
        let a = Task { await first.appear() }
        await localExec.waitForEntry()
        let b = Task { await second.appear() }
        await Self.drain()
        #expect(second.phase == .loading)
        #expect(await transport.changesReadRequests.count == 1)
        await localExec.open()
        await a.value
        await b.value
        #expect(first.phase == .loaded(read.changes))
        #expect(second.phase == .loaded(read.changes))
        #expect(await transport.changesReadRequests.count == 2)
    }

    @Test func cancellationDiscardsLateResultsButHoldsTheGateUntilLocalCompletion() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let gate = GitExecGate()
        let first = Self.store(transport, gate: gate)
        let second = Self.store(transport, gate: gate)
        let a = Task { await first.appear() }
        await localExec.waitForEntry()
        first.cancel()
        let b = Task { await second.appear() }
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 1)
        #expect(first.phase == .loading)
        #expect(second.phase == .loading)
        await localExec.open()
        await a.value
        await b.value
        #expect(first.phase == .loading)
        #expect(first.readAt == nil)
        #expect(second.phase == .loaded(read.changes))
    }

    @Test func cancellingAWaitingStoreNeverEntersTheTransport() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let gate = GitExecGate()
        let first = Self.store(transport, gate: gate)
        let second = Self.store(transport, gate: gate)
        let a = Task { await first.appear() }
        await localExec.waitForEntry()
        let b = Task { await second.appear() }
        await Self.drain()
        second.cancel()
        await b.value
        await localExec.open()
        await a.value
        #expect(second.phase == .loading)
        #expect(await transport.changesReadRequests.count == 1)
    }

    @Test func aCancellationAwareLocalExecReleasesTheGateImmediately() async throws {
        let clock = ChangesManualSleeper()
        let gate = GitExecGate()
        let first = ChangesStore(
            directory: { "/app" }, read: { _ in
                try await clock.sleep(.seconds(10))
                throw TransportError.gitTimedOut
            }, gate: gate)
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read)])
        let second = Self.store(transport, gate: gate)
        let a = Task { await first.appear() }
        for _ in 0..<2_000 {
            if await clock.durations.count == 1 { break }
            await Task.yield()
        }
        #expect(await clock.durations.count == 1)
        let b = Task { await second.appear() }
        first.cancel()
        await a.value
        await b.value
        #expect(first.phase == .loading)
        #expect(second.phase == .loaded(read.changes))
    }

    @Test(arguments: [false, true])
    func aTappedFileWaitsForRefreshAndIsCancelledIfTheCheckoutMoves(moves: Bool) async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        let next = try ChangesStoreTests.read(moves ? GitProbeRecordings.worktree : GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(next)])
        let patch = FilePatch(files: [], isTruncated: false)
        await transport.scriptFilePatchReads([.success(patch)])
        let store = Self.store(transport, gate: GitExecGate())
        await store.appear()
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let refreshing = Task { await store.refresh() }
        await localExec.waitForEntry()
        let file = try #require(read.changes.files.first { !$0.isUntrackedDirectory })
        store.openDiff(file)
        let diff = try #require(store.fileDiff.current)
        let opening = Task { await diff.appear() }
        await Self.drain()
        #expect(diff.phase == .loading)
        #expect(await transport.filePatchRequests.isEmpty)
        await localExec.open()
        await refreshing.value
        await opening.value
        if moves {
            #expect(store.fileDiff.current == nil)
            #expect(await transport.filePatchRequests.isEmpty)
        } else {
            #expect(diff.phase == .loaded(patch))
            #expect(await transport.filePatchRequests.count == 1)
        }
    }

    @Test func closingADiffCancelsItsQueuedPatch() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let store = Self.store(transport, gate: GitExecGate())
        await store.appear()
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let refreshing = Task { await store.refresh() }
        await localExec.waitForEntry()
        store.openDiff(try #require(read.changes.files.first { !$0.isUntrackedDirectory }))
        let diff = try #require(store.fileDiff.current)
        let opening = Task { await diff.appear() }
        await Self.drain()
        store.closeDiff()
        await opening.value
        await localExec.open()
        await refreshing.value
        #expect(diff.phase == .loading)
        #expect(await transport.filePatchRequests.isEmpty)
    }

    @Test func aDirectoryListingSharesTheHostGateAndLeavingCancelsIt() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let gate = GitExecGate()
        let first = Self.store(transport, gate: gate)
        let second = Self.store(transport, gate: gate)
        await first.appear()
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let reading = Task { await second.appear() }
        await localExec.waitForEntry()
        let directory = ChangedFile(
            path: Data("newdir/".utf8), originalPath: nil, kind: .untracked, staging: nil)
        let expanding = Task { await first.toggleDirectory(directory) }
        await Self.drain()
        #expect(first.untrackedDirectories.expansion(for: directory.path) == .loading)
        #expect(await transport.untrackedDirectoryRequests.isEmpty)
        first.cancel()
        await expanding.value
        await localExec.open()
        await reading.value
        #expect(first.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(await transport.untrackedDirectoryRequests.isEmpty)
    }

    @Test func aDirectoryListingRunsAfterAnotherStoresReadCompletes() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let directory = ChangedFile(
            path: Data("newdir/".utf8), originalPath: nil, kind: .untracked, staging: nil)
        let listing = try GitProbe.parseUntrackedDirectory(
            stdout: GitProbeRecordings.untrackedListing.stdout,
            stderr: GitProbeRecordings.untrackedListing.stderr,
            nonce: GitProbeRecordings.nonce, directory: directory.path)
        await transport.scriptUntrackedDirectoryListings([.success(listing)])
        let gate = GitExecGate()
        let first = Self.store(transport, gate: gate)
        let second = Self.store(transport, gate: gate)
        await first.appear()
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let reading = Task { await second.appear() }
        await localExec.waitForEntry()
        let expanding = Task { await first.toggleDirectory(directory) }
        await Self.drain()
        #expect(await transport.untrackedDirectoryRequests.isEmpty)
        await localExec.open()
        await reading.value
        await expanding.value
        #expect(first.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))
        #expect(await transport.untrackedDirectoryRequests.count == 1)
    }

    @Test func separateHostsDoNotBlockOneAnother() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let firstExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: firstExec)
        let first = Self.store(transport, gate: GitExecGate())
        let second = Self.store(transport, gate: GitExecGate())
        let a = Task { await first.appear() }
        await firstExec.waitForEntry()
        await second.appear()
        #expect(second.phase == .loaded(read.changes))
        #expect(first.phase == .loading)
        await firstExec.open()
        await a.value
    }

    @Test func aTimedOutLocalExecReleasesTheNextStoreWithoutARetry() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.failure(TransportError.gitTimedOut), .success(read)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let gate = GitExecGate()
        let first = Self.store(transport, gate: gate)
        let second = Self.store(transport, gate: gate)
        let a = Task { await first.appear() }
        await localExec.waitForEntry()
        let b = Task { await second.appear() }
        await Self.drain()
        #expect(second.phase == .loading)
        await localExec.open()
        await a.value
        await b.value
        #expect(first.phase == .timedOut)
        #expect(second.phase == .loaded(read.changes))
        #expect(await transport.changesReadRequests.count == 2)
    }

    /// The Agents list builds its row stores with the production factory,
    /// which hands them the Host's gate: a row's settle read waits behind
    /// another git exec on that Host instead of running beside it.
    @Test func agentRowStoresReadThroughTheHostsGate() async throws {
        let host = Host.fixture()
        let wireAgent = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "w1:t1", terminalID: "term_1", workspaceID: "w1",
            agent: "claude", cwd: "/home/dev/src/app", terminalTitleStripped: "")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [wireAgent]))
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read)])
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        defer { console.setHosts([]) }
        await console.resume()
        // Connected precedes inventory: the row must belong to the applied snapshot.
        let agentID = ConsoleAgent.ID(hostID: host.id, paneID: wireAgent.paneID)
        try await Self.waitUntil("the Host's Agent inventory never became ready") {
            console.hostStatuses[host.id] == .connected
                && !console.hostsAwaitingSnapshot.contains(host.id)
                && console.agents.contains { $0.id == agentID }
        }
        let agent = try #require(console.agents.first { $0.id == agentID })

        let gate = console.gitExecGate(for: host.id)
        let other = ScriptedTransportCallGate()
        let holder = Task { try await gate.run { await other.waitUntilOpen() } }
        await other.waitForEntry()
        console.rowChanges.rowAppeared(agent)
        defer { console.rowChanges.rowDisappeared(agent.id) }
        let store = try #require(console.rowChanges.store(for: agent))
        try await Self.waitUntil("the settle read never started") { store.activeRead != nil }
        await Self.drain()
        #expect(await transport.changesReadRequests.isEmpty)
        #expect(store.phase == .loading)

        await other.open()
        try await holder.value
        try await Self.waitUntil("the settle read never landed") {
            store.phase == .loaded(read.changes)
        }
        #expect(
            await transport.changesReadRequests
                == [ChangesReadRequest(directory: "/home/dev/src/app")])
    }

    private static func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private static func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), comment)
    }
}
