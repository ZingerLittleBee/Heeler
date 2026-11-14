import CryptoKit
import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Watching a Pane over real SSH and a real tmux (ADR 0045): each Attach is a
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
                #expect(try await fixture.tmux(nil, "show-options", "-v", "-t", target, "destroy-unattached") == "off\n")
                #expect(try await fixture.tmux(nil, "show-options", "-v", "-t", target, "detach-on-destroy") == "on\n")
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
    /// asked for, though the view wrote its markers and its text apart.
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
                let parts = ["\u{1B}[200~", paste, "\u{1B}[201~"]
                for part in parts { session.send(Data(part.utf8)) }
                let bracketed = parts.joined()
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

    // MARK: Sizing

    private struct DesktopClient: Sendable {
        let pid: Int
        let fixture: TmuxSSHFixture

        func stop() async {
            _ = try? await fixture.run("kill \(pid) 2>/dev/null; true")
            try? await fixture.eventually {
                let ps = (try? await fixture.require("ps -p \(pid) -o pid= || true")) ?? ""
                return ps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// A stand-in desktop terminal attached to `target` over a real PTY whose
    /// window area is `windowColumns` by `windowRows` (one status line below).
    private func attachDesktopClient(
        to target: String, windowColumns: Int, windowRows: Int, on fixture: TmuxSSHFixture
    ) async throws -> DesktopClient {
        let home = fixture.configuration.homePath
        let program = "\(home)/bin/desktop-client"
        try await fixture.writeProgram(
            at: program,
            """
            #!/usr/bin/python3
            import fcntl, os, pty, signal, struct, subprocess, sys, termios
            tmux_exec, sock, target, cols, rows, pid_file = sys.argv[1:7]
            if os.fork() > 0:
                os._exit(0)
            os.setsid()
            devnull = os.open("/dev/null", os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(devnull, fd)
            if devnull > 2:
                os.close(devnull)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", int(rows), int(cols), 0, 0))
            env = {
                "HOME": os.environ["HOME"],
                "TMUX_TMPDIR": os.environ["TMUX_TMPDIR"],
                "TERM": "xterm-256color",
                "PATH": "/usr/bin:/bin",
            }
            child = subprocess.Popen(
                [tmux_exec, "-N", "-S", sock, "attach-session", "-t", target],
                stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
            )
            os.close(slave)
            def shutdown(_sig, _frame):
                try:
                    child.terminate()
                except OSError:
                    pass
                try:
                    os.close(master)
                except OSError:
                    pass
                os._exit(0)
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, shutdown)
            with open(pid_file, "w") as handle:
                handle.write(f"{os.getpid()}\\n")
            try:
                while os.read(master, 16384):
                    pass
            except OSError:
                pass
            try:
                os.close(master)
            except OSError:
                pass
            child.wait()
            """)
        let pidFile = "\(home)/desktop-\(UUID().uuidString.prefix(8)).pid"
        let ptyRows = windowRows + 1
        let command = [
            "/usr/bin/python3", program, fixture.configuration.tmuxExecutable, fixture.socketPath(),
            target, "\(windowColumns)", "\(ptyRows)", pidFile,
        ].map(GitProbe.singleQuoted).joined(separator: " ")
        try await fixture.require(command)
        try await fixture.eventually {
            guard try await fixture.exists(pidFile) else { return false }
            let clients = try await fixture.tmux(
                nil, "list-clients", "-F", "#{client_control_mode} #{client_width}x#{client_height}")
            return clients.contains("0 \(windowColumns)x\(ptyRows)\n")
        }
        let pidText = try await fixture.require("cat " + GitProbe.singleQuoted(pidFile))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int(pidText))
        return DesktopClient(pid: pid, fixture: fixture)
    }

    private struct PanePlacement: Equatable, Sendable {
        let paneWidth: Int
        let paneHeight: Int
        let windowWidth: Int
        let windowHeight: Int
        let zoomed: Bool
    }

    private func placement(of pane: String, on fixture: TmuxSSHFixture) async throws -> PanePlacement {
        let fields = try await fixture.tmux(
            nil, "display-message", "-p", "-t", pane,
            "#{pane_width} #{pane_height} #{window_width} #{window_height} #{window_zoomed_flag}"
        ).split(whereSeparator: \.isWhitespace)
        let numbers = try fields.map { try #require(Int($0)) }
        try #require(numbers.count == 5)
        return PanePlacement(
            paneWidth: numbers[0], paneHeight: numbers[1],
            windowWidth: numbers[2], windowHeight: numbers[3],
            zoomed: numbers[4] != 0)
    }

    private func windowDimensions(_ target: String, on fixture: TmuxSSHFixture) async throws -> String {
        try await fixture.tmux(nil, "display-message", "-p", "-t", target, "#{window_width}x#{window_height}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(
        "a shown Pane scales its window to fit the device, stops at a smaller desktop client's ceiling, and leaves the rest of the view blank",
        .timeLimit(.minutes(2)))
    func aShownPaneFitsTheDeviceAndRespectsADesktopCeiling() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()

            // A 3-pane split with a larger desktop client on the same window:
            // Heeler scales from the Pane's share, corrects until the Pane fits,
            // and never zooms a pane.
            let (pane, file) = try await followingPane(["new-window", "-t", "main:", "-n", "split"], on: fixture)
            _ = try await followingPane(["split-window", "-h", "-t", pane], on: fixture)
            _ = try await followingPane(["split-window", "-h", "-t", pane], on: fixture)
            try await fixture.tmux(nil, "select-layout", "-t", pane, "even-horizontal")
            try await append("split ready\\n", to: file, on: fixture)
            try await waitUntilShown("split ready", in: pane, on: fixture)

            let largeDesktop = try await attachDesktopClient(
                to: "main", windowColumns: 180, windowRows: 50, on: fixture)
            do {
                try await fixture.eventually { try await windowDimensions(pane, on: fixture) == "180x50" }
                let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
                do {
                    var req = TerminalAttachRequest(target: .terminal(pane), surfaceHasHistory: false, cols: 40, rows: 12)
                    req.coreID = try await fixture.serverInstance().id
                    let session = try await transport.attachPane(pane, request: req)
                    var output = session.output.makeAsyncIterator()
                    _ = try await read(until: "split ready", from: &output)

                    let fitted = try await placement(of: pane, on: fixture)
                    #expect(fitted.paneWidth <= 40 && fitted.paneWidth >= 39)
                    #expect(fitted.paneHeight == 12)
                    #expect(fitted.windowWidth > 40 && fitted.windowWidth < 180)
                    #expect(!fitted.zoomed)

                    session.resize(cols: 50, rows: 15)
                    try await fixture.eventually {
                        let resized = try await placement(of: pane, on: fixture)
                        return resized.paneWidth <= 50 && resized.paneWidth >= 49 && resized.paneHeight == 15
                    }
                    #expect(try await !placement(of: pane, on: fixture).zoomed)

                    await session.end()
                    try await transport.close()
                } catch {
                    try? await transport.close()
                    throw error
                }
                await largeDesktop.stop()
            } catch {
                await largeDesktop.stop()
                throw error
            }

            // An already-attached idle desktop client smaller than the device
            // caps the window across every window-size mode (never typing after
            // Heeler attaches), and in the terminal view the smaller Pane stays
            // inside its own rows and columns while the rest of the 80x24 view
            // stays blank.
            let ceilingModes: [(mode: String, aggressive: Bool)] = [
                ("latest", false),
                ("latest", true),
                ("smallest", false),
                ("largest", false),
            ]
            for scenario in ceilingModes {
                try await fixture.reset()
                try await fixture.startServer()
                try await fixture.tmux(nil, "set-option", "-gw", "window-size", scenario.mode)
                try await fixture.tmux(nil, "set-option", "-gw", "aggressive-resize", scenario.aggressive ? "on" : "off")

                let (cappedPane, cappedFile) = try await followingPane(
                    ["new-window", "-t", "main:", "-n", "capped"], on: fixture)
                let smallDesktop = try await attachDesktopClient(
                    to: "main", windowColumns: 36, windowRows: 6, on: fixture)
                let label = Comment(rawValue: "\(scenario.mode) aggressive=\(scenario.aggressive)")
                do {
                    try await fixture.eventually { try await windowDimensions(cappedPane, on: fixture) == "36x6" }
                    try await append((1...10).map { "row \($0)\\n" }.joined(), to: cappedFile, on: fixture)
                    try await waitUntilShown("row 10", in: cappedPane, on: fixture)

                    let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
                    do {
                        var req = TerminalAttachRequest(
                            target: .terminal(cappedPane), surfaceHasHistory: false, cols: 80, rows: 24)
                        req.coreID = try await fixture.serverInstance().id
                        let session = try await transport.attachPane(cappedPane, request: req)
                        var output = session.output.makeAsyncIterator()
                        _ = try await read(until: "row 10", from: &output)

                        let initial = try await placement(of: cappedPane, on: fixture)
                        #expect(initial.windowWidth <= 36 && initial.windowHeight <= 6, label)
                        #expect(
                            initial
                                == PanePlacement(
                                    paneWidth: 36, paneHeight: 6, windowWidth: 36, windowHeight: 6, zoomed: false),
                            label)

                        session.resize(cols: 30, rows: 5)
                        try await fixture.eventually {
                            try await windowDimensions(cappedPane, on: fixture) == "30x5"
                        }
                        session.resize(cols: 100, rows: 30)
                        try await fixture.eventually {
                            try await windowDimensions(cappedPane, on: fixture) == "36x6"
                        }
                        try await append("live 11\\n", to: cappedFile, on: fixture)
                        _ = try await read(until: "live 11", from: &output)
                        let afterResize = try await placement(of: cappedPane, on: fixture)
                        #expect(afterResize.windowWidth <= 36 && afterResize.windowHeight <= 6, label)
                        #expect(
                            afterResize
                                == PanePlacement(
                                    paneWidth: 36, paneHeight: 6, windowWidth: 36, windowHeight: 6, zoomed: false),
                            label)

                        await session.end()
                        try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
                        try await transport.close()
                    } catch {
                        try? await transport.close()
                        throw error
                    }

                    if scenario.mode == "largest" {
                        try await openCappedPaneInTheTerminalView(cappedPane, file: cappedFile, on: fixture)
                    }
                    await smallDesktop.stop()
                } catch {
                    await smallDesktop.stop()
                    throw error
                }
            }

            // A smaller desktop client that attaches after Heeler already sized
            // the window drops the window to that desktop's size.
            for mode in ["latest", "largest"] {
                try await fixture.reset()
                try await fixture.startServer()
                try await fixture.tmux(nil, "set-option", "-gw", "window-size", mode)
                let (latePane, lateFile) = try await followingPane(
                    ["new-window", "-t", "main:", "-n", "late"], on: fixture)
                try await append("late ready\\n", to: lateFile, on: fixture)
                try await waitUntilShown("late ready", in: latePane, on: fixture)

                let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
                var lateDesktop: DesktopClient?
                do {
                    var req = TerminalAttachRequest(
                        target: .terminal(latePane), surfaceHasHistory: false, cols: 80, rows: 24)
                    req.coreID = try await fixture.serverInstance().id
                    let session = try await transport.attachPane(latePane, request: req)
                    var output = session.output.makeAsyncIterator()
                    _ = try await read(until: "late ready", from: &output)
                    #expect(try await windowDimensions(latePane, on: fixture) == "80x24", Comment(rawValue: mode))

                    let attached = try await attachDesktopClient(
                        to: "main", windowColumns: 40, windowRows: 8, on: fixture)
                    lateDesktop = attached
                    try await fixture.eventually {
                        try await placement(of: latePane, on: fixture)
                            == PanePlacement(
                                paneWidth: 40, paneHeight: 8, windowWidth: 40, windowHeight: 8, zoomed: false)
                    }

                    await attached.stop()
                    lateDesktop = nil
                    try await fixture.eventually {
                        try await windowDimensions(latePane, on: fixture) == "80x24"
                    }

                    await session.end()
                    try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
                    try await transport.close()
                } catch {
                    await lateDesktop?.stop()
                    try? await transport.close()
                    throw error
                }
            }
        }
    }

    @MainActor
    private func openCappedPaneInTheTerminalView(
        _ pane: String, file: String, on fixture: TmuxSSHFixture
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
            try await waitForViewport(of: terminal) { $0.contains("row 10") }

            let capped = try await placement(of: pane, on: fixture)
            #expect(capped == PanePlacement(paneWidth: 36, paneHeight: 6, windowWidth: 36, windowHeight: 6, zoomed: false))

            // Stream more lines so the terminal scrolls live output: the scroll
            // region confines it to rows 1..6 and leaves rows 7..24 blank.
            try await append("live 11\\nlive 12\\nlive 13\\n", to: file, on: fixture)
            try await waitForViewport(of: terminal) { $0.contains("live 13") }
            #expect(try await windowDimensions(pane, on: fixture) == "36x6")

            let viewport = try #require(terminal.terminalSession.readViewportText())
            let lines = viewport.components(separatedBy: "\n")
            #expect(lines.count >= 24)
            for row in lines.prefix(6) {
                #expect(row.trimmingCharacters(in: .whitespaces).count <= 36)
            }
            for row in lines.dropFirst(6) {
                #expect(row.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            await attach.stop()
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            store.setHosts([])
        } catch {
            await attach.stop()
            store.setHosts([])
            throw error
        }
    }

    @Test("sizing a Pane's window leaves other windows untouched across window-size modes, aggressive-resize, and with no desktop client")
    func sizingAPaneLeavesOtherWindowsUntouched() async throws {
        let cases: [(mode: String, aggressive: Bool, desktop: Bool)] = [
            ("latest", false, true),
            ("latest", true, true),
            ("smallest", false, true),
            ("largest", false, true),
            ("latest", false, false),
            ("smallest", false, false),
        ]
        try await TmuxSSHFixture.with { fixture in
            for scenario in cases {
                try await fixture.reset()
                try await fixture.startServer()
                try await fixture.tmux(nil, "set-option", "-gw", "window-size", scenario.mode)
                try await fixture.tmux(nil, "set-option", "-gw", "aggressive-resize", scenario.aggressive ? "on" : "off")

                try await fixture.tmux(nil, "new-session", "-d", "-s", "work", "-x", "150", "-y", "44", "/bin/cat")
                let firstOther = "work:0"
                let (pane, file) = try await followingPane(["new-window", "-d", "-t", "work:", "-n", "watched"], on: fixture)
                _ = try await followingPane(["split-window", "-d", "-h", "-t", pane], on: fixture)
                try await fixture.tmux(nil, "new-window", "-d", "-t", "work:", "-n", "third", "/bin/cat")
                let thirdOther = "work:2"
                try await fixture.tmux(nil, "new-session", "-d", "-s", "side", "-x", "132", "-y", "38", "/bin/cat")
                let sideOther = "side:0"
                try await append("ready\\n", to: file, on: fixture)
                try await waitUntilShown("ready", in: pane, on: fixture)

                let desktop: DesktopClient? =
                    scenario.desktop
                    ? try await attachDesktopClient(to: "work", windowColumns: 150, windowRows: 44, on: fixture)
                    : nil
                do {
                    if scenario.desktop {
                        try await fixture.eventually { try await windowDimensions(firstOther, on: fixture) == "150x44" }
                    }
                    let beforeFirst = try await windowDimensions(firstOther, on: fixture)
                    let beforeThird = try await windowDimensions(thirdOther, on: fixture)
                    let beforeSide = try await windowDimensions(sideOther, on: fixture)
                    #expect(beforeFirst == "150x44")
                    #expect(beforeThird == "150x44")
                    #expect(beforeSide == "132x38")

                    let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
                    do {
                        var req = TerminalAttachRequest(
                            target: .terminal(pane), surfaceHasHistory: false, cols: 42, rows: 14)
                        req.coreID = try await fixture.serverInstance().id
                        let session = try await transport.attachPane(pane, request: req)
                        var output = session.output.makeAsyncIterator()
                        _ = try await read(until: "ready", from: &output)

                        let watched = try await placement(of: pane, on: fixture)
                        #expect(watched.paneWidth <= 42 && watched.paneWidth >= 41)
                        #expect(watched.paneHeight == 14)
                        #expect(!watched.zoomed)

                        let label = "\(scenario.mode) aggressive=\(scenario.aggressive) desktop=\(scenario.desktop)"
                        #expect(try await windowDimensions(firstOther, on: fixture) == beforeFirst, Comment(rawValue: label))
                        #expect(try await windowDimensions(thirdOther, on: fixture) == beforeThird, Comment(rawValue: label))
                        #expect(try await windowDimensions(sideOther, on: fixture) == beforeSide, Comment(rawValue: label))

                        await session.end()
                        try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
                        #expect(try await windowDimensions(firstOther, on: fixture) == beforeFirst, Comment(rawValue: label))
                        #expect(try await windowDimensions(thirdOther, on: fixture) == beforeThird, Comment(rawValue: label))
                        #expect(try await windowDimensions(sideOther, on: fixture) == beforeSide, Comment(rawValue: label))
                        try await transport.close()
                    } catch {
                        try? await transport.close()
                        throw error
                    }
                    await desktop?.stop()
                } catch {
                    await desktop?.stop()
                    throw error
                }
            }
        }
    }

    @Test("hiding a retained Attach turns on ignore-size and hands the window back; showing it again takes the size back")
    func hidingARetainedAttachHandsTheWindowBackAndShowingTakesItAgain() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await followingPane(["new-window", "-t", "main:", "-n", "retained"], on: fixture)
            try await append("retained ready\\n", to: file, on: fixture)
            try await waitUntilShown("retained ready", in: pane, on: fixture)
            let desktop = try await attachDesktopClient(to: "main", windowColumns: 150, windowRows: 44, on: fixture)
            do {
                try await fixture.eventually { try await windowDimensions(pane, on: fixture) == "150x44" }
                try await exerciseRetentionHandBack(pane, desktop: desktop, on: fixture)
                await desktop.stop()
            } catch {
                await desktop.stop()
                throw error
            }
        }
    }

    @MainActor
    private func exerciseRetentionHandBack(
        _ pane: String, desktop: DesktopClient, on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()
        let attach = AttachTerminalStore(
            target: .terminal(pane), runTerminal: store.terminalRunner(for: host.id, keepingTo: store.corePin(on: host.id)))
        do {
            try await fixture.eventually { await store.terminals.contains { $0.paneID == pane } }
            attach.viewDidResize(cols: 70, rows: 20)
            try await fixture.eventually { await attach.status == .live }
            try await fixture.eventually { try await windowDimensions(pane, on: fixture) == "70x20" }

            let activeClient = try #require(
                try await clients(on: fixture).first { $0.hasPrefix(TmuxAttachScript.sessionPrefix) })
            #expect(activeClient.contains("pause-after=\(TmuxSSHTransport.pauseAfter)"))
            #expect(!activeClient.contains("ignore-size"))

            // Stop showing the Pane while keeping the retained Attach: the
            // client turns on ignore-size and hands the window back at once.
            attach.setViewed(false)
            try await fixture.eventually { try await windowDimensions(pane, on: fixture) == "150x44" }
            #expect(try await attachSessions(on: fixture).count == 1)
            let hiddenClient = try #require(
                try await clients(on: fixture).first { $0.hasPrefix(TmuxAttachScript.sessionPrefix) })
            #expect(hiddenClient.contains("ignore-size"))
            #expect(hiddenClient.contains("pause-after=\(TmuxSSHTransport.pauseAfter)"))

            // Showing it again clears ignore-size and takes the size back.
            attach.setViewed(true)
            try await fixture.eventually { try await windowDimensions(pane, on: fixture) == "70x20" }
            let reshownClient = try #require(
                try await clients(on: fixture).first { $0.hasPrefix(TmuxAttachScript.sessionPrefix) })
            #expect(!reshownClient.contains("ignore-size"))

            // With no desktop client attached, hiding keeps the window's size.
            await desktop.stop()
            attach.setViewed(false)
            try await fixture.eventually {
                let flags = try await clients(on: fixture).first { $0.hasPrefix(TmuxAttachScript.sessionPrefix) } ?? ""
                return flags.contains("ignore-size")
            }
            #expect(try await windowDimensions(pane, on: fixture) == "70x20")

            await attach.stop()
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            store.setHosts([])
        } catch {
            await attach.stop()
            store.setHosts([])
            throw error
        }
    }

    // MARK: Composer Send

    private struct CaptureSummary: Equatable, Sendable {
        let length: Int
        let headHex: String
        let tailHex: String
        let sha256: String
    }

    private static func captureSummary(
        of path: String, from offset: Int, on fixture: TmuxSSHFixture
    ) async throws -> CaptureSummary? {
        let script = [
            "/usr/bin/python3", "-c",
            "import hashlib, sys; p, off = sys.argv[1], int(sys.argv[2]); "
                + "f = open(p, 'rb'); f.seek(off); b = f.read(); "
                + "print(len(b), b[:16].hex(), b[-16:].hex(), hashlib.sha256(b).hexdigest())",
            path, "\(offset)",
        ].map(GitProbe.singleQuoted).joined(separator: " ")
        let output = try await fixture.require(script).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4, let length = Int(parts[0]) else { return nil }
        return CaptureSummary(
            length: length, headHex: String(parts[1]), tailHex: String(parts[2]), sha256: String(parts[3]))
    }

    @Test("Composer Send pastes CRLF, CJK and tmux syntax between bracketed paste markers, and pastes a 1 MB message")
    func composerSendPastesExactBytesAndOneMegabyte() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let home = fixture.configuration.homePath
            let program = "\(home)/bin/claude.py"
            try await fixture.writeProgram(
                at: program,
                """
                #!/usr/bin/python3
                import os, sys, tty
                capture_path, ready_path = sys.argv[1:3]
                tty.setraw(0)
                os.write(1, b"\\x1b[?2004h")
                with open(capture_path, "wb"):
                    pass
                with open(ready_path, "w") as handle:
                    handle.write("ready\\n")
                with open(capture_path, "ab", buffering=0) as sink:
                    while True:
                        chunk = os.read(0, 65536)
                        if not chunk:
                            break
                        sink.write(chunk)
                """)
            let token = UUID().uuidString.prefix(8)
            let captureFile = "\(home)/send-\(token).bin"
            let readyFile = "\(home)/send-\(token).ready"
            let pane = try await fixture.require(
                fixture.tmuxLine([
                    "new-window", "-d", "-t", "main:", "-P", "-F", "#{pane_id}",
                    "/usr/bin/python3", program, captureFile, readyFile,
                ]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(TmuxAttachScript.isPaneID(pane))
            try await fixture.eventually { try await fixture.exists(readyFile) }
            try await exerciseComposerSend(pane, captureFile: captureFile, on: fixture)
        }
    }

    /// Text typed into the Attach, then Stop, reach the program in that order.
    /// The stand-in is the same capturing Claude the Send test uses, so Stop
    /// presses one Escape and the program reads the bytes.
    @Test("typed text then Stop reach the Pane in that order")
    func typedTextThenStopReachThePaneInOrder() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let home = fixture.configuration.homePath
            let program = "\(home)/bin/claude.py"
            try await fixture.writeProgram(
                at: program,
                """
                #!/usr/bin/python3
                import os, sys, tty
                capture_path, ready_path = sys.argv[1:3]
                tty.setraw(0)
                with open(capture_path, "wb"):
                    pass
                with open(ready_path, "w") as handle:
                    handle.write("ready\\n")
                with open(capture_path, "ab", buffering=0) as sink:
                    while True:
                        chunk = os.read(0, 65536)
                        if not chunk:
                            break
                        sink.write(chunk)
                """)
            let token = UUID().uuidString.prefix(8)
            let captureFile = "\(home)/stop-\(token).bin"
            let readyFile = "\(home)/stop-\(token).ready"
            let pane = try await fixture.require(
                fixture.tmuxLine([
                    "new-window", "-d", "-t", "main:", "-P", "-F", "#{pane_id}",
                    "/usr/bin/python3", program, captureFile, readyFile,
                ]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(TmuxAttachScript.isPaneID(pane))
            try await fixture.eventually { try await fixture.exists(readyFile) }
            try await exerciseStopOrder(pane, captureFile: captureFile, on: fixture)
        }
    }

    @MainActor
    private func exerciseStopOrder(
        _ pane: String, captureFile: String, on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()

        var attachToLeave: AgentAttachStore?
        do {
            try await fixture.eventually { await store.agents.contains { $0.agent.paneID == pane } }
            let row = try #require(store.agents.first { $0.agent.paneID == pane })
            #expect(row.agent.kind == "claude")
            let session = store.composerSession(for: row)
            let attach = AgentAttachStore(
                target: pane, paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: store.terminalRunner(for: host.id, keepingTo: session.corePin), closePane: {})
            attachToLeave = attach
            attach.viewDidResize(cols: 80, rows: 24)
            try await fixture.eventually { await attach.input.readySession != nil }

            #expect(attach.input.send(Data("ab".utf8)))
            let interrupt = try #require(
                store.terminalInterrupt(for: row, keepingTo: session.corePin, attach: attach) { .sent })
            #expect(await interrupt.perform() == .sent)
            #expect(attach.input.send(Data(Self.endOfTyping.utf8)))

            let expected = Self.hex(Data("ab".utf8) + Data([0x1B]) + Data(Self.endOfTyping.utf8))
            #expect(try await typed(into: captureFile, on: fixture) == expected)

            await attach.leave().value
            store.setHosts([])
        } catch {
            if let attachToLeave { await attachToLeave.leave().value }
            store.setHosts([])
            throw error
        }
    }

    @MainActor
    private func exerciseComposerSend(
        _ pane: String, captureFile: String, on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()

        var attachToLeave: AgentAttachStore?
        do {
            try await fixture.eventually { await store.agents.contains { $0.agent.paneID == pane } }
            let row = try #require(store.agents.first { $0.agent.paneID == pane })
            #expect(row.agent.kind == "claude")
            #expect(store.capabilities(for: host.id).composerSend)

            let session = store.composerSession(for: row)
            session.composer.open()
            let attach = AgentAttachStore(
                target: pane, paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: store.terminalRunner(for: host.id, keepingTo: session.corePin), closePane: {})
            attachToLeave = attach
            attach.viewDidResize(cols: 80, rows: 24)
            try await fixture.eventually { await attach.input.readySession != nil }

            var policy = ComposerDeliveryPolicy.terminal
            policy.coreAttach = attach

            let first = "SEND1 alpha\r\nbeta\n中文テスト $HOME ~ #{pane_id} ; 'q' \"dq\" \\ \\;"
            session.composer.replaceDraft(with: first)
            #expect(await session.composer.send(policy: policy) == .submittedViaAttach)
            #expect(session.composer.draft.isEmpty)

            let expectedFirst = Data(("\u{1B}[200~" + first + "\u{1B}[201~\r").utf8)
            try await fixture.eventually {
                try await Self.captureSummary(of: captureFile, from: 0, on: fixture)?.length == expectedFirst.count
            }
            let firstHex = try await fixture.require(
                "od -An -tx1 -v \(GitProbe.singleQuoted(captureFile)) | tr -d ' \\n'")
            #expect(firstHex == Self.hex(expectedFirst))
            #expect(try await fixture.tmux(nil, "list-buffers", "-F", "#{buffer_name}").isEmpty)

            var megabyte = ""
            megabyte.reserveCapacity(1_048_576)
            for line in 0..<16_384 {
                megabyte += String(format: "%08x:", line) + String(repeating: "m", count: 54) + "\n"
            }
            #expect(megabyte.utf8.count == 1_048_576)
            let expectedSecond = Data(("\u{1B}[200~" + megabyte + "\u{1B}[201~\r").utf8)
            let expectedSecondDigest = SHA256.hash(data: expectedSecond)
                .map { String(format: "%02x", $0) }.joined()

            session.composer.replaceDraft(with: megabyte)
            #expect(await session.composer.send(policy: policy) == .submittedViaAttach)
            #expect(session.composer.draft.isEmpty)

            try await fixture.eventually {
                try await Self.captureSummary(of: captureFile, from: expectedFirst.count, on: fixture)?.length
                    == expectedSecond.count
            }
            let summary = try #require(
                try await Self.captureSummary(of: captureFile, from: expectedFirst.count, on: fixture))
            #expect(summary.length == expectedSecond.count)
            #expect(summary.headHex == Self.hex(Data(expectedSecond.prefix(16))))
            #expect(summary.tailHex == Self.hex(Data(expectedSecond.suffix(16))))
            #expect(summary.sha256 == expectedSecondDigest)
            #expect(try await fixture.tmux(nil, "list-buffers", "-F", "#{buffer_name}").isEmpty)

            await attach.leave().value
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            store.setHosts([])
        } catch {
            if let attachToLeave { await attachToLeave.leave().value }
            store.setHosts([])
            throw error
        }
    }

    /// A Pane streaming output, so a close that stops reading leaves tmux with
    /// output it can never write.
    private func streamingPane(on fixture: TmuxSSHFixture) async throws -> String {
        let pane = try await fixture.require(
            fixture.tmuxLine([
                "new-window", "-d", "-t", "main:", "-P", "-F", "#{pane_id}",
                "/bin/sh", "-c", "while :; do cat /usr/share/dict/words; done",
            ]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(TmuxAttachScript.isPaneID(pane))
        return pane
    }

    /// The server still answers, and no Attach session or client is left.
    private func serverStillAnswersWithoutAnAttach(on fixture: TmuxSSHFixture) async throws {
        try await fixture.eventually {
            let names = try await fixture.sessionNames()
            let attached = try await clients(on: fixture)
            return names == ["main"] && attached.allSatisfy { !$0.hasPrefix(TmuxAttachScript.sessionPrefix) }
        }
        #expect(try await fixture.sessionNames() == ["main"])
    }

    @Test("closing an Attach while its Pane streams leaves the server answering")
    func closingAnAttachWhileItsPaneStreamsLeavesTheServerAnswering() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let pane = try await streamingPane(on: fixture)
            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                var output = session.output.makeAsyncIterator()
                _ = try await read(from: &output) { $0.utf8.count >= 8_192 }
                await session.end()
                try await serverStillAnswersWithoutAnAttach(on: fixture)
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    /// Dropping the channel, without the app-side detach, is what a killed app
    /// or a lost connection does. The remote drain has to let the client leave.
    @Test("a dropped Attach channel leaves the server answering")
    func aDroppedAttachChannelLeavesTheServerAnswering() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let pane = try await streamingPane(on: fixture)
            let transport = try await fixture.connectTmux(storedPaths: try fixture.paths())
            do {
                let session = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                var output = session.output.makeAsyncIterator()
                _ = try await read(from: &output) { $0.utf8.count >= 8_192 }
                try await transport.close()
                try await serverStillAnswersWithoutAnAttach(on: fixture)
                // The session's output ends because its connection did. Nothing
                // here calls `end()`, which would detach first.
                _ = session
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    /// With a desktop client on one session, a newer unattached user session
    /// holding a streaming Pane, and concurrent one-shot format reads, both
    /// dropping an Attach connection outright and closing Attaches cleanly keep
    /// the same tmux server and user sessions alive with no Attach left behind.
    @Test(
        "closing or dropping streaming Attaches under concurrent reads keeps the server and user sessions intact",
        .timeLimit(.minutes(2)))
    func closingOrDroppingStreamingAttachesUnderConcurrentReadsKeepsTheServerAlive() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let desktop = try await attachDesktopClient(
                to: "main", windowColumns: 120, windowRows: 40, on: fixture)
            let home = fixture.configuration.homePath
            let readerProgram = "\(home)/bin/concurrent-readers"
            let readerPIDFile = "\(home)/readers-\(UUID().uuidString.prefix(8)).pid"
            try await fixture.writeProgram(
                at: readerProgram,
                """
                #!/usr/bin/python3
                import os, signal, subprocess, sys, threading
                tmux_exec, sock, pane, pid_file = sys.argv[1:5]
                if os.fork() > 0:
                    os._exit(0)
                os.setsid()
                devnull = os.open("/dev/null", os.O_RDWR)
                for fd in (0, 1, 2):
                    os.dup2(devnull, fd)
                if devnull > 2:
                    os.close(devnull)
                stop = threading.Event()
                def shutdown(_sig, _frame):
                    stop.set()
                    os._exit(0)
                for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                    signal.signal(sig, shutdown)
                env = {
                    "HOME": os.environ["HOME"],
                    "TMUX_TMPDIR": os.environ["TMUX_TMPDIR"],
                    "PATH": "/usr/bin:/bin",
                }
                cmds = [
                    [tmux_exec, "-u", "-N", "-S", sock, "display-message", "-p", "-t", pane, "#{pid} #{pane_id} #{@heeler-status}"],
                    [tmux_exec, "-u", "-N", "-S", sock, "list-panes", "-a", "-F", "#{session_id} #{window_id} #{pane_id} #{@heeler-attach}"],
                    [tmux_exec, "-u", "-N", "-S", sock, "list-clients", "-F", "#{client_control_mode} #{window_id} #{client_width} #{client_height} #{status} #{client_flags}"],
                ]
                def loop(cmd):
                    while not stop.is_set():
                        subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for cmd in cmds:
                    threading.Thread(target=loop, args=(cmd,), daemon=True).start()
                with open(pid_file, "w") as handle:
                    handle.write(f"{os.getpid()}\\n")
                stop.wait()
                """)

            func stopReaders() async {
                guard let text = try? await fixture.require("cat \(GitProbe.singleQuoted(readerPIDFile)) 2>/dev/null || true"),
                    let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
                else { return }
                _ = try? await fixture.run("kill \(pid) 2>/dev/null; true")
                try? await fixture.eventually {
                    let ps = (try? await fixture.require("ps -p \(pid) -o pid= || true")) ?? ""
                    return ps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }

            do {
                let keepPane = try await fixture.require(
                    fixture.tmuxLine([
                        "new-session", "-d", "-s", "work", "-n", "keep", "-P", "-F", "#{pane_id}", "/bin/cat",
                    ]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let streaming = try await fixture.require(
                    fixture.tmuxLine([
                        "new-window", "-d", "-t", "work:", "-P", "-F", "#{pane_id}",
                        "/bin/sh", "-c", "trap '' INT; while :; do cat /usr/share/dict/words; done",
                    ]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let initialInstance = try await fixture.serverInstance()

                let startReaders = [
                    "/usr/bin/python3", readerProgram, fixture.configuration.tmuxExecutable,
                    fixture.socketPath(), keepPane, readerPIDFile,
                ].map(GitProbe.singleQuoted).joined(separator: " ")
                try await fixture.require(startReaders)
                try await fixture.eventually { try await fixture.exists(readerPIDFile) }

                let storedPaths = try fixture.paths()
                for round in 0..<8 {
                    let transport = try await fixture.connectTmux(storedPaths: storedPaths)
                    do {
                        var retainedRequest = TerminalAttachRequest(
                            target: .terminal(keepPane), isViewed: false, surfaceHasHistory: false, cols: 80, rows: 24)
                        retainedRequest.coreID = initialInstance.id
                        let retained = try await transport.attachPane(keepPane, request: retainedRequest)
                        let viewed = try await transport.attachPane(
                            streaming, request: try await request(for: streaming, on: fixture))
                        var output = viewed.output.makeAsyncIterator()
                        _ = try await read(from: &output) { $0.utf8.count >= 8_192 }

                        if round.isMultiple(of: 2) {
                            try await transport.close()
                            _ = (retained, viewed)
                        } else {
                            let stopping = try await fixture.require(
                                fixture.tmuxLine([
                                    "new-window", "-d", "-t", "work:", "-P", "-F", "#{pane_id}",
                                    "/bin/sh", "-c", "trap 'exit 0' INT; while :; do cat /usr/share/dict/words; done",
                                ]))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            var retainedStoppingRequest = TerminalAttachRequest(
                                target: .terminal(stopping), isViewed: false, surfaceHasHistory: false, cols: 80, rows: 24)
                            retainedStoppingRequest.coreID = initialInstance.id
                            let retainedStopping = try await transport.attachPane(stopping, request: retainedStoppingRequest)
                            var stopActionRequest = TerminalAttachRequest(
                                target: .terminal(stopping), isViewed: false, surfaceHasHistory: false, cols: 0, rows: 0)
                            stopActionRequest.coreID = initialInstance.id
                            let stopAttach = try await transport.attachPane(stopping, request: stopActionRequest)
                            _ = await stopAttach.tmuxSend?.sendKey("C-c", { try await Task.sleep(for: $0) })
                            async let statusWrite: Void = {
                                _ = try? await fixture.tmux(
                                    nil, "set-option", "-p", "-t", stopping, "@heeler-status", "state=idle:app=grok")
                            }()
                            await stopAttach.end()
                            await retainedStopping.end()
                            await viewed.end()
                            await retained.end()
                            _ = await statusWrite
                            try await transport.close()
                        }
                    } catch {
                        try? await transport.close()
                        throw error
                    }
                    #expect(try await fixture.answers())
                    #expect(try await fixture.serverInstance() == initialInstance)
                }

                await stopReaders()
                await desktop.stop()
                try await fixture.eventually {
                    let names = try await fixture.sessionNames()
                    let attached = try await clients(on: fixture)
                    return names == ["main", "work"]
                        && attached.allSatisfy { !$0.hasPrefix(TmuxAttachScript.sessionPrefix) }
                }
                #expect(try await fixture.serverInstance() == initialInstance)
                #expect(try await fixture.sessionNames() == ["main", "work"])
                #expect(try await clients(on: fixture).isEmpty)
            } catch {
                await stopReaders()
                await desktop.stop()
                throw error
            }
        }
    }

    /// Text written after the client has exited must not run. The group,
    /// including `exit`, is parsed before the pipeline, so the shell is gone
    /// and cannot treat that text as commands.
    @Test("text written after the client exits is not run by the shell")
    func textAfterTheClientExitsIsNotRunByTheShell() async throws {
        try await TmuxSSHFixture.with { fixture in
            let home = fixture.configuration.homePath
            let token = UUID().uuidString.prefix(8)
            let program = "\(home)/stand-in-\(token)"
            let stamp = "\(home)/stamp-\(token)"
            let marker = "\(home)/ran-\(token)"
            let scriptPath = "\(home)/attach-\(token).sh"
            let proofPath = "\(home)/proof-\(token).sh"
            try await fixture.writeProgram(
                at: program,
                """
                #!/bin/sh
                touch \(GitProbe.singleQuoted(stamp))
                exit 0
                """)
            let paths = try #require(TmuxPaths(executable: program, socket: "\(home)/sock-\(token)"))
            let script = try #require(
                TmuxAttachScript.script(paths: paths, session: "heeler-attach-0", pane: "%1", pauseAfter: 10))
            try await fixture.writeFile(at: scriptPath, script)
            try await fixture.writeFile(
                at: proofPath,
                """
                #!/bin/sh
                set -eu
                trap '' PIPE
                marker=\(GitProbe.singleQuoted(marker))
                stamp=\(GitProbe.singleQuoted(stamp))
                fifo=\(GitProbe.singleQuoted("\(home)/fifo-\(token)"))
                pid=0
                trap 'if [ "$pid" -ne 0 ]; then kill "$pid" 2>/dev/null || true; fi; rm -f "$fifo"' EXIT
                rm -f "$marker" "$stamp"
                mkfifo "$fifo"
                /bin/sh -s < "$fifo" &
                pid=$!
                exec 3>"$fifo"
                cat \(GitProbe.singleQuoted(scriptPath)) >&3
                i=0
                while [ ! -f "$stamp" ]; do
                  i=$((i + 1))
                  [ "$i" -lt 200 ] || exit 1
                  sleep 0.05
                done
                printf '%s\\n' "echo RAN > $marker" >&3 || true
                exec 3>&-
                sleep 0.3
                if kill -0 "$pid" 2>/dev/null; then
                  exit 1
                fi
                wait "$pid" || true
                pid=0
                [ ! -e "$marker" ]
                """)
            try await fixture.require("/bin/sh " + GitProbe.singleQuoted(proofPath))
            #expect(try await fixture.exists(stamp))
            #expect(try await !fixture.exists(marker))
        }
    }

    /// A partial control-mode line without a trailing newline must never be
    /// forwarded or executed when the SSH channel drops, whether the line ends
    /// unquoted, inside single quotes, or inside double quotes, while complete
    /// lines before it run and `kill-session` still ends the Attach session.
    @Test("a partial control-mode line in any quote state is never executed when the channel drops")
    func aPartialControlLineInAnyQuoteStateIsNeverExecuted() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, _) = try await followingPane(["new-window", "-d", "-t", "main:"], on: fixture)
            let storedPaths = try fixture.paths()

            let partials: [(label: String, line: String)] = [
                ("single", "set-option -p -t \(pane) @heeler-partial 'single"),
                ("double", "set-option -p -t \(pane) @heeler-partial \"double"),
                ("unquoted", "set-option -p -t \(pane) @heeler-partial unquoted"),
            ]
            for (label, partialLine) in partials {
                try await fixture.tmux(nil, "set-option", "-p", "-u", "-t", pane, "@heeler-complete")
                try await fixture.tmux(nil, "set-option", "-p", "-u", "-t", pane, "@heeler-partial")
                let token = "\(label)-\(UUID().uuidString.prefix(8).lowercased())"
                let attachName = "\(TmuxAttachScript.sessionPrefix)\(token)"
                let script = try #require(
                    TmuxAttachScript.script(
                        paths: storedPaths, session: attachName, pane: pane, pauseAfter: TmuxSSHTransport.pauseAfter))
                let ssh = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: storedPaths))
                do {
                    let channel = try await ssh.openTmuxControlClient(Data(script.utf8))
                    let startup = try await channel.read(maximumBytes: 64 * 1024, timeout: .seconds(5))
                    #expect(startup?.isEmpty == false, Comment(rawValue: label))
                    try await fixture.eventually {
                        try await clients(on: fixture).contains { $0.hasPrefix("\(attachName) 1 ") }
                    }
                    let completeLine = "set-option -p -t \(pane) @heeler-complete \(label)\n"
                    try await channel.write(Data(completeLine.utf8), timeout: .seconds(5))
                    try await fixture.eventually {
                        try await fixture.tmux(nil, "display-message", "-p", "-t", pane, "#{@heeler-complete}") == "\(label)\n"
                    }
                    #expect(!partialLine.contains("\n"))
                    try await channel.write(Data(partialLine.utf8), timeout: .seconds(5))
                    try await Task.sleep(for: .milliseconds(150))
                    try await ssh.close()
                } catch {
                    try? await ssh.close()
                    throw error
                }
                try await serverStillAnswersWithoutAnAttach(on: fixture)
                let completed = try await fixture.tmux(nil, "display-message", "-p", "-t", pane, "#{@heeler-complete}")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let leaked = try await fixture.tmux(nil, "display-message", "-p", "-t", pane, "#{@heeler-partial}")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(completed == label, Comment(rawValue: label))
                #expect(leaked.isEmpty, Comment(rawValue: label))
            }
        }
    }

    /// If a session with the generated `heeler-attach-*` name already exists,
    /// `new-session` fails and the Attach script neither starts the feeder nor
    /// kills or alters that pre-existing session.
    @Test("a pre-existing session with the generated Attach name survives untouched")
    func aPreExistingSessionWithTheAttachNameSurvives() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, _) = try await followingPane(["new-window", "-d", "-t", "main:"], on: fixture)
            let taken = "\(TmuxAttachScript.sessionPrefix)0a1b2c3d"
            let takenPane = try await fixture.require(
                fixture.tmuxLine(["new-session", "-d", "-s", taken, "-P", "-F", "#{pane_id}", "/bin/cat"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let takenID = try await fixture.tmux(nil, "display-message", "-p", "-t", "=\(taken):", "#{session_id}")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let storedPaths = try fixture.paths()
            let script = try #require(
                TmuxAttachScript.script(
                    paths: storedPaths, session: taken, pane: pane, pauseAfter: TmuxSSHTransport.pauseAfter))

            // 1. Direct `/bin/sh -s` execution with trailing input after the script.
            let scriptPath = "\(fixture.configuration.homePath)/dup-attach.sh"
            let marker = "\(fixture.configuration.homePath)/dup-ran"
            try await fixture.writeFile(at: scriptPath, script + "touch \(GitProbe.singleQuoted(marker))\n")
            let run = try await fixture.run("/bin/sh -s < " + GitProbe.singleQuoted(scriptPath))
            #expect(run.exitStatus == 0)
            #expect(String(decoding: run.stdout, as: UTF8.self).isEmpty)
            #expect(try await !fixture.exists(marker))
            #expect(try await fixture.sessionNames() == [taken, "main"].sorted())
            #expect(
                try await fixture.tmux(nil, "display-message", "-p", "-t", "=\(taken):", "#{session_id} #{@heeler-attach}")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == takenID)
            #expect(try await fixture.tmux(nil, "list-panes", "-s", "-t", "=\(taken):", "-F", "#{pane_id}") == "\(takenPane)\n")

            // 2. Full `TmuxSSHTransport.attachPane` over SSH against the duplicate name.
            let ssh = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: storedPaths))
            let transport = TmuxSSHTransport(
                connection: ssh, socketName: fixture.socketName, storedPaths: storedPaths,
                nextAttachSession: { taken }, attachStartLimit: .seconds(5))
            do {
                await #expect(throws: (any Error).self) {
                    _ = try await transport.attachPane(pane, request: try await request(for: pane, on: fixture))
                }
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
            #expect(try await fixture.sessionNames() == [taken, "main"].sorted())
            #expect(
                try await fixture.tmux(nil, "display-message", "-p", "-t", "=\(taken):", "#{session_id} #{@heeler-attach}")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == takenID)
            #expect(try await fixture.tmux(nil, "list-panes", "-s", "-t", "=\(taken):", "-F", "#{pane_id}") == "\(takenPane)\n")
        }
    }

    /// When `new-session` succeeds and prints a `session_id` (`$<digits>`), any
    /// later failure in the Attach setup — whether a `set-option` in the initial
    /// command queue before `@heeler-attach` is set, or `link-window` in
    /// `tmux -C` when the target Pane is gone — ends that created `session_id`
    /// by id (never by session name) so no unmarked or marked session leaks.
    @Test("a failed Attach setup ends the session its new-session created by id and never by name")
    func aFailedAttachSetupEndsOnlyTheSessionItCreated() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, _) = try await followingPane(["new-window", "-d", "-t", "main:"], on: fixture)
            let storedPaths = try fixture.paths()
            let home = fixture.configuration.homePath
            let token = UUID().uuidString.prefix(8)
            let attachName = "\(TmuxAttachScript.sessionPrefix)setup-fail"
            let decoyPane = try await fixture.require(
                fixture.tmuxLine(["new-session", "-d", "-s", "decoy", "-P", "-F", "#{pane_id}", "/bin/cat"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let decoyID = try await fixture.tmux(nil, "display-message", "-p", "-t", "=decoy:", "#{session_id}")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Stand-in tmux wrapper: when `createWords` runs (`set-option` in argv),
            // create the real session, leave `@heeler-attach` unset, rename the created
            // session away from `attachName` (`leaked-unmarked-$$`), rename the user's
            // `decoy` session onto `attachName`, print the created `session_id`, and exit 1.
            let wrapper = "\(home)/bin/tmux-fail-setup-\(token)"
            let createdLog = "\(home)/created-ids-\(token).log"
            try await fixture.writeProgram(
                at: wrapper,
                """
                #!/bin/sh
                real_tmux=\(GitProbe.singleQuoted(storedPaths.executable))
                log_file=\(GitProbe.singleQuoted(createdLog))
                has_set=0
                sock=""
                name=""
                prev=""
                for w in "$@"; do
                    [ "$w" = "set-option" ] && has_set=1
                    case "$prev" in
                    -S) [ -z "$sock" ] && sock=$w ;;
                    -s) [ -z "$name" ] && name=$w ;;
                    esac
                    prev=$w
                done
                if [ "$has_set" -eq 1 ]; then
                    cid=$("$real_tmux" -u -N -S "$sock" new-session -d -E -s "$name" -P -F '#{session_id}' sleep 2147483647) || exit $?
                    "$real_tmux" -u -N -S "$sock" rename-session -t "$cid" "leaked-unmarked-$$"
                    "$real_tmux" -u -N -S "$sock" rename-session -t "=decoy" "$name"
                    printf '%s\\n' "$cid" >> "$log_file"
                    printf '%s\\n' "$cid"
                    exit 1
                fi
                exec "$real_tmux" "$@"
                """)
            let wrapperPaths = try #require(TmuxPaths(executable: wrapper, socket: storedPaths.socket))

            // 1. Direct `/bin/sh -s` execution where `createWords` fails after `new-session` printed `$id`.
            let script = try #require(
                TmuxAttachScript.script(
                    paths: wrapperPaths, session: attachName, pane: pane, pauseAfter: TmuxSSHTransport.pauseAfter))
            let scriptPath = "\(home)/fail-setup-\(token).sh"
            let marker = "\(home)/fail-setup-ran-\(token)"
            try await fixture.writeFile(at: scriptPath, script + "touch \(GitProbe.singleQuoted(marker))\n")
            let run = try await fixture.run("/bin/sh -s < " + GitProbe.singleQuoted(scriptPath))
            #expect(run.exitStatus == 0)
            #expect(String(decoding: run.stdout, as: UTF8.self).isEmpty)
            #expect(try await !fixture.exists(marker))
            let loggedFirst = try await fixture.require("cat " + GitProbe.singleQuoted(createdLog))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(loggedFirst.hasPrefix("$"))
            // `leaked-unmarked` (`$cid`) was killed by id, while `decoy` (now named `attachName`) survived!
            #expect(try await fixture.sessionNames() == [attachName, "main"].sorted())
            #expect(
                try await fixture.tmux(nil, "display-message", "-p", "-t", "=\(attachName):", "#{session_id}")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == decoyID)
            #expect(
                try await fixture.tmux(nil, "list-panes", "-s", "-t", "=\(attachName):", "-F", "#{pane_id}")
                    == "\(decoyPane)\n")

            // 2. Full `TmuxSSHTransport.attachPane` over SSH against the same partial `createWords` failure.
            try await fixture.tmux(nil, "rename-session", "-t", "=\(attachName)", "decoy")
            let failSSH = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: wrapperPaths))
            let failTransport = TmuxSSHTransport(
                connection: failSSH, socketName: fixture.socketName, storedPaths: wrapperPaths,
                nextAttachSession: { attachName }, attachStartLimit: .seconds(5))
            do {
                await #expect(throws: (any Error).self) {
                    _ = try await failTransport.attachPane(pane, request: try await request(for: pane, on: fixture))
                }
                try await failTransport.close()
            } catch {
                try? await failTransport.close()
                throw error
            }
            let loggedBoth = try await fixture.require("cat " + GitProbe.singleQuoted(createdLog))
                .split(whereSeparator: \.isNewline)
            #expect(loggedBoth.count == 2)
            #expect(try await fixture.sessionNames() == [attachName, "main"].sorted())
            #expect(
                try await fixture.tmux(nil, "display-message", "-p", "-t", "=\(attachName):", "#{session_id}")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == decoyID)

            // 3. `link-window` failure inside `tmux -C` (`%999` gone), both via `/bin/sh -s </dev/null`
            // and via `TmuxSSHTransport.attachPane`, ends the created session and leaves nothing behind.
            let missingPaneScript = try #require(
                TmuxAttachScript.script(
                    paths: storedPaths, session: "\(TmuxAttachScript.sessionPrefix)missing-pane",
                    pane: "%999", pauseAfter: TmuxSSHTransport.pauseAfter))
            let missingScriptPath = "\(home)/missing-pane-\(token).sh"
            try await fixture.writeFile(at: missingScriptPath, missingPaneScript)
            _ = try await fixture.run("/bin/sh -s < " + GitProbe.singleQuoted(missingScriptPath))
            #expect(try await fixture.sessionNames() == [attachName, "main"].sorted())

            let realSSH = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: storedPaths))
            let realTransport = TmuxSSHTransport(
                connection: realSSH, socketName: fixture.socketName, storedPaths: storedPaths,
                attachStartLimit: .seconds(5))
            do {
                await #expect(throws: TransportError.tmuxPaneGone) {
                    _ = try await realTransport.attachPane("%999", request: try await request(for: "%999", on: fixture))
                }
                try await realTransport.close()
            } catch {
                try? await realTransport.close()
                throw error
            }
            #expect(try await fixture.sessionNames() == [attachName, "main"].sorted())
        }
    }

    /// A Host-side `SIGKILL` of an Attach's wrapper shell, feeder and `tmux -C`
    /// together leaves an unattached `@heeler-attach` session while keeping the
    /// server alive; Heeler's next Host connection ends that leftover while
    /// preserving both attached `@heeler-attach` sessions and unattached user
    /// sessions that merely share the `heeler-attach-` name prefix.
    @Test("connecting cleans up unattached @heeler-attach leftovers without touching attached or unmarked sessions")
    func connectingCleansUpUnattachedMarkedAttachSessionsOnly() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let (pane, file) = try await followingPane(["new-window", "-d", "-t", "main:"], on: fixture)
            let userPrefixed = "\(TmuxAttachScript.sessionPrefix)user-owned"
            _ = try await fixture.require(
                fixture.tmuxLine(["new-session", "-d", "-s", userPrefixed, "-P", "-F", "#{pane_id}", "/bin/cat"]))
            let storedPaths = try fixture.paths()

            let deadSSH = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: storedPaths))
            let deadTransport = TmuxSSHTransport(
                connection: deadSSH, socketName: fixture.socketName, storedPaths: storedPaths)
            let liveSSH = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: storedPaths))
            let liveTransport = TmuxSSHTransport(
                connection: liveSSH, socketName: fixture.socketName, storedPaths: storedPaths)
            do {
                let doomedAttach = try await deadTransport.attachPane(
                    pane, request: try await request(for: pane, on: fixture))
                let clientAfterFirst = try await fixture.tmux(
                    nil, "list-clients", "-F", "#{session_id} #{session_name} #{client_pid}")
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                #expect(clientAfterFirst.count == 1)
                let doomedParts = try #require(clientAfterFirst.first).split(separator: " ").map(String.init)
                #expect(doomedParts.count == 3)
                let doomedSessionID = doomedParts[0]
                let doomedSessionName = doomedParts[1]
                let doomedClientPID = try #require(Int(doomedParts[2]))

                let liveAttach = try await liveTransport.attachPane(
                    pane, request: try await request(for: pane, on: fixture))
                var liveOutput = liveAttach.output.makeAsyncIterator()
                let clientsBoth = try await fixture.tmux(
                    nil, "list-clients", "-F", "#{session_id} #{session_name}")
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                let liveEntry = try #require(clientsBoth.first { !$0.hasPrefix("\(doomedSessionID) ") })
                let liveParts = liveEntry.split(separator: " ").map(String.init)
                let liveSessionName = liveParts[1]

                // SIGKILL the entire remote exec subtree of `doomedAttach` at once.
                _ = try await fixture.require(
                    """
                    /usr/bin/python3 -c '
                    import os, signal, subprocess, sys
                    target = int(sys.argv[1])
                    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True).splitlines()
                    parent, children, comm = {}, {}, {}
                    for r in rows:
                        parts = r.split(None, 2)
                        if len(parts) < 3: continue
                        pid, ppid, name = int(parts[0]), int(parts[1]), parts[2].strip()
                        parent[pid] = ppid
                        comm[pid] = os.path.basename(name)
                        children.setdefault(ppid, []).append(pid)
                    root = target
                    while parent.get(root, 0) > 1 and "sshd" not in comm.get(parent[root], ""):
                        root = parent[root]
                    stack, tree = [root], []
                    while stack:
                        cur = stack.pop()
                        tree.append(cur)
                        stack.extend(children.get(cur, []))
                    for pid in tree:
                        try: os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                    ' \(doomedClientPID)
                    """)

                // Server stays alive, and `doomedSessionName` remains as an unattached `@heeler-attach` leftover.
                try await fixture.eventually {
                    let line = try await fixture.tmux(
                        nil, "display-message", "-p", "-t", "=\(doomedSessionName):",
                        "#{session_attached} #{@heeler-attach}")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return line == "0 \(pane)"
                }
                #expect(
                    try await fixture.sessionNames()
                        == [doomedSessionName, liveSessionName, "main", userPrefixed].sorted())

                // Connecting Heeler cleans up ONLY the unattached `@heeler-attach` leftover.
                try await cleanLeftoversViaConsole(
                    expectingGone: doomedSessionName,
                    preserving: [liveSessionName, "main", userPrefixed].sorted(),
                    on: fixture)

                // The live Attach was never disturbed and still streams output.
                try await append("still-streaming\\n", to: file, on: fixture)
                let received = try await read(until: "still-streaming", from: &liveOutput)
                #expect(received.contains("still-streaming"))
                await liveAttach.end()
                _ = doomedAttach
                try? await deadTransport.close()
                try await liveTransport.close()
            } catch {
                try? await deadTransport.close()
                try? await liveTransport.close()
                throw error
            }
            #expect(try await fixture.sessionNames() == ["main", userPrefixed].sorted())
        }
    }

    @MainActor
    private func cleanLeftoversViaConsole(
        expectingGone gone: String, preserving expected: [String], on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-leftover-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()
        do {
            try await fixture.eventually {
                try await fixture.sessionNames() == expected
            }
            let sesiones = try await fixture.sessionNames()
            #expect(!sesiones.contains(gone))
            store.setHosts([])
        } catch {
            store.setHosts([])
            throw error
        }
    }

    /// Chat's actions open an unviewed, zero-geometry control client that sets
    /// `ignore-size` and never sends `-C`, then detach immediately. Under
    /// `window-size latest` with another client attached, the window's size is
    /// unchanged throughout and no `heeler-attach` session remains afterwards.
    @Test("Chat's actions leave a window's size unchanged under window-size latest and close their Attach")
    func chatActionsLeaveWindowSizeUnchangedAndCloseTheirAttach() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            try await fixture.tmux(nil, "set-option", "-gw", "window-size", "latest")
            let desktop = try await attachDesktopClient(
                to: "main", windowColumns: 112, windowRows: 34, on: fixture)
            do {
                try await fixture.eventually {
                    try await windowDimensions("main:0", on: fixture) == "112x34"
                }
                let home = fixture.configuration.homePath
                let program = "\(home)/bin/claude.py"
                try await fixture.writeProgram(
                    at: program,
                    """
                    #!/usr/bin/python3
                    import os, sys, tty
                    capture_path, ready_path = sys.argv[1:3]
                    tty.setraw(0)
                    rule = "─" * 112
                    prompt = (
                        "\\x1b[?2004h\\x1b[1;36mClaude Code\\x1b[0m\\r\\n"
                        + rule + "\\r\\n❯\\u00a0\\x1b[7m \\x1b[0m\\r\\n" + rule + "\\r\\n"
                    )
                    os.write(1, prompt.encode("utf-8"))
                    with open(capture_path, "wb"):
                        pass
                    with open(ready_path, "w") as handle:
                        handle.write("ready\\n")
                    with open(capture_path, "ab", buffering=0) as sink:
                        while True:
                            chunk = os.read(0, 65536)
                            if not chunk:
                                break
                            sink.write(chunk)
                    """)
                let token = UUID().uuidString.prefix(8)
                let captureFile = "\(home)/chat-\(token).bin"
                let readyFile = "\(home)/chat-\(token).ready"
                let pane = try await fixture.require(
                    fixture.tmuxLine([
                        "new-window", "-t", "main:", "-P", "-F", "#{pane_id}",
                        "/usr/bin/python3", program, captureFile, readyFile,
                    ]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(TmuxAttachScript.isPaneID(pane))
                try await fixture.tmux(
                    nil, "set-option", "-p", "-t", pane, "@heeler-status",
                    "state=idle:app=claude-code:turn=1:blocked=0")
                try await fixture.eventually { try await fixture.exists(readyFile) }
                try await waitUntilShown("❯", in: pane, on: fixture)
                #expect(try await windowDimensions(pane, on: fixture) == "112x34")

                try await exerciseChatActions(pane, captureFile: captureFile, on: fixture)

                await desktop.stop()
            } catch {
                await desktop.stop()
                throw error
            }
        }
    }

    @MainActor
    private func exerciseChatActions(
        _ pane: String, captureFile: String, on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-chat-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()

        do {
            try await fixture.eventually {
                let hasAgent = await store.agents.contains { $0.agent.paneID == pane }
                let offersChat = await store.capabilities(for: host.id).offersChat(for: .claude)
                return hasAgent && offersChat
            }
            let row = try #require(store.agents.first { $0.agent.paneID == pane })
            #expect(row.agent.kind == "claude")
            let session = store.composerSession(for: row)
            session.composer.open()

            // 1. Screen read uses capture-pane -e -p without opening an Attach or resizing.
            let screen = try await store.readAgentScreen(pane, on: host.id, keepingTo: session.corePin)
            #expect(InputBoxStateDetector.detect(screen, program: .claude).isSendable)
            #expect(screen.rows.contains { $0.runs.contains { $0.style != .plain } })
            #expect(try await attachSessions(on: fixture).isEmpty)
            #expect(try await windowDimensions(pane, on: fixture) == "112x34")

            // 2. Chat Send opens a size-less Attach, pastes and submits, detaches, and leaves size 112x34.
            let hostID = host.id
            let corePin = session.corePin
            let policy = ComposerDeliveryPolicy.chat(
                rules: ChatSendRules(
                    program: .claude,
                    commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
                activity: { .idle },
                readScreen: { try await store.readAgentScreen(pane, on: hostID, keepingTo: corePin) },
                pause: { _ in })
            session.composer.replaceDraft(with: "chat send")
            #expect(await session.composer.send(policy: policy) == .submittedViaAttach)
            let expectedSend = Data("\u{1B}[200~chat send \u{1B}[201~\r".utf8)
            try await fixture.eventually {
                try await Self.captureSummary(of: captureFile, from: 0, on: fixture)?.length == expectedSend.count
            }
            #expect(try await fixture.tmux(nil, "list-buffers", "-F", "#{buffer_name}").isEmpty)
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            #expect(try await windowDimensions(pane, on: fixture) == "112x34")

            // 3. Tools-keyboard press opens a size-less Attach, sends the key, detaches, and leaves size 112x34.
            try await store.sendAgentKeys(["down"], to: pane, on: hostID, keepingTo: corePin)
            let expectedAfterDown = expectedSend + Data("\u{1B}[B".utf8)
            try await fixture.eventually {
                try await Self.captureSummary(of: captureFile, from: 0, on: fixture)?.length == expectedAfterDown.count
            }
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            #expect(try await windowDimensions(pane, on: fixture) == "112x34")

            // 4. Chat Stop opens a size-less Attach, sends Escape, writes idle, detaches, and leaves size 112x34.
            try await fixture.tmux(
                nil, "set-option", "-p", "-t", pane, "@heeler-status",
                "state=working:app=claude-code:turn=2:blocked=0")
            try await fixture.eventually {
                await store.agents.first { $0.agent.paneID == pane }?.agent.status == .working
            }
            let agentKeys = ChatAgentKeysStore { keys in
                try await store.sendAgentKeys(keys, to: pane, on: hostID, keepingTo: corePin)
            }
            let interrupt = store.chatInterrupt(
                for: row,
                program: .claude,
                keepingTo: corePin,
                context: {
                    let screen = try await store.readAgentScreen(pane, on: hostID, keepingTo: corePin)
                    return ChatStopContext(screen: screen, activity: .working)
                },
                agentKeys: agentKeys)
            #expect(await interrupt.perform() == .sent)
            let expectedAfterStop = expectedAfterDown + Data([0x1B])
            try await fixture.eventually {
                try await Self.captureSummary(of: captureFile, from: 0, on: fixture)?.length == expectedAfterStop.count
            }
            let allHex = try await fixture.require(
                "od -An -tx1 -v \(GitProbe.singleQuoted(captureFile)) | tr -d ' \\n'")
            #expect(allHex == Self.hex(expectedAfterStop))
            let statusAfterStop = try await fixture.tmux(
                nil, "display-message", "-p", "-t", pane, "#{@heeler-status}"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(statusAfterStop == "state=idle:app=claude-code:turn=2:blocked=0")
            try await fixture.eventually { try await attachSessions(on: fixture).isEmpty }
            #expect(try await windowDimensions(pane, on: fixture) == "112x34")

            store.setHosts([])
        } catch {
            store.setHosts([])
            throw error
        }
    }

    /// A stand-in `claude` running in a real tmux Pane exposes its real `TMUX`
    /// (`<socket>,<pid>,<session index>`) and `TMUX_PANE` to the Host process
    /// reader: the Chat binder matches it only when both the socket path and
    /// server pid match the Host's stored paths and server instance, and
    /// `@heeler-chat` JSON holding quotes, braces, `;`, `#{` and a backslash
    /// round-trips byte for byte through `TmuxLaunch.setPaneOptions` and the
    /// live inventory loop before Chat binds the Transcript and clears the
    /// superseded pick.
    @Test("Chat's binder matches a Pane's process only on its real tmux server and reads back @heeler-chat")
    func chatBinderMatchesOnlyThePanesRealTmuxServerAndReadsBackHeelerChat() async throws {
        try await TmuxSSHFixture.with { fixture in
            let otherSocket = fixture.socketName + "-2"
            try await fixture.startServer()
            try await fixture.startServer(otherSocket)

            let home = fixture.configuration.homePath
            let agentsDirectory = "\(home)/agents"
            let claudeDirectory = "\(home)/.claude"
            let cleanupPaths = "\(GitProbe.singleQuoted(claudeDirectory)) \(GitProbe.singleQuoted(agentsDirectory))"
            do {
                let waiter = "\(agentsDirectory)/stand-in-agent"
                let claudeLink = "\(agentsDirectory)/claude"
                // A non-platform binary under a `claude` symlink, so macOS SIP does
                // not withhold its real `TMUX` and `TMUX_PANE` from `ps eww`.
                try await fixture.require(
                    """
                    mkdir -p \(GitProbe.singleQuoted(agentsDirectory))
                    printf '#include <unistd.h>\\nint main(void) { pause(); return 0; }\\n' \
                    | /usr/bin/cc -x c - -o \(GitProbe.singleQuoted(waiter))
                    ln -sf \(GitProbe.singleQuoted(waiter)) \(GitProbe.singleQuoted(claudeLink))
                    """)

                let pane = try await fixture.require(
                    fixture.tmuxLine([
                        "new-window", "-d", "-t", "main:", "-c", home, "-P", "-F", "#{pane_id}",
                        claudeLink, "--stand-in",
                    ]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(TmuxAttachScript.isPaneID(pane))

                let storedPaths = try fixture.paths()
                let instance = try await fixture.serverInstance()
                let otherPaths = try fixture.paths(otherSocket)
                let otherInstance = try await fixture.serverInstance(otherSocket)
                #expect(otherPaths.socket != storedPaths.socket)
                #expect(otherInstance.pid != instance.pid)

                let sessionUUID = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
                let pickUUID = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"

                let transport = try await fixture.connectTmux(storedPaths: storedPaths)
                do {
                    let status = try await transport.status()
                    #expect(status.paths == storedPaths)
                    #expect(status.instance == instance)

                    do {
                        let inventory = try await transport.inventory()
                        var iterator = inventory.makeAsyncIterator()
                        let firstSnapshot = try #require(try await iterator.next())
                        #expect(firstSnapshot.instance == instance)
                        let paneRow = try #require(firstSnapshot.panes.first { $0.paneID == pane })
                        #expect(paneRow.foregroundArguments == [claudeLink, "--stand-in"])
                        #expect(TmuxAgentRule.agentKind(in: paneRow) == "claude")

                        let pid = String(paneRow.processID)
                        let facts = try await transport.hostServices.readProcesses(
                            HostProcessReader.Request(
                                pids: [pid],
                                readsStart: true,
                                valuesOf: [
                                    HerdrCoreTerminalProcesses.tmuxVariable,
                                    HerdrCoreTerminalProcesses.tmuxPaneVariable,
                                    HerdrCoreSessionBinder.homeVariable,
                                ],
                                descendantsOf: pid))
                        let processFacts = try #require(facts[pid])
                        #expect(processFacts.name == "claude")
                        #expect(processFacts.variables[HerdrCoreTerminalProcesses.tmuxPaneVariable] == .value(pane))
                        guard case .value(let rawTmux)? = processFacts.variables[HerdrCoreTerminalProcesses.tmuxVariable],
                            case .value(let realStart) = processFacts.start
                        else {
                            Issue.record("The stand-in agent process did not expose TMUX and start: \(processFacts)")
                            try await transport.close()
                            try await fixture.require("rm -rf \(cleanupPaths)")
                            return
                        }

                        // Real `TMUX` is `<socket>,<pid>,<session index>` and parses to exact socket + server pid.
                        let sessionIndex = String(paneRow.sessionID.dropFirst())
                        #expect(
                            paneRow.sessionID.hasPrefix("$") && !sessionIndex.isEmpty
                                && sessionIndex.allSatisfy(\.isNumber))
                        #expect(rawTmux == "\(storedPaths.socket),\(instance.pid),\(sessionIndex)")
                        #expect(
                            HerdrCoreTerminalProcesses.parseTmuxEnvironment(rawTmux)
                                == .init(socketPath: storedPaths.socket, serverPID: instance.pid))

                        // Plant Claude Code's session registry entry and Transcript for this real pid + procStart.
                        let sessionsDir = "\(claudeDirectory)/sessions"
                        let projectDir = "\(claudeDirectory)/projects/\(ClaudeProjectKey.key(forDirectory: home))"
                        let registryFields: [String: JSONValue] = [
                            "pid": .number(Double(paneRow.processID)),
                            "sessionId": .string(sessionUUID),
                            "cwd": .string(home),
                            "procStart": .string(realStart),
                            "startedAt": .number(1_780_000_000_000),
                            "updatedAt": .number(1_780_000_000_000),
                        ]
                        let registryJSON = try #require(
                            String(data: JSONEncoder().encode(JSONValue.object(registryFields)), encoding: .utf8))
                        let transcriptText = try ChatFixture.text("claude/probe2-transcript.jsonl")
                            .replacingOccurrences(of: "e951205e-24af-4a5e-baa7-3ccbebd2de2c", with: sessionUUID)
                            .split(separator: "\n").prefix(5).joined(separator: "\n")
                        try await fixture.require(
                            "mkdir -p \(GitProbe.singleQuoted(sessionsDir)) \(GitProbe.singleQuoted(projectDir))")
                        try await fixture.writeFile(at: "\(sessionsDir)/\(pid).json", registryJSON)
                        try await fixture.writeFile(at: "\(projectDir)/\(sessionUUID).jsonl", transcriptText)

                        let hostFiles = ChatHostFiles(
                            status: { try await transport.hostServices.fileStatus(atPath: $0) },
                            list: { try await transport.hostServices.listFiles($0) },
                            read: { try await transport.hostServices.readHostFileRange($0) },
                            home: { try await transport.hostServices.hostHomeDirectory() })
                        let hostSystem = HerdrCoreHostSystem(kernel: await transport.hostFacts().kernel)
                        let cannotTell = hostSystem.cannotTellSession(.claude)
                        func binder(socketPath: String, serverPID: Int) -> HerdrCoreSessionBinder {
                            HerdrCoreSessionBinder(
                                program: .claude,
                                processes: { try await transport.hostServices.readProcesses($0) },
                                files: hostFiles,
                                clearLabels: { _ in },
                                hostSystem: hostSystem,
                                processScope: .tmux(paneID: pane, socketPath: socketPath, serverPID: serverPID))
                        }

                        let record = HerdrCoreTerminalRecord(tmuxPane: paneRow)
                        #expect(
                            try await binder(socketPath: storedPaths.socket, serverPID: instance.pid).check(record)
                                == .bound(sessionID: sessionUUID, transcriptRoot: claudeDirectory, directory: home))
                        #expect(
                            try await binder(socketPath: otherPaths.socket, serverPID: instance.pid).check(record)
                                == .unavailable(cannotTell))
                        #expect(
                            try await binder(socketPath: storedPaths.socket, serverPID: otherInstance.pid).check(record)
                                == .unavailable(cannotTell))
                        #expect(
                            try await binder(socketPath: otherPaths.socket, serverPID: otherInstance.pid).check(record)
                                == .unavailable(cannotTell))

                        // Write `@heeler-chat` with quotes, braces, `;`, `#{` and `\` and read it back via the loop.
                        let trickyFile = #"/work/semi;colon/#{pane_id}\back"quote/rollout.jsonl;"#
                        let trickyPick = try #require(
                            HerdrCoreSessionHint.pickLabelValue(
                                session: pickUUID, file: trickyFile, pid: paneRow.processID, start: realStart))
                        #expect(trickyPick.contains("\""))
                        #expect(trickyPick.contains("{") && trickyPick.contains("}"))
                        #expect(trickyPick.contains(";"))
                        #expect(trickyPick.contains("#{"))
                        #expect(trickyPick.contains("\\"))

                        let setCommand = TmuxLaunch.setPaneOptions(
                            pane: pane,
                            instance: instance,
                            options: [("@heeler-chat", trickyPick)],
                            paths: storedPaths)
                        let setResult = try await transport.runTmuxScript(
                            setCommand.script, throughLoginShell: setCommand.throughLoginShell)
                        #expect(setResult.exitStatus == 0)
                        #expect(TmuxLaunch.serverInstanceMatches(instance, stdout: setResult.stdout))

                        let updatedSnapshot = try #require(try await iterator.next())
                        let updatedPane = try #require(updatedSnapshot.panes.first { $0.paneID == pane })
                        #expect(updatedPane.chatPick == trickyPick)
                        let decodedPick = try #require(HerdrCoreSessionHint(label: updatedPane.chatPick))
                        #expect(decodedPick.session == pickUUID)
                        #expect(decodedPick.file == trickyFile)
                        #expect(decodedPick.pid == paneRow.processID)
                        #expect(decodedPick.start == realStart)
                    }

                    try await transport.close()
                } catch {
                    try? await transport.close()
                    throw error
                }

                try await exerciseChatBinding(pane, sessionUUID: sessionUUID, on: fixture)
                try await fixture.require("rm -rf \(cleanupPaths)")
            } catch {
                _ = try? await fixture.require("rm -rf \(cleanupPaths)")
                throw error
            }
        }
    }

    @MainActor
    private func exerciseChatBinding(
        _ pane: String, sessionUUID: String, on fixture: TmuxSSHFixture
    ) async throws {
        let suite = "tmux-chat-bind-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()

        var openedChat: AgentChatStore?
        do {
            try await fixture.eventually {
                let hasAgent = await store.agents.contains { $0.agent.paneID == pane }
                let offersChat = await store.capabilities(for: host.id).offersChat(for: .claude)
                return hasAgent && offersChat
            }
            let row = try #require(store.agents.first { $0.agent.paneID == pane })
            let chat = try #require(store.chatStore(for: row, program: .claude))
            openedChat = chat
            chat.show()

            try await fixture.eventually {
                guard case .following(let path) = await chat.conversation.phase else { return false }
                return path.hasSuffix("/\(sessionUUID).jsonl")
            }
            // Exact process evidence clears the superseded `@heeler-chat` pick on the server.
            try await fixture.eventually {
                try await fixture.tmux(nil, "display-message", "-p", "-t", pane, "#{@heeler-chat}")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            chat.end()
            store.setHosts([])
        } catch {
            openedChat?.end()
            store.setHosts([])
            throw error
        }
    }
}
