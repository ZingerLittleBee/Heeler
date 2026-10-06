import Foundation
import Testing

@testable import Heeler

/// The Composer's Chat route: the same draft and `agent.prompt` delivery,
/// under a policy that refuses rather than typing into the terminal.
@MainActor
@Suite("Agent Composer Chat route")
struct AgentComposerChatRouteTests {
    private static func chatPolicy(
        validate: @escaping @MainActor (String) -> ComposerRefusal? = { _ in nil },
        outgoingText: @escaping @MainActor (String) -> String = { $0 },
        preflight: (@MainActor (String) async -> ComposerRefusal?)? = nil,
        verify: (@MainActor (String) async -> Bool)? = nil
    ) -> ComposerDeliveryPolicy {
        ComposerDeliveryPolicy(
            route: .chat, insertsIntoAttachWhenBlocked: false, outgoingText: outgoingText,
            validate: validate, preflight: preflight, verify: verify)
    }

    private static func store(
        _ transport: ScriptedTransport, status: AgentStatus = .idle
    ) -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1", initialStatus: status) { params in
            try await transport.promptAgent(params)
        }
    }

    @Test func blockedAgentRefusesWithoutTouchingTheTerminal() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = Self.store(transport, status: .blocked)
        store.bindAttachInput(input)
        store.replaceDraft(with: "n")

        let result = await store.send(policy: Self.chatPolicy())

        #expect(result == .refused(.agentBlocked))
        #expect(store.draft == "n")
        #expect(store.messages.isEmpty)
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func agentBlockedRejectionReturnsTheDraft() async {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_blocked", message: "agent is blocked"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = Self.store(transport)
        store.bindAttachInput(input)
        store.replaceDraft(with: "approve")

        let result = await store.send(policy: Self.chatPolicy())

        #expect(result == .refused(.agentBlocked))
        #expect(store.draft == "approve")
        #expect(store.messages.isEmpty)
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func aValidationRefusalKeepsTheDraftAndSendsNothing() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "!ls")

        let result = await store.send(
            policy: Self.chatPolicy(validate: { _ in .unsafeText("shell") }))

        #expect(result == .refused(.unsafeText("shell")))
        #expect(store.draft == "!ls")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func aPreflightRefusalKeepsTextTypedMeanwhile() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        let gate = AsyncStream<Void>.makeStream()
        store.replaceDraft(with: "first")
        let policy = Self.chatPolicy(preflight: { _ in
            for await _ in gate.stream { break }
            return .inputNotReady("The input box has text in it.")
        })

        let send = Task { await store.send(policy: policy) }
        try await waitUntil("the echo should show while the screen is read") {
            store.messages.count == 1
        }
        store.replaceDraft(with: "second")
        gate.continuation.yield()
        let result = await send.value

        #expect(result == .refused(.inputNotReady("The input box has text in it.")))
        #expect(store.draft == "first\nsecond")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func thePromptCarriesTheOutgoingTextAndTheEchoTheTypedText() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "/review")

        let result = await store.send(
            policy: Self.chatPolicy(outgoingText: { "$" + $0.dropFirst() + " " }))

        #expect(result == .deliveredViaPrompt)
        #expect(store.messages.map(\.text) == ["/review"])
        #expect(store.messages.map(\.route) == [.chat])
        #expect(
            await transport.agentPromptParams == [AgentPromptParams(target: "w1:p1", text: "$review ")])
    }

    @Test func textLeftInTheInputBoxIsMarkedNotDeliveredAndNeverResent() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "hello")

        let result = await store.send(policy: Self.chatPolicy(verify: { _ in false }))

        #expect(result == .deliveredViaPrompt)
        try await waitUntil("the check should mark the message") {
            store.messages.first?.state == .undelivered
        }
        #expect(await store.retry(try #require(store.messages.first).id, policy: Self.chatPolicy()) == .ignored)
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func aFailureIsRetriedOnlyByItsOwnRoute() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(TransportError.sshUnreachable(detail: "offline"))
        let store = Self.store(transport)
        store.replaceDraft(with: "hello")
        _ = await store.send(policy: Self.chatPolicy())
        let failed = try #require(store.messages.first)
        await transport.setAgentPromptFailure(nil)

        #expect(await store.retry(failed.id) == .ignored)
        #expect(await store.retry(failed.id, policy: Self.chatPolicy()) == .deliveredViaPrompt)
        #expect(await transport.agentPromptParams.count == 2)
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
