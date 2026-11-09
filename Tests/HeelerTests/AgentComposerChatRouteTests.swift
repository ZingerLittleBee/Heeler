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

    /// The E2E case: Oh My Pi held the draft while it worked, then went
    /// Idle. The hold described an Agent that has moved on, so it ends.
    @Test func aHoldOnTheAgentEndsWhenAgentStatusChanges() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        store.replaceDraft(with: "next step")
        let hold = ComposerRefusal.inputNotReady("Oh My Pi is working. Send once it's idle, or steer from the terminal.")

        let result = await store.send(policy: Self.chatPolicy(preflight: { _ in hold }))

        #expect(result == .refused(hold))
        #expect(store.notice == ComposerNotice(refusal: hold, route: .chat))
        store.agentStatusDidChange(.idle)
        #expect(store.notice == nil)
        #expect(store.draft == "next step")
    }

    @MainActor
    private final class Seen {
        var steps: [String] = []
        var echoes: [[AgentComposerStore.DeliveryState]] = []
    }

    /// The herdr-core run: a Send while Antigravity CLI worked showed
    /// "Sending" for 1.5 to 2.5 s, while the session check's exec and the
    /// screen read's paint ran, before the same hold took it back. A
    /// reported Working now holds before either, so the echo leaves in the
    /// main-actor turn it came in: a job queued behind the Send never sees
    /// it, and nothing renders it.
    @Test func aWorkingHoldNeverShowsTheEcho() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        let ready = try ScreenFixture.screen("agy-02-idle-empty-120x40")
        let seen = Seen()
        let policy = ComposerDeliveryPolicy.chat(
            rules: ChatSendRules(
                program: .agy, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: false, program: .agy)),
            activity: { .working },
            readScreen: {
                seen.steps.append("read")
                // Each is a Host round trip on herdr-core.
                await Task.yield()
                return ready
            },
            confirmSession: {
                seen.steps.append("check")
                await Task.yield()
                return nil
            },
            pause: { _ in })
        let hold = ComposerRefusal.inputNotReady(
            "The Agent isn't taking messages: Antigravity CLI is working. Send once it's idle, or steer from the terminal."
        )
        store.replaceDraft(with: "hello")

        let send = Task { await store.send(policy: policy) }
        let look = Task { seen.echoes.append(store.messages.map(\.state)) }
        let result = await send.value
        await look.value

        #expect(result == .refused(hold))
        #expect(seen.echoes == [[]])
        #expect(seen.steps.isEmpty)
        #expect(store.draft == "hello")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(store.notice == ComposerNotice(refusal: hold, route: .chat))
        store.agentStatusDidChange(.idle)
        #expect(store.notice == nil)
    }

    /// The Mac pick run: "can't tell" stayed in the Composer after the pick
    /// it asked for. A hold about the conversation Chat followed ends once
    /// it follows another; one noted after the Send's own check moved Chat
    /// stays, and a refusal of the text itself is not about the conversation.
    @Test func aHoldOnTheConversationEndsWhenChatFollowsAnother() async {
        final class Followed { var generation = 1 }
        let followed = Followed()
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "next step")
        let hold = ComposerRefusal.inputNotReady("Codex now shows another conversation.")
        var policy = Self.chatPolicy(preflight: { _ in
            followed.generation = 2
            return hold
        })
        policy.conversation = { followed.generation }

        _ = await store.send(policy: policy)

        #expect(store.notice == ComposerNotice(refusal: hold, route: .chat, conversation: 2))
        store.conversationDidChange(to: 2)
        #expect(store.notice?.refusal == hold)
        store.conversationDidChange(to: 3)
        #expect(store.notice == nil)
        #expect(store.draft == "next step")

        let unsafe = ComposerRefusal.unsafeText("A leading ! runs a shell command.")
        var textPolicy = Self.chatPolicy(validate: { _ in unsafe })
        textPolicy.conversation = { followed.generation }
        _ = await store.send(policy: textPolicy)
        store.conversationDidChange(to: 4)
        #expect(store.notice?.refusal == unsafe)
    }

    @Test(arguments: [ComposerRefusal.agentBlocked, .commandAwaitsIdle("compact")])
    func everyHoldOnTheAgentEndsWithItsStatus(_ hold: ComposerRefusal) async {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .blocked)
        store.replaceDraft(with: "/compact")

        _ = await store.send(policy: Self.chatPolicy(validate: { _ in hold }))

        #expect(store.notice?.refusal == hold)
        store.agentStatusDidChange(.idle)
        #expect(store.notice == nil)
    }

    /// `/compact` waits for Idle: a Working Agent turning Blocked is still
    /// not idle, so the same Send would be refused again.
    @Test func aCommandAwaitingIdleHoldsUntilTheAgentIsIdle() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        store.replaceDraft(with: "/compact")
        let hold = ComposerRefusal.commandAwaitsIdle("compact")

        _ = await store.send(policy: Self.chatPolicy(validate: { _ in hold }))
        store.agentStatusDidChange(.blocked)
        store.agentStatusDidChange(.working)

        #expect(store.notice == ComposerNotice(refusal: hold, route: .chat))
        store.agentStatusDidChange(.done)
        #expect(store.notice == nil)
    }

    @Test func aHoldOnABlockedAgentOutlivesAChangeToBlocked() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        store.replaceDraft(with: "hello")

        _ = await store.send(policy: Self.chatPolicy(preflight: { _ in .agentBlocked }))
        store.agentStatusDidChange(.blocked)

        #expect(store.notice?.refusal == .agentBlocked)
        store.agentStatusDidChange(.working)
        #expect(store.notice == nil)
    }

    /// hc-lab D10 (2026-11-03): after OpenCode's `/new`, a Send just before a prompt
    /// typed in its terminal landed was refused while that prompt made the Agent
    /// Working. The draft came back, and so does the reason, though the change
    /// that would end it came first. The next change ends it as usual.
    @Test func aRefusalThatAStatusChangeUnderTheSendWouldEndStillSaysWhy() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .idle)
        store.replaceDraft(with: "Reply with the single word NEW.")
        let hold = ComposerRefusal.inputNotReady(
            "OpenCode's terminal isn't showing this conversation. Open it in the terminal, then send again.")
        let policy = Self.chatPolicy(preflight: { _ in
            store.agentStatusDidChange(.working)
            return hold
        })

        let result = await store.send(policy: policy)

        #expect(result == .refused(hold))
        #expect(store.draft == "Reply with the single word NEW.")
        #expect(store.messages.isEmpty)
        #expect(store.notice == ComposerNotice(refusal: hold, route: .chat))
        #expect(await transport.agentPromptParams.isEmpty)
        store.agentStatusDidChange(.idle)
        #expect(store.notice == nil)
    }

    /// A retry's refusal shows on the message it failed, with its own words.
    @Test func aRetryRefusedUnderAStatusChangeKeepsItsReason() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        store.replaceDraft(with: "next step")
        let hold = ComposerRefusal.inputNotReady("Oh My Pi is working. Send once it's idle, or steer from the terminal.")
        await transport.setAgentPromptFailure(TransportError.sshUnreachable(detail: "offline"))
        _ = await store.send(policy: Self.chatPolicy())
        let failed = try #require(store.messages.first)

        let result = await store.retry(failed.id, policy: Self.chatPolicy(preflight: { _ in
            store.agentStatusDidChange(.idle)
            return hold
        }))

        #expect(result == .refused(hold))
        #expect(store.messages.first?.state == .failed(hold.message))
    }

    @Test func aHoldThatAStatusChangeUnderTheSendKeepsStillShows() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        store.replaceDraft(with: "hello")

        _ = await store.send(policy: Self.chatPolicy(preflight: { _ in
            store.agentStatusDidChange(.blocked)
            return .agentBlocked
        }))

        #expect(store.notice == ComposerNotice(refusal: .agentBlocked, route: .chat))
    }

    @Test func aRefusalOfTheTextOutlivesAStatusChangeButNotAnEdit() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport, status: .working)
        store.replaceDraft(with: "exit")
        let refusal = ComposerRefusal.unsafeText("Sending this would exit Oh My Pi. Open the terminal to exit.")

        _ = await store.send(policy: Self.chatPolicy(validate: { _ in refusal }))
        store.agentStatusDidChange(.idle)

        #expect(store.notice == ComposerNotice(refusal: refusal, route: .chat))
        store.applyEditorDraft("exit", selection: NSRange(location: 2, length: 0))
        #expect(store.notice != nil)
        store.applyEditorDraft("exit now", selection: NSRange(location: 8, length: 0))
        #expect(store.notice == nil)
    }

    @Test func aSendThatGoesEndsTheNotice() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "hello")
        var held = true
        let policy = Self.chatPolicy(preflight: { _ in held ? .inputNotReady("The input box has text in it.") : nil })

        _ = await store.send(policy: policy)
        #expect(store.notice != nil)
        held = false

        #expect(await store.send(policy: policy) == .deliveredViaPrompt)
        #expect(store.notice == nil)
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
