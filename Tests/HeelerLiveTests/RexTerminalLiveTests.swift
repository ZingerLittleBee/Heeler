import Foundation
import GhosttyTerminal
import HeelerSSH
import Testing
import UIKit

@testable import Heeler

/// Explicit opt-in only: Rex terminal streams against a Rex server that
/// already runs on this Mac, over its local Unix socket, painted into
/// Heeler's own Ghostty terminal and compared with the server's text of the
/// same terminal. It never runs in the HeelerTests target or in CI, and
/// fails rather than skips when selected without its configuration.
///
/// It creates one session labeled `heeler-lab-…` whose programs run with a
/// scrubbed environment, opens data connections only to that session's
/// blocks, and destroys the session before it ends. It touches no other
/// session. It prints counts and booleans only, never terminal contents.
///
/// `/tmp/heeler-lab-home` must exist (the programs' HOME and directory).
/// Give the socket path to the Simulator's launchd environment, run the
/// suite, then unset it:
///
/// ```sh
/// mkdir -p /tmp/heeler-lab-home
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexTerminalLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@Suite("Rex terminal streams over a local socket", .serialized, .timeLimit(.minutes(4)))
@MainActor
struct RexTerminalLiveTests {
    nonisolated static let labHome = "/tmp/heeler-lab-home"

    @Test func labTerminalsPaintAsTheServerShowsThem() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        let lab = try await RexLab.open(path: socketPath)
        var failure: (any Error)?
        do {
            try await run(lab)
        } catch {
            failure = error
        }
        let remaining = await lab.destroyEverything()
        print("Rex lab: \(remaining.lab) lab sessions remain, \(remaining.total) sessions in all")
        #expect(remaining.lab == 0)
        await lab.control.close()
        if let failure { throw failure }
    }

    private func run(_ lab: RexLab) async throws {
        // The local grid decides the blocks' size, so both sides wrap alike.
        let probe = try await GhosttyReplica.make()
        let grid = probe.grid
        probe.tearDown()
        print("Rex lab: local grid \(grid.columns)x\(grid.rows)")

        let programs = LabPrograms(columns: grid.columns)
        let session = try await lab.createSession(
            blocks: [
                ("shell", ["/bin/sh"]), ("scrollback", programs.scrollback), ("alternate", programs.alternate),
                ("wide", programs.wide), ("busy", programs.busy),
            ],
            grid: grid)

        try await colorsResumeAndRefusals(lab, session: session.id, block: session.blocks[0], grid: grid)
        try await scrollback(lab, session: session.id, block: session.blocks[1], grid: grid)
        try await alternateScreen(lab, session: session.id, block: session.blocks[2], grid: grid)
        try await wideAndWrapped(lab, session: session.id, block: session.blocks[3], grid: grid)
        try await busy(lab, session: session.id, block: session.blocks[4], grid: grid)
    }

    // MARK: Scenarios

    /// A shell prints colors; the data link drops and resumes; then a second
    /// HELLO while one is live is refused, a resume that counts too few bytes
    /// is refused for good, and a new HELLO opens again.
    private func colorsResumeAndRefusals(_ lab: RexLab, session: String, block: String, grid: LocalGrid) async throws {
        try await lab.type("\(LabPrograms.colors)\r", session: session, block: block)
        try await Task.sleep(for: .milliseconds(500))
        let run = try await StreamRun.start(lab: lab, session: session, block: block)
        try await run.settle()
        try await compare("colors", run: run, lab: lab, session: session, block: block, grid: grid)

        // Drop the connection under the stream while the terminal is idle.
        try await lab.channels.dropLast()
        try await Task.sleep(for: .milliseconds(300))
        try await lab.type("echo resumed-$((40 + 2))\r", session: session, block: block)
        try await run.settle()
        let status = await run.stream.status
        print(
            "Rex lab resume: resumes \(status.resumes), streams \(status.streamsOpened), "
                + "paints \(status.paintCount)")
        #expect(status.resumes == 1)
        #expect(status.streamsOpened == 1)
        try await compare("colors after resume", run: run, lab: lab, session: session, block: block, grid: grid)
        await run.stop()

        let route = lab.route
        let first = try await RexDataLink.open(session: session, block: block, route: route)
        let second = await Self.failure { try await RexDataLink.open(session: session, block: block, route: route) }
        let secondRefused = Self.ending(second) == .refused(.alreadyConnected)
        await first.disconnect()
        let resume = await Self.failure { try await first.resume(over: route) }
        let resumeRefused = Self.ending(resume) == .refused(.streamUnavailable)
        let again = await Self.failure { try await first.resume(over: route) }
        var resumeSpent = false
        if case .notResumable(nil)? = again as? RexDataLinkError { resumeSpent = true }
        let fresh = try await RexDataLink.open(session: session, block: block, route: route)
        let freshReads = try await fresh.receive().count > 0
        await fresh.close()
        print(
            "Rex lab refusals: second HELLO refused \(secondRefused), short RESUME refused \(resumeRefused), "
                + "second RESUME not sent \(resumeSpent), fresh HELLO reads \(freshReads)")
        #expect(secondRefused)
        #expect(resumeRefused)
        #expect(resumeSpent)
        #expect(freshReads)
    }

    private func scrollback(_ lab: RexLab, session: String, block: String, grid: LocalGrid) async throws {
        var options = RexTerminalStream.Options()
        // Small pages, so the redraw is read through blob_read.
        options.paint.pageBytes = 64 * 1024
        let run = try await StreamRun.start(lab: lab, session: session, block: block, options: options)
        try await run.settle()
        try await compare("scrollback", run: run, lab: lab, session: session, block: block, grid: grid)
        await run.stop()
    }

    /// Painted on the alternate screen, which hides the primary one; once the
    /// program leaves it, the stream repaints.
    private func alternateScreen(_ lab: RexLab, session: String, block: String, grid: LocalGrid) async throws {
        let run = try await StreamRun.start(lab: lab, session: session, block: block)
        try await run.settle()
        try await compare("alternate", run: run, lab: lab, session: session, block: block, grid: grid)
        let paints = await run.stream.status.paintCount
        try await lab.type("x\r", session: session, block: block)
        try await run.settle(paintsAbove: paints)
        let repainted = await run.stream.status.paintCount > paints
        print("Rex lab alternate: repainted after leaving \(repainted)")
        #expect(repainted)
        try await compare("primary after alternate", run: run, lab: lab, session: session, block: block, grid: grid)
        await run.stop()
    }

    private func wideAndWrapped(_ lab: RexLab, session: String, block: String, grid: LocalGrid) async throws {
        let run = try await StreamRun.start(lab: lab, session: session, block: block)
        try await run.settle()
        try await compare("wide and wrapped", run: run, lab: lab, session: session, block: block, grid: grid)
        await run.stop()
    }

    /// The stream opens while the program writes: the first paint is best
    /// effort, then one exact paint replaces it once the program stops.
    private func busy(_ lab: RexLab, session: String, block: String, grid: LocalGrid) async throws {
        let run = try await StreamRun.start(lab: lab, session: session, block: block, beforeStart: {
            try await lab.type("x\r", session: session, block: block)
            try await Task.sleep(for: .milliseconds(150))
        })
        try await run.settle(timeout: .seconds(30))
        let status = await run.stream.status
        print(
            "Rex lab busy: paints \(status.paintCount), exact \(status.exactPaintCount), dirty \(status.isDirty), "
                + "program bytes \(status.programBytes)")
        #expect(status.exactPaintCount >= 1)
        try await compare("busy", run: run, lab: lab, session: session, block: block, grid: grid)
        await run.stop()
    }

    // MARK: Comparing

    /// Compares what Heeler's Ghostty shows with the server's text of the
    /// same terminal: the whole history with soft wraps joined, and the
    /// visible rows. Prints counts and booleans only.
    private func compare(
        _ name: String, run: StreamRun, lab: RexLab, session: String, block: String, grid: LocalGrid
    ) async throws {
        let replica = run.replica
        try await replica.waitForSettledText()
        let localAll = Self.normalized(replica.allText())
        let localRows = Self.normalized(replica.viewportText())
        let serverAll = Self.normalized(try await lab.text(session: session, block: block, unwrap: true))
        let serverRows = Self.normalized(try await lab.text(session: session, block: block, unwrap: false))
        let serverScreen = Array(serverRows.suffix(localRows.count))
        let allMatch = localAll == serverAll
        let rowsMatch = localRows == serverScreen
        // Heeler's row reader ends a row whose last cell is a wide character's
        // spacer (the character did not fit and wrapped) with that character
        // as well; the server's text leaves it on the next row only.
        let wideWrapRows = localRows.indices.filter { index in
            guard index < serverScreen.count, localRows[index] != serverScreen[index],
                let extra = localRows[index].last, String(localRows[index].dropLast()) == serverScreen[index]
            else { return false }
            return extra == serverScreen[safe: index + 1]?.first && Self.isWide(extra)
        }
        let rowsMatchApartFromWideWraps =
            localRows.count == serverScreen.count
            && localRows.indices.allSatisfy { localRows[$0] == serverScreen[$0] || wideWrapRows.contains($0) }
        let gridMatch = replica.serverGrid.map { $0.columns == grid.columns && $0.rows == grid.rows } ?? false
        let serverTitle = try await lab.title(session: session, block: block)
        let titleMatch = replica.title == RexTerminalReads.displayTitle(serverTitle)
        let status = await run.stream.status
        var report =
            "Rex lab \(name): lines \(localAll.count)/\(serverAll.count) match \(allMatch), "
            + "rows \(localRows.count) match \(rowsMatch) (apart from \(wideWrapRows.count) wide-wrap rows "
            + "\(rowsMatchApartFromWideWraps)), grid match \(gridMatch), title match \(titleMatch), "
            + "paints \(status.paintCount) exact \(status.exactPaintCount), snapshot bytes \(status.skippedSnapshotBytes)"
        if !allMatch {
            let first =
                zip(localAll, serverAll).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                ?? min(localAll.count, serverAll.count)
            report += ", first differing line \(first)"
        }
        if !rowsMatchApartFromWideWraps {
            // Which rows agree, never the text.
            let pattern = zip(localRows, serverScreen).map { $0 == $1 ? "1" : "0" }.joined()
            report += ", server rows \(serverRows.count), rows agreeing \(pattern)"
        }
        print(report)
        #expect(allMatch, "\(name): the whole text differs")
        #expect(rowsMatchApartFromWideWraps, "\(name): the visible rows differ")
        #expect(gridMatch, "\(name): the grids differ")
    }

    /// Lines with trailing spaces cut, and trailing empty lines dropped.
    static func normalized(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String(line)
            while line.last == " " || line.last == "\r" { line.removeLast() }
            return line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// East Asian wide or fullwidth, as a terminal gives two cells.
    static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
                0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
                true
            default:
                false
            }
        }
    }

    static func failure(_ operation: () async throws -> some Any) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    static func ending(_ failure: (any Error)?) -> RexDataEnding? {
        guard case .ended(let ending)? = failure as? RexDataLinkError else { return nil }
        return ending
    }
}

struct LocalGrid: Sendable {
    let columns: Int
    let rows: Int
}

/// The programs the lab session runs, written for the local grid. Each
/// keeps its terminal open once done.
struct LabPrograms {
    let columns: Int

    static let colors =
        #"printf '\033[31mred\033[0m \033[1;32mbold green\033[0m \033[44mblue bg\033[0m \033[38;5;208m208\033[0m \033[38;2;10;200;30mtrue\033[0m\n'; i=0; while [ $i -lt 40 ]; do printf 'loop %02d \033[3%dmcolor\033[0m\n' $i $((i % 8)); i=$((i+1)); done"#

    var scrollback: [String] {
        let long = String(repeating: "W", count: columns + columns / 2)
        return shell(
            #"i=0; while [ $i -lt 3000 ]; do if [ $((i % 10)) -eq 3 ]; then printf '\033[1;32mline %05d\033[0m abcdefghij\n' $i; else printf 'line %05d abcdefghijabcdefghij\n' $i; fi; if [ $((i % 97)) -eq 5 ]; then printf 'long %05d \#(long)\n' $i; fi; if [ $((i % 50)) -eq 7 ]; then printf 'wide %05d 漢字テスト end\n' $i; fi; i=$((i+1)); done; printf '$ tail'"#)
    }

    var alternate: [String] {
        shell(
            #"i=0; while [ $i -lt 40 ]; do printf 'primary %03d\n' $i; i=$((i+1)); done; printf '\033[?1049h\033[H\033[2J\033[7malternate screen\033[0m\n box one\n box two\n'; read x; printf '\033[?1049lback on primary\n'"#)
    }

    var wide: [String] {
        let edge = String(repeating: "0", count: columns - 1)
        return shell(
            #"printf 'wide 漢字テスト end\n'; printf '\#(edge)漢字\n'; i=0; while [ $i -lt 40 ]; do printf 'ab漢'; i=$((i+1)); done; printf '\n'; i=0; while [ $i -lt 3 ]; do printf 'wrapped-%d ' $i; j=0; while [ $j -lt 30 ]; do printf 'word%02d ' $j; j=$((j+1)); done; printf '\n'; i=$((i+1)); done"#)
    }

    var busy: [String] {
        shell(
            #"read x; i=0; while [ $i -lt 300 ]; do printf 'busy %06d \033[3%dmtick\033[0m\n' $i $((i % 8)); i=$((i+1)); /bin/sleep 0.01; done; printf 'done\n'"#)
    }

    /// The script, then an idle wait, so the terminal stays as it ended.
    private func shell(_ script: String) -> [String] {
        ["/bin/sh", "-c", script + "; exec /bin/sleep 600"]
    }
}

/// The lab's control link, the lab session it creates, and the channels its
/// data links open, all against the local socket.
actor RexLab {
    static let labelPrefix = "heeler-lab-"

    final class Channels: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UnixDomainSocketChannel?

        func opened(_ channel: UnixDomainSocketChannel) {
            lock.withLock { last = channel }
        }

        /// Ends the last channel opened, as a dropped connection does.
        func dropLast() async throws {
            let channel = lock.withLock { last }
            try await channel?.close(timeout: .seconds(1))
        }
    }

    nonisolated let control: RexControlLink
    nonisolated let channels = Channels()
    nonisolated let path: String
    private var created: [String] = []

    private init(control: RexControlLink, path: String) {
        self.control = control
        self.path = path
    }

    static func open(path: String) async throws -> RexLab {
        RexLab(control: try await RexControlLink.open(over: try UnixDomainSocketChannel(path: path)), path: path)
    }

    nonisolated var route: RexDataRoute {
        RexDataRoute(
            control: { [control] in control },
            openChannel: { [path, channels] in
                let channel = try UnixDomainSocketChannel(path: path)
                channels.opened(channel)
                return channel
            })
    }

    /// One session with a window per block, each block a program under a
    /// scrubbed environment, sized to `grid`. The session is attached.
    func createSession(
        blocks: [(String, [String])], grid: LocalGrid, name: String = "r4a"
    ) async throws -> (id: String, blocks: [String]) {
        let label = Self.labelPrefix + name + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        let windows: [JSONValue] = blocks.map { name, argv in
            let command: [JSONValue] =
                [
                    "/usr/bin/env", "-i", "HOME=\(RexTerminalLiveTests.labHome)", "TERM=xterm-256color", "PS1=$ ",
                    "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8",
                ].map(JSONValue.string) + argv.map(JSONValue.string)
            return .object([
                "window_label": .string(name),
                "layout": .object([
                    "block": .object([
                        "flavor": .string("com.superlogical.terminal.shell"), "label": .string(name),
                        "options": .object([
                            "shell": .string("none"), "command": .array(command),
                            "cwd": .string(RexTerminalLiveTests.labHome),
                            "size": .object(["columns": .number(Double(grid.columns)), "rows": .number(Double(grid.rows))]),
                            "exit": .object(["on_completion": .bool(false)]),
                        ]),
                    ])
                ]),
            ])
        }
        let created = try await control.call(
            "session.create", payload: JSONValue.object(["label": .string(label), "initial_windows": .array(windows)])
        ).result(JSONValue.self)
        let id = try #require(created["session_id"]?.stringValue)
        self.created.append(id)
        guard case .array(let made)? = created["initial_windows"] else {
            throw LabError.unreadable("session.create")
        }
        let blockIDs = made.compactMap { window -> String? in
            guard case .array(let ids)? = window["block_ids"] else { return nil }
            return ids.first?.stringValue
        }
        guard blockIDs.count == blocks.count else { throw LabError.unreadable("session.create blocks") }
        _ = try await control.call("session.attach", payload: JSONValue.object(["session_id": .string(id)]))
        return (id, blockIDs)
    }

    nonisolated func type(_ text: String, session: String, block: String) async throws {
        _ = try await control.call(
            RexInventoryWire.terminalMethod("write"),
            payload: JSONValue.object([
                "session_id": .string(session), "block_id": .string(block), "args": .object(["data": .string(text)]),
            ]))
    }

    /// The server's own text of the terminal, paged.
    nonisolated func text(session: String, block: String, unwrap: Bool) async throws -> String {
        var read = RexTerminalRead.format(unwrap: unwrap)
        var text = Data()
        while true {
            var args: [String: JSONValue] = ["max_bytes": .number(983_040)]
            let method: String
            switch read {
            case .format:
                method = "format"
                args["format"] = .string("text")
                args["unwrap"] = .bool(unwrap)
                args["trim"] = .bool(true)
            case .blobRead(let id, let offset):
                method = "blob_read"
                args["id"] = .number(Double(id))
                args["offset"] = .number(Double(offset))
            default:
                throw LabError.unreadable("text")
            }
            let result = try await control.call(
                RexInventoryWire.terminalMethod(method),
                payload: JSONValue.object([
                    "session_id": .string(session), "block_id": .string(block), "args": .object(args),
                ])
            ).result(JSONValue.self)
            guard case .page(let bytes, let next) = RexTerminalReads.answer(to: read, result) else {
                throw LabError.unreadable(method)
            }
            text.append(bytes)
            guard let next else { return String(decoding: text, as: UTF8.self) }
            read = .blobRead(id: next, offset: text.count)
        }
    }

    nonisolated func title(session: String, block: String) async throws -> String {
        let result = try await control.call(
            RexInventoryWire.terminalMethod("title"),
            payload: JSONValue.object(["session_id": .string(session), "block_id": .string(block)])
        ).result(JSONValue.self)
        return result["title"]?.stringValue ?? ""
    }

    /// Destroys every session this lab created, then counts what is left:
    /// lab sessions by their label's prefix, and sessions in all.
    func destroyEverything() async -> (lab: Int, total: Int) {
        for id in created {
            _ = try? await control.call("session.destroy", payload: JSONValue.object(["session_id": .string(id)]))
        }
        created = []
        guard let listed = try? await control.call("session.list").result(JSONValue.self),
            case .array(let sessions)? = listed["sessions"]
        else { return (-1, -1) }
        let lab = sessions.count(where: { $0["label"]?.stringValue?.hasPrefix(Self.labelPrefix) == true })
        return (lab, sessions.count)
    }

    enum LabError: Error {
        case unreadable(String)
    }
}

/// One stream painted into one Ghostty terminal.
@MainActor
final class StreamRun {
    let stream: RexTerminalStream
    let replica: GhosttyReplica
    private var consumer: Task<Void, Never>?

    private init(stream: RexTerminalStream, replica: GhosttyReplica) {
        self.stream = stream
        self.replica = replica
    }

    static func start(
        lab: RexLab, session: String, block: String, options: RexTerminalStream.Options = .init(),
        beforeStart: () async throws -> Void = {}
    ) async throws -> StreamRun {
        let replica = try await GhosttyReplica.make()
        let stream = RexTerminalStream(session: session, block: block, route: lab.route, options: options)
        let run = StreamRun(stream: stream, replica: replica)
        try await beforeStart()
        await stream.start()
        run.consumer = Task { @MainActor [stream, replica] in
            while let instruction = await stream.next() {
                replica.apply(instruction)
            }
        }
        return run
    }

    /// Waits until a paint is in, it is not dirty, and nothing arrived for a
    /// while.
    func settle(paintsAbove paints: Int = 0, timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let status = await stream.status
            if status.isPainted, !status.isDirty, status.paintCount > paints,
                ContinuousClock.now - replica.lastChange > .milliseconds(600)
            {
                return
            }
            if let ended = replica.ended {
                Issue.record("The stream ended: \(ended)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let status = await stream.status
        Issue.record(
            "The stream did not settle: painted \(status.isPainted), dirty \(status.isDirty), paints \(status.paintCount)")
    }

    func stop() async {
        await stream.stop()
        _ = await consumer?.value
        replica.tearDown()
    }
}

/// Heeler's Ghostty terminal in a window of its own, fed a stream's
/// instructions.
@MainActor
final class GhosttyReplica {
    let terminal: HeelerTerminalView
    let window: UIWindow
    let grid: LocalGrid
    private(set) var serverGrid: RexTerminalGrid?
    private(set) var title: String?
    private(set) var ended: RexTerminalEnd?
    private(set) var lastChange = ContinuousClock.now

    private init(terminal: HeelerTerminalView, window: UIWindow, grid: LocalGrid) {
        self.terminal = terminal
        self.window = window
        self.grid = grid
    }

    static func make() async throws -> GhosttyReplica {
        var size: (columns: Int, rows: Int)?
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { size = ($0, $1) }, notificationCenter: NotificationCenter())
        let controller = UIViewController()
        controller.view = terminal
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 520, height: 420)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        terminal.layoutIfNeeded()
        for _ in 0..<300
        where terminal.viewportRows == nil || size?.rows != terminal.viewportRows
            || terminal.terminalSession.readViewportText() == nil
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let measured = try #require(size)
        return GhosttyReplica(
            terminal: terminal, window: window, grid: LocalGrid(columns: measured.columns, rows: measured.rows))
    }

    func apply(_ instruction: RexTerminalInstruction) {
        lastChange = .now
        switch instruction {
        case .grid(let grid): serverGrid = grid
        case .paint(let bytes, _): terminal.receive(bytes)
        case .feed(let bytes): terminal.receive(bytes)
        case .title(let title): self.title = title
        case .theme, .exited, .restarting: break
        case .ended(let end): ended = end
        }
    }

    func viewportText() -> String {
        terminal.terminalSession.readViewportText() ?? ""
    }

    /// Everything the terminal holds, history included, with soft wraps
    /// joined, as a selection of it all reads.
    func allText() -> String {
        _ = terminal.surface?.performBindingAction("select_all")
        let text = terminal.surface?.readSelection() ?? ""
        _ = terminal.surface?.performBindingAction("clear_selection")
        return text
    }

    /// Ghostty applies output off the main thread: waits until two reads a
    /// moment apart agree.
    func waitForSettledText() async throws {
        var last = allText()
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let next = allText()
            if next == last { return }
            last = next
        }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
