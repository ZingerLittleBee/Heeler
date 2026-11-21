import Foundation
import Testing

@testable import Heeler

/// Changes opened in place of Agent detail. The presentation owns the only
/// reference to its store, so closing it discards the content.
@MainActor
@Suite("Changes presentation")
struct AgentChangesPresentationTests {
    @Test func openingMakesOneStoreAndClosingDiscardsIt() {
        var made = 0
        let presentation = AgentChangesPresentation {
            made += 1
            return ChangesStore(directory: { "/home/dev/src/app" }) { _ in
                throw ChangesReadError.unavailable
            }
        }
        #expect(presentation.store == nil)

        presentation.open()
        let first = presentation.store
        presentation.open()
        #expect(first != nil)
        #expect(presentation.store === first)
        #expect(made == 1)

        presentation.close()
        #expect(presentation.store == nil)

        presentation.open()
        #expect(presentation.store !== first)
        #expect(presentation.store?.phase == .loading)
        #expect(made == 2)
    }

    /// Worktree Details and the dirty-removal refusal hand that Worktree's
    /// directory. The Agent menu hands nil, so the next open follows the Agent
    /// again instead of keeping the Worktree path.
    @Test func openingForAWorktreeReadsThatDirectory() async throws {
        let transport = ScriptedTransport()
        var handed: [String?] = []
        let presentation = AgentChangesPresentation(makeStoreIn: { fixed in
            handed.append(fixed)
            return ChangesStore(directory: { fixed ?? "/home/dev/src/app/pkg" }) { request in
                try await transport.readChanges(request)
            }
        })

        presentation.open(directory: "/work/Heeler-wt")
        let store = try #require(presentation.store)
        await store.appear()
        #expect(handed == ["/work/Heeler-wt"])
        #expect(
            await transport.changesReadRequests
                == [ChangesReadRequest(directory: "/work/Heeler-wt")])

        let shown = presentation.store
        presentation.open(directory: "/other")
        #expect(presentation.store === shown)
        #expect(handed == ["/work/Heeler-wt"])

        await store.refresh()
        #expect(
            await transport.changesReadRequests.map(\.directory)
                == ["/work/Heeler-wt", "/work/Heeler-wt"])

        presentation.close()
        #expect(presentation.store == nil)

        presentation.open()
        let followed = try #require(presentation.store)
        await followed.appear()
        #expect(handed == ["/work/Heeler-wt", nil])
        #expect(
            await transport.changesReadRequests.map(\.directory)
                == [
                    "/work/Heeler-wt", "/work/Heeler-wt",
                    "/home/dev/src/app/pkg",
                ])
    }
    @Test func insertingClosesChangesAndHandsTheReferenceBackExactlyOnce() async throws {
        let read = try ChangesStoreTests.read(GitProbeRecordings.subdir)
        let presentation = AgentChangesPresentation {
            ChangesStore(directory: { "/home/dev/src/app/pkg" }) { _ in read }
        }
        presentation.open()
        let store = try #require(presentation.store)
        await store.appear()
        let file = ChangedFile(
            path: Data("pkg/renamed.txt".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        store.insert(file: file)
        #expect(presentation.store == nil)
        #expect(presentation.takePendingInsertion() == "renamed.txt ")
        #expect(presentation.takePendingInsertion() == nil)

        // A departing menu cannot hand another reference to the next view.
        store.insert(file: file)
        #expect(presentation.takePendingInsertion() == nil)
    }

    @Test func worktreeInsertionsStayAbsoluteAndAnOrdinaryBackInsertsNothing() async throws {
        let read = try ChangesStoreTests.read(GitProbeRecordings.subdir)
        let presentation = AgentChangesPresentation(makeStoreIn: { directory in
            ChangesStore(directory: { directory }) { _ in read }
        })
        presentation.open(directory: "/work/other/pkg")
        let store = try #require(presentation.store)
        await store.appear()
        let file = ChangedFile(
            path: Data("pkg/renamed.txt".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        store.insert(file: file)
        #expect(presentation.takePendingInsertion() == "/home/dev/src/app/pkg/renamed.txt ")

        presentation.open()
        presentation.close()
        #expect(presentation.takePendingInsertion() == nil)
    }
}
