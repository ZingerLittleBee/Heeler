import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Watching a Pane over real SSH and a real tmux (ADR 0043): each Attach is a
/// control client in a session of Heeler's own, and the Pane reaches the
/// terminal as a first paint and then its own output. The watched Pane is
/// `tail -f` of a file on the Host, so a test prints into it by appending.
extension TmuxTransportE2ETests {
    /// A Pane following a new file, started by `words`, which name where it
    /// goes. Its program is given as words of their own, so tmux runs it
    /// without the account's shell.
    private func followingPane(
        _ words: [String], on fixture: TmuxSSHFixture
    ) async throws -> (pane: String, file: String) {
        let file = "\(fixture.configuration.homePath)/pane-\(UUID().uuidString.prefix(8)).out"
        try await fixture.require(": > " + GitProbe.singleQuoted(file))
        let pane = try await fixture.require(
            fixture.tmuxLine(words + ["-P", "-F", "#{pane_id}", "/usr/bin/tail", "-n", "+1", "-f", file]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(TmuxAttachScript.isPaneID(pane))
        return (pane, file)
    }

    /// Appends `format` to `file`, which printf expands: `\033` is an escape.
    private func append(_ format: String, to file: String, on fixture: TmuxSSHFixture) async throws {
        try await fixture.require("printf \(GitProbe.singleQuoted(format)) >> \(GitProbe.singleQuoted(file))")
    }

    /// Waits until the Pane shows `text`, so what follows sees it there.
    private func waitUntilShown(_ text: String, in pane: String, on fixture: TmuxSSHFixture) async throws {
        try await fixture.eventually {
            try await fixture.tmux(nil, "capture-pane", "-p", "-t", pane).contains(text)
        }
    }

    private func request(for pane: String, on fixture: TmuxSSHFixture) async throws -> TerminalAttachRequest {
        var request = TerminalAttachRequest(target: .terminal(pane), surfaceHasHistory: false, cols: 80, rows: 24)
        request.coreID = try await fixture.serverInstance().id
        return request
    }

    private func read(
        until text: String, from output: inout AsyncThrowingStream<Data, any Error>.Iterator
    ) async throws -> String {
        try await read(from: &output) { $0.contains(text) }
    }

    private func read(
        from output: inout AsyncThrowingStream<Data, any Error>.Iterator, until done: (String) -> Bool
    ) async throws -> String {
        var read = ""
        while !done(read) {
            guard let bytes = try await output.next() else { break }
            read += String(decoding: bytes, as: UTF8.self)
        }
        return read
    }

    private func attachSessions(on fixture: TmuxSSHFixture) async throws -> [String] {
        try await fixture.sessionNames().filter { $0.hasPrefix(TmuxAttachScript.sessionPrefix) }
    }

    private func clients(on fixture: TmuxSSHFixture) async throws -> [String] {
        try await fixture.tmux(nil, "list-clients", "-F", "#{client_session} #{client_control_mode} #{client_flags}")
            .split(separator: "\n").map(String.init)
    }

    @Test("an Attach watches one Pane through a session of its own, which ends with it")
    func anAttachWatchesAPaneThroughASessionOfItsOwn() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await followingPane(["new-window", "-d", "-t", "main:", "-n", "watched"], on: fixture)
            let window = try await fixture.tmux(nil, "display-message", "-p", "-t", pane, "#{window_id}")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let (other, otherFile) = try await followingPane(["split-window", "-d", "-t", pane], on: fixture)
            try await append((1...40).map { "line \($0)\\n" }.joined(), to: file, on: fixture)
            try await waitUntilShown("line 40", in: pane, on: fixture)

            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                var output = session.output.makeAsyncIterator()
                // The first paint brings the lines scrolled off the Pane too.
                let painted = try await read(until: "line 40", from: &output)
                #expect(painted.hasPrefix(TmuxPanePaint.reset))
                #expect(painted.contains("line 1\r\n"))

                // A session of its own, marked, ending with its one control
                // client, and holding only the Pane's window.
                let mine = try #require(try await attachSessions(on: fixture).first)
                #expect(try await fixture.sessionNames() == ["main", mine].sorted())
                let target = "=\(mine):"
                #expect(try await fixture.tmux(nil, "show-options", "-v", "-t", target, "@heeler-attach") == "\(pane)\n")
                #expect(try await fixture.tmux(nil, "show-options", "-v", "-t", target, "destroy-unattached") == "on\n")
                #expect(try await fixture.tmux(nil, "list-windows", "-t", "=\(mine)", "-F", "#{window_id}") == "\(window)\n")
                let client = try #require(try await clients(on: fixture).first)
                #expect(try await clients(on: fixture).count == 1)
                #expect(client.hasPrefix("\(mine) 1 "))
                #expect(client.contains("pause-after=\(TmuxSSHTransport.pauseAfter)"))

                // A bare attach still picks a session of the user's.
                let bare = try await fixture.tmux(nil, "-C", "attach")
                #expect(bare.contains("%session-changed $0 main\n"))

                // Only this Pane's output follows, not its neighbour's.
                try await append("elsewhere\\n", to: otherFile, on: fixture)
                try await waitUntilShown("elsewhere", in: other, on: fixture)
                try await append("fresh\\n", to: file, on: fixture)
                let live = try await read(until: "fresh", from: &output)
                #expect(!live.contains("elsewhere"))
                #expect(!live.contains(TmuxPanePaint.reset))

                // Ending it ends its session. The user's Panes stay.
                await session.end()
                try await fixture.eventually { try await fixture.sessionNames() == ["main"] }
                #expect(try await clients(on: fixture).isEmpty)
                let panes = try await fixture.tmux(nil, "list-panes", "-a", "-F", "#{pane_id}")
                #expect(panes.contains("\(pane)\n") && panes.contains("\(other)\n"))
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    @Test("a Pane paused for falling behind is painted again and goes on")
    func aPausedPaneIsPaintedAgain() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await followingPane(["new-window", "-d", "-t", "main:"], on: fixture)
            try await append("before the pause\\n", to: file, on: fixture)
            try await waitUntilShown("before the pause", in: pane, on: fixture)

            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                var output = session.output.makeAsyncIterator()
                _ = try await read(until: "before the pause", from: &output)
                let client = try await fixture.tmux(nil, "list-clients", "-F", "#{client_name}")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // tmux pauses a Pane for a client `pause-after` behind it; this pauses it now.
                try await fixture.tmux(nil, "refresh-client", "-t", client, "-A", "\(pane):pause")
                let repainted = try await read(from: &output) { read in
                    read.components(separatedBy: TmuxPanePaint.reset).dropFirst().last?.contains("before the pause") == true
                }
                #expect(repainted.contains(TmuxPanePaint.reset))

                // Continued: its output reaches the client again.
                try await append("after the pause\\n", to: file, on: fixture)
                _ = try await read(until: "after the pause", from: &output)
                await session.end()
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    /// Heeler's session would keep the window, and its program, alive after
    /// the user ended every session of theirs that held it.
    @Test("a window only Heeler's session holds is closed, and its Attach ends")
    func aWindowOnlyHeelersSessionHoldsIsClosed() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await followingPane(["new-session", "-d", "-s", "solo"], on: fixture)
            try await append("solo\\n", to: file, on: fixture)
            try await waitUntilShown("solo", in: pane, on: fixture)

            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                var output = session.output.makeAsyncIterator()
                _ = try await read(until: "solo", from: &output)

                try await fixture.tmux(nil, "kill-session", "-t", "=solo")
                var ending: (any Error)?
                do {
                    while try await output.next() != nil {}
                } catch {
                    ending = error
                }
                #expect(ending as? TransportError == .tmuxPaneGone)
                try await fixture.eventually { try await fixture.sessionNames() == ["main"] }
                #expect(try await !fixture.tmux(nil, "list-panes", "-a", "-F", "#{pane_id}").contains("\(pane)\n"))
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    @Test("a Pane on its alternate screen opens in the terminal view with both screens and its modes")
    func aPaneOnItsAlternateScreenOpensWithBothScreensAndItsModes() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await followingPane(["new-window", "-d", "-t", "main:"], on: fixture)
            try await append("normal 1\\nnormal 2\\nnormal 3\\n", to: file, on: fixture)
            try await waitUntilShown("normal 3", in: pane, on: fixture)
            try await append(
                "\\033[?1049h\\033[H\\033[2JALT TOP\\033[?1h\\033[?1000h\\033[?1006h\\033[?2004h", to: file, on: fixture)
            try await waitUntilShown("ALT TOP", in: pane, on: fixture)
            // tmux 3.7 reports bracketed paste; an older one says nothing of it.
            let reportsBracketedPaste =
                try await fixture.tmux(nil, "display-message", "-p", "-t", pane, "#{bracket_paste_flag}") == "1\n"
            try await openInTheTerminalView(
                pane, file: file, reportsBracketedPaste: reportsBracketedPaste, on: fixture)
        }
    }

    @MainActor
    private func openInTheTerminalView(
        _ pane: String, file: String, reportsBracketedPaste: Bool, on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()
        let attach = AttachTerminalStore(
            target: .terminal(pane), runTerminal: store.terminalRunner(for: host.id, keepingTo: store.corePin(on: host.id)))
        let controller = UIHostingController(rootView: TerminalScreenView(feed: attach.feed))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        do {
            try await fixture.eventually { await store.terminals.contains { $0.paneID == pane } }
            controller.view.layoutIfNeeded()
            let terminal = try #require(Self.terminalViews(in: controller.view).first)
            attach.viewDidResize(cols: 80, rows: 24)
            try await fixture.eventually { await attach.status == .live }
            try await waitForViewport(of: terminal) { $0.contains("ALT TOP") }
            #expect(attach.modes.isAlternateScreen)
            #expect(attach.modes.usesApplicationCursorKeys)
            #expect(attach.modes.tracksMouse)
            #expect(attach.modes.usesSGRMouseEncoding)
            #expect(attach.modes.usesBracketedPaste == reportsBracketedPaste)

            // Back on the normal screen, it shows what the Pane had there.
            try await append("\\033[?1049l", to: file, on: fixture)
            try await waitForViewport(of: terminal) { $0.contains("normal 3") && !$0.contains("ALT TOP") }
            #expect(!attach.modes.isAlternateScreen)

            await attach.stop()
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            store.setHosts([])
        } catch {
            await attach.stop()
            store.setHosts([])
            throw error
        }
    }

    @MainActor
    private func waitForViewport(of terminal: HeelerTerminalView, _ shows: (String) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let text = terminal.terminalSession.readViewportText(), shows(text) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TmuxSSHFailure.timeout
    }

    @MainActor
    private static func terminalViews(in root: UIView) -> [HeelerTerminalView] {
        var found: [HeelerTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? HeelerTerminalView { found.append(terminal) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    // MARK: Input

    /// Sent last, so the probe's file ending in it holds everything typed.
    private static let endOfTyping = "#end"

    /// A Pane whose program reads what it is typed, raw, into a new file,
    /// after asking for bracketed paste and, for `mok2`, modifyOtherKeys 2.
    private func probePane(asking mode: String, on fixture: TmuxSSHFixture) async throws -> (pane: String, file: String) {
        let home = fixture.configuration.homePath
        let program = "\(home)/bin/read-typed"
        try await fixture.writeProgram(
            at: program,
            """
            #!/bin/sh
            stty raw -echo
            if [ "$2" = mok2 ]; then printf '\\033[>4;2m'; fi
            printf '\\033[?2004h'
            exec cat > "$1"
            """)
        let file = "\(home)/typed-\(UUID().uuidString.prefix(8)).bin"
        let pane = try await fixture.require(
            fixture.tmuxLine(["new-window", "-d", "-t", "main:", "-P", "-F", "#{pane_id}", "/bin/sh", program, file, mode]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(TmuxAttachScript.isPaneID(pane))
        // The file appears once the terminal is raw and the modes are asked for.
        try await fixture.eventually { try await fixture.run("test -e \(GitProbe.singleQuoted(file))").exitStatus == 0 }
        return (pane, file)
    }

    /// What the probe read, in hex, once the last thing it read was
    /// `endOfTyping`, or when that never came.
    private func typed(into file: String, on fixture: TmuxSSHFixture) async throws -> String {
        let end = Self.hex(Data(Self.endOfTyping.utf8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var read = ""
        repeat {
            if !read.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            read = try await fixture.require("od -An -tx1 -v \(GitProbe.singleQuoted(file)) | tr -d ' \\n'")
        } while !read.hasSuffix(end) && ContinuousClock.now < deadline
        return read
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The measured keys typed here: text, legacy keys, each kind of key with
    /// no legacy encoding, and Ctrl with each punctuation that has a control
    /// character.
    private static let typedKeys = [
        "a", "Space", "Enter", "Tab", "BTab", "Escape", "BSpace", "Up", "Home", "PPage", "F1", "F5",
        "S-Enter", "C-Enter", "M-Enter", "C-Tab", "C-S-Tab", "C-BSpace", "C-Up", "M-Left", "C-a", "C-c",
        "C-j", "C-_", "C-Space", "C-S-a", "C-1", "M-a", "M-A", "C-M-a", "S-Space",
        "C-@", "C-[", #"C-\"#, "C-]", "C-^", "C-?",
    ]

    /// Keys typed into an Attach reach the Pane's program as the input
    /// measurements recorded a desktop terminal's (`tmux-input-v1.json`):
    /// under tmux's default `extended-keys off`, and under `on` for a program
    /// that asked for modifyOtherKeys 2. A key with no legacy encoding arrives
    /// only while `#{pane_key_mode}` reads an extended mode, and otherwise not
    /// at all. A key the view can send in other forms (`alternates`) is typed
    /// in each, and each reads as the desktop terminal's key. A tmux the
    /// measurements did not cover is held to 3.7b's reads.
    @Test("keys typed into an Attach reach the Pane's program as a desktop terminal's do")
    func keysTypedIntoAnAttachReachTheProgramAsMeasured() async throws {
        let vector = try TmuxInputVectorFile.load()
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let version = try await fixture.tmux(nil, "-V").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "tmux ", with: "")
            let measured = vector.runs.contains { $0.version == version } ? version : "3.7b"
            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                for (extendedKeys, program) in [("off", "legacy"), ("on", "mok2")] {
                    let run = try #require(
                        vector.runs.first {
                            $0.version == measured && $0.extendedKeys == extendedKeys && $0.program == program
                                && ($0.extendedKeysFormat ?? "xterm") == "xterm"
                        })
                    try await fixture.tmux(nil, "set-option", "-s", "extended-keys", extendedKeys)
                    let (pane, file) = try await probePane(asking: program, on: fixture)
                    try await fixture.eventually {
                        try await fixture.tmux(nil, "display-message", "-p", "-t", pane, TmuxKey.paneKeyModeFormat)
                            .trimmingCharacters(in: .whitespacesAndNewlines) == run.paneKeyMode
                    }
                    var expected = ""
                    let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                    for name in Self.typedKeys {
                        let key = try #require(vector.keys.first { $0.name == name })
                        let sent = key.extended != true
                            || TmuxKey(name: key.key ?? "", isExtended: true).isSent(whilePaneKeyModeReads: run.paneKeyMode)
                        for form in [key.desktop] + (key.alternates ?? []) {
                            session.send(TmuxInputVectorFile.bytes(form))
                            if sent { expected += run.read[name] ?? "" }
                        }
                    }
                    session.send(Data(Self.endOfTyping.utf8))
                    expected += Self.hex(Data(Self.endOfTyping.utf8))
                    let read = try await typed(into: file, on: fixture)
                    #expect(read == expected, "tmux \(version), extended-keys \(extendedKeys), \(program)")
                    await session.end()
                }
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    /// Text typed into an Attach arrives exactly: quotes, `$`, `~`, `#{}`,
    /// `;`, CJK, emoji and a trailing backslash. A paste arrives as one, line
    /// feeds and tabs kept, between the bracketed paste markers the program
    /// asked for.
    @Test("text and a paste typed into an Attach arrive exactly")
    func textAndAPasteTypedIntoAnAttachArriveExactly() async throws {
        let vector = try TmuxInputVectorFile.load()
        let texts = vector.texts.map(\.text).filter { !$0.unicodeScalars.contains { $0.value < 0x20 } }
        let paste = try #require(vector.pasteTexts.first { $0.name == "tabs-unicode" }).text
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await probePane(asking: "legacy", on: fixture)
            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                for text in texts { session.send(Data(text.utf8)) }
                let bracketed = "\u{1B}[200~" + paste + "\u{1B}[201~"
                session.send(Data(bracketed.utf8))
                session.send(Data(Self.endOfTyping.utf8))
                let expected = Self.hex(Data((texts.joined() + bracketed + Self.endOfTyping).utf8))
                #expect(try await typed(into: file, on: fixture) == expected)
                // The paste's buffer went with it.
                #expect(try await fixture.tmux(nil, "list-buffers", "-F", "#{buffer_name}").isEmpty)
                await session.end()
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }
}
