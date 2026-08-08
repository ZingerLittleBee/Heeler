import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent Composer store")
struct AgentComposerStoreTests {
    @Test func typingStaysLocalAndSendUsesOnePromptRPC() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }

        store.replaceDraft(with: "Fix the failing tests")

        #expect(store.draft == "Fix the failing tests")
        #expect(await transport.agentPromptParams.isEmpty)

        let send = Task { await store.send() }
        try await waitUntil("the prompt should be waiting for its acknowledgment") {
            await promptGate.entryCount == 1
        }

        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.text) == ["Fix the failing tests"])
        #expect(store.messages.map(\.state) == [.sending])
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "Fix the failing tests")
            ])

        await promptGate.open()
        await send.value

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func statusPushesAdvanceAcknowledgedMessageFromWorkingToDone() async throws {
        let transport = ScriptedTransport()
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        let store = AgentComposerStore(
            target: "w1:p1", statusUpdates: updates
        ) { params in
            try await transport.promptAgent(params)
        }
        store.open()
        store.replaceDraft(with: "Continue")

        await store.send()
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])

        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: .working, liveUpdatesAvailable: true))
        try await waitUntil("Working should come from the status stream") {
            store.messages.map(\.state) == [.delivered(.working)]
        }

        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: .done, liveUpdatesAvailable: true))
        try await waitUntil("Done should come from the status stream") {
            store.messages.map(\.state) == [.delivered(.done)]
        }

        #expect(await transport.agentPromptParams.count == 1)
        #expect(await transport.agentPromptParams.first?.wait == nil)
        continuation.finish()
    }

    @Test func sendingWhileWorkingAcknowledgesThatTheAgentIsBusy() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .working) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Queue this next")

        await store.send()

        #expect(store.messages.map(\.state) == [.delivered(.agentBusy)])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func priorDoneStatusDoesNotClaimThatANewMessageIsDone() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .done) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "One more request")

        await store.send()

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
    }

    @Test func statusArrivingBeforeAcknowledgmentIsAppliedAfterDelivery() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Start now")
        let send = Task { await store.send() }
        try await waitUntil("the prompt should be in flight") {
            await promptGate.entryCount == 1
        }

        store.agentStatusDidChange(.working)
        await promptGate.open()
        await send.value

        #expect(store.messages.map(\.state) == [.delivered(.working)])
    }

    @Test func failedSendCanRetryWithoutLosingItsText() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(TransportError.timedOut)
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Please retry this")
        await store.send()
        let message = try #require(store.messages.first)

        #expect(
            message.state
                == .failed("The Host did not answer. Check the connection and retry."))
        #expect(message.text == "Please retry this")

        await transport.setAgentPromptFailure(nil)
        let retryGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: retryGate)
        let retry = Task { await store.retry(message.id) }
        try await waitUntil("retry should return to Sending") {
            await retryGate.entryCount == 1 && store.messages.first?.state == .sending
        }
        await retryGate.open()
        await retry.value

        #expect(store.messages.first?.text == "Please retry this")
        #expect(store.messages.first?.state == .delivered(.acknowledged))
        #expect(await transport.agentPromptParams.count == 2)
    }

    @Test func withdrawingFailurePreservesTheFailedTextAndNewDraft() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            TransportError.sshUnreachable(detail: "connection dropped"))
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Earlier message")
        await store.send()
        let failedID = try #require(store.messages.first?.id)
        store.replaceDraft(with: "New thought")

        store.withdrawToDraft(failedID)

        #expect(store.messages.isEmpty)
        #expect(store.draft == "Earlier message\nNew thought")
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func reconnectStatusUpdatesDoNotTouchTheLocalDraft() async throws {
        let transport = ScriptedTransport()
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        let store = AgentComposerStore(
            target: "w1:p1", statusUpdates: updates
        ) { params in
            try await transport.promptAgent(params)
        }
        store.open()
        store.replaceDraft(with: "Survive Attach, background, and reconnect")

        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: nil, liveUpdatesAvailable: false))
        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: .idle, liveUpdatesAvailable: true))
        try await waitUntil("status recovery should be consumed") {
            await transport.agentPromptParams.isEmpty
        }

        #expect(store.draft == "Survive Attach, background, and reconnect")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        continuation.finish()
    }

    @Test func consoleOwnershipPreservesDraftAcrossReconnectViewReplacement() throws {
        let console = ConsoleStore()
        let hostID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let agentBeforeReconnect = makeAgent(hostID: hostID, status: .working)
        let firstStore = console.composerStore(for: agentBeforeReconnect)
        firstStore.replaceDraft(with: "Keep this local draft")

        let agentAfterReconnect = makeAgent(hostID: hostID, status: .idle)
        let replacementStore = console.composerStore(for: agentAfterReconnect)

        #expect(firstStore === replacementStore)
        #expect(replacementStore.draft == "Keep this local draft")
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        #expect(await condition(), comment)
    }

    private func makeAgent(hostID: Host.ID, status: AgentStatus) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term-1", kind: "claude", title: "Task",
                status: status, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                cwd: "/work", revision: 1),
            workspaceLabel: "Project", repoName: "Project")
    }
}
