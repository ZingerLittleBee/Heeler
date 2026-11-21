import Foundation
import Testing

@testable import Heeler

/// Expanding an untracked directory over the scripted Transport, and what a
/// refresh does to that expansion.
@MainActor
@Suite("Changes untracked directories", .timeLimit(.minutes(1)))
struct ChangesUntrackedDirectoryStoreTests {
    @Test func aTransportWithoutGitReportsTheListingUnavailable() async {
        let transport = FakeTransport(
            pingResult: .success(ServerInfo(version: "0.9.0", protocolVersion: 22)))
        let request = UntrackedDirectoryRequest(
            topLevel: Data("/home/dev/src/app".utf8), directory: Data("newdir/".utf8))
        await #expect(throws: ChangesReadError.unavailable) {
            _ = try await transport.listUntrackedDirectory(request)
        }
    }

    @Test func anUnscriptedListingReportsChangesUnavailable() async {
        let transport = ScriptedTransport()
        let request = UntrackedDirectoryRequest(
            topLevel: Data("/home/dev/src/app".utf8), directory: Data("newdir/".utf8))
        await #expect(throws: ChangesReadError.unavailable) {
            _ = try await transport.listUntrackedDirectory(request)
        }
    }

    @Test func tappingADirectoryListsItsFilesAndTappingAgainCollapsesIt() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        let listing = try Self.listing()
        await transport.scriptUntrackedDirectoryListings([.success(listing)])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextUntrackedDirectoryListing(using: gate)

        let expanding = Task { await store.toggleDirectory(directory) }
        await gate.waitForEntry()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loading)
        #expect(store.phase == .loaded(read.changes))

        await gate.open()
        await expanding.value
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))
        let requests = await transport.untrackedDirectoryRequests
        #expect(
            requests == [
                UntrackedDirectoryRequest(
                    topLevel: read.changes.checkout.topLevel, directory: directory.path)
            ])
        #expect(requests.first?.directory == Data("newdir/".utf8))

        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(await transport.untrackedDirectoryRequests.count == 1)
    }

    @Test func theListingReachesTheStoreUnchanged() async throws {
        let transport = ScriptedTransport()
        let (store, _, directory) = try await Self.loaded(transport)
        let listing = try GitProbe.parseUntrackedDirectory(
            stdout: GitProbeRecordings.untrackedListing.stdout,
            stderr: GitProbeRecordings.untrackedListing.stderr,
            nonce: GitProbeRecordings.nonce,
            directory: Data("newdir/".utf8),
            displayLimit: 2)
        await transport.scriptUntrackedDirectoryListings([.success(listing)])

        await store.toggleDirectory(directory)

        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))
        #expect(listing.total == 18)
        #expect(listing.entries.count == 2)
        #expect(listing.limitNotice != nil)
    }

    @Test func aRefreshCollapsesExpandedDirectoriesWithoutListingAgain() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        await transport.scriptUntrackedDirectoryListings([.success(try Self.listing())])
        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) != nil)

        await transport.scriptChangesReads([.success(read)])
        await store.refresh()

        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(await transport.untrackedDirectoryRequests.count == 1)
        #expect(await transport.changesReadRequests.count == 2)
    }

    @Test func aFailedRefreshKeepsTheExpansionUntilTheNextSuccess() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        let listing = try Self.listing()
        await transport.scriptUntrackedDirectoryListings([.success(listing)])
        await store.toggleDirectory(directory)

        await transport.scriptChangesReads([.failure(TransportError.gitTimedOut)])
        await store.refresh()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))

        await transport.scriptChangesReads([.success(read)])
        await store.refresh()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
    }

    @Test func aTimedOutRefreshKeepsExpandedDirectoriesAndTheKeptContent() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        let listing = try Self.listing()
        await transport.scriptUntrackedDirectoryListings([.success(listing)])
        await store.toggleDirectory(directory)

        await transport.scriptChangesReads([.failure(TransportError.gitTimedOut)])
        await store.refresh()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))
        #expect(store.timedOutKeepingContent)
        #expect(store.phase == .loaded(read.changes))

        await transport.scriptChangesReads([.success(read)])
        await store.refresh()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(!store.timedOutKeepingContent)
    }

    @Test func aListingThatLandsAfterARefreshIsDiscarded() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        await transport.scriptChangesReads([.success(read)])
        await transport.scriptUntrackedDirectoryListings([.success(try Self.listing())])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextUntrackedDirectoryListing(using: gate)

        let expanding = Task { await store.toggleDirectory(directory) }
        await gate.waitForEntry()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loading)

        await store.refresh()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)

        await gate.open()
        await expanding.value
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(await transport.untrackedDirectoryRequests.count == 1)
    }

    @Test func collapsingWhileAListingIsInFlightDropsTheLateResult() async throws {
        let transport = ScriptedTransport()
        let (store, _, directory) = try await Self.loaded(transport)
        await transport.scriptUntrackedDirectoryListings([.success(try Self.listing())])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextUntrackedDirectoryListing(using: gate)

        let expanding = Task { await store.toggleDirectory(directory) }
        await gate.waitForEntry()
        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)

        await gate.open()
        await expanding.value
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
    }

    /// A is expanded and B is waiting on its listing. Collapsing A must not
    /// leave B on loading after B's listing lands.
    @Test func collapsingOneDirectoryLeavesAnothersInFlightListing() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        let listing = try Self.listing()
        let other = ChangedFile(
            path: Data("other/".utf8), originalPath: nil, kind: .untracked, staging: nil)
        let kept = UntrackedDirectoryListing(
            directory: other.path,
            entries: [
                ChangedFile(
                    path: Data("other/a.txt".utf8), originalPath: nil, kind: .untracked,
                    staging: nil)
            ],
            total: 1,
            isTruncated: false,
            isSeparateRepository: false,
            limitNotice: nil)
        await transport.scriptUntrackedDirectoryListings([
            .success(listing),
            .success(kept),
        ])
        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))

        let gate = ScriptedTransportCallGate()
        await transport.gateNextUntrackedDirectoryListing(using: gate)
        let expanding = Task { await store.toggleDirectory(other) }
        await gate.waitForEntry()
        #expect(store.untrackedDirectories.expansion(for: other.path) == .loading)

        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(store.untrackedDirectories.expansion(for: other.path) == .loading)

        await gate.open()
        await expanding.value
        #expect(store.untrackedDirectories.expansion(for: other.path) == .loaded(kept))
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(store.phase == .loaded(read.changes))
        #expect(await transport.untrackedDirectoryRequests.count == 2)
    }

    /// Collapsing and opening the same directory again drops the listing that
    /// was already in flight, then keeps the new one.
    @Test func reopeningADirectoryDropsTheListingThatWasCollapsed() async throws {
        let transport = ScriptedTransport()
        let (store, _, directory) = try await Self.loaded(transport)
        let stale = try Self.listing()
        let fresh = UntrackedDirectoryListing(
            directory: directory.path,
            entries: [],
            total: 0,
            isTruncated: false,
            isSeparateRepository: false,
            limitNotice: nil)
        await transport.scriptUntrackedDirectoryListings([
            .success(stale),
            .success(fresh),
        ])
        let firstGate = ScriptedTransportCallGate()
        await transport.gateNextUntrackedDirectoryListing(using: firstGate)
        let first = Task { await store.toggleDirectory(directory) }
        await firstGate.waitForEntry()

        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)

        let secondGate = ScriptedTransportCallGate()
        await transport.gateNextUntrackedDirectoryListing(using: secondGate)
        let second = Task { await store.toggleDirectory(directory) }
        await secondGate.waitForEntry()
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loading)

        await firstGate.open()
        await first.value
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loading)

        await secondGate.open()
        await second.value
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(fresh))
        #expect(await transport.untrackedDirectoryRequests.count == 2)
    }

    @Test func aFailedListingStaysOnThatDirectoryAndTheNextTapReadsAgain() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        let listing = try Self.listing()
        await transport.scriptUntrackedDirectoryListings([
            .failure(ChangesReadError.gitFailed("fatal: cannot change to '/home/dev/src/app'")),
            .success(listing),
        ])

        await store.toggleDirectory(directory)
        #expect(
            store.untrackedDirectories.expansion(for: directory.path)
                == .failed("fatal: cannot change to '/home/dev/src/app'"))
        #expect(store.phase == .loaded(read.changes))
        #expect(await transport.untrackedDirectoryRequests.count == 1)

        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(await transport.untrackedDirectoryRequests.count == 1)

        await store.toggleDirectory(directory)
        #expect(store.untrackedDirectories.expansion(for: directory.path) == .loaded(listing))
        #expect(await transport.untrackedDirectoryRequests.count == 2)
    }

    @Test func anExpandedDirectoryOpensItsFirstChildAsAnUntrackedPatch() async throws {
        let transport = ScriptedTransport()
        let (store, _, directory) = try await Self.loaded(transport)
        let listing = try Self.listing()
        await transport.scriptUntrackedDirectoryListings([.success(listing)])
        await transport.scriptFilePatchReads([.success(FilePatch(files: [], isTruncated: false))])
        await store.toggleDirectory(directory)

        let child = try #require(listing.entries.first)
        store.openDiff(child)
        let diff = try #require(store.fileDiff.current)
        await diff.appear()

        let requests = await transport.filePatchRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.isUntracked)
        #expect(request.path == child.path)
    }

    @Test func aCancelledListingLeavesTheDirectoryCollapsed() async throws {
        let transport = ScriptedTransport()
        let (store, read, directory) = try await Self.loaded(transport)
        await transport.scriptUntrackedDirectoryListings([.failure(TransportError.cancelled)])

        await store.toggleDirectory(directory)

        #expect(store.untrackedDirectories.expansion(for: directory.path) == nil)
        #expect(store.phase == .loaded(read.changes))
        #expect(await transport.untrackedDirectoryRequests.count == 1)
    }

    private static func listing() throws -> UntrackedDirectoryListing {
        try GitProbe.parseUntrackedDirectory(
            stdout: GitProbeRecordings.untrackedListing.stdout,
            stderr: GitProbeRecordings.untrackedListing.stderr,
            nonce: GitProbeRecordings.nonce,
            directory: Data("newdir/".utf8))
    }

    private static func loaded(
        _ transport: ScriptedTransport
    ) async throws -> (ChangesStore, CheckoutChangesRead, ChangedFile) {
        let read = try ChangesStoreTests.read(GitProbeRecordings.hostile)
        await transport.scriptChangesReads([.success(read)])
        let store = ChangesStore(
            directory: { "/home/dev/src/app" },
            read: { request in try await transport.readChanges(request) },
            readPatch: { request in try await transport.readFilePatch(request) },
            listUntrackedDirectory: { request in
                try await transport.listUntrackedDirectory(request)
            })
        await store.appear()
        let directory = try #require(read.changes.files.first { $0.isUntrackedDirectory })
        return (store, read, directory)
    }
}
