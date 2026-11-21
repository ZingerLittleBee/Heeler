import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("File diff list changes", .timeLimit(.minutes(1)))
struct FileDiffListChangeTests {
    private static func file(_ added: Int) -> ChangedFile {
        ChangedFile(
            path: Data("source.swift".utf8), originalPath: nil, kind: .modified,
            staging: .unstaged, lineCounts: .lines(added: added, removed: 1))
    }

    private static func changes(_ files: [ChangedFile], truncated: Bool = false) -> CheckoutChanges {
        CheckoutChanges(
            checkout: CheckoutLocation(
                topLevel: Data("/app".utf8), isLinkedWorktree: false, displayPath: "/app"),
            head: CheckoutHead(branch: .named("main"), commit: nil, latestCommit: nil),
            files: files, isStatusTruncated: truncated)
    }

    @Test func changedCountsKeepThePatchAndTimeUntilReload() async throws {
        let transport = ScriptedTransport()
        let old = Self.file(2)
        let new = Self.file(7)
        let before = Self.changes([old])
        let after = Self.changes([new])
        await transport.scriptChangesReads([
            .success(CheckoutChangesRead(changes: before, directoryPrefix: Data())),
            .success(CheckoutChangesRead(changes: after, directoryPrefix: Data()))
        ])
        let patch = FilePatch(files: [], isTruncated: true)
        let reloaded = FilePatch(files: [], isTruncated: false)
        await transport.scriptFilePatchReads([.success(patch), .success(patch), .success(reloaded)])
        var now = Date(timeIntervalSince1970: 1_000)
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            readPatch: { try await transport.readFilePatch($0) }, now: { now })
        defer { store.cancel() }
        await store.appear()
        store.openDiff(old)
        let diff = try #require(store.fileDiff.current)
        await diff.appear()
        await diff.loadMore()
        #expect(diff.truncation == .tooLarge)
        await store.refresh()
        #expect(diff.listChange == .changed)
        #expect(diff.phase == .loaded(patch))
        #expect(diff.readAt == Date(timeIntervalSince1970: 1_000))
        #expect(await transport.filePatchRequests.count == 2)
        now = Date(timeIntervalSince1970: 2_000)
        await diff.reload()
        #expect(diff.listChange == nil)
        #expect(diff.file.lineCounts == .lines(added: 7, removed: 1))
        #expect(diff.phase == .loaded(reloaded))
        #expect(diff.readAt == now)
        #expect(diff.truncation == .none)
        #expect(await transport.filePatchRequests.map(\.limit) == [.initial, .extended, .initial])
        #expect(await transport.changesReadRequests.count == 2)
    }
    @Test func aRemovedFileOffersReloadAndAnUnchangedCleanListDoesNotRepeatTheNotice() async {
        let file = Self.file(2)
        let patch = FilePatch(files: [], isTruncated: false)
        let diff = FileDiffStore(file: file, checkout: Self.changes([file]).checkout, read: { _ in patch })
        await diff.appear()
        let time = diff.readAt
        diff.noteListRefresh(Self.changes([]))
        #expect(diff.listChange == .removed)
        #expect(diff.phase == .loaded(patch))
        #expect(diff.readAt == time)
        await diff.reload()
        #expect(diff.listChange == nil)
        diff.noteListRefresh(Self.changes([]))
        #expect(diff.listChange == nil)
        diff.noteListRefresh(Self.changes([file]))
        #expect(diff.listChange == .changed)
    }

    @Test func incompleteListsAndCollapsedDirectoriesDoNotProveRemoval() async {
        let child = ChangedFile(
            path: Data("newdir/child.swift".utf8), originalPath: nil, kind: .untracked, staging: nil)
        let directory = ChangedFile(
            path: Data("newdir/".utf8), originalPath: nil, kind: .untracked, staging: nil)
        let patch = FilePatch(files: [], isTruncated: false)
        let diff = FileDiffStore(
            file: child, checkout: Self.changes([directory]).checkout, read: { _ in patch })
        await diff.appear()
        diff.noteListRefresh(Self.changes([], truncated: true))
        #expect(diff.listChange == nil)
        diff.noteListRefresh(Self.changes([directory]))
        #expect(diff.listChange == nil)
        diff.noteListRefresh(Self.changes([]))
        #expect(diff.listChange == .removed)
        diff.noteListRefresh(Self.changes([], truncated: true))
        #expect(diff.listChange == .removed)
    }

    @Test func unchangedFilesAndFilesBeyondTheDisplayLimitAreNotReportedRemoved() async {
        let file = Self.file(2)
        let diff = FileDiffStore(
            file: file, checkout: Self.changes([file]).checkout,
            read: { _ in FilePatch(files: [], isTruncated: false) })
        await diff.appear()
        let preceding = (0..<CheckoutChanges.displayLimit).map { index in
            ChangedFile(
                path: Data("\(index).swift".utf8), originalPath: nil, kind: .modified, staging: .unstaged)
        }
        diff.noteListRefresh(Self.changes(preceding + [file]))
        #expect(diff.listChange == nil)
        diff.noteListRefresh(Self.changes(preceding + [Self.file(9)]))
        #expect(diff.listChange == .changed)
    }

    @Test func failedReloadKeepsTheOldPatchTimeAndNoticeThenPullRetriesTheFileOnly() async throws {
        let transport = ScriptedTransport()
        let patch = FilePatch(files: [], isTruncated: false)
        await transport.scriptFilePatchReads([
            .success(patch), .failure(TransportError.gitTimedOut), .success(patch)
        ])
        var now = Date(timeIntervalSince1970: 1_000)
        let file = Self.file(2)
        let diff = FileDiffStore(
            file: file, checkout: Self.changes([file]).checkout,
            read: { try await transport.readFilePatch($0) }, now: { now })
        await diff.appear()
        diff.noteListRefresh(Self.changes([Self.file(9)]))
        now = Date(timeIntervalSince1970: 2_000)
        await diff.reload()
        #expect(diff.listChange == .changed)
        #expect(diff.phase == .loaded(patch))
        #expect(diff.readAt == Date(timeIntervalSince1970: 1_000))
        #expect(diff.refreshError != nil)
        await diff.refresh()
        #expect(diff.listChange == nil)
        #expect(diff.readAt == now)
        #expect(await transport.changesReadRequests.isEmpty)
    }

    @Test func aListChangeDuringReloadIsNotClearedByAnOlderPatchReply() async throws {
        let transport = ScriptedTransport()
        let patch = FilePatch(files: [], isTruncated: false)
        await transport.scriptFilePatchReads([.success(patch), .success(patch)])
        let file = Self.file(2)
        let diff = FileDiffStore(
            file: file, checkout: Self.changes([file]).checkout,
            read: { try await transport.readFilePatch($0) })
        await diff.appear()
        diff.noteListRefresh(Self.changes([Self.file(3)]))
        let localExec = ScriptedTransportCallGate()
        await transport.gateNextFilePatchRead(using: localExec)
        let reloading = Task { await diff.reload() }
        await localExec.waitForEntry()
        diff.noteListRefresh(Self.changes([Self.file(9)]))
        await localExec.open()
        await reloading.value
        #expect(diff.file.lineCounts == .lines(added: 3, removed: 1))
        #expect(diff.listChange == .changed)
    }

    @Test func aFailedListRefreshKeepsTheExistingDiffNotice() async throws {
        let transport = ScriptedTransport()
        let original = Self.changes([Self.file(2)])
        let changed = Self.changes([Self.file(9)])
        await transport.scriptChangesReads([
            .success(.init(changes: original, directoryPrefix: Data())),
            .success(.init(changes: changed, directoryPrefix: Data())),
            .failure(TransportError.gitTimedOut)
        ])
        let patch = FilePatch(files: [], isTruncated: false)
        await transport.scriptFilePatchReads([.success(patch)])
        let store = ChangesStore(
            directory: { "/app" }, read: { try await transport.readChanges($0) },
            readPatch: { try await transport.readFilePatch($0) })
        defer { store.cancel() }
        await store.appear()
        store.openDiff(Self.file(2))
        let diff = try #require(store.fileDiff.current)
        await diff.appear()
        await store.refresh()
        let time = diff.readAt
        await store.refresh()
        #expect(diff.listChange == .changed)
        #expect(diff.readAt == time)
        #expect(diff.phase == .loaded(patch))
        #expect(await transport.filePatchRequests.count == 1)
    }
}
