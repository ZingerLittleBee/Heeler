import Foundation
import Synchronization
import Testing

@testable import Heeler

/// An Attach on a tmux Pane through the tmux transport (ADR 0043): a session
/// of Heeler's own with one control client, a first paint, the Pane's output
/// after it, and an end for each way the Pane or the connection can go.
@Suite("tmux pane attach", .timeLimit(.minutes(1)))
struct TmuxPaneAttachTests {
    private let request = TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 4)

    private func host(height: Int = 4) async -> ScriptedTmuxHost {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", height: height),
            .make(pane: 1, paneIndex: 1, command: "zsh", height: height),
            .make(session: 1, sessionName: "other", window: 2, pane: 2, command: "zsh", height: height),
        ])
        return tmux
    }

    private func attach(
        _ pane: String = "%0", on tmux: ScriptedTmuxHost, startLimit: Duration = .seconds(5)
    ) async throws -> TerminalAttachSession {
        let transport = await tmux.transport(
            socketName: "default", storedPaths: ScriptedTmuxHost.paths(), attachStartLimit: startLimit)
        return try await transport.attachPane(pane, request: request)
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

    /// Reads output until `text` shows up in it.
    private func read(
        until text: String, from output: inout AsyncThrowingStream<Data, any Error>.Iterator
    ) async throws -> String {
        var read = ""
        while !read.contains(text), let bytes = try await output.next() {
            read += String(decoding: bytes, as: UTF8.self)
        }
        return read
    }

    /// Each command the Attaches' clients wrote, as the words tmux parses it into.
    private func commands(on tmux: ScriptedTmuxHost) async -> [[String]] {
        await tmux.controlCommands.flatMap(ScriptedTmuxHost.commandList(of:))
    }

    private static func endsASession(_ words: [String]) -> Bool {
        words.count == 3 && words[0] == "kill-session" && words[1] == "-t" && words[2].hasPrefix("$")
    }

    private func ending(of output: inout AsyncThrowingStream<Data, any Error>.Iterator) async -> (any Error)? {
        do {
            while try await output.next() != nil {}
            return nil
        } catch {
            return error
        }
    }

    // MARK: Starting

    @Test func anAttachStartsItsOwnSessionOnThePane() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let script = try #require(await tmux.controlScripts.first)
        #expect(script.contains("\"$t\" -u -N -S \"$s\" -C new-session -E -s heeler-attach-"))
        #expect(script.contains("| { cat; cat >/dev/null; }"))
        #expect(script.contains("\nexit\n}"))
        #expect(script.contains("@heeler-attach '%0'"))
        #expect(script.contains("link-window -s '%0'"))
        #expect(await tmux.openControlClients == 1)
        let first = try #require(await commands(on: tmux).first)
        #expect(first.prefix(3) == ["list-panes", "-s", "-t"])
        #expect(first.dropFirst(3).first?.hasPrefix("=heeler-attach-") == true)
    }

    /// What was typed is written, then detach, and the output ends without the
    /// Pane-gone failure a detach's `%exit` would otherwise be.
    @Test func closingDetachesAfterQueuedInputAndTheOutputEndsCleanly() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        session.send(Data("ab".utf8))
        try await waitUntil("the text") { await commands(on: tmux).contains(Self.text("ab")) }
        await session.end()
        let written = await commands(on: tmux)
        let textAt = try #require(written.firstIndex(of: Self.text("ab")))
        let detachAt = try #require(written.lastIndex(of: ["detach-client"]))
        #expect(textAt < detachAt)
        #expect(await tmux.openControlClients == 0)
        #expect(await ending(of: &output) == nil)
    }

    @Test func theFirstPaintComesFirstThenThePanesOutput() async throws {
        let tmux = await host()
        await tmux.setScreen(["$ claude", "> hello", "", ""], of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        let painted = try await read(until: "> hello", from: &output)
        #expect(painted.hasPrefix(TmuxPanePaint.reset))
        await tmux.paneOutput("other pane\r\n", in: "%1")
        await tmux.paneOutput("thinking\r\n", in: "%0")
        let live = try await read(until: "thinking", from: &output)
        #expect(live == "thinking\r\n")
    }

    /// A Pane gone before its session linked it ends the Terminal, and the
    /// session that started around its placeholder is ended.
    @Test func aPaneThatIsGoneEndsTheAttachAndItsSession() async throws {
        let tmux = await host()
        await #expect(throws: TransportError.tmuxPaneGone) { try await attach("%7", on: tmux) }
        #expect(await commands(on: tmux).contains(where: Self.endsASession))
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }
    }

    /// The Terminal joined one server; another took the socket since, with a
    /// pane of the same id.
    @Test func anAttachOnAnotherServerEndsItsSession() async throws {
        let tmux = await host()
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        var request = request
        request.coreID = "tmux-4242-1"
        await #expect(throws: TransportError.tmuxServerGone) { try await transport.attachPane("%0", request: request) }
        #expect(await commands(on: tmux).contains(where: Self.endsASession))
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }

        request.coreID = ScriptedTmuxHost.instance.id
        let session = try await transport.attachPane("%0", request: request)
        await session.end()
    }

    @Test func aStartThatNeverAnswersTimesOutAndClosesItsExec() async throws {
        let tmux = await host()
        await tmux.silenceNextControlClient()
        await #expect(throws: TransportError.timedOut) {
            try await attach(on: tmux, startLimit: .milliseconds(100))
        }
    }

    // MARK: While attached

    @Test func aPausedPaneIsPaintedAgain() async throws {
        let tmux = await host()
        await tmux.setScreen(["first", "", "", ""], of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        _ = try await read(until: "first", from: &output)
        await tmux.setScreen(["after the pause", "", "", ""], of: "%0")
        await tmux.pause("%0")
        let repainted = try await read(until: "after the pause", from: &output)
        #expect(repainted.hasPrefix(TmuxPanePaint.reset))
        #expect(await commands(on: tmux).contains(["refresh-client", "-A", "%0:continue"]))
    }

    // MARK: Ending

    @Test func endingTheSessionClosesTheClient() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await session.end()
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }
        #expect(await ending(of: &output) == nil)
    }

    /// Heeler's session would keep the window, and its program, alive.
    @Test func aWindowOnlyHeelerHoldsIsClosedAndTheAttachEnds() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await tmux.endUserSessions(holding: "%0")
        let error = await ending(of: &output)
        #expect(error as? TransportError == .tmuxPaneGone)
        #expect(await commands(on: tmux).contains(["kill-window", "-t", "@0"]))
    }

    @Test func aServerThatStopsEndsTheAttach() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await tmux.stopServer()
        #expect(await ending(of: &output) as? TransportError == .tmuxPaneGone)
    }

    @Test func aLostConnectionEndsTheAttachWithTheLoss() async throws {
        let tmux = await host()
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane("%0", request: request)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        try await transport.close()
        guard case .sshUnreachable = await ending(of: &output) as? TransportError else {
            Issue.record("The attach did not end with the loss")
            return
        }
    }

    // MARK: Input

    /// What the Attach's client wrote for input, as tmux parses it: keys,
    /// text, buffers, pastes, and the reads of `#{pane_key_mode}`.
    private func input(on tmux: ScriptedTmuxHost) async -> [[String]] {
        await commands(on: tmux).filter { words in
            ["send-keys", "set-buffer", "paste-buffer", "delete-buffer"].contains(words.first ?? "")
                || words.contains(TmuxKey.paneKeyModeFormat)
        }
    }

    private static let keyModeRead = ["display-message", "-p", "-t", "%0", TmuxKey.paneKeyModeFormat]

    private static func text(_ text: String) -> [String] { ["send-keys", "-l", "-t", "%0", "--", text] }

    private static func key(_ name: String) -> [String] { ["send-keys", "-t", "%0", name] }

    /// Text goes as text and each key by its tmux name, in the order typed,
    /// through the Attach's own client.
    @Test func textAndKeysGoThroughTheClientInOrder() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        session.send(Data(#"echo "hi" $HOME ~ #{x};"#.utf8) + Data([0x0D]))
        session.send(Data("\u{1B}[A\u{03}\u{1B}[Z".utf8))
        let expected = [
            Self.text(#"echo "hi" $HOME ~ #{x};"#), Self.key("Enter"), Self.key("Up"), Self.key("C-c"), Self.key("BTab"),
        ]
        try await waitUntil("the input") { await input(on: tmux).count >= expected.count }
        #expect(await input(on: tmux) == expected)
    }

    /// A key with no legacy encoding goes only while the Pane's program reads
    /// keys in an extended mode, never before tmux 3.5 (an empty read), and
    /// what was typed after it follows it.
    @Test(arguments: [("VT10x", false), ("", false), ("Ext 1", true), ("Ext 2", true)])
    func aKeyWithNoLegacyEncodingGoesOnlyInAnExtendedMode(mode: String, sent: Bool) async throws {
        let tmux = await host()
        await tmux.setKeyMode(mode, of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        session.send(Data("\u{1B}[27;2;13~".utf8))
        session.send(Data("x".utf8))
        let expected = [Self.keyModeRead] + (sent ? [Self.key("S-Enter")] : []) + [Self.text("x")]
        try await waitUntil("the input") { await input(on: tmux).count >= expected.count }
        #expect(await input(on: tmux) == expected)
    }

    /// Every measured key reaches tmux by the name the shared vector holds,
    /// and none as bytes with `send-keys -H`.
    @Test func everyMeasuredKeyGoesByItsName() async throws {
        let vector = try TmuxInputVectorFile.load()
        let tmux = await host()
        await tmux.setKeyMode("Ext 2", of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        for key in vector.keys { session.send(TmuxInputVectorFile.bytes(key.desktop)) }
        let expected = vector.keys.map { key in key.text.map(Self.text) ?? Self.key(key.key ?? "") }
        let sent = { await self.input(on: tmux).filter { $0 != Self.keyModeRead } }
        try await waitUntil("every key") { await sent().count >= expected.count }
        #expect(await sent() == expected)
        #expect(await !commands(on: tmux).contains { $0.first == "send-keys" && $0.contains("-H") })
    }

    private static let pasted = Data("\u{1B}[200~line one\nline \"two\"\u{1B}[201~\r".utf8)

    private static func pasteCommands(_ name: String) -> [[String]] {
        [
            ["set-buffer", "-b", name, "--", "line one\nline \"two\""],
            ["paste-buffer", "-p", "-r", "-d", "-b", name, "-t", "%0"],
            Self.key("Enter"),
        ]
    }

    /// A paste goes into a buffer named for this Attach, and is pasted from it
    /// exactly, line feeds included, which deletes the buffer.
    @Test func aPasteGoesThroughABufferOfTheAttachs() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let name = try #require(await tmux.attachSessions.first)
        session.send(Self.pasted)
        let expected = Self.pasteCommands(name)
        try await waitUntil("the paste") { await input(on: tmux).count >= expected.count }
        #expect(await input(on: tmux) == expected)
        #expect(await tmux.buffers.isEmpty)
    }

    /// The view can write a paste's start marker, its text and its end marker
    /// apart: it is still one paste, whose line feeds stay line feeds. Cut
    /// inside the start marker after `ESC [ 2`, in the text, and inside the
    /// end marker; cuts after `ESC` and `ESC [` are `TmuxInputStreamTests`'.
    @Test(arguments: [[3], [4], [5], [6], [14], [20], [26], [27], [29], [3, 14, 27], [6, 26, 30]])
    func aPasteCutAcrossWritesIsOnePaste(cuts: [Int]) async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let name = try #require(await tmux.attachSessions.first)
        var start = 0
        for cut in cuts + [Self.pasted.count] {
            session.send(Data(Self.pasted.prefix(cut).dropFirst(start)))
            start = cut
        }
        let expected = Self.pasteCommands(name)
        try await waitUntil("the paste") { await input(on: tmux).count >= expected.count }
        #expect(await input(on: tmux) == expected)
    }

    /// A paste that failed leaves its buffer, which Heeler deletes by its
    /// name; the user's own buffers stay.
    @Test func aBufferAFailedPasteLeftIsDeleted() async throws {
        let tmux = await host()
        await tmux.setBuffer("the user's", named: "buffer0")
        await tmux.failNextPaste()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let name = try #require(await tmux.attachSessions.first)
        session.send(Data("\u{1B}[200~text\u{1B}[201~".utf8))
        let expected = [
            ["set-buffer", "-b", name, "--", "text"],
            ["paste-buffer", "-p", "-r", "-d", "-b", name, "-t", "%0"],
            ["delete-buffer", "-b", name],
        ]
        try await waitUntil("the buffer to go") { await input(on: tmux).count >= expected.count }
        #expect(await input(on: tmux) == expected)
        #expect(await tmux.buffers == ["buffer0": "the user's"])
    }

    /// Once the Attach ended, input is refused rather than kept.
    @Test func inputAfterTheEndIsRefused() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await tmux.endUserSessions(holding: "%0")
        _ = await ending(of: &output)
        await #expect(throws: (any Error).self) {
            try await session.sendAcknowledged(Data("ls".utf8))
        }
        await session.end()
    }

    // MARK: Sizing

    @Test func aViewedAttachScalesAndCorrectsItsWindowsSizeWithoutZooming() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", width: 53, height: 24),
            .make(pane: 1, paneIndex: 1, command: "zsh", width: 53, height: 24),
            .make(pane: 2, paneIndex: 2, command: "zsh", width: 52, height: 24),
            .make(session: 1, sessionName: "other", window: 2, pane: 3, command: "zsh", width: 132, height: 40),
        ])
        await tmux.setWindow("@0", width: 160, height: 24, layout: ScriptedTmuxHost.horizontalSplit(["%0", "%1", "%2"]))
        await tmux.setWindow("@2", width: 132, height: 40)
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 40, rows: 10))
        defer { Task { await session.end() } }

        let size = try #require(await tmux.paneSize("%0"))
        #expect(size.width <= 40 && size.height <= 10)
        #expect(size == (40, 10))
        #expect(await tmux.windowSize("@2") == (132, 40))
        let sent = await commands(on: tmux)
        #expect(sent.contains { $0.prefix(2) == ["refresh-client", "-C"] && $0.last?.hasPrefix("@0:") == true })
        #expect(!sent.contains { $0.contains("resize-pane") || $0.contains("-Z") })
    }

    @Test func aSmallerDesktopClientCapsTheWindowAndChangingTheCeilingRepaintsThePane() async throws {
        let tmux = await host(height: 6)
        await tmux.setWindow("@0", width: 50, height: 6)
        await tmux.setDesktopClients([.init(windowID: "@0", width: 50, height: 7, status: "on")])
        await tmux.setScreen(["capped", "", "", "", "", ""], of: "%0")
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 12))
        defer { Task { await session.end() } }

        var output = session.output.makeAsyncIterator()
        let first = try await read(until: "capped", from: &output)
        #expect(await tmux.windowSize("@0") == (50, 6))
        #expect(await commands(on: tmux).contains(["refresh-client", "-C", "@0:50x6"]))
        #expect(await !commands(on: tmux).contains(["refresh-client", "-C", "@0:80x12"]))
        #expect(first.contains("\u{1B}[1;6r"))

        await tmux.setScreen(["tighter", "", "", "", ""], of: "%0")
        await tmux.setDesktopClients([.init(windowID: "@0", width: 40, height: 6, status: "on")])
        let repainted = try await read(until: "tighter", from: &output)
        #expect(await tmux.windowSize("@0") == (40, 5))
        #expect(await commands(on: tmux).contains(["refresh-client", "-C", "@0:40x5"]))
        #expect(repainted.contains("\u{1B}[1;5r"))
    }

    @Test func clientCeilingHonorsStatusLinesSkipsNonQualifyingClientsAndUncapsWithNone() async throws {
        for (status, expectedRows) in [("on", 7), ("off", 8), ("2", 6)] {
            let tmux = await host(height: expectedRows)
            await tmux.setWindow("@0", width: 50, height: expectedRows)
            await tmux.setDesktopClients([.init(windowID: "@0", width: 50, height: 8, status: status)])
            let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
            let session = try await transport.attachPane(
                "%0",
                request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 12))
            #expect(await tmux.windowSize("@0") == (50, expectedRows))
            #expect(await commands(on: tmux).contains(["refresh-client", "-C", "@0:50x\(expectedRows)"]))
            await session.end()
        }

        // Control clients, ignore-size clients, and clients on another window do not cap @0;
        // with no qualifying client on @0, there is no ceiling.
        let tmux = await host(height: 12)
        await tmux.setWindow("@0", width: 60, height: 10)
        await tmux.setDesktopClients([
            .init(name: "/dev/ttys010", windowID: "@0", width: 30, height: 6, ignoringSize: true),
            .init(name: "/dev/ttys011", windowID: "@0", width: 30, height: 6, controlMode: true),
            .init(name: "/dev/ttys012", sessionID: "$2", windowID: "@2", width: 30, height: 6),
        ])
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 12))
        defer { Task { await session.end() } }
        #expect(await tmux.windowSize("@0") == (80, 12))
        #expect(await commands(on: tmux).contains(["refresh-client", "-C", "@0:80x12"]))
    }

    @Test func clientAndWindowNotificationsEachTriggerACeilingReReadAndResize() async throws {
        let tmux = await host(height: 20)
        await tmux.setWindow("@0", width: 80, height: 20)
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 20))
        defer { Task { await session.end() } }
        #expect(await tmux.windowSize("@0") == (80, 20))

        // 1. %client-session-changed: a smaller desktop client attaches on @0.
        await tmux.attachDesktopClient(
            .init(name: "/dev/ttys020", sessionID: "$0", windowID: "@0", width: 44, height: 9, status: "on"))
        try await waitUntil("capped after client-session-changed") { await tmux.windowSize("@0") == (44, 8) }

        // 2. %session-window-changed: that session moves to @2, lifting the ceiling;
        //    moving a status=2 session onto @0 caps at 36x8.
        await tmux.switchDesktopWindow(sessionID: "$0", to: "@2")
        try await waitUntil("uncapped after session-window-changed away") { await tmux.windowSize("@0") == (80, 20) }

        await tmux.attachDesktopClient(
            .init(name: "/dev/ttys021", sessionID: "$1", windowID: "@2", width: 36, height: 10, status: "2"))
        await tmux.switchDesktopWindow(sessionID: "$1", to: "@0")
        try await waitUntil("capped after session-window-changed onto @0") { await tmux.windowSize("@0") == (36, 8) }

        // 3. %client-detached: the client on @0 detaches, lifting the ceiling again.
        await tmux.detachDesktopClient(named: "/dev/ttys021")
        try await waitUntil("uncapped after client-detached") { await tmux.windowSize("@0") == (80, 20) }

        // 4. %layout-change on @0: splitting @0 into two panes wants 161x20,
        //    re-reads the 120x25 ceiling, and caps the request at @0:120x20.
        await tmux.attachDesktopClient(
            .init(name: "/dev/ttys022", sessionID: "$0", windowID: "@0", width: 120, height: 25, status: "off"))
        let listReadsBeforeLayout = await commands(on: tmux).filter { $0.first == "list-clients" }.count
        await tmux.setWindow("@0", width: 80, height: 20, layout: ScriptedTmuxHost.horizontalSplit(["%0", "%1"]))
        try await waitUntil("capped split after layout-change") { await tmux.windowSize("@0") == (120, 20) }
        try await waitUntil("ceiling re-read on layout-change") {
            await commands(on: tmux).filter { $0.first == "list-clients" }.count > listReadsBeforeLayout
        }
        #expect(await commands(on: tmux).contains(["refresh-client", "-C", "@0:120x20"]))
        #expect(await !commands(on: tmux).contains { $0.prefix(2) == ["refresh-client", "-C"] && $0.last == "@0:161x20" })
    }

    @Test func resizesRideTheInputQueueInOrderAndKeepSplitSequencesTogether() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let name = try #require(await tmux.attachSessions.first)

        await tmux.holdControlReplies(true)
        defer { Task { await tmux.holdControlReplies(false) } }
        session.send(Data("before".utf8))
        session.send(Data("\u{1B}".utf8))
        session.resize(cols: 100, rows: 12)
        session.send(Data("after".utf8))
        session.send(Data("\u{1B}[200~hel".utf8))
        session.resize(cols: 90, rows: 10)
        session.send(Data("lo\u{1B}[201~".utf8))

        // Keystrokes and split paste arrive without waiting for sizing reads to finish.
        try await waitUntil("input sent before sizing finishes") {
            await commands(on: tmux).contains(["paste-buffer", "-p", "-r", "-d", "-b", name, "-t", "%0"])
        }
        let sentBeforeSizingFinished = await commands(on: tmux).filter {
            $0.first == "send-keys" || $0.first == "paste-buffer"
        }
        #expect(sentBeforeSizingFinished == [
            Self.text("before"),
            Self.key("Escape"),
            Self.text("after"),
            ["paste-buffer", "-p", "-r", "-d", "-b", name, "-t", "%0"],
        ])

        await tmux.holdControlReplies(false)
        try await waitUntil("coalesced resize to 90x10") { await tmux.windowSize("@0") == (90, 10) }
        let sizeRequests = await commands(on: tmux).filter {
            $0.first == "refresh-client" && $0.contains("-C")
        }
        #expect(sizeRequests == [
            ["refresh-client", "-C", "@0:80x4"],
            ["refresh-client", "-C", "@0:90x10"],
        ])

        // Also when an earlier resize's read is already in flight, queued resizes
        // coalesce to the last target and never block trailing keystrokes.
        let countBeforeBurst = await commands(on: tmux).count
        await tmux.holdControlReplies(true)
        session.resize(cols: 110, rows: 14)
        try await waitUntil("first resize read in flight") {
            await commands(on: tmux).dropFirst(countBeforeBurst).contains { $0.first == "list-clients" }
        }
        session.resize(cols: 120, rows: 16)
        session.resize(cols: 130, rows: 18)
        session.send(Data("next".utf8))
        try await waitUntil("trailing keystrokes sent while sizing read held") {
            await commands(on: tmux).dropFirst(countBeforeBurst).contains(Self.text("next"))
        }
        await tmux.holdControlReplies(false)
        try await waitUntil("settled on 130x18") { await tmux.windowSize("@0") == (130, 18) }
        let burstSizeRequests = await commands(on: tmux).dropFirst(countBeforeBurst).filter {
            $0.first == "refresh-client" && $0.contains("-C")
        }
        #expect(burstSizeRequests == [["refresh-client", "-C", "@0:130x18"]])
    }

    @Test func hidingAndShowingTurnsIgnoreSizeOnAndOff() async throws {
        let tmux = await host(height: 48)
        await tmux.setWindow("@0", width: 160, height: 48)
        await tmux.setDesktopClients([.init(windowID: "@0", width: 160, height: 49, status: "on")])
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 24))
        defer { Task { await session.end() } }

        #expect(await tmux.windowSize("@0") == (80, 24))
        #expect(await tmux.controlClientsIgnoringSize() == [false])

        session.setPresence(.hidden)
        try await waitUntil("ignore-size on") { await tmux.controlClientsIgnoringSize() == [true] }
        #expect(await tmux.windowSize("@0") == (160, 48))
        #expect(await commands(on: tmux).contains(["refresh-client", "-f", "ignore-size", "-C", "@0:80x24"]))

        let countWhileHidden = await commands(on: tmux).count
        await tmux.setDesktopClients([.init(windowID: "@0", width: 140, height: 41, status: "on")])
        try await waitUntil("check after desktop resize") { await commands(on: tmux).count >= countWhileHidden + 1 }
        #expect(await tmux.windowSize("@0") == (140, 40))
        // Only TmuxPaneFeed's link check runs while hidden; no sizing or repaint commands leave.
        let whileHidden = Array((await commands(on: tmux)).dropFirst(countWhileHidden))
        #expect(!whileHidden.contains { $0.first == "refresh-client" || $0.first == "capture-pane" })

        session.setPresence(.viewed(nil))
        try await waitUntil("ignore-size off") { await tmux.controlClientsIgnoringSize() == [false] }
        #expect(await tmux.windowSize("@0") == (80, 24))
        #expect(await commands(on: tmux).contains(["refresh-client", "-f", "!ignore-size", "-C", "@0:80x24"]))
    }

    @Test func anAttachOpenedHiddenOrObservingLeavesTheWindowsSizeAlone() async throws {
        let tmux = await host(height: 48)
        await tmux.setWindow("@0", width: 160, height: 48)
        await tmux.setDesktopClients([.init(windowID: "@0", width: 160, height: 49, status: "on")])
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())

        let hidden = try await transport.attachPane(
            "%0",
            request: TerminalAttachRequest(
                target: .terminal("%0"), viewer: .resumed, isViewed: false, surfaceHasHistory: true, cols: 80, rows: 24))
        try await waitUntil("ignore-size on") { await tmux.controlClientsIgnoringSize() == [true] }
        #expect(await tmux.windowSize("@0") == (160, 48))
        #expect(await commands(on: tmux).contains(["refresh-client", "-f", "ignore-size"]))
        #expect(await !commands(on: tmux).contains { $0.first == "refresh-client" && $0.contains("-C") })
        await hidden.end()

        let observing = try await transport.attachPane(
            "%0",
            request: TerminalAttachRequest(
                target: .terminal("%0"), viewer: .observe, surfaceHasHistory: true, cols: 80, rows: 24))
        try await waitUntil("ignore-size on") { await tmux.controlClientsIgnoringSize() == [true] }
        observing.setPresence(.viewed(nil))
        var observingOutput = observing.output.makeAsyncIterator()
        _ = try await observingOutput.next()
        #expect(await tmux.controlClientsIgnoringSize() == [true])
        #expect(await tmux.windowSize("@0") == (160, 48))
        #expect(await !commands(on: tmux).contains { $0.first == "refresh-client" && $0.contains("-C") })
        await observing.end()
    }

    @Test func hidingWithNoDesktopClientKeepsTheWindowsSize() async throws {
        let tmux = await host(height: 30)
        await tmux.setWindow("@0", width: 120, height: 30)
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 24))
        defer { Task { await session.end() } }

        #expect(await tmux.windowSize("@0") == (80, 24))
        session.setPresence(.hidden)
        try await waitUntil("ignore-size on") { await tmux.controlClientsIgnoringSize() == [true] }
        #expect(await tmux.windowSize("@0") == (80, 24))
    }

    @Test func checkedSendSurfaceSharesTheNamedBufferOrdersAfterTypingAndReportsOutcomes() async throws {
        let tmux = await host()
        await tmux.setBracketedPaste(true, of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()

        let send = try #require(session.tmuxSend)
        #expect(await send.bracketedPaste() == .enabled)

        let sessionName = try #require(await tmux.attachSessions.first)
        session.send(Data("a".utf8))
        let pasted = await send.paste("line 1\nline 2", { try await Task.sleep(for: $0) })
        let submitted = await send.sendKey("Enter", { try await Task.sleep(for: $0) })
        #expect(pasted == .left)
        #expect(submitted == .left)
        #expect(await tmux.buffers.isEmpty)
        #expect(
            await input(on: tmux) == [
                Self.text("a"),
                ["set-buffer", "-b", sessionName, "--", "line 1\nline 2"],
                ["paste-buffer", "-p", "-r", "-d", "-b", sessionName, "-t", "%0"],
                Self.key("Enter"),
            ])

        await tmux.failNextPaste()
        let refusedPaste = await send.paste("gone", { try await Task.sleep(for: $0) })
        #expect(refusedPaste == .notLeft)
        try await waitUntil("the failed paste's buffer is deleted") { await tmux.buffers.isEmpty }

        await tmux.holdControlReplies(true)
        let unansweredPaste = await send.paste("held", { _ in })
        #expect(unansweredPaste == .unknown)
        try await waitUntil("delete-buffer queued after timeout") {
            await commands(on: tmux).contains(["delete-buffer", "-b", sessionName])
        }
        await tmux.holdControlReplies(false)
        try await waitUntil("held paste cleaned up") { await tmux.buffers.isEmpty }
    }

    @Test func olderTmuxAttachReportsUnreportedBracketedPasteUntilOutputTurnsItOff() async throws {
        let tmux = ScriptedTmuxHost(version: "tmux 3.3a")
        await tmux.setPanes([.make(pane: 0, command: "claude", height: 4)])
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()

        let send = try #require(session.tmuxSend)
        #expect(await send.bracketedPaste() == .unreportedAndNotTurnedOff)
        await tmux.paneOutput("\u{1B}[?2004lprompt", in: "%0")
        _ = try await read(until: "prompt", from: &output)
        #expect(await send.bracketedPaste() == .disabled)
    }

    @Test func aClientEndingMidPasteLeavesNoHeelerBufferAndReportsUnknownOnceStarted() async throws {
        let tmux = await host()
        await tmux.setBuffer("the user's", named: "buffer0")

        // 1. Typed paste (#690) whose control client breaks mid-paste leaves no Heeler buffer.
        let first = try await attach(on: tmux)
        var firstOutput = first.output.makeAsyncIterator()
        _ = try await firstOutput.next()
        await tmux.breakControlClientOnNextPasteWrite()
        first.send(Data("\u{1B}[200~sensitive typed paste\u{1B}[201~".utf8))
        _ = await ending(of: &firstOutput)
        #expect(await tmux.buffers == ["buffer0": "the user's"])
        await first.end()

        // 2. Checked Send paste (#691) whose control client breaks mid-paste leaves no Heeler buffer
        // and reports `.unknown` (since the paste already started), whereas a paste called after the
        // session's queue ended never starts and reports `.notLeft`.
        let second = try await attach(on: tmux)
        var secondOutput = second.output.makeAsyncIterator()
        _ = try await secondOutput.next()
        let secondSend = try #require(second.tmuxSend)
        await tmux.breakControlClientOnNextPasteWrite()
        let brokenMidPaste = await secondSend.paste("sensitive composer paste", { try await Task.sleep(for: $0) })
        #expect(brokenMidPaste == .unknown)
        #expect(await tmux.buffers == ["buffer0": "the user's"])
        await second.end()

        let neverStarted = await secondSend.paste("after end", { try await Task.sleep(for: $0) })
        #expect(neverStarted == .notLeft)
        #expect(await tmux.buffers == ["buffer0": "the user's"])

        // 3. If tmux exits (`%exit`) or the Attach ends while a paste is held in flight, the started
        // paste reports `.unknown` rather than `.notLeft`, and leaves no Heeler buffer.
        let third = try await attach(on: tmux)
        var thirdOutput = third.output.makeAsyncIterator()
        _ = try await thirdOutput.next()
        let thirdSend = try #require(third.tmuxSend)
        await tmux.holdControlReplies(true)
        let inFlight = Task { await thirdSend.paste("in flight before server exit", { try await Task.sleep(for: $0) }) }
        try await waitUntil("in-flight paste written") {
            await commands(on: tmux).contains { $0 == ["set-buffer", "-b", $0.dropFirst(2).first ?? "", "--", "in flight before server exit"] }
        }
        #expect(await tmux.buffers == ["buffer0": "the user's"])
        await tmux.stopServer()
        #expect(await inFlight.value == .unknown)
        await tmux.holdControlReplies(false)
        await third.end()
    }

    @Test func runOrderedReportsNotLeftBeforeStartingAndUnknownOnceStarted() async throws {
        // 1. Queue already finished before `runOrdered`: never starts -> `.notLeft`.
        let finishedQueue = TerminalAttachInputQueue()
        finishedQueue.finish()
        let ranOnFinished = Mutex(false)
        let afterFinish = await TmuxPaneAttach.runOrdered(on: finishedQueue) {
            ranOnFinished.withLock { $0 = true }
            return .left
        }
        #expect(afterFinish == .notLeft)
        #expect(!ranOnFinished.withLock { $0 })

        // 2. Queued behind a failing write: `pump` stops before reaching the action -> `.notLeft`.
        let failingQueue = TerminalAttachInputQueue()
        let allowWriteFailure = AsyncStream.makeStream(of: Void.self)
        let enteredWrite = Mutex(false)
        let failingPump = Task {
            try await failingQueue.pump(
                write: { _ in
                    enteredWrite.withLock { $0 = true }
                    for await _ in allowWriteFailure.stream { break }
                    throw TransportError.channelFailed(detail: "lost")
                },
                resize: { _, _ in })
        }
        failingQueue.send(Data("x".utf8))
        try await waitUntil("write in flight") { enteredWrite.withLock { $0 } }
        let ranBehindFailure = Mutex(false)
        let queuedBehindFailure = Task {
            await TmuxPaneAttach.runOrdered(on: failingQueue) {
                ranBehindFailure.withLock { $0 = true }
                return .left
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        allowWriteFailure.continuation.finish()
        _ = try? await failingPump.value
        #expect(await queuedBehindFailure.value == .notLeft)
        #expect(!ranBehindFailure.withLock { $0 })

        // 3. Operation started, then queue finishes and `pump` cancels while in flight
        // (`performAcknowledged` throws `sessionEnded` before a result is recorded) -> `.unknown`.
        let activeQueue = TerminalAttachInputQueue()
        let started = Mutex(false)
        let activePump = Task {
            try? await activeQueue.pump(write: { _ in }, resize: { _, _ in })
        }
        let inFlight = Task {
            await TmuxPaneAttach.runOrdered(on: activeQueue) {
                started.withLock { $0 = true }
                try await Task.sleep(for: .seconds(60))
                return .left
            }
        }
        try await waitUntil("operation started") { started.withLock { $0 } }
        activeQueue.finish()
        activePump.cancel()
        #expect(await inFlight.value == .unknown)
    }
}
