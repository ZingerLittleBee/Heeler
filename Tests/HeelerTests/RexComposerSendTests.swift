import Foundation
import Synchronization
import Testing

@testable import Heeler

/// Composer Send on a Rex Agent (ADR 0055), pinned as tmux's and herdr-core's
/// are: one paste and one Enter on the control link, each after the Agent is
/// read again in the block's lane, nothing for a Blocked Agent or a program
/// with bracketed paste off, one `0x03` for a shell that took over, a request
/// with no answer never sent again, and nothing for another server. Ids,
/// programs and texts are invented.
/// A clock whose every reading is three seconds after the last.
private final class SlowClock: Sendable {
    private let readings = Mutex(0)
    private let start = ContinuousClock.now

    var clock: BlockedCardClock {
        BlockedCardClock(
            now: { self.start + .seconds(3) * self.readings.withLock { count in defer { count += 1 }; return count } },
            sleep: { try await Task.sleep(for: $0) })
    }
}

@MainActor
@Suite("Rex composer send", .timeLimit(.minutes(1)))
struct RexComposerSendTests {
    private static let prompt = ["\u{1B}[0m\u{1B}[2m>\u{1B}[0m ", "", "", ""]

    private static func world(reporting state: String? = "idle") -> FakeRexWorld {
        FakeRexWorld(sessions: [RexChatRig.studio(reporting: state)])
    }

    /// The paste, then Enter, each after a fresh read of the holder in the lane.
    @Test func aSendPastesThenSubmits() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()
        let before = await rig.server.requests.count

        let outcome = await send.send("fix the flaky test", route: .chat, attach: nil)

        #expect(outcome == .submitted)
        #expect(await rig.pasted() == ["fix the flaky test"])
        #expect(await rig.written() == ["\r"])
        let terminal = RexInventoryWire.terminalMethod("")
        let process = RexInventoryWire.terminalMethod("process")
        let methods = await rig.server.requests.dropFirst(before).map(\.method)
            .filter { $0.hasPrefix(terminal) || $0 == "block.event" }
        let modes = RexInventoryWire.terminalMethod("modes")
        let format = RexInventoryWire.terminalMethod("format")
        let blobRead = RexInventoryWire.terminalMethod("blob_read")
        let pasteIndex = try #require(methods.firstIndex(of: "block.event"))
        // Pre-lane and in-lane reads run concurrently before the paste, then
        // a fresh process read confirms the holder before Enter.
        let beforePaste = Array(methods[..<pasteIndex])
        #expect(beforePaste.sorted() == [process, format, blobRead, modes, process, modes].sorted())
        #expect(Array(methods[pasteIndex...]) == ["block.event", process, RexChatRig.write])
        await rig.tookNothing()
    }

    /// A Blocked Agent's dialog would take the Enter as its answer.
    @Test func aBlockedAgentGetsNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world(reporting: "blocked"))
        defer { rig.end() }
        let send = try rig.composerSend()
        try await rig.waitUntil("Blocked") { rig.projection.agentsByPane[RexChatRig.paneID]?.agent.status == .blocked }

        #expect(await send.send("hello", route: .chat, attach: nil) == .refused(.agentBlocked))
        let fromTerminal = await send.send("hello", route: .terminal, attach: nil)
        guard case .refused(.inputNotReady) = fromTerminal else {
            Issue.record("Expected the terminal to be told to answer first, got \(fromTerminal)")
            return
        }
        #expect(await rig.inputs().isEmpty)
    }

    /// Without bracketed paste the server would type the text and each line
    /// break would submit.
    @Test func bracketedPasteOffSendsNothing() async throws {
        let block = FakeRexChatBlock(lines: Self.prompt)
        block.update { $0.bracketedPaste = false }
        let rig = try await RexChatRig.start(block, world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()

        #expect(await send.send("hello", route: .chat, attach: nil) == .refused(.programNotAcceptingPaste))
        #expect(await rig.inputs().isEmpty)
    }

    /// A kitty flags read whose answer shows nothing certain sends nothing,
    /// and says the screen could not be read, not that the Host is silent.
    @Test func anUnreadableFlagsReadSendsNothing() async throws {
        let block = FakeRexChatBlock(lines: Self.prompt)
        block.update { $0.kittyFlags = 64 }
        let rig = try await RexChatRig.start(block, world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()

        let outcome = await send.send("hello", route: .chat, attach: nil)
        #expect(outcome == .refused(.inputNotReady(TransportError.rexScreenUnreadable.presentation.message)))
        #expect(await rig.inputs().isEmpty)
    }

    /// A modes answer this build cannot read sends nothing, and says Rex's
    /// answer could not be read, not the screen and not a silent Host.
    @Test func anUnreadableModesAnswerSendsNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()
        await rig.server.answer(RexInventoryWire.terminalMethod("modes")) { _ in .result(["screen": "primary"]) }

        let outcome = await send.send("hello", route: .chat, attach: nil)
        #expect(
            outcome
                == .refused(
                    .inputNotReady(
                        "Rex sent an answer Heeler cannot read: Rex's terminal modes could not be read. Check the Rex version on the Host."
                    )))
        #expect(await rig.inputs().isEmpty)
    }

    /// The program can turn bracketed paste off after the first read: the
    /// read in the lane, just before the paste, decides.
    @Test func bracketedPasteOffByTheLaneSendsNothing() async throws {
        let block = FakeRexChatBlock(lines: Self.prompt)
        block.update { $0.bracketedPasteAnswers = [true, false] }
        let rig = try await RexChatRig.start(block, world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()

        #expect(await send.send("hello", route: .chat, attach: nil) == .refused(.programNotAcceptingPaste))
        #expect(await rig.inputs().isEmpty)
    }

    /// Another process by the time the lane is held gets no paste.
    @Test func anotherProcessBeforeThePasteGetsNothing() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()
        rig.block.update {
            $0.foregrounds = [
                FakeRexChatBlock.foreground("claude", pid: 4242), FakeRexChatBlock.foreground("claude", pid: 5151),
            ]
        }

        let outcome = await send.send("hello", route: .chat, attach: nil)

        #expect(outcome == .refused(.inputNotReady(
            "Another process took over the terminal as Heeler reached it, so nothing was sent.")))
        #expect(await rig.inputs().isEmpty)
    }

    /// A shell that took over after the paste gets one `0x03`, which drops the
    /// paste unrun, and no Enter.
    @Test func aShellAfterThePasteGetsOneInterrupt() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()
        rig.block.update {
            $0.foregrounds = [
                FakeRexChatBlock.foreground("claude", pid: 4242), FakeRexChatBlock.foreground("claude", pid: 4242),
                FakeRexChatBlock.foreground("zsh", pid: 4300), FakeRexChatBlock.foreground("zsh", pid: 4300),
            ]
        }

        let outcome = await send.send("hello", route: .chat, attach: nil)

        guard case .refused(.notSubmitted(let message)) = outcome else {
            Issue.record("Expected nothing submitted, got \(outcome)")
            return
        }
        #expect(message.contains("no longer in the terminal"))
        #expect(await rig.pasted() == ["hello"])
        #expect(await rig.written() == ["\u{03}"])
    }

    /// The `0x03` goes only while the shell still leads, read again in the
    /// lane: the Agent back in the foreground by then would take it as an
    /// interrupt of its own work.
    @Test(arguments: [("the agent back", "claude", 4242), ("another shell", "zsh", 4301)])
    func theInterruptWaitsForTheSameShell(_ who: String, program: String, pid: Int) async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()
        rig.block.update {
            $0.foregrounds = [
                FakeRexChatBlock.foreground("claude", pid: 4242), FakeRexChatBlock.foreground("claude", pid: 4242),
                FakeRexChatBlock.foreground("zsh", pid: 4300), FakeRexChatBlock.foreground(program, pid: pid),
            ]
        }

        let outcome = await send.send("hello", route: .chat, attach: nil)

        guard case .refused(.notSubmitted(let message)) = outcome else {
            Issue.record("Expected nothing submitted for \(who), got \(outcome)")
            return
        }
        #expect(message.contains("may still be in the terminal"))
        #expect(await rig.pasted() == ["hello"])
        #expect(await rig.written().isEmpty)
    }

    /// The paste and the Enter must both land inside the submit window.
    @Test func aSlowHostSubmitsNothing() async throws {
        let rig = try await RexChatRig.start(
            FakeRexChatBlock(lines: Self.prompt), world: Self.world(), sendClock: SlowClock().clock)
        defer { rig.end() }
        let send = try rig.composerSend()

        let outcome = await send.send("hello", route: .chat, attach: nil)

        guard case .refused(.notSubmitted) = outcome else {
            Issue.record("Expected nothing submitted, got \(outcome)")
            return
        }
        #expect(await rig.pasted() == ["hello"])
        #expect(await rig.written().isEmpty)
    }

    /// A paste with no answer may have arrived: it is never sent again, the
    /// next Send only warns, and the one after goes.
    @Test func aPasteWithNoAnswerIsNeverSentAgain() async throws {
        let rig = try await RexChatRig.start(
            FakeRexChatBlock(lines: Self.prompt), world: Self.world(),
            inputDeadline: RexDeliveryDeadline(silence: .milliseconds(100), limit: .milliseconds(200)))
        defer { rig.end() }
        await rig.server.stopAnswering("block.event")
        let send = try rig.composerSend()

        #expect(await send.send("first", route: .chat, attach: nil) == .outcomeUnknown)
        #expect(await send.send("second", route: .chat, attach: nil) == .refused(.inputNotReady(
            "The last message may still be in the Agent's input, so nothing was sent. Check the terminal, then send again.")))
        await rig.server.answer("block.event", with: .result(.object([:])))
        #expect(await send.send("third", route: .chat, attach: nil) == .submitted)

        #expect(await rig.pasted() == ["first", "third"])
        #expect(await rig.written() == ["\r"])
    }

    /// Two Sends never share one Enter: the second waits for the first.
    @Test func sendsTakeTurns() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: Self.world())
        defer { rig.end() }
        let send = try rig.composerSend()

        let first = Task { await send.send("one", route: .chat, attach: nil) }
        let second = Task { await send.send("two", route: .terminal, attach: nil) }
        #expect(await first.value == .submitted)
        #expect(await second.value == .submitted)

        let order = await rig.inputs().map { request in
            request.payload?["event"]?["payload"]?["text"]?.stringValue
                ?? request.payload?["args"]?["data"]?.stringValue ?? ""
        }
        #expect(order == ["one", "\r", "two", "\r"])
    }

    /// A Send made on one server instance sends nothing once another answers.
    @Test func anotherServerGetsNothing() async throws {
        let world = Self.world()
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: world, servers: 2)
        defer { rig.end() }
        let send = try rig.composerSend()
        let first = rig.projection.inventoryCore

        world.restart(as: "instance-b")
        await rig.server.close(.goingAway)
        try await rig.waitUntil("the next instance") {
            rig.projection.inventoryCore != first && !rig.projection.isAwaitingSnapshot
        }

        #expect(await send.send("hello", route: .chat, attach: nil) == .refused(.inputNotReady(
            TransportError.rexServerGone.presentation.message)))
        #expect(await rig.inputs().isEmpty)
    }
}
