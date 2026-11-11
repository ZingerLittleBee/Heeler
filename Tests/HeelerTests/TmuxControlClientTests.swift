import Foundation
import Testing

@testable import Heeler

/// One control-mode client over one exec (ADR 0043): its commands in order,
/// each reply matched to the command that asked, and one end for everything
/// that waits on it. Every later Attach feature sends through it.
@Suite("tmux control client")
struct TmuxControlClientTests {
    private func client(
        readTimeout: Duration = .seconds(30)
    ) -> (TmuxControlClient, ScriptedTmuxLoopChannel) {
        let channel = ScriptedTmuxLoopChannel(onClose: {})
        return (TmuxControlClient(channel: channel, readTimeout: readTimeout), channel)
    }

    private func command(_ words: String...) -> TmuxControlCommand {
        TmuxControlCommand(words)
    }

    private func lines(_ channel: ScriptedTmuxLoopChannel) async -> [String] {
        await channel.written.map { String(decoding: $0, as: UTF8.self) }
    }

    private func waitUntil(
        _ what: String, _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// The events the client delivered until it ended.
    private func drained(_ client: TmuxControlClient) async -> [TmuxControlClient.Event] {
        var events: [TmuxControlClient.Event] = []
        for await event in client.events { events.append(event) }
        return events
    }

    private func reply(_ number: UInt64, fromClient: Bool = true, _ lines: [String] = []) -> TmuxControlReply {
        TmuxControlReply(number: number, fromClient: fromClient, succeeded: true, lines: lines.map { Data($0.utf8) })
    }

    // MARK: Writing

    /// Until tmux prints, the shell that execs it may still be reading its
    /// input: a command written then would be the shell's.
    @Test func nothingIsWrittenBeforeTmuxFirstPrints() async throws {
        let (client, channel) = client()
        try await client.send(command("display-message", "-p", "x"), tag: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await channel.written.isEmpty)

        await channel.send(Data("%begin 1 10 0\n%end 1 10 0\n".utf8))
        try await waitUntil("the command to be written") { await !channel.written.isEmpty }
        #expect(await lines(channel) == ["display-message -p x\n"])
    }

    @Test func commandsAreWrittenALineEachInTheOrderTheyWereSent() async throws {
        let (client, channel) = client()
        await channel.send(Data("%begin 1 10 0\n%end 1 10 0\n".utf8))
        for tag in UInt64(1)...5 {
            try await client.send(command("display-message", "-p", "\(tag)"), tag: tag)
        }
        try await waitUntil("five lines") { await channel.written.count == 5 }
        #expect(await lines(channel) == (1...5).map { "display-message -p \($0)\n" })
    }

    // MARK: Replies

    /// tmux's numbers count every command the server ran, so only the order
    /// says which command a reply answers.
    @Test func eachReplyGoesToTheCommandsTagInOrderWithOutput() async throws {
        let (client, channel) = client()
        try await client.send(command("first"), tag: 7)
        try await client.send(command("second"), tag: 3)
        await channel.send(
            Data(
                """
                %begin 1 40 1
                one
                %end 1 40 1
                %output %1 between
                %begin 1 44 1
                two
                %end 1 44 1

                """.utf8))
        await channel.finish()
        let events = await drained(client)
        #expect(
            events == [
                .replied(tag: 7, reply(40, ["one"])),
                .output(pane: "%1", bytes: Data("between".utf8)),
                .replied(tag: 3, reply(44, ["two"])),
                .ended(.channelEnded),
            ])
    }

    @Test func aRunGetsItsOwnReply() async throws {
        let (client, channel) = client()
        try await client.send(command("tagged"), tag: 1)
        async let answer = client.run(command("run"), timeout: .seconds(5))
        try await waitUntil("both commands to wait") { await client.waitingCommands == 2 }
        await channel.send(Data("%begin 1 1 1\nfor tag\n%end 1 1 1\n%begin 1 2 1\nfor run\n%end 1 2 1\n".utf8))
        #expect(try await answer == reply(2, ["for run"]))
    }

    /// A command whose caller stopped waiting still has a reply coming, and
    /// the next command's reply is the one after it.
    @Test func aRunThatTimedOutKeepsItsPlaceInLine() async throws {
        let (client, channel) = client()
        await channel.send(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        await #expect(throws: TransportError.timedOut) {
            try await client.run(command("slow"), timeout: .milliseconds(20))
        }
        async let next = client.run(command("next"), timeout: .seconds(5))
        try await waitUntil("the second command to be written") { await channel.written.count == 2 }
        await channel.send(Data("%begin 1 2 1\nslow\n%end 1 2 1\n%begin 1 3 1\nnext\n%end 1 3 1\n".utf8))
        #expect(try await next == reply(3, ["next"]))
    }

    @Test func aCancelledRunKeepsItsPlaceInLine() async throws {
        let (client, channel) = client()
        let cancelled = Task { try await client.run(command("slow"), timeout: .seconds(5)) }
        try await waitUntil("the first command to wait") { await client.waitingCommands == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        async let next = client.run(command("next"), timeout: .seconds(5))
        try await waitUntil("the second command to wait") { await client.waitingCommands == 2 }
        await channel.send(Data("%begin 1 2 1\nslow\n%end 1 2 1\n%begin 1 3 1\nnext\n%end 1 3 1\n".utf8))
        #expect(try await next == reply(3, ["next"]))
    }

    /// A run whose task was cancelled before it began waits for nothing: it
    /// ends at once, not at its timeout, and writes nothing.
    @Test func aRunCancelledBeforeItWaitsEndsAtOnce() async throws {
        let (client, channel) = client()
        await channel.send(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.run(command("late"), timeout: .seconds(60))
        }
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await client.waitingCommands == 0)
        #expect(await channel.written.isEmpty)
    }

    /// A posted command keeps its place in line, and its reply goes nowhere.
    @Test func aPostedCommandsReplyIsDropped() async throws {
        let (client, channel) = client()
        await channel.send(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        try await client.post(command("posted"))
        try await client.send(command("tagged"), tag: 4)
        try await waitUntil("both commands to be written") { await channel.written.count == 2 }
        #expect(await lines(channel) == ["posted\n", "tagged\n"])
        await channel.send(Data("%begin 1 2 1\nfor post\n%end 1 2 1\n%begin 1 3 1\nfor tag\n%end 1 3 1\n".utf8))
        await channel.finish()
        #expect(await drained(client) == [.replied(tag: 4, reply(3, ["for tag"])), .ended(.channelEnded)])
    }

    @Test func aPostAfterTheEndThrowsIt() async throws {
        let (client, channel) = client()
        await channel.finish()
        _ = await drained(client)
        await #expect(throws: TmuxControlClient.Ended(end: .channelEnded)) {
            try await client.post(command("late"))
        }
    }

    /// The commands the client was started with reply with flags 0, one
    /// block each, before anything it writes.
    @Test func theStartCommandsRepliesAreKeptApart() async throws {
        let (client, channel) = client()
        async let barrier = client.run(command("barrier"), timeout: .seconds(5))
        try await waitUntil("the barrier to wait") { await client.waitingCommands == 1 }
        await channel.send(
            Data(
                """
                %begin 1 1 0
                %end 1 1 0
                %begin 1 2 0
                can't find window: @99
                %error 1 2 0
                %begin 1 3 1
                $4
                %end 1 3 1
                %begin 1 4 0
                %end 1 4 0

                """.utf8))
        #expect(try await barrier == reply(3, ["$4"]))
        let start = await client.startReplies
        #expect(start.map(\.number) == [1, 2])
        #expect(start.map(\.succeeded) == [true, false])
        #expect(start.allSatisfy { !$0.fromClient })
    }

    /// Commands that ran for other reasons (a user's `after-` hooks) reply with
    /// flags 0 too, and answer none of this client's commands.
    @Test func laterRepliesWithoutTheClientsFlagAnswerNothing() async throws {
        let (client, channel) = client()
        async let answer = client.run(command("mine"), timeout: .seconds(5))
        try await waitUntil("the first command to wait") { await client.waitingCommands == 1 }
        await channel.send(Data("%begin 1 3 1\n%end 1 3 1\n".utf8))
        _ = try await answer
        async let second = client.run(command("mine"), timeout: .seconds(5))
        try await waitUntil("the second command to wait") { await client.waitingCommands == 1 }
        await channel.send(Data("%begin 1 4 0\nhook\n%end 1 4 0\n%begin 1 5 1\nsecond\n%end 1 5 1\n".utf8))
        #expect(try await second == reply(5, ["second"]))
    }

    @Test func aReplyNoCommandAskedForEndsTheClient() async throws {
        let (client, channel) = client()
        await channel.send(Data("%begin 1 3 1\n%end 1 3 1\n".utf8))
        let events = await drained(client)
        guard case .ended(.failed(.malformedResponse)) = events.last else {
            Issue.record("ended with \(String(describing: events.last))")
            return
        }
        try await waitUntil("the exec to be closed") { await channel.isClosed }
    }

    // MARK: Ending

    @Test func exitEndsTheClientAndEveryCommandStillWaiting() async throws {
        let (client, channel) = client()
        let waiting = Task { try await client.run(command("waits"), timeout: .seconds(5)) }
        try await waitUntil("the command to wait") { await client.waitingCommands == 1 }
        await channel.send(Data("%begin 1 1 0\n%end 1 1 0\n%exit detached\n".utf8))
        await #expect(throws: TmuxControlClient.Ended(end: .exited(reason: "detached"))) { try await waiting.value }
        #expect(await drained(client) == [.ended(.exited(reason: "detached"))])
        await #expect(throws: TmuxControlClient.Ended(end: .exited(reason: "detached"))) {
            try await client.send(command("late"), tag: 1)
        }
        try await waitUntil("the exec to be closed") { await channel.isClosed }
    }

    @Test func theExecEndingWithoutExitIsItsOwnEnd() async throws {
        let (client, channel) = client()
        await channel.finish()
        #expect(await drained(client) == [.ended(.channelEnded)])
        #expect(await client.end == .channelEnded)
    }

    @Test func aFailedReadEndsTheClientWithThatFailure() async throws {
        let (client, channel) = client()
        let failure = TransportError.sshUnreachable(detail: "gone")
        await channel.fail(failure)
        #expect(await drained(client) == [.ended(.failed(failure))])
    }

    /// The client reads with a timeout so that it notices its end; a read that
    /// timed out says nothing about the exec.
    @Test func aReadThatTimesOutIsNotAnEnd() async throws {
        let (client, channel) = client(readTimeout: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(80))
        await channel.send(Data("%output %2 still here\n".utf8))
        await channel.finish()
        #expect(
            await drained(client) == [.output(pane: "%2", bytes: Data("still here".utf8)), .ended(.channelEnded)])
    }

    @Test func aFailedWriteEndsTheClient() async throws {
        let (client, channel) = client()
        await channel.send(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        try await waitUntil("the client to start writing") { await client.isWriting }
        await channel.fail(.channelFailed(detail: "broken"))
        try? await client.send(command("x"), tag: 1)
        #expect(await drained(client) == [.ended(.failed(.channelFailed(detail: "broken")))])
    }

    @Test func closingEndsTheClientAndClosesItsExec() async throws {
        let (client, channel) = client()
        let waiting = Task { try await client.run(command("waits"), timeout: .seconds(5)) }
        try await waitUntil("the command to wait") { await client.waitingCommands == 1 }
        await client.close()
        #expect(await channel.isClosed)
        await #expect(throws: TmuxControlClient.Ended(end: .closed)) { try await waiting.value }
        #expect(await drained(client) == [.ended(.closed)])
        await #expect(throws: TmuxControlClient.Ended(end: .closed)) {
            try await client.run(command("late"), timeout: .seconds(1))
        }
    }

    @Test func outputPastTheReadersLimitEndsTheClient() async throws {
        let channel = ScriptedTmuxLoopChannel(onClose: {})
        let client = TmuxControlClient(channel: channel, reader: TmuxControlReader(lineLimit: 8))
        await channel.send(Data("%output %1 more than eight bytes\n".utf8))
        let events = await drained(client)
        guard case .ended(.failed(.malformedResponse)) = events.last else {
            Issue.record("ended with \(String(describing: events.last))")
            return
        }
    }
}

/// Commands as a control client writes them: words tmux reads back exactly,
/// whatever they hold (ADR 0043).
@Suite("tmux control command")
struct TmuxControlCommandTests {
    @Test func plainWordsAreWrittenAsTheyAre() {
        #expect(TmuxControlCommand(["kill-window", "-t", "x_1-2"]).line == "kill-window -t x_1-2")
    }

    @Test func otherWordsAreDoubleQuoted() {
        #expect(
            TmuxControlCommand(["display-message", "-p", "-t", "%5", "#{pane_id} #{?@heeler-attach,1,0};$x"]).line
                == ##"display-message -p -t "%5" "\#\{pane_id\} \#\{?@heeler-attach,1,0\}\;\$x""##)
    }

    @Test func anEmptyWordIsKept() {
        #expect(TmuxControlCommand(["set-option", "-u", ""]).line == #"set-option -u """#)
    }

    /// tmux reads `\ooo` in double quotes from 3.3a on, and expands `$` and `~`
    /// there unless they are escaped.
    @Test func controlCharactersAndExpansionsAreEscaped() {
        #expect(
            TmuxControlCommand(["x", "it's \"a\" $HOME ~ \\ \u{1B}[1m\n\u{7F}中"]).line
                == #"x "it's \"a\" \$HOME \~ \\ \033[1m\n\177中""#)
    }

    @Test func aLineNeverHoldsANewline() {
        let line = TmuxControlCommand(["a\nb", "\r"]).line
        #expect(!line.contains { $0.isNewline })
    }
}
