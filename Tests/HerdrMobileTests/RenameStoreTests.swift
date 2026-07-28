import Foundation
import Testing

@testable import HerdrMobile

/// Rename form logic (#98) against a scripted rename closure: validation
/// mirroring the server's live-verified rules, the agent clear semantics,
/// the double-tap guard, and outcome mapping — no SSH, no ConsoleStore.
@MainActor
@Suite("Rename store")
struct RenameStoreTests {
    private func agentStore(
        current: String = "reviewer",
        rename: @escaping (String?) async throws -> Void = { _ in }
    ) -> RenameStore {
        RenameStore(
            subject: .agent(detectedKind: "claude"),
            currentValue: current,
            rename: rename)
    }

    private func workspaceStore(
        current: String = "Proj",
        rename: @escaping (String?) async throws -> Void = { _ in }
    ) -> RenameStore {
        RenameStore(subject: .workspace, currentValue: current, rename: rename)
    }

    // MARK: Agent name validation (server rule, verified live: 0.7.5
    // rejects violations with invalid_agent_name)

    @Test(arguments: [
        "reviewer", "a", "agent-2", "agent_2", "x1234567890",
        String(repeating: "a", count: 32),
    ])
    func validAgentNamesPassTheServerRule(name: String) {
        #expect(RenameStore.isValidAgentName(name))
    }

    @Test(arguments: [
        "", "Agent", "1agent", "-agent", "_agent", "agent name", "拆解任务",
        "café", String(repeating: "a", count: 33),
    ])
    func invalidAgentNamesFailTheServerRule(name: String) {
        #expect(!RenameStore.isValidAgentName(name))
    }

    @Test func invalidAgentInputSurfacesTheRuleAndBlocksSubmit() {
        let store = agentStore()
        store.input = "Not Valid"
        #expect(store.validationMessage != nil)
        #expect(!store.canSubmit)
    }

    @Test func emptyAgentInputMeansClearAndStaysSubmittable() async {
        // Verified live: omitting the name clears back to the detected kind,
        // so an empty input is the clear spelling, not an error.
        let recorder = RenameRecorder()
        let store = agentStore { value in recorder.record(value) }
        store.input = "   "

        #expect(store.validationMessage == nil)
        #expect(store.canSubmit)
        #expect(store.clearHint == "Leave empty to fall back to the detected kind (claude).")
        await store.submit()

        #expect(store.state == .renamed)
        #expect(recorder.values == [nil])
    }

    @Test func agentSubmitSendsTheTrimmedName() async {
        let recorder = RenameRecorder()
        let store = agentStore { value in recorder.record(value) }
        store.input = " reviewer-2 "

        await store.submit()

        #expect(store.state == .renamed)
        #expect(recorder.values == ["reviewer-2"])
    }

    // MARK: Workspace labels (server enforces nothing, verified live; the
    // empty submit is withheld client-side only)

    @Test func workspaceLabelsSkipTheAgentNameRule() {
        let store = workspaceStore()
        store.input = "My Project (iOS)"
        #expect(store.validationMessage == nil)
        #expect(store.canSubmit)
        #expect(store.clearHint == nil)
    }

    @Test func emptyWorkspaceLabelCannotSubmit() async {
        let store = workspaceStore { _ in
            Issue.record("an empty workspace label must never reach the transport")
        }
        store.input = "  "

        #expect(!store.canSubmit)
        await store.submit()

        #expect(store.state == .editing)
    }

    // MARK: Submission

    @Test func rapidDoubleTapRenamesOnce() async throws {
        let gate = Gate()
        let recorder = RenameRecorder()
        let store = workspaceStore { value in
            await gate.waitUntilOpen()
            recorder.record(value)
        }
        store.input = "New"

        let first = Task { await store.submit() }
        try await waitUntil("the first submit should reach the gate") {
            await gate.enteredCount == 1
        }
        #expect(!store.canDismiss)
        let second = Task { await store.submit() }
        await second.value  // the guard makes this return without touching the gate.
        #expect(await gate.enteredCount == 1)

        await gate.open()
        await first.value

        #expect(recorder.values == ["New"])
        #expect(store.state == .renamed)
    }

    @Test func serverRejectionSurfacesItsMessage() async {
        // The live-verified rejection shapes: invalid_agent_name,
        // agent_not_found, workspace_not_found — all carry a message worth
        // showing verbatim.
        let store = agentStore { _ in
            throw HerdrAPIError(
                code: "invalid_agent_name",
                message: "agent name must start with a lowercase letter")
        }

        await store.submit()

        #expect(
            store.state
                == .failed(
                    "herdr rejected the rename: agent name must start with a lowercase letter"))
    }

    @Test func disconnectedHostMapsToAFriendlyMessage() async {
        let store = workspaceStore { _ in
            throw TransportError.sshUnreachable(detail: "connection dropped")
        }
        store.input = "New"

        await store.submit()

        #expect(store.state == .failed("The Host is not connected."))
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}

/// Records every submitted value; MainActor-only, like the store.
@MainActor
private final class RenameRecorder {
    private(set) var values: [String?] = []

    func record(_ value: String?) {
        values.append(value)
    }
}

/// Parks the first caller until opened, so the double-tap guard can be
/// exercised deterministically.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func waitUntilOpen() async {
        enteredCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume() }
    }
}
