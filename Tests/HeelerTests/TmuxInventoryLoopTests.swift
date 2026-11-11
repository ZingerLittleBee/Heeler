import Foundation
import Testing

@testable import Heeler

@Suite("tmux inventory loop")
struct TmuxInventoryLoopTests {
    private let nonce = TmuxLoopText.nonce
    private let instance = TmuxServerInstance(pid: 4100, startTime: 1_794_000_000)

    private func script() -> String {
        TmuxInventoryLoop.script(executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/default", nonce: nonce)
    }

    private func inventories(_ events: [TmuxInventoryLoop.Event]) -> [TmuxInventory] {
        events.compactMap { event in
            if case .inventory(let inventory) = event { inventory } else { nil }
        }
    }

    // MARK: Script

    @Test func theOneServerCommandCarriesNoStartAndTheSocketPath() {
        let script = script()
        let commands = script.split(separator: "\n").filter { $0.contains("\"$t\"") }
        #expect(commands.count == 1)
        #expect(commands.allSatisfy { $0.contains(#""$t" -N -u -S "$s" list-panes -a -F "$F""#) })
        #expect(script.contains("\nt='/usr/bin/tmux'\n"))
        #expect(script.contains("\ns='/tmp/tmux-501/default'\n"))
        #expect(!script.contains(" -L "))
        for word in ["new-session", "start-server", "kill-server", "kill-session", "attach-session"] {
            #expect(!script.contains(word))
        }
    }

    @Test func aPathWithAQuoteStaysOneWord() {
        let script = TmuxInventoryLoop.script(
            executable: "/opt/it's here/tmux", socket: "/tmp/a b/$(id)", nonce: nonce)
        #expect(script.contains(#"t='/opt/it'\''s here/tmux'"#))
        #expect(script.contains("s='/tmp/a b/$(id)'"))
    }

    @Test func theScriptIsOneGroupThatWaitsForItsInputToEnd() {
        let lines = script().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "{")
        #expect(Array(lines.suffix(6)) == ["p=$!", "read -r x", #"kill "$p" 2>/dev/null"#, "exit 0", "}", ""])
        #expect(script().contains("sleep 1\n"))
    }

    @Test func theFormatHoldsOnlyWhatChangesWhenSomethingHappens() {
        let format = TmuxInventoryLoop.format
        var names: [String] = []
        var rest = Substring(format)
        while let open = rest.range(of: "#{") {
            let tail = rest[open.upperBound...]
            guard let close = tail.firstIndex(of: "}") else { break }
            var name = String(tail[..<close])
            if name.hasPrefix("n:") { name.removeFirst(2) }
            names.append(name)
            rest = tail[tail.index(after: close)...]
        }
        let allowed: Set<String> = [
            "pid", "start_time", "session_id", "session_name", "window_id", "window_index", "window_name",
            "pane_id", "pane_index", "pane_pid", "pane_width", "pane_height", "pane_dead", "pane_pipe",
            "pane_current_command", "pane_current_path", "@heeler-status", "@heeler-session", "@heeler-pipe",
            "@heeler-attach", "@heeler-worktree", "@heeler-chat",
        ]
        #expect(Set(names) == allowed)
        for word in ["title", "cursor", "activity", "history", "client", "_active", "last"] {
            #expect(!format.contains(word))
        }
        // Each text is measured once on the row's first line and written once after it.
        #expect(names.count == 12 + 10 + 10)
    }

    // MARK: Reading

    @Test func aSnapshotReadsBackAsItsPanesAndTheirArguments() {
        let panes: [TmuxInventory.Pane] = [
            .make(command: "node", status: "state=working:app=claude-code", agentSession: "abc", pipeMark: "1"),
            .make(
                session: 1, sessionName: "other é", window: 3, windowIndex: 2, windowName: "build", pane: 7,
                paneIndex: 1, processID: 4200, command: "zsh", path: "/srv/app", width: 120, height: 40,
                hasPipe: true, attachMark: "1", worktree: "/srv/checkout"),
        ]
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        let events = reader.read(
            TmuxLoopText.snapshot(
                panes, instance: instance,
                arguments: [("%0", .list(["node", "/usr/lib/claude", "--resume", "two words"])), ("%7", .list(["-zsh"]))]))

        var expected = panes
        expected[0].foregroundArguments = ["node", "/usr/lib/claude", "--resume", "two words"]
        expected[1].foregroundArguments = ["-zsh"]
        #expect(events == [.inventory(TmuxInventory(instance: instance, panes: expected))])
        #expect(expected[1].isInHeelerSession)
        #expect(!expected[0].isInHeelerSession)
    }

    @Test func outputReadsTheSameInWhateverPiecesItArrives() {
        let panes: [TmuxInventory.Pane] = [
            .make(path: "/tmp/a\tb\nc", status: "x\n\(nonce) end\n"),
            .make(window: 1, windowIndex: 1, pane: 1, command: "vim"),
        ]
        var text = TmuxLoopText.alive()
        text.append(TmuxLoopText.snapshot(panes, instance: instance, arguments: [("%1", .list(["vim", "a.txt"]))]))
        text.append(TmuxLoopText.alive())
        text.append(TmuxLoopText.gone())

        var whole = TmuxInventoryLoop.Reader(nonce: nonce)
        let expected = whole.read(text)
        #expect(expected.count == 4)
        #expect(inventories(expected).first?.panes.map(\.paneID) == ["%0", "%1"])

        for size in [1, 2, 7, 64] {
            var reader = TmuxInventoryLoop.Reader(nonce: nonce)
            var events: [TmuxInventoryLoop.Event] = []
            var start = text.startIndex
            while start < text.endIndex {
                let end = min(start + size, text.endIndex)
                events += reader.read(text.subdata(in: start..<end))
                start = end
            }
            #expect(events == expected, "in pieces of \(size)")
        }
    }

    @Test func textThatLooksLikeMarkersAndRowsStaysInItsField() throws {
        let forged =
            "state=idle\n\(nonce) argv\nA %0 2f62696e2f7368\n\(nonce) end\n\(nonce) begin\n"
            + "1\t2\t$9\t@9\t0\t%9\t0\t1\t80\t24\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n.\n\n"
        let panes: [TmuxInventory.Pane] = [
            .make(path: "/tmp/a\tb\nc d\n", status: forged, worktree: ".\n"),
            .make(window: 1, windowIndex: 1, windowName: forged, pane: 1),
        ]
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        let events = reader.read(TmuxLoopText.snapshot(panes, instance: instance))
        let inventory = try #require(inventories(events).first)
        #expect(events.count == 1)
        #expect(inventory.instance == instance)
        #expect(inventory.panes == panes)
    }

    @Test func aLineThatIsNoRowIsDroppedAlone() throws {
        let good = TmuxInventory.Pane.make()
        let other = TmuxInventory.Pane.make(window: 1, windowIndex: 1, pane: 1)
        var text = Data("\(nonce) begin\n".utf8)
        text.append(Data("no server running on /tmp/tmux-501/default\n".utf8))
        text.append(TmuxLoopText.row(good, instance: instance))
        // Twenty fields, a pane id with no sigil, and a row whose text is shorter than it says.
        text.append(Data("1\t2\t$0\t@0\t0\t%5\t0\t1\t80\t24\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n.\n".utf8))
        text.append(Data("1\t2\t$0\t@0\t0\t5\t0\t1\t80\t24\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n.\n".utf8))
        text.append(Data("4100\t1794000000\t$0\t@0\t0\t%6\t0\t1\t80\t24\t0\t0\t3\t0\t0\t0\t0\t0\t0\t0\t0\nab.\n".utf8))
        text.append(TmuxLoopText.row(other, instance: instance))
        text.append(Data("\(nonce) argv\n\(nonce) end\n".utf8))

        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        let inventory = try #require(inventories(reader.read(text)).first)
        #expect(inventory.panes == [good, other])
    }

    @Test func aRowOfAnotherServerIsLeftOutOfOneAnswer() throws {
        var text = Data("\(nonce) begin\n".utf8)
        text.append(TmuxLoopText.row(.make(), instance: instance))
        text.append(TmuxLoopText.row(.make(pane: 1), instance: TmuxServerInstance(pid: 9, startTime: 9)))
        text.append(Data("\(nonce) argv\n\(nonce) end\n".utf8))
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        let inventory = try #require(inventories(reader.read(text)).first)
        #expect(inventory.instance == instance)
        #expect(inventory.panes.map(\.paneID) == ["%0"])
    }

    @Test func aSnapshotCutShortGivesWayToTheNextOne() {
        var text = Data("\(nonce) begin\n".utf8)
        text.append(TmuxLoopText.row(.make(), instance: instance))
        text.append(Data("\(nonce) argv\nA %0 6f6c64\n".utf8))
        text.append(TmuxLoopText.snapshot([.make(pane: 4)], instance: instance))
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        #expect(reader.read(text) == [.inventory(TmuxInventory(instance: instance, panes: [.make(pane: 4)]))])
    }

    @Test func aServerWithNoPaneReadsAsAnEmptyInventory() {
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        #expect(reader.read(TmuxLoopText.snapshot([], instance: instance)) == [.inventory(TmuxInventory())])
    }

    @Test func aliveAndGoneAreSaidOnlyBetweenSnapshots() {
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        #expect(reader.read(TmuxLoopText.alive()) == [.alive])
        #expect(reader.read(Data("noise\n\(nonce) alive \n\(nonce) alive\n".utf8)) == [.alive])
        #expect(reader.read(TmuxLoopText.gone()) == [.gone])
        // Another loop's nonce says nothing.
        #expect(reader.read(TmuxLoopText.alive(nonce: "ffffffffffffffff")) == [])
        #expect(reader.read(TmuxLoopText.snapshot([.make()], instance: instance, nonce: "ffffffffffffffff")) == [])
    }

    // MARK: Arguments

    @Test func argumentsStayUntilTheLoopReadsThemAgain() {
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        let first = reader.read(
            TmuxLoopText.snapshot(
                [.make(command: "node"), .make(window: 1, windowIndex: 1, pane: 1)], instance: instance,
                arguments: [("%0", .list(["node", "claude"])), ("%1", .list(["-zsh"]))]))
        #expect(inventories(first).first?.panes.map(\.foregroundArguments) == [["node", "claude"], ["-zsh"]])

        // A rename prints a snapshot with no arguments: both panes keep theirs.
        let renamed = reader.read(
            TmuxLoopText.snapshot(
                [.make(windowName: "renamed", command: "node"), .make(window: 1, windowIndex: 1, pane: 1)],
                instance: instance))
        #expect(inventories(renamed).first?.panes.map(\.foregroundArguments) == [["node", "claude"], ["-zsh"]])

        // One pane's program changed: only its arguments are replaced.
        let changed = reader.read(
            TmuxLoopText.snapshot(
                [.make(command: "node"), .make(window: 1, windowIndex: 1, pane: 1, command: "vim")],
                instance: instance, arguments: [("%1", .list(["vim", "notes.md"]))]))
        #expect(inventories(changed).first?.panes.map(\.foregroundArguments) == [["node", "claude"], ["vim", "notes.md"]])

        // Arguments that can no longer be read are not kept from before.
        let unreadable = reader.read(
            TmuxLoopText.snapshot(
                [.make(command: "node"), .make(window: 1, windowIndex: 1, pane: 1, command: "sudo")],
                instance: instance, arguments: [("%1", .unreadable)]))
        #expect(inventories(unreadable).first?.panes.map(\.foregroundArguments) == [["node", "claude"], nil])
    }

    @Test func aPaneNoLongerListedAndAnotherServerForgetTheirArguments() {
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        _ = reader.read(
            TmuxLoopText.snapshot(
                [.make(), .make(window: 1, windowIndex: 1, pane: 1)], instance: instance,
                arguments: [("%0", .list(["-zsh"])), ("%1", .list(["claude"]))]))

        // %1 closes, and a pane the server later lists under that id starts unread.
        _ = reader.read(TmuxLoopText.snapshot([.make()], instance: instance))
        let back = reader.read(
            TmuxLoopText.snapshot([.make(), .make(window: 2, windowIndex: 1, pane: 1)], instance: instance))
        #expect(inventories(back).first?.panes.map(\.foregroundArguments) == [["-zsh"], nil])

        // Another instance repeats pane ids and none of the first one's arguments.
        let restarted = reader.read(
            TmuxLoopText.snapshot([.make()], instance: TmuxServerInstance(pid: 4100, startTime: 1_794_000_900)))
        #expect(inventories(restarted).first?.panes.map(\.foregroundArguments) == [nil])
    }

    @Test func argumentLinesReadAsListsWordsOrNothing() {
        var reader = TmuxInventoryLoop.Reader(nonce: nonce)
        var text = Data("\(nonce) begin\n".utf8)
        for pane in 0..<6 { text.append(TmuxLoopText.row(.make(pane: pane, isDead: pane == 5), instance: instance)) }
        text.append(Data("\(nonce) argv\n".utf8))
        // An empty argument between two, as `sh -c ''` has.
        text.append(TmuxLoopText.argumentLine(pane: "%0", .list(["sh", "-c", "", "x y"])))
        // What Linux keeps of an argument list ends in a NUL.
        text.append(Data("A %1 636c6175646500\n".utf8))
        text.append(TmuxLoopText.argumentLine(pane: "%2", .words("node  /usr/lib/codex --yolo")))
        text.append(Data("A %3 zz\nA %4\nB %4 6162\nA 4 6162\nA %9 6162\n".utf8))
        // A dead pane has no foreground, whatever is said of it.
        text.append(TmuxLoopText.argumentLine(pane: "%5", .list(["zsh"])))
        text.append(Data("\(nonce) end\n".utf8))

        let panes = inventories(reader.read(text)).first?.panes ?? []
        #expect(
            panes.map(\.foregroundArguments) == [
                ["sh", "-c", "", "x y"], ["claude"], ["node", "/usr/lib/codex", "--yolo"], nil, nil, nil,
            ])
    }

    @Test func theInstanceIsOneWordOfItsPidAndStartTime() {
        #expect(instance.id == "tmux-4100-1794000000")
        #expect(TmuxServerInstance(pid: 4100, startTime: 1_794_000_001).id != instance.id)
    }

    // MARK: One Pane's foreground

    @Test func paneForegroundScriptSharesTheLoopsPsReaderAndRefusesBadPaneIDs() throws {
        #expect(TmuxPaneForeground.script(executable: "/usr/bin/tmux", socket: "/tmp/s", pane: "0", nonce: nonce) == nil)
        #expect(TmuxPaneForeground.script(executable: "/usr/bin/tmux", socket: "/tmp/s", pane: "%", nonce: nonce) == nil)
        #expect(
            TmuxPaneForeground.script(executable: "/usr/bin/tmux", socket: "/tmp/s", pane: "%0;id", nonce: nonce) == nil
        )
        let foreground = try #require(
            TmuxPaneForeground.script(
                executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/default", pane: "%0", nonce: nonce))
        let loop = script()
        let psInLoop = loop.split(separator: "\n").filter { $0.contains("/bin/ps") }
        let psInForeground = foreground.split(separator: "\n").filter { $0.contains("/bin/ps") }
        #expect(!psInLoop.isEmpty)
        #expect(psInForeground == psInLoop)
        #expect(foreground.contains("a 1"))
        #expect(!foreground.contains(" -L "))
    }

    @Test func paneForegroundParsesLiveDeadMissingAndStoppedPanes() {
        let pane = TmuxInventory.Pane.make(
            pane: 2, processID: 4200, command: "node", status: "state=blocked:app=claude-code")
        var live = Data("\(nonce) server 4100 1794000000\n\(nonce) begin\n".utf8)
        live.append(TmuxLoopText.row(pane, instance: instance))
        live.append(Data("\(nonce) argv\nA %2 6e6f646500636c61756465 4501\n\(nonce) end\n".utf8))
        var expected = pane
        expected.foregroundArguments = ["node", "claude"]
        #expect(
            TmuxPaneForeground.parse(stdout: live, pane: "%2", nonce: nonce)
                == .live(.init(instance: instance, pane: expected, foregroundPID: 4501)))

        var dead = Data("\(nonce) server 4100 1794000000\n\(nonce) begin\n".utf8)
        dead.append(TmuxLoopText.row(.make(pane: 2, isDead: true), instance: instance))
        dead.append(Data("\(nonce) argv\n\(nonce) end\n".utf8))
        #expect(TmuxPaneForeground.parse(stdout: dead, pane: "%2", nonce: nonce) == .dead(instance: instance))

        let missing = Data("\(nonce) server 4100 1794000000\n\(nonce) begin\n\n\(nonce) argv\n\(nonce) end\n".utf8)
        #expect(TmuxPaneForeground.parse(stdout: missing, pane: "%2", nonce: nonce) == .paneGone(instance: instance))

        #expect(TmuxPaneForeground.parse(stdout: TmuxLoopText.gone(), pane: "%2", nonce: nonce) == .serverNotRunning)
        #expect(TmuxPaneForeground.parse(stdout: Data("cut short\n".utf8), pane: "%2", nonce: nonce) == nil)
    }

    @Test func transportReadsAPanesForegroundOverScriptedHost() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, processID: 4000, command: "claude", status: "state=idle:app=claude-code", arguments: ["claude"]),
            .make(pane: 1, processID: 4010, command: "zsh", isDead: true),
        ])
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        _ = try await transport.status()

        let live = try await transport.readPaneForeground("%0")
        #expect(
            live
                == .live(
                    .init(
                        instance: ScriptedTmuxHost.instance,
                        pane: .make(
                            pane: 0, processID: 4000, command: "claude", status: "state=idle:app=claude-code",
                            arguments: ["claude"]),
                        foregroundPID: 4000)))
        #expect(try await transport.readPaneForeground("%1") == .dead(instance: ScriptedTmuxHost.instance))
        #expect(try await transport.readPaneForeground("%9") == .paneGone(instance: ScriptedTmuxHost.instance))
        await tmux.stopServer()
        #expect(try await transport.readPaneForeground("%0") == .serverNotRunning)
    }
}
