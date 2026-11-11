import Foundation
import Testing

@testable import Heeler

/// An Attach on a tmux Pane through the tmux transport (ADR 0043): a session
/// of Heeler's own with one control client, a first paint, the Pane's output
/// after it, and an end for each way the Pane or the connection can go.
@Suite("tmux pane attach")
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

    /// Each line the Attaches' clients wrote, as the words tmux parses it into.
    private func commands(on tmux: ScriptedTmuxHost) async -> [[String]] {
        await tmux.controlCommands.map(ScriptedTmuxHost.words(of:))
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
        #expect(script.contains("exec \"$t\" -u -N -S \"$s\" -C new-session -E -s heeler-attach-"))
        #expect(script.contains("@heeler-attach '%0'"))
        #expect(script.contains("link-window -s '%0'"))
        #expect(await tmux.openControlClients == 1)
        let first = try #require(await commands(on: tmux).first)
        #expect(first.prefix(3) == ["list-panes", "-s", "-t"])
        #expect(first.dropFirst(3).first?.hasPrefix("=heeler-attach-") == true)
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
        await tmux.setDesktopClients([.init(windowID: "@0", width: 50, height: 6)])
        await tmux.setScreen(["capped", "", "", "", "", ""], of: "%0")
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane(
            "%0", request: TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 12))
        defer { Task { await session.end() } }

        var output = session.output.makeAsyncIterator()
        let first = try await read(until: "capped", from: &output)
        #expect(await tmux.windowSize("@0") == (50, 6))
        #expect(first.contains("\u{1B}[1;6r"))

        await tmux.setScreen(["tighter", "", "", "", ""], of: "%0")
        await tmux.setDesktopClients([.init(windowID: "@0", width: 40, height: 5)])
        let repainted = try await read(until: "tighter", from: &output)
        #expect(await tmux.windowSize("@0") == (40, 5))
        #expect(repainted.contains("\u{1B}[1;5r"))
    }

    @Test func resizesRideTheInputQueueInOrderAndKeepSplitSequencesTogether() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let name = try #require(await tmux.attachSessions.first)

        session.send(Data("before".utf8))
        session.send(Data("\u{1B}".utf8))
        session.resize(cols: 100, rows: 12)
        session.send(Data("after".utf8))
        session.send(Data("\u{1B}[200~hel".utf8))
        session.resize(cols: 90, rows: 10)
        session.send(Data("lo\u{1B}[201~".utf8))

        try await waitUntil("the ordered input and resizes") {
            await commands(on: tmux).contains(["paste-buffer", "-p", "-r", "-d", "-b", name, "-t", "%0"])
        }
        let ordered = await commands(on: tmux).filter { words in
            words.first == "send-keys" || words.first == "paste-buffer"
                || (words.first == "refresh-client" && words.contains("-C"))
        }
        #expect(ordered == [
            ["refresh-client", "-C", "@0:80x4"],
            Self.text("before"),
            Self.key("Escape"),
            ["refresh-client", "-C", "@0:100x12"],
            Self.text("after"),
            ["refresh-client", "-C", "@0:90x10"],
            ["paste-buffer", "-p", "-r", "-d", "-b", name, "-t", "%0"],
        ])
    }

    @Test func hidingAndShowingTurnsIgnoreSizeOnAndOff() async throws {
        let tmux = await host(height: 48)
        await tmux.setWindow("@0", width: 160, height: 48)
        await tmux.setDesktopClients([.init(windowID: "@0", width: 160, height: 48)])
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
        await tmux.setDesktopClients([.init(windowID: "@0", width: 140, height: 40)])
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
        await tmux.setDesktopClients([.init(windowID: "@0", width: 160, height: 48)])
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())

        let hidden = try await transport.attachPane(
            "%0",
            request: TerminalAttachRequest(
                target: .terminal("%0"), viewer: .resumed, isViewed: false, surfaceHasHistory: true, cols: 80, rows: 24))
        #expect(await tmux.windowSize("@0") == (160, 48))
        #expect(await tmux.controlClientsIgnoringSize() == [true])
        #expect(await commands(on: tmux).contains(["refresh-client", "-f", "ignore-size"]))
        #expect(await !commands(on: tmux).contains { $0.first == "refresh-client" && $0.contains("-C") })
        await hidden.end()

        let observing = try await transport.attachPane(
            "%0",
            request: TerminalAttachRequest(
                target: .terminal("%0"), viewer: .observe, surfaceHasHistory: true, cols: 80, rows: 24))
        observing.setPresence(.viewed(nil))
        #expect(await tmux.windowSize("@0") == (160, 48))
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
}
