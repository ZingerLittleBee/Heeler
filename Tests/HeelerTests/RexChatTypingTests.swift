import Foundation
import Testing

@testable import Heeler

/// Chat's reads and typing in a Rex terminal (ADR 0055), as the herdr-core and
/// tmux suites pin theirs: on the control link only, to the Agent that holds
/// the foreground when the lane is held, over the screen a Blocked Card
/// answers, once each, and never on a screen Rex's answer does not show with
/// certainty. Nothing takes a size or a block, and nothing is recorded on the
/// Host. Ids, programs and screens are invented.
@MainActor
@Suite("Rex chat typing", .timeLimit(.minutes(1)))
struct RexChatTypingTests {
    private static let dialog = [
        "\u{1B}[0m\u{1B}[1mAllow this command?\u{1B}[0m", "\u{1B}[0m\u{1B}[38;5;2m❯ 1. Yes\u{1B}[0m", "  2. No", "",
    ]

    private func typing(_ rig: RexChatRig) throws -> RexChatTyping {
        try rig.projection.chatTyping(at: RexChatRig.paneID)
    }

    private func refusal(_ operation: () async throws -> Void) async -> String? {
        do {
            try await operation()
            return nil
        } catch let refusal as HerdrCoreChatTyping.Refusal {
            return refusal.message
        } catch {
            Issue.record("Expected a refusal, got \(error)")
            return nil
        }
    }

    // MARK: Keys

    /// A key is read for, checked and written on the control link: the
    /// holder, the program's flags and modes, the holder again in the lane,
    /// then one write.
    @Test func aKeyGoesToTheAgentStillHoldingTheTerminal() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }
        let before = await rig.server.requests.count

        try await rig.projection.sendAgentKeys(["esc"], to: RexChatRig.paneID)

        #expect(await rig.written() == ["\u{1B}"])
        let terminal = RexInventoryWire.terminalMethod("")
        let methods = await rig.server.requests.dropFirst(before).map(\.method).filter { $0.hasPrefix(terminal) }
        #expect(methods == [
            RexInventoryWire.terminalMethod("process"), RexInventoryWire.terminalMethod("format"),
            RexInventoryWire.terminalMethod("blob_read"), RexInventoryWire.terminalMethod("modes"),
            RexInventoryWire.terminalMethod("process"), RexChatRig.write,
        ])
        await rig.tookNothing()
    }

    /// Keys follow the modes and kitty flags Rex reports, and go in one write.
    @Test func keysAreEncodedForTheProgramsModes() async throws {
        let block = FakeRexChatBlock(lines: Self.dialog)
        block.update {
            $0.kittyFlags = 1
            $0.cursorKeys = true
        }
        let rig = try await RexChatRig.start(block)
        defer { rig.end() }

        try await rig.projection.sendAgentKeys(["esc", "esc"], to: RexChatRig.paneID)
        block.update { $0.kittyFlags = 0 }
        try await rig.projection.sendAgentKeys(["up"], to: RexChatRig.paneID)

        #expect(await rig.written() == ["\u{1B}[27u\u{1B}[27u", "\u{1B}OA"])
    }

    /// A shell left behind gets nothing meant for the Agent.
    @Test func aTerminalTheAgentLeftGetsNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }
        rig.block.update { $0.foregrounds = [FakeRexChatBlock.foreground("zsh", pid: 4300)] }

        let message = await refusal { try await rig.projection.sendAgentKeys(["esc"], to: RexChatRig.paneID) }

        #expect(message == "The Agent no longer holds this terminal, so Heeler pressed nothing.")
        #expect(await rig.inputs().isEmpty)
    }

    /// The holder is read again once the block's lane is held: another
    /// process by then gets nothing.
    @Test func anotherProcessAsTheLaneOpensGetsNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }
        rig.block.update {
            $0.foregrounds = [
                FakeRexChatBlock.foreground("claude", pid: 4242), FakeRexChatBlock.foreground("claude", pid: 5151),
            ]
        }

        let message = await refusal { try await rig.projection.sendAgentKeys(["esc"], to: RexChatRig.paneID) }

        #expect(message == "Another process took over the terminal as Heeler reached it, so Heeler pressed nothing.")
        #expect(await rig.inputs().isEmpty)
    }

    /// A modes answer this build cannot read presses nothing, and says Rex's
    /// answer could not be read, not that the screen could not be.
    @Test func anUnreadableModesAnswerPressesNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }
        await rig.server.answer(RexInventoryWire.terminalMethod("modes")) { _ in
            .result(["screen": "sideways", "modes": []])
        }

        let message = await refusal { try await rig.projection.sendAgentKeys(["esc"], to: RexChatRig.paneID) }

        #expect(
            message
                == "Rex sent an answer Heeler cannot read: Rex's terminal modes could not be read. Check the Rex version on the Host."
        )
        #expect(await rig.inputs().isEmpty)
    }

    /// A write with no answer may have arrived: it is reported unknown, not
    /// as a key Heeler pressed nothing for, and never sent again.
    @Test func aWriteWithNoAnswerIsNotSentAgain() async throws {
        let rig = try await RexChatRig.start(
            FakeRexChatBlock(lines: Self.dialog),
            inputDeadline: RexDeliveryDeadline(silence: .milliseconds(100), limit: .milliseconds(200)))
        defer { rig.end() }
        await rig.server.stopAnswering(RexChatRig.write)

        let error = await #expect(throws: TransportError.self) {
            try await rig.projection.sendAgentKeys(["esc"], to: RexChatRig.paneID)
        }
        #expect(error == .coreMutationOutcomeUnknown)
        #expect(error?.isRetryable == false)
        #expect(error?.presentation.message.contains("pressed nothing") == false)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await rig.written() == ["\u{1B}"])
    }

    // MARK: The terminal Composer's Stop

    /// The terminal Composer's Stop is one Esc checked as Chat's keys are: it
    /// reaches the Agent that holds the terminal, never a shell left behind,
    /// and a block with no Agent listed keeps Send.
    @Test func theTerminalStopPressesEscForTheAgentOnly() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }
        let projection = rig.projection
        let pin = TerminalCorePin(joined: projection.inventoryCore)
        guard case .interrupt(let stop)? = projection.checkedTerminalStop(
            for: RexChatRig.paneID, keepingTo: pin, live: { projection })
        else {
            Issue.record("Expected the terminal's Stop")
            return
        }

        #expect(await stop.perform() == .sent)
        #expect(await rig.written() == ["\u{1B}"])

        rig.block.update { $0.foregrounds = [FakeRexChatBlock.foreground("zsh", pid: 4300)] }
        #expect(await stop.perform() == .failed("The Agent no longer holds this terminal, so Heeler pressed nothing."))
        #expect(await rig.written() == ["\u{1B}"])

        // The rig answers every block's foreground with the Agent, so only a
        // block the inventory does not list has no Agent.
        let unlisted = RexPaneAddress(sessionID: "session:studio", blockID: "block:gone").paneID
        guard case .keepSend? = projection.checkedTerminalStop(for: unlisted, keepingTo: pin, live: { projection })
        else {
            Issue.record("Expected Send to stay on a block with no Agent")
            return
        }
        await rig.tookNothing()
    }

    // MARK: Pastes

    /// A paste goes whole as a paste event; text with a line break waits for
    /// bracketed paste, which would otherwise send each line, as read in the
    /// lane after the holder.
    @Test func linesNeedBracketedPaste() async throws {
        let block = FakeRexChatBlock(lines: Self.dialog)
        block.update { $0.bracketedPaste = false }
        let rig = try await RexChatRig.start(block)
        defer { rig.end() }

        let message = await refusal { try await rig.projection.pasteIntoAgent("one\ntwo", paneID: RexChatRig.paneID) }
        #expect(message == ComposerRefusal.programNotAcceptingPaste.message)
        #expect(await rig.inputs().isEmpty)

        try await rig.projection.pasteIntoAgent("one line", paneID: RexChatRig.paneID)
        block.update { $0.bracketedPaste = true }
        let before = await rig.server.requests.count
        try await rig.projection.pasteIntoAgent("one\ntwo", paneID: RexChatRig.paneID)

        #expect(await rig.pasted() == ["one line", "one\ntwo"])
        let terminal = RexInventoryWire.terminalMethod("")
        let process = RexInventoryWire.terminalMethod("process")
        let methods = await rig.server.requests.dropFirst(before).map(\.method)
            .filter { $0.hasPrefix(terminal) || $0 == "block.event" }
        #expect(methods == [process, process, RexInventoryWire.terminalMethod("modes"), "block.event"])
        await rig.tookNothing()
    }

    // MARK: The screen and the Blocked Card

    @Test func theScreenIsReadOnTheControlLink() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }

        let screen = try await rig.projection.readAgentScreen(RexChatRig.paneID)

        #expect(screen.rows.map(\.text) == ["Allow this command?", "❯ 1. Yes", "  2. No", ""])
        await rig.tookNothing()
    }

    /// A screen with a sequence Rex was never seen to write is no screen, and a
    /// Blocked Card's answer over it does not go.
    @Test func anUnreadableScreenIsNoScreen() async throws {
        let block = FakeRexChatBlock(lines: Self.dialog)
        let rig = try await RexChatRig.start(block)
        defer { rig.end() }
        let screen = try typing(rig).blockedScreen
        _ = try await screen.readScreen()
        block.update { $0.lines[0] = "\u{1B}[2J" + "Allow this command?" }

        await #expect(throws: TransportError.rexScreenUnreadable) { try await screen.readScreen() }
        let message = await refusal {
            try await screen.type(.keys(["1"])) { $0.rows.first?.text == "Allow this command?" }
        }

        #expect(message == "The terminal's screen couldn't be read through Rex: Nothing was typed.")
        #expect(await rig.inputs().isEmpty)
    }

    /// Chat's Send over such a screen says Heeler could not read it through
    /// Rex and typed nothing: it names no herdr, and no version to check.
    @Test func chatsSendOverAnUnreadableScreenNamesRex() async throws {
        let block = FakeRexChatBlock(lines: Self.dialog)
        block.update { $0.lines[0] = "\u{1B}[2J" + "Allow this command?" }
        let rig = try await RexChatRig.start(block)
        defer { rig.end() }
        let projection = rig.projection
        let policy = ComposerDeliveryPolicy.chat(
            rules: ChatSendRules(
                program: .codex,
                commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .codex)),
            activity: { .idle },
            readScreen: { try await projection.readAgentScreen(RexChatRig.paneID) },
            pause: { _ in })

        let refused = try #require(await policy.preflight?("hello"))

        #expect(
            refused
                == .inputNotReady(
                    "Heeler couldn't check the Agent's input box. The terminal's screen couldn't be read through Rex: Nothing was typed."
                ))
        #expect(!refused.message.localizedCaseInsensitiveContains("herdr"))
        #expect(!refused.message.localizedCaseInsensitiveContains("version"))
        #expect(await rig.inputs().isEmpty)
    }

    /// The card's answer goes only while its screen still shows, read in the
    /// lane just before the write.
    @Test func aBlockedAnswerGoesOnlyOverItsScreen() async throws {
        let block = FakeRexChatBlock(lines: Self.dialog)
        let rig = try await RexChatRig.start(block)
        defer { rig.end() }
        let screen = try typing(rig).blockedScreen
        let shows: @Sendable (ANSIScreen) -> Bool = { $0.rows.first?.text == "Allow this command?" }

        _ = try await screen.readScreen()
        try await screen.type(.keys(["1"]), whileShowing: shows)
        #expect(await rig.written() == ["1"])

        block.update { $0.lines[0] = "Another question?" }
        let message = await refusal { try await screen.type(.keys(["1"]), whileShowing: shows) }

        #expect(message == BlockedCardStore.changedMessage)
        #expect(await rig.written() == ["1"])
        #expect(screen.recordAnswer == nil)
    }

    /// Another process since the card's read: its dialog may not be the one
    /// the user answers.
    @Test func anotherHolderSinceTheScreenReadGetsNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog))
        defer { rig.end() }
        let screen = try typing(rig).blockedScreen
        _ = try await screen.readScreen()
        rig.block.update { $0.foregrounds = [FakeRexChatBlock.foreground("claude", pid: 5151)] }

        let message = await refusal { try await screen.type(.keys(["1"])) { _ in true } }

        #expect(message == "Another process took over the terminal after Heeler read the screen, so Heeler pressed nothing.")
        #expect(await rig.inputs().isEmpty)
    }

    // MARK: Another server

    /// Typing made on one server instance sends nothing once another answers.
    @Test func anotherServerGetsNothing() async throws {
        let world = FakeRexWorld(sessions: [RexChatRig.studio()])
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.dialog), world: world, servers: 2)
        defer { rig.end() }
        let typing = try typing(rig)
        let first = rig.projection.inventoryCore

        world.restart(as: "instance-b")
        await rig.server.close(.goingAway)
        try await rig.waitUntil("the next instance") {
            rig.projection.inventoryCore != first && !rig.projection.isAwaitingSnapshot
        }

        let message = await refusal { try await typing.press(["esc"]) }

        #expect(message == TransportError.rexServerGone.presentation.message)
        #expect(await rig.inputs().isEmpty)
        #expect(try rig.projection.chatTyping(at: RexChatRig.paneID) !== typing)
    }
}
