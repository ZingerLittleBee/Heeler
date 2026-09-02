import Foundation
import SwiftUI
import Testing
import UIKit

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

    @Test func queuedMessageWaitsForItsOwnWorkingPhaseBeforeDone() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "First message")
        await store.send()
        store.agentStatusDidChange(.working)

        store.replaceDraft(with: "Queued message")
        await store.send()

        #expect(
            store.messages.map(\.state)
                == [.delivered(.working), .delivered(.agentBusy)])

        store.agentStatusDidChange(.done)
        #expect(
            store.messages.map(\.state)
                == [.delivered(.done), .delivered(.agentBusy)])

        store.agentStatusDidChange(.working)
        #expect(
            store.messages.map(\.state)
                == [.delivered(.done), .delivered(.working)])

        store.agentStatusDidChange(.done)
        #expect(
            store.messages.map(\.state)
                == [.delivered(.done), .delivered(.done)])
        #expect(await transport.agentPromptParams.count == 2)
    }

    @Test func queuedMessageStaysBusyWhenPriorWorkFinishesBeforeAcknowledgment() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .working) { params in
            try await transport.promptAgent(params)
        }
        await transport.gateNextAgentPrompt(using: promptGate)
        store.replaceDraft(with: "Queued message")
        let send = Task { await store.send() }
        try await waitUntil("the queued prompt should be in flight") {
            await promptGate.entryCount == 1
        }

        store.agentStatusDidChange(.done)
        await promptGate.open()
        await send.value

        #expect(store.messages.map(\.state) == [.delivered(.agentBusy)])
    }

    @Test func idleEndsAWorkingMessage() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Interrupt this")
        await store.send()
        store.agentStatusDidChange(.working)

        store.agentStatusDidChange(.idle)

        #expect(store.messages.map(\.state) == [.delivered(.done)])
        #expect(await transport.agentPromptParams.count == 1)
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

    @Test func sendingWhileBlockedInsertsIntoAttachWithoutEnterOrPrompt() async throws {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.text) == ["n"])
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(writes == [Data("n".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func sendingWhileWorkingStillUsesPromptWhenAttachIsLive() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .working) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Queue this next")

        let result = await store.send()

        #expect(result == .deliveredViaPrompt)
        #expect(store.messages.map(\.state) == [.delivered(.agentBusy)])
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.count == 1)
        #expect(await transport.agentPromptParams.first?.wait == nil)
    }

    @Test func agentBlockedPromptFallsThroughToAttachInsert() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_blocked", message: "agent is blocked"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "approve")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(writes == [Data("approve".utf8)])
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "approve")
            ])
        if case .failed(let detail) = store.messages.first?.state {
            Issue.record("expected Attach delivery, got failure: \(detail)")
        }
    }

    @Test func blockedSendWithoutLiveAttachFailsAndKeepsRetry() async throws {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .failed)
        #expect(await transport.agentPromptParams.isEmpty)
        let message = try #require(store.messages.first)
        #expect(
            message.state
                == .failed("The message could not be sent. Check the connection and retry.")
        )
        #expect(message.text == "n")

        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        store.bindAttachInput(input)
        let retry = await store.retry(message.id)

        #expect(retry == .deliveredViaAttach)
        #expect(store.messages.first?.state == .delivered(.acknowledged))
        #expect(writes == [Data("n".utf8)])
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func agentBlockedWithoutLiveAttachDoesNotShowHerdrRejection() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_blocked", message: "agent is blocked"))
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .failed)
        let message = try #require(store.messages.first)
        #expect(message.text == "n")
        #expect(
            message.state
                == .failed("The message could not be sent. Check the connection and retry.")
        )
        if case .failed(let detail) = message.state {
            #expect(!detail.contains("herdr rejected"))
        }
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "n")
            ])

        store.withdrawToDraft(message.id)
        #expect(store.messages.isEmpty)
        #expect(store.draft == "n")
    }

    @Test func blockedSendRejectsUnsafeScalarsWithoutWriting() async throws {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "escape\u{1B}[31m")

        let result = await store.send()

        #expect(result == .failed)
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        let message = try #require(store.messages.first)
        #expect(
            message.state
                == .failed("The message contains unsafe terminal control characters."))

        store.withdrawToDraft(message.id)
        #expect(store.messages.isEmpty)
        #expect(store.draft == "escape\u{1B}[31m")
    }

    @Test func blockedAttachInsertDoesNotWrapBracketedPaste() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "first\nsecond")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data("first\nsecond".utf8)])
        #expect(writes.first?.starts(with: TerminalBracketedPaste.start) != true)
    }

    @Test func blockedDeliveredEchoDoesNotClaimWorkingFromLaterStatus() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "n")

        await store.send()
        store.agentStatusDidChange(.working)
        store.agentStatusDidChange(.done)

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(writes == [Data("n".utf8)])
    }

    @Test func replaceTrailingTokenSwapsTheTokenAndKeepsTheRest() {
        let store = Self.draftOnlyStore()
        store.replaceDraft(with: "fix this /rev")

        store.replaceTrailingToken("/rev", with: "/code-review ")

        #expect(store.draft == "fix this /code-review ")
    }

    @Test func replaceTrailingTokenLeavesADraftThatNoLongerEndsWithIt() {
        let store = Self.draftOnlyStore()
        store.replaceDraft(with: "/rev then more")

        store.replaceTrailingToken("/rev", with: "/code-review ")

        #expect(store.draft == "/rev then more")
    }

    @Test func replaceTrailingTokenIgnoresAnEmptyToken() {
        let store = Self.draftOnlyStore()
        store.replaceDraft(with: "keep me")

        store.replaceTrailingToken("", with: "/code-review ")

        #expect(store.draft == "keep me")
    }

    @Test func promptDeliveryRecordsTheSubmittedMessageOnce() async {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        _ = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Fix the failing tests")

        let result = await store.send()

        #expect(result == .deliveredViaPrompt)
        #expect(input.userMessageIndex.entries.map(\.rawText) == ["Fix the failing tests"])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func failedPromptDoesNotRecordAUserMessage() async {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(TransportError.timedOut)
        let input = TerminalInputController()
        _ = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Fix the failing tests")

        let result = await store.send()

        #expect(result == .failed)
        #expect(input.userMessageIndex.entries.isEmpty)
    }

    @Test func blockedAttachInsertIsIndexedOnEnterNotTwice() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "please approve the refactor")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data("please approve the refactor".utf8)])
        #expect(input.userMessageIndex.entries.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)

        #expect(input.send(Data([0x0D])))
        #expect(
            input.userMessageIndex.entries.map(\.rawText)
                == ["please approve the refactor"])
    }

    @Test func promptDeliveryDoesNotRecordIntoAReplacementSession() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let input = TerminalInputController()
        let generationA = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Fix the failing tests")

        let send = Task { await store.send() }
        try await waitUntil("the prompt should be waiting for its acknowledgment") {
            await promptGate.entryCount == 1
        }

        input.detachSessionForReplacement()
        input.endSession(generationA, preservingPendingPaste: true)
        _ = input.beginSession { _ in }
        #expect(input.userMessageIndex.entries.isEmpty)

        await promptGate.open()
        let result = await send.value

        #expect(result == .deliveredViaPrompt)
        #expect(input.userMessageIndex.entries.isEmpty)

        store.replaceDraft(with: "rewrite the matching tests")
        #expect(await store.send() == .deliveredViaPrompt)
        #expect(
            input.userMessageIndex.entries.map(\.rawText)
                == ["rewrite the matching tests"])
    }

    @Test func blockedMultilineDraftIsIndexedOnceAtEnter() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        let draft = "please approve\nthen continue"
        store.replaceDraft(with: draft)

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data(draft.utf8)])
        #expect(input.userMessageIndex.entries.isEmpty)

        #expect(input.send(Data([0x0D])))
        #expect(input.userMessageIndex.entries.map(\.rawText) == [draft])
    }

    @Test func blockedDraftEscapeCancelsTheIndexedLine() async {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        _ = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "please approve the refactor")

        #expect(await store.send() == .deliveredViaAttach)
        #expect(input.userMessageIndex.entries.isEmpty)
        #expect(input.sendEscapeKey())
        #expect(input.send(Data([0x0D])))
        #expect(input.userMessageIndex.entries.isEmpty)
    }

    private static func draftOnlyStore() -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.timedOut
        }
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
            workspaceLabel: "Project",
            repositoryCheckout: RepositoryCheckout(
                repoKey: "/work/Project/.git",
                repoName: "Project",
                repoRoot: "/work/Project",
                checkoutPath: "/work/Project",
                isLinkedWorktree: false))
    }
}

@MainActor
@Suite("Agent Composer send button")
struct AgentComposerSendButtonTests {
    @Test
    func buttonKeepsOriginalVisualDiameter() async throws {
        let image = try await Self.render(isEnabled: true, colorScheme: .dark)
        let bounds = try #require(Self.visibleContentBounds(in: image))
        let width = bounds.width / image.scale

        #expect(
            (30...34).contains(width),
            "Send visual diameter should remain about 32pt; rendered width was \(width)")
    }

    @Test
    func buttonKeepsItsArrowVisibleAcrossStatesAndAppearances() async throws {
        for isEnabled in [false, true] {
            for colorScheme in [ColorScheme.light, .dark] {
                let image = try await Self.render(
                    isEnabled: isEnabled,
                    colorScheme: colorScheme)
                let range = try #require(
                    Self.luminanceRange(
                        in: image,
                        unitRect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)))

                #expect(
                    range > 0.12,
                    "Send center has no visible arrow when isEnabled=\(isEnabled), colorScheme=\(colorScheme); luminance range was \(range)")
            }
        }
    }

    private static func render(isEnabled: Bool, colorScheme: ColorScheme) async throws -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let renderer = ImageRenderer(
            content: ZStack {
                Color(uiColor: .secondarySystemBackground)
                AgentComposerSendButton(isEnabled: isEnabled) {}
            }
            .environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(width: bounds.width, height: bounds.height)
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    private static func luminanceRange(in image: UIImage, unitRect: CGRect) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let minX = max(0, Int(unitRect.minX * CGFloat(width)))
        let maxX = min(width, Int(unitRect.maxX * CGFloat(width)))
        let minY = max(0, Int(unitRect.minY * CGFloat(height)))
        let maxY = min(height, Int(unitRect.maxY * CGFloat(height)))
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                let luminance =
                    (0.2126 * Double(pixels[offset])
                        + 0.7152 * Double(pixels[offset + 1])
                        + 0.0722 * Double(pixels[offset + 2])) / 255
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        return maximum - minimum
    }

    private static func visibleContentBounds(in image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let background = Self.luminance(at: 0, in: pixels)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard abs(Self.luminance(at: offset, in: pixels) - background) > 0.25 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func luminance(at offset: Int, in pixels: [UInt8]) -> Double {
        (0.2126 * Double(pixels[offset])
            + 0.7152 * Double(pixels[offset + 1])
            + 0.0722 * Double(pixels[offset + 2])) / 255
    }
}
