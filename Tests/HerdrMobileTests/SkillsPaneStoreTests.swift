import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("skills pane store")
struct SkillsPaneStoreTests {
    private static func skill(_ name: String) -> AgentSkill {
        AgentSkill(scope: .global, name: name, description: nil)
    }

    @Test func loadIfNeededFetchesOnce() async {
        var calls: [Bool] = []
        let store = SkillsPaneStore { forceRefresh in
            calls.append(forceRefresh)
            return [Self.skill("tdd")]
        }
        await store.loadIfNeeded()
        await store.loadIfNeeded()
        #expect(calls == [false])
        #expect(store.phase == .loaded)
        #expect(store.skills.map(\.name) == ["tdd"])
    }

    @Test func refreshForcesAndReplaces() async {
        var calls: [Bool] = []
        let store = SkillsPaneStore { forceRefresh in
            calls.append(forceRefresh)
            return forceRefresh ? [Self.skill("fresh")] : [Self.skill("stale")]
        }
        await store.loadIfNeeded()
        await store.refresh()
        #expect(calls == [false, true])
        #expect(store.skills.map(\.name) == ["fresh"])
    }

    @Test func failureCarriesAMessageAndRetryRecovers() async {
        var shouldFail = true
        let store = SkillsPaneStore { _ in
            if shouldFail { throw TransportError.timedOut }
            return [Self.skill("back")]
        }
        await store.loadIfNeeded()
        #expect(store.phase == .failed("The Host did not answer in time."))

        shouldFail = false
        await store.refresh()
        #expect(store.phase == .loaded)
        #expect(store.skills.map(\.name) == ["back"])
    }

    @Test func failedRefreshKeepsThePreviousList() async {
        var shouldFail = false
        let store = SkillsPaneStore { _ in
            if shouldFail { throw TransportError.sshUnreachable(detail: "gone") }
            return [Self.skill("kept")]
        }
        await store.loadIfNeeded()
        shouldFail = true
        await store.refresh()
        #expect(store.phase == .failed("The Host is not connected."))
        #expect(store.skills.map(\.name) == ["kept"])
    }

    @Test func cancellationReturnsToIdleSoTheNextAppearanceRetries() async {
        var attempts = 0
        let store = SkillsPaneStore { _ in
            attempts += 1
            if attempts == 1 { throw CancellationError() }
            return [Self.skill("second-try")]
        }
        await store.loadIfNeeded()
        #expect(store.phase == .idle)
        await store.loadIfNeeded()
        #expect(store.skills.map(\.name) == ["second-try"])
    }
}
