import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Changes automatic refresh", .timeLimit(.minutes(1)))
struct ChangesAutoRefreshTests {
    @Test func leavingWorkingWaitsForTheDebounceThenReadsTheCheckout() async throws {
        let transport = ScriptedTransport()
        let old = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        let new = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(old), .success(new)])
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/home/dev/src/app" },
            read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        let following = Task { await store.followAgentStatus() }
        defer { following.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 1)
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        #expect(await clock.durations == [.milliseconds(300)])
        #expect(store.phase == .loaded(old.changes))
        await clock.fireAll()
        await Self.waitUntil { store.phase == .loaded(new.changes) }
        #expect(await transport.changesReadRequests.count == 2)
    }

    @Test(arguments: [AgentStatus.idle, .blocked, .unknown, .done])
    func everyNonNilExitFromWorkingTriggers(status: AgentStatus) async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        updates.yield(.init(status: status, liveUpdatesAvailable: true))
        await Self.drain()
        #expect(await clock.durations.count == 1)
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)
    }

    @Test func baselineDuplicatesNilAndOtherTransitionsNeverTrigger() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read)])
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        let statuses: [AgentStatus?] = [.done, .idle, .blocked, .idle, .working, .working, nil, .done]
        for status in statuses {
            updates.yield(.init(status: status, liveUpdatesAvailable: true))
            await Self.drain()
        }
        #expect(await clock.durations.isEmpty)
        #expect(await transport.changesReadRequests.count == 1)
    }

    /// A Host that connects again may have run whole turns unseen, so its
    /// first live status that is not Working reads, whether or not the
    /// drop's unknown status reached the store; a Working one waits for
    /// its exit, and the same connection never reads again by itself.
    @Test(arguments: [true, false])
    func aNewConnectionCountsAsAnExit(seesTheDrop: Bool) async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read), .success(read), .success(read)])
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .done, liveUpdatesAvailable: true, connectionGeneration: 0))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        if seesTheDrop {
            updates.yield(.init(status: nil, liveUpdatesAvailable: false, connectionGeneration: 0))
            await Self.drain()
        }
        updates.yield(.init(status: .done, liveUpdatesAvailable: true, connectionGeneration: 1))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)

        updates.yield(.init(status: .done, liveUpdatesAvailable: true, connectionGeneration: 1))
        updates.yield(.init(status: .working, liveUpdatesAvailable: true, connectionGeneration: 2))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)
        updates.yield(.init(status: .done, liveUpdatesAvailable: true, connectionGeneration: 2))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 3)
    }

    @Test func repeatedEdgesRestartTheDebounceAndCoalesceOneFollowUp() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        defer { store.cancel(); updates.finish() }
        let appearing = Task { await store.appear() }
        await localExec.waitForEntry()
        for _ in 0..<3 {
            updates.yield(.init(status: .working, liveUpdatesAvailable: true))
            updates.yield(.init(status: .done, liveUpdatesAvailable: true))
            await Self.drain()
        }
        #expect(await clock.durations == Array(repeating: .milliseconds(300), count: 3))
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 1)
        await localExec.open()
        await appearing.value
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)
        #expect(store.phase == .loaded(read.changes))
    }

    @Test func aTimeoutDropsThePendingFollowUpAndDoesNotRetry() async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.failure(TransportError.gitTimedOut)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        defer { store.cancel(); updates.finish() }
        let appearing = Task { await store.appear() }
        await localExec.waitForEntry()
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        await localExec.open()
        await appearing.value
        await Self.drain()
        #expect(store.phase == .timedOut)
        #expect(await transport.changesReadRequests.count == 1)
    }

    @Test func leavingCancelsTheDebounceAndReappearanceUsesAFreshBaseline() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(read)])
        let clock = ChangesManualSleeper()
        let first = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let second = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        var appearances = 0
        first.continuation.yield(.init(status: .working, liveUpdatesAvailable: true))
        second.continuation.yield(.init(status: .done, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: {
                appearances += 1
                return appearances == 1 ? first.stream : second.stream
            }, sleep: { try await clock.sleep($0) })
        let following = Task { await store.followAgentStatus() }
        await store.appear()
        await Self.drain()
        first.continuation.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        following.cancel()
        await following.value
        await clock.fireAll()
        let reopened = Task { await store.followAgentStatus() }
        defer { reopened.cancel(); second.continuation.finish() }
        await Self.drain()
        #expect(appearances == 2)
        #expect(await clock.durations.count == 1)
        #expect(await transport.changesReadRequests.count == 1)
    }

    @Test func workingReadKeepsItsTimeAndWarningUntilANonWorkingReadSucceeds() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([
            .success(read), .failure(TransportError.gitTimedOut), .success(read)
        ])
        let clock = ChangesManualSleeper()
        var now = Date(timeIntervalSince1970: 1_000)
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) }, now: { now })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        #expect(store.freshness?.readAt == Date(timeIntervalSince1970: 1_000))
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        #expect(store.freshness != nil)
        now = Date(timeIntervalSince1970: 2_000)
        await clock.fireAll()
        await Self.waitUntil { store.timedOutKeepingContent }
        #expect(store.freshness?.readAt == Date(timeIntervalSince1970: 1_000))
        await store.refresh()
        #expect(store.readAt == Date(timeIntervalSince1970: 2_000))
        #expect(store.freshness == nil)
    }

    @Test func onlyAnAutomaticListChangeAnnouncesAndKeepsCheckoutIdentity() async throws {
        let transport = ScriptedTransport()
        let old = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        // Keep the Checkout fixed so the list's SwiftUI identity is stable.
        let clean = CheckoutChangesRead(
            changes: CheckoutChanges(
                checkout: old.changes.checkout, head: old.changes.head, files: [],
                isStatusTruncated: false, isMetadataTruncated: false),
            directoryPrefix: old.directoryPrefix)
        await transport.scriptChangesReads([
            .success(old), .success(old), .success(clean), .success(old)
        ])
        let clock = ChangesManualSleeper()
        var announcements: [String] = []
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) },
            announce: { announcements.append($0) })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        #expect(announcements.isEmpty)
        for expectedAnnouncements in [0, 1] {
            updates.yield(.init(status: .working, liveUpdatesAvailable: true))
            updates.yield(.init(status: .done, liveUpdatesAvailable: true))
            await Self.drain()
            await clock.fireAll()
            await Self.drain()
            #expect(announcements.count == expectedAnnouncements)
        }
        #expect(announcements == ["Checkout Changes updated."])
        #expect(store.checkout == old.changes.checkout)
        await store.refresh()
        #expect(announcements.count == 1)
    }

    @Test func cancellingTheStatusTaskCancelsAnAutomaticReadAndDiscardsItsLateReply() async throws {
        let transport = ScriptedTransport()
        let old = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        let new = try ChangesStoreTests.read(GitProbeRecordings.clean)
        await transport.scriptChangesReads([.success(old), .success(new)])
        let clock = ChangesManualSleeper()
        var announcements: [String] = []
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) },
            now: { Date(timeIntervalSince1970: 1_000) }, announce: { announcements.append($0) })
        let following = Task { await store.followAgentStatus() }
        await store.appear()
        await Self.drain()
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        await clock.fireAll()
        await localExec.waitForEntry()
        following.cancel()
        await following.value
        #expect(!store.isRefreshing)
        await localExec.open()
        await Self.drain()
        #expect(store.phase == .loaded(old.changes))
        #expect(store.readAt == Date(timeIntervalSince1970: 1_000))
        #expect(announcements.isEmpty)
        updates.finish()
    }

    @Test func edgesDuringAnAutomaticReadProduceOneFollowUp() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read), .success(read), .success(read)])
        let clock = ChangesManualSleeper()
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        await clock.fireAll()
        await localExec.waitForEntry()
        for _ in 0..<3 {
            updates.yield(.init(status: .working, liveUpdatesAvailable: true))
            updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
            await Self.drain()
        }
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)
        await localExec.open()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 3)
        #expect(!store.isRefreshing)
    }

    @Test func workingDuringAReadKeepsTheWarningAndUsesTheCompletionTime() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read)])
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: localExec)
        let clock = ChangesManualSleeper()
        var now = Date(timeIntervalSince1970: 1_000)
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .idle, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) }, now: { now })
        defer { store.cancel(); updates.finish() }
        let appearing = Task { await store.appear() }
        await localExec.waitForEntry()
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        now = Date(timeIntervalSince1970: 2_000)
        await localExec.open()
        await appearing.value
        #expect(store.freshness?.readAt == Date(timeIntervalSince1970: 2_000))
        #expect(!store.isRefreshing)
    }

    @Test func anAutomaticRecoveryFromAFailureAnnouncesTheNewList() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.failure(ChangesReadError.incomplete), .success(read)])
        let clock = ChangesManualSleeper()
        var announcements: [String] = []
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) },
            announce: { announcements.append($0) })
        defer { store.cancel(); updates.finish() }
        await store.appear()
        await Self.drain()
        #expect(store.phase == .incomplete)
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntil { store.phase == .loaded(read.changes) }
        #expect(announcements == ["Checkout Changes updated."])
    }

    @Test func theStatusLoopAndPendingDebounceDoNotKeepTheStoreAlive() async throws {
        let clock = ChangesManualSleeper()
        let read = try ChangesStoreTests.read(GitProbeRecordings.clean)
        let (stream, updates) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates.yield(.init(status: .working, liveUpdatesAvailable: true))
        var store: ChangesStore? = ChangesStore(
            directory: { "/app" }, read: { _ in read },
            agentStatus: { stream }, sleep: { try await clock.sleep($0) })
        weak var weakStore = store
        await store?.appear()
        await Self.drain()
        updates.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        #expect(await clock.durations.count == 1)
        store = nil
        await Self.drain()
        #expect(weakStore == nil)
        await clock.fireAll()
        updates.finish()
    }

    @Test func siblingRowsInSameCheckoutShareFreshReadWithoutDuplicateExecs() async throws {
        let hostID = UUID()
        let transport = ScriptedTransport()
        let firstRead = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        let secondRead = CheckoutChangesRead(
            changes: CheckoutChanges(
                checkout: firstRead.changes.checkout,
                head: firstRead.changes.head,
                files: []),
            directoryPrefix: Data())
        await transport.scriptChangesReads([
            .success(firstRead), .success(firstRead), .success(secondRead),
        ])
        let gate = GitExecGate()
        let agents: [ConsoleAgent] = [
            ("/home/dev/src/app", "w1:p1"),
            ("/home/dev/src/app/sub", "w1:p2"),
            ("/home/dev/src/app", "w1:p3"),
        ].map { dir, paneID in
            ConsoleAgent(
                hostID: hostID,
                hostName: "box",
                agent: Agent(
                    AgentInfo(
                        agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
                        tabID: "w1:t1", terminalID: "term_\(paneID)", workspaceID: "w1",
                        agent: "claude", cwd: dir, terminalTitleStripped: paneID)),
                workspaceLabel: "ws",
                repositoryCheckout: nil)
        }
        let rows = AgentRowChanges { agent in
            ChangesStore(
                directory: { agent.directory },
                read: { try await transport.readChanges($0) },
                gate: gate,
                sleep: { _ in })
        }
        for agent in agents { rows.rowAppeared(agent) }
        defer { for agent in agents { rows.rowDisappeared(agent.id) } }
        await Self.waitUntil {
            agents.allSatisfy { rows.store(for: $0)?.phase == .loaded(firstRead.changes) }
        }
        // p1 and p3 share the exact directory, so cold appearance runs 2 execs (root + sub), not 3.
        #expect(await transport.changesReadRequests.count == 2)

        // Now all 3 rows proved the same Checkout topLevel; gate the first
        // refresh read on the wire so the sibling rows queue behind the Host
        // gate, then verify all 3 adopt the single completed read.
        let refreshGate = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: refreshGate)
        let refreshTasks = agents.compactMap { rows.store(for: $0)?.startRead(automatic: true) }
        await refreshGate.waitForEntry()
        await Self.drain()
        await refreshGate.open()
        for task in refreshTasks { await task.value }
        #expect(await transport.changesReadRequests.count == 3)
        #expect(agents.allSatisfy { rows.store(for: $0)?.phase == .loaded(secondRead.changes) })
    }

    @Test func siblingReadStartedBeforeWorkingExitDoesNotCancelPostWorkingRefreshOrClearFreshness() async throws {
        let hostID = UUID()
        let transport = ScriptedTransport()
        let firstRead = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        let secondRead = CheckoutChangesRead(
            changes: CheckoutChanges(
                checkout: firstRead.changes.checkout,
                head: firstRead.changes.head,
                files: Array(firstRead.changes.files.prefix(1))),
            directoryPrefix: Data())
        let thirdRead = CheckoutChangesRead(
            changes: CheckoutChanges(
                checkout: firstRead.changes.checkout,
                head: firstRead.changes.head,
                files: []),
            directoryPrefix: Data())
        await transport.scriptChangesReads([
            .success(firstRead), .success(secondRead), .success(thirdRead),
        ])
        let gate = GitExecGate()
        let clockA = ChangesManualSleeper()
        let clockB = ChangesManualSleeper()
        let statusA = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let statusB = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        statusA.continuation.yield(.init(status: .idle, liveUpdatesAvailable: true))
        statusB.continuation.yield(.init(status: .working, liveUpdatesAvailable: true))
        defer {
            statusA.continuation.finish()
            statusB.continuation.finish()
        }
        let makeAgent = { (paneID: String) in
            ConsoleAgent(
                hostID: hostID,
                hostName: "box",
                agent: Agent(
                    AgentInfo(
                        agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
                        tabID: "w1:t1", terminalID: "term_\(paneID)", workspaceID: "w1",
                        agent: "claude", cwd: "/home/dev/src/app", terminalTitleStripped: paneID)),
                workspaceLabel: "ws",
                repositoryCheckout: nil)
        }
        let agentA = makeAgent("w1:p1")
        let agentB = makeAgent("w1:p2")
        let rows = AgentRowChanges { agent in
            let isA = agent.agent.paneID == "w1:p1"
            return ChangesStore(
                directory: { agent.directory },
                read: { try await transport.readChanges($0) },
                gate: gate,
                agentStatus: { isA ? statusA.stream : statusB.stream },
                sleep: { try await (isA ? clockA : clockB).sleep($0) })
        }
        rows.rowAppeared(agentA)
        rows.rowAppeared(agentB)
        defer {
            rows.rowDisappeared(agentA.id)
            rows.rowDisappeared(agentB.id)
        }
        await Self.drain()
        await clockA.fireAll()
        await clockB.fireAll()
        await Self.waitUntil {
            rows.store(for: agentA)?.phase == .loaded(firstRead.changes)
                && rows.store(for: agentB)?.phase == .loaded(firstRead.changes)
        }
        #expect(await transport.changesReadRequests.count == 1)

        // Start a read on A and hold it in flight on the wire.
        let readAGate = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: readAGate)
        let readATask = rows.store(for: agentA)?.startRead(automatic: true)
        await readAGate.waitForEntry()

        // While A's read is in flight, B exits Working and its debounce queues
        // a post-Working refresh behind the Host gate.
        statusB.continuation.yield(.init(status: .done, liveUpdatesAvailable: true))
        await Self.drain()
        await clockB.fireAll()
        await Self.drain()

        // Hold B's post-Working read too so we can observe B's state right
        // after A's older snapshot finishes.
        let readBGate = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: readBGate)
        await readAGate.open()
        await readATask?.value

        // B's queued post-Working read must NOT have been cancelled by A's
        // earlier-dispatched snapshot, and B must keep its working freshness
        // warning until its own post-Working read completes.
        await readBGate.waitForEntry()
        #expect(rows.store(for: agentB)?.freshness != nil)
        await readBGate.open()
        await Self.waitUntil {
            rows.store(for: agentB)?.phase == .loaded(thirdRead.changes)
                && rows.store(for: agentB)?.freshness == nil
        }
        #expect(await transport.changesReadRequests.count == 3)
    }

    @Test func siblingReadCopiesDirectoryPrefixForSameDirectoryAndPreservesOtherSubdirectoryPrefix() async throws {
        let hostID = UUID()
        let transport = ScriptedTransport()
        let base = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        let subRead = CheckoutChangesRead(
            changes: base.changes,
            directoryPrefix: Data("sub/".utf8))
        let otherRead = CheckoutChangesRead(
            changes: base.changes,
            directoryPrefix: Data("other/".utf8))
        let newerSubRead = CheckoutChangesRead(
            changes: CheckoutChanges(
                checkout: base.changes.checkout,
                head: base.changes.head,
                files: []),
            directoryPrefix: Data("sub/".utf8))
        await transport.scriptChangesReads([
            .success(subRead), .success(otherRead), .success(newerSubRead),
        ])
        let gate = GitExecGate()
        let makeAgent = { (dir: String, paneID: String) in
            ConsoleAgent(
                hostID: hostID,
                hostName: "box",
                agent: Agent(
                    AgentInfo(
                        agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
                        tabID: "w1:t1", terminalID: "term_\(paneID)", workspaceID: "w1",
                        agent: "claude", cwd: dir, terminalTitleStripped: paneID)),
                workspaceLabel: "ws",
                repositoryCheckout: nil)
        }
        let sub1 = makeAgent("/home/dev/src/app/sub", "w1:p1")
        let sub2 = makeAgent("/home/dev/src/app/sub", "w1:p2")
        let other = makeAgent("/home/dev/src/app/other", "w1:p3")
        let rows = AgentRowChanges { agent in
            ChangesStore(
                directory: { agent.directory },
                read: { try await transport.readChanges($0) },
                gate: gate,
                sleep: { _ in })
        }
        for agent in [sub1, sub2, other] { rows.rowAppeared(agent) }
        defer { for agent in [sub1, sub2, other] { rows.rowDisappeared(agent.id) } }
        await Self.waitUntil {
            [sub1, sub2, other].allSatisfy { rows.store(for: $0)?.phase == .loaded(base.changes) }
        }
        #expect(await transport.changesReadRequests.count == 2)
        #expect(rows.store(for: sub2)?.directoryPrefix == Data("sub/".utf8))
        #expect(rows.store(for: other)?.directoryPrefix == Data("other/".utf8))

        // Opening Changes detail from the sibling row that adopted without
        // running git must inherit the subdirectory prefix immediately.
        let detail = ChangesStore(
            directory: { sub2.directory },
            read: { try await transport.readChanges($0) })
        rows.changesOpened(detail, for: sub2.id, startsFromRow: true)
        #expect(detail.directoryPrefix == Data("sub/".utf8))
        rows.changesClosed(detail, for: sub2.id)

        // When sub1 reads again, `other` adopts the newer Checkout totals but
        // preserves its own `other/` directory prefix.
        await rows.store(for: sub1)?.refresh(automatic: true)
        #expect(rows.store(for: other)?.phase == .loaded(newerSubRead.changes))
        #expect(rows.store(for: other)?.directoryPrefix == Data("other/".utf8))
    }

    private static func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }
}
