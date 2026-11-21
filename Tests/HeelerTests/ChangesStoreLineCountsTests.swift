import Foundation
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("Changes store line counts and header")
struct ChangesStoreLineCountsTests {
    @Test func loadedFilesAndHeaderKeepTrackedCountsSeparateFromUntrackedItems() async throws {
        let changes = try await load(GitProbeRecordings.tracking)
        #expect(changes.files.first { $0.displayPath == "app.txt" }?.lineCounts
            == .lines(added: 3, removed: 1))
        let binary = try #require(changes.files.first { $0.displayPath == "logo.bin" })
        #expect(binary.lineCounts == .binary)
        #expect(binary.rowAccessibilityLabel == "logo.bin, modified, staged, binary")
        let new = try #require(changes.files.first { $0.displayPath == "notes.txt" })
        #expect(new.lineCounts == nil)
        #expect(new.rowAccessibilityLabel == "notes.txt, untracked")
        #expect(changes.totals.trackedFiles == 2)
        #expect(changes.totals.untrackedItems == 1)
        #expect(changes.totals.added == 3)
        #expect(changes.totals.removed == 1)
        #expect(changes.totals.accessibilitySummary
            == "2 files changed. 3 lines added, 1 line removed in tracked files. 1 untracked item")
    }

    @Test func theHeaderShowsCommitsAheadAndBehindItsUpstream() async throws {
        let changes = try await load(GitProbeRecordings.tracking)
        #expect(changes.head.upstream?.state == .tracking(ahead: 2, behind: 1))
        #expect(changes.head.upstream?.summary == "origin/main: 2 ahead, 1 behind")
        #expect(summary(changes).contains("2 commits ahead and 1 commit behind origin/main."))
    }

    @Test func aDeletedFilesCountLabelDoesNotDependOnItsRowBeingVisible() async throws {
        let changes = try await load(GitProbeRecordings.hostile)
        let deleted = try #require(changes.files.first { $0.displayPath == "gone.txt" })
        #expect(deleted.rowAccessibilityLabel
            == "gone.txt, deleted, unstaged, 0 lines added, 1 line removed")
    }

    @Test func theHeaderStatesWhenTheUpstreamWasDeleted() async throws {
        let changes = try await load(GitProbeRecordings.upstreamGone)
        #expect(changes.head.upstream?.state == .deleted)
        #expect(changes.head.upstream?.summary == "Upstream origin/feature was deleted")
        #expect(summary(changes).contains("Upstream origin/feature was deleted."))
    }

    @Test func aDetachedHeadKeepsItsCommitAndHasNoUpstream() async throws {
        let changes = try await load(GitProbeRecordings.worktree)
        #expect(changes.head.branch == .detached)
        #expect(changes.head.upstream == nil)
        #expect(!changes.head.isUnborn)
        #expect(summary(changes).contains("Detached at 4f87954."))
        #expect(!summary(changes).contains("No commits yet"))
        #expect(changes.totals.added == 1)
        #expect(changes.totals.removed == 0)
        #expect(changes.totals.trackedFiles == 1)
    }

    @Test func anUnbornCheckoutSaysNoCommitsYetOnBothObjectFormats() async throws {
        for recording in [GitProbeRecordings.unborn, GitProbeRecordings.unbornSHA256] {
            let changes = try await load(recording)
            #expect(changes.head.isUnborn)
            #expect(changes.head.commit == nil)
            #expect(changes.head.latestCommit == nil)
            #expect(summary(changes).contains("Branch main. No commits yet."))
            #expect(changes.files.first { $0.displayPath == "staged.txt" }?.kind == .added)
            #expect(changes.files.first { $0.displayPath == "loose.txt" }?.kind == .untracked)
        }
    }

    @Test func anUnbornCheckoutKeepsItsLiveUpstreamWithoutClaimingDeletion() async throws {
        let changes = try await load(GitProbeRecordings.countsUnbornWithLiveUpstream)
        #expect(changes.head.isUnborn)
        #expect(changes.head.upstream?.state == .unknown)
        #expect(summary(changes).contains("Branch main. No commits yet."))
        #expect(summary(changes).contains("Upstream origin/main, comparison unavailable."))
        #expect(!summary(changes).contains("was deleted"))
        #expect(changes.totals.trackedFiles == 1)
        #expect(changes.totals.untrackedItems == 1)
    }

    @Test func aRefreshReplacesCountsWithoutChangingRowIdentity() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesStoreTests.read(GitProbeRecordings.tracking)
        // Script a subsequent read of the same paths with different counts.
        let updated = Data(String(decoding: GitProbeRecordings.tracking.stdout, as: UTF8.self)
            .replacingOccurrences(of: "3\t1\tapp.txt", with: "5\t2\tapp.txt").utf8)
        let second = try ChangesStoreTests.read((updated, GitProbeRecordings.tracking.stderr))
        await transport.scriptChangesReads([.success(first), .success(second)])
        let store = Self.store(transport)
        await store.appear()
        #expect(store.phase == .loaded(first.changes))
        await store.refresh()
        guard case .loaded(let changes) = store.phase else {
            Issue.record("expected loaded Changes after refresh")
            return
        }
        #expect(changes.files.map(\.id) == first.changes.files.map(\.id))
        #expect(changes.files.first { $0.displayPath == "app.txt" }?.lineCounts
            == .lines(added: 5, removed: 2))
        #expect(changes.totals.added == 5)
        #expect(changes.totals.removed == 2)
        #expect(await transport.changesReadRequests.count == 2)
    }

    @Test func countsProvideDisplayAndVoiceOverTextForTheTooLargeDiffSeam() throws {
        let changes = try ChangesStoreTests.read(GitProbeRecordings.rewrittenRename).changes
        let file = try #require(changes.files.first)
        #expect(file.lineCounts?.summary == "+41 −20 lines")
        #expect(file.lineCounts?.accessibilityLabel == "41 lines added, 20 lines removed")
        #expect(file.rowAccessibilityLabel
            == "new.txt, renamed from old.txt, staged and unstaged, 41 lines added, 20 lines removed")
        #expect(LineCounts.binary.summary == "Binary")
        #expect(LineCounts.binary.accessibilityLabel == "binary")
    }

    private func load(_ recording: (stdout: Data, stderr: Data)) async throws -> CheckoutChanges {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.success(try ChangesStoreTests.read(recording))])
        let store = Self.store(transport)
        await store.appear()
        guard case .loaded(let changes) = store.phase else {
            Issue.record("expected loaded Changes, got \(store.phase)")
            throw ChangesReadError.incomplete
        }
        return changes
    }

    private static func store(_ transport: ScriptedTransport) -> ChangesStore {
        ChangesStore(directory: { "/home/dev/src/app" }, read: { request in
            try await transport.readChanges(request)
        })
    }

    private func summary(_ changes: CheckoutChanges) -> String {
        changes.accessibilitySummary(
            relativeTo: Date(timeIntervalSince1970: 1_790_600_000),
            locale: Locale(identifier: "en_US"))
    }
}

@Suite("Changes list row text")
struct ChangesRowTextTests {
    @Test func aRowNamesTheFileAndItsDirectory() {
        let file = Self.file("Sources/Checkout/CartStore.swift", staging: .unstaged)
        #expect(file.fileName == "CartStore.swift")
        #expect(file.directory == "Sources/Checkout")
        #expect(file.rowDetail == "Sources/Checkout")
        let topLevel = Self.file("README.md", staging: .unstaged)
        #expect(topLevel.fileName == "README.md")
        #expect(topLevel.directory == "")
        #expect(topLevel.rowDetail == nil)
    }

    /// The group carries staging, so the row's text never does.
    @Test func stagingIsLeftToTheGroup() {
        #expect(Self.file("a/b.swift", staging: .staged).rowDetail == "a")
        #expect(Self.file("a/b.swift", staging: .both).rowDetail == "a")
        #expect(Self.file("b.swift", staging: .staged).rowDetail == nil)
        #expect(Self.file("a/b.swift", staging: .both).isPartlyStaged)
        #expect(!Self.file("a/b.swift", staging: .staged).isPartlyStaged)
    }

    @Test func eachFileFallsInItsSourceControlGroup() {
        #expect(ChangesFileGroup(Self.file("a", kind: .conflicted, staging: nil)) == .conflicts)
        #expect(ChangesFileGroup(Self.file("a", kind: .added, staging: .staged)) == .staged)
        #expect(ChangesFileGroup(Self.file("a", staging: .unstaged)) == .changes)
        #expect(ChangesFileGroup(Self.file("a", staging: .both)) == .changes)
        #expect(ChangesFileGroup(Self.file("a/", kind: .untracked, staging: nil)) == .untracked)
    }

    /// Groups follow VS Code's order, keep the files' order, and leave out
    /// a group with nothing in it.
    @Test func theListGroupsItsFilesInOrder() {
        let changes = CheckoutChanges(
            checkout: Self.location("~/src/app"),
            head: CheckoutHead(branch: .named("main"), commit: nil, latestCommit: nil),
            files: [
                Self.file("c.swift", kind: .conflicted, staging: nil),
                Self.file("a.swift", staging: .unstaged),
                Self.file("b.swift", staging: .staged),
                Self.file("d.swift", staging: .both),
                Self.file("new.txt", kind: .untracked, staging: nil),
            ])
        #expect(changes.listedSections.map(\.group) == [.conflicts, .staged, .changes, .untracked])
        #expect(changes.listedSections.map { $0.files.map(\.displayPath) }
            == [["c.swift"], ["b.swift"], ["a.swift", "d.swift"], ["new.txt"]])
        let unstagedOnly = CheckoutChanges(
            checkout: Self.location("~/src/app"),
            head: CheckoutHead(branch: .named("main"), commit: nil, latestCommit: nil),
            files: [Self.file("a.swift", staging: .unstaged)])
        #expect(unstagedOnly.listedSections.map(\.group) == [.changes])
    }

    @Test func aRenameShowsWhereItCameFrom() {
        // Moved between directories under the same name.
        #expect(
            Self.file(
                "Sources/Shipping/ShippingRates.swift",
                from: "Sources/Checkout/ShippingRates.swift", kind: .renamed, staging: .staged
            ).rowDetail == "Sources/Checkout → Sources/Shipping")
        // Renamed in place.
        #expect(
            Self.file(
                "Sources/Checkout/PaymentSheet.swift",
                from: "Sources/Checkout/LegacyPaymentSheet.swift", kind: .renamed, staging: .staged
            ).rowDetail == "From LegacyPaymentSheet.swift · Sources/Checkout")
        // Renamed and moved, or moved to or from the top level.
        #expect(
            Self.file("New/b.swift", from: "Old/a.swift", kind: .renamed, staging: .staged)
                .rowDetail == "From Old/a.swift · New")
        #expect(
            Self.file("b.swift", from: "Old/b.swift", kind: .renamed, staging: .staged)
                .rowDetail == "From Old/b.swift")
    }

    @Test func anUntrackedFolderKeepsItsSlash() {
        let nested = Self.file("Fixtures/receipts/", kind: .untracked, staging: nil)
        #expect(nested.fileName == "receipts/")
        #expect(nested.directory == "Fixtures")
        #expect(nested.rowDetail == "Fixtures")
        let topLevel = Self.file("Fixtures/", kind: .untracked, staging: nil)
        #expect(topLevel.fileName == "Fixtures/")
        #expect(topLevel.rowDetail == nil)
        #expect(Self.file("notes.txt", kind: .untracked, staging: nil).rowDetail == nil)
    }

    @Test func aCheckoutIsNamedByItsLastComponent() {
        #expect(Self.location("~/src/storefront").name == "storefront")
        #expect(Self.location("/workspace/heeler/").name == "heeler")
        #expect(Self.location("~").name == "~")
        #expect(Self.location("/").name == "/")
    }

    private static func file(
        _ path: String, from original: String? = nil, kind: ChangedFile.Kind = .modified,
        staging: ChangedFile.Staging?
    ) -> ChangedFile {
        ChangedFile(
            path: Data(path.utf8), originalPath: original.map { Data($0.utf8) }, kind: kind,
            staging: staging)
    }

    private static func location(_ displayPath: String) -> CheckoutLocation {
        CheckoutLocation(topLevel: Data(), isLinkedWorktree: false, displayPath: displayPath)
    }

    private static func changes(tracked: Int, untracked: Int, truncated: Bool = false)
        -> CheckoutChanges
    {
        var changes = CheckoutChanges(
            checkout: location("~/src/app"),
            head: CheckoutHead(branch: .named("main"), commit: nil, latestCommit: nil),
            files: [])
        changes.totals = ChangesTotals(trackedFiles: tracked, untrackedItems: untracked)
        changes.isStatusTruncated = truncated
        return changes
    }
}

@MainActor
@Suite("Tide git item")
struct TideGitItemTests {
    @Test func countsEachSideOfEachFileAsTideDoes() {
        let item = TideGitItem(Self.changes(
            files: [
                Self.file("a.swift", staging: .staged),
                Self.file("b.swift", staging: .unstaged),
                Self.file("c.swift", staging: .both),
                Self.file("d.swift", kind: .conflicted, staging: nil),
                Self.file("notes/", kind: .untracked, staging: nil),
            ],
            untracked: 1, upstream: .tracking(ahead: 2, behind: 1)))
        #expect(item.text == "main ⇣1 ⇡2 ~1 +2 !2 ?1")
        #expect(
            item.accessibilityValue
                == "Branch main, 1 commit behind, 2 commits ahead, 1 conflicted, 2 staged, "
                + "2 modified, 1 untracked")
    }

    @Test func aCleanCheckoutShowsItsBranchAlone() {
        for upstream: CheckoutUpstream.State in [.tracking(ahead: 0, behind: 0), .deleted, .unknown] {
            let item = TideGitItem(Self.changes(files: [], upstream: upstream))
            #expect(item.text == "main")
            #expect(item.counts.isEmpty)
        }
    }

    @Test func aDetachedHeadShowsItsShortCommit() {
        let item = TideGitItem(Self.changes(branch: .detached, files: []))
        #expect(item.isDetached)
        #expect(item.location == "4f1a9c2")
        #expect(item.text == "@4f1a9c2")
        #expect(item.accessibilityValue == "Detached at 4f1a9c2")
    }

    @Test func aLongBranchShortensAsTideDoes() {
        let name = "feature/checkout-retry-keeps-the-cart"
        let item = TideGitItem(Self.changes(branch: .named(name), files: []))
        #expect(item.location == "feature/checkout-retry-…")
        #expect(item.location.count == TideGitItem.truncationLength)
        #expect(item.accessibilityValue == "Branch \(name)")
        #expect(TideGitItem.shortened(String(repeating: "a", count: 24)).count == 24)
        #expect(!TideGitItem.shortened(String(repeating: "a", count: 24)).hasSuffix("…"))
    }

    @Test func aCappedStatusSaysItsCountsAreIncomplete() {
        var changes = Self.changes(files: [Self.file("a.swift", staging: .unstaged)])
        changes.isStatusTruncated = true
        #expect(TideGitItem(changes).accessibilityValue == "Branch main, 1 modified, file counts incomplete")
    }

    @Test func showsOnlyForALoadedReadThatDidNotTimeOut() {
        let changes = Self.changes(files: [])
        #expect(TideGitItem(phase: .loading, timedOutKeepingContent: false) == nil)
        #expect(TideGitItem(phase: .notAGitWorkingTree, timedOutKeepingContent: false) == nil)
        #expect(TideGitItem(phase: .loaded(changes), timedOutKeepingContent: true) == nil)
        #expect(TideGitItem(phase: .loaded(changes), timedOutKeepingContent: false) != nil)
    }

    static func file(
        _ path: String, kind: ChangedFile.Kind = .modified, staging: ChangedFile.Staging?
    ) -> ChangedFile {
        ChangedFile(path: Data(path.utf8), originalPath: nil, kind: kind, staging: staging)
    }

    static func changes(
        branch: CheckoutHead.Branch = .named("main"), files: [ChangedFile], untracked: Int = 0,
        upstream: CheckoutUpstream.State? = nil
    ) -> CheckoutChanges {
        var changes = CheckoutChanges(
            checkout: CheckoutLocation(
                topLevel: Data(), isLinkedWorktree: false, displayPath: "~/src/app"),
            head: CheckoutHead(
                branch: branch, commit: "4f1a9c2e8b7d6a5031e4f8c9b2a7d6e5f0c1b3a4",
                latestCommit: nil,
                upstream: upstream.map { CheckoutUpstream(name: "origin/main", state: $0) }),
            files: files)
        changes.totals.untrackedItems = untracked
        changes.totals.trackedFiles = files.filter { $0.kind != .untracked }.count
        return changes
    }
}
