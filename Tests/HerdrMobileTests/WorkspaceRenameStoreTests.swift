import Foundation
import Testing

@testable import HerdrMobile

/// Workspace rename form logic (#98) against a scripted rename closure:
/// empty-label handling, the double-tap guard, and outcome mapping.
@MainActor
@Suite("Workspace rename store")
struct WorkspaceRenameStoreTests {
    private func makeStore(
        current: String = "Proj",
        rename: @escaping (String) async throws -> Void = { _ in }
    ) -> WorkspaceRenameStore {
        WorkspaceRenameStore(currentLabel: current, rename: rename)
    }

    @Test func workspaceLabelsAcceptUserFacingText() {
        let store = makeStore()
        store.input = "My Project (iOS)"
        #expect(store.canSubmit)
    }

    @Test func emptyWorkspaceLabelCannotSubmit() async {
        let store = makeStore { _ in
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
        let store = makeStore { value in
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
        let store = makeStore { _ in
            throw HerdrAPIError(
                code: "workspace_not_found",
                message: "workspace not found")
        }
        store.input = "New"

        await store.submit()

        #expect(
            store.state
                == .failed("herdr rejected the rename: workspace not found"))
    }

    @Test func disconnectedHostMapsToAFriendlyMessage() async {
        let store = makeStore { _ in
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
    private(set) var values: [String] = []

    func record(_ value: String) {
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
