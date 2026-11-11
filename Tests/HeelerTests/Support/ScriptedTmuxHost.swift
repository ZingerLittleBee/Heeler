import Foundation

@testable import Heeler

/// A Host with a tmux on it, for tests of the tmux transport, detection and
/// everything above them. It answers the probe's script from what the script
/// asks: which executable, which socket, through the login shell or not.
///
/// Each server lists the panes a test gives it, and an inventory loop opened
/// on it prints them as the real script would: once, then on each change,
/// with a pane's arguments only when its command or the program its status
/// names changed. The loop speaks the script's own text (`TmuxLoopText`), so
/// the app's reader is the one under test. A `runTmuxCommand` applies
/// `new-window`, `new-session`, `rename-session`, `kill-pane`,
/// `kill-window` and `set-option` to those panes, and a discovery script lists
/// `installedExecutables`. `show-environment -g` prints the global lines a
/// test planted, and `show-environment -t` prints a session delta only when
/// the target is a session id (`$n`). The Helper's `locate` script prints the
/// Host's home and data home, a script placing Heeler's Claude Code hook files
/// writes each here-document into `hostFiles`, and the connection reads those
/// files back as SFTP would.
actor ScriptedTmuxHost: TmuxHostConnection, ServerKindDetectionConnection {
    static let nonce = "scripted-tmux-host-nonce"
    static let executable = "/opt/homebrew/bin/tmux"
    static let directory = "/private/tmp/tmux-501"
    static let instance = TmuxServerInstance(pid: 4242, startTime: 1_794_326_988)
    static let home = "/Users/dev"

    static func socketPath(_ name: String = "default", in directory: String = directory) -> String {
        "\(directory)/\(name)"
    }

    static func paths(_ name: String = "default") -> TmuxPaths {
        guard let paths = TmuxPaths(executable: executable, socket: socketPath(name)) else {
            preconditionFailure("The scripted tmux paths are valid")
        }
        return paths
    }

    nonisolated let routeID: UUID? = nil
    private let kernel: String
    /// `$SHELL` of the probe, which a launch wraps the agent in.
    let shell: String
    /// Programs discovery reports, in the order it prints them.
    var installedExecutables: [String] = ["claude"]
    /// OpenCode's own version line, printed only when a test sets one.
    var openCodeVersion: String?
    /// Each `runTmuxCommand` script, in order, including one that failed.
    private(set) var commands: [String] = []
    private var nextProcessID = 8000
    /// Every tmux on the Host, by path, with what its `-V` prints.
    private var executables: [String: String]
    /// The tmux the login shell's `PATH` finds.
    private var loginExecutable: String?
    /// The tmux directory the login shell's `TMUX_TMPDIR` names.
    private var loginDirectory: String
    /// The servers that answer, by socket path.
    private var servers: [String: TmuxServerInstance]
    /// What each server lists, by socket path, in `list-panes -a` order. A
    /// pane's `foregroundArguments` are what the Host would read of it now.
    private var panes: [String: [TmuxInventory.Pane]] = [:]
    /// Raw `show-environment -g` lines, by socket. A session map is that
    /// session's delta, keyed by `$n`.
    private var globalEnvironment: [String: [String]] = [:]
    private var sessionEnvironment: [String: [String: [String]]] = [:]
    /// When set, `show-environment` exits with this status and prints nothing.
    private var showEnvironmentStatus: Int32?
    private var loops: [UInt64: Loop] = [:]
    private var nextLoop: UInt64 = 0
    private var loopFailures: [TransportError] = []
    /// Each inventory loop's exec, opened and closed, in order.
    private(set) var loopLog: [String] = []
    private(set) var loopScripts: [String] = []
    private var failures: [TransportError] = []
    private var nextAnswers: [GitExecResult] = []
    private var foregroundFailures: [TransportError] = []
    private var nextForegroundAnswers: [GitExecResult] = []
    private var foregroundPIDs: [String: [String: Int?]] = [:]
    private(set) var foregroundScripts: [String] = []
    private var onNextPaste: (@Sendable () async -> Void)?
    private var connected = true
    /// The Host Helper seam on the same scripted file tree, rooted at `Self.home`.
    nonisolated let helper: ScriptedHelperHost
    private var refusesHookFiles = false
    private struct SeededProcess {
        var variables: [String: String?]
        var name: String?
        var parent: Int?
    }
    private var seededProcesses: [Int: SeededProcess] = [:]
    private var unavailableProcesses: Set<Int> = []
    private var allProcessesUnavailable = false
    private(set) var processVariableReads: [String] = []

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []

    /// A Mac with Homebrew's tmux, and a server on each of `sockets`.
    init(
        executable: String? = ScriptedTmuxHost.executable, version: String = "tmux 3.7b",
        directory: String = ScriptedTmuxHost.directory, sockets: [String] = ["default"],
        kernel: String = "Darwin", shell: String = "/bin/zsh"
    ) {
        self.kernel = kernel
        self.shell = shell
        helper = ScriptedHelperHost(home: Self.home, kernel: kernel)
        executables = executable.map { [$0: version] } ?? [:]
        loginExecutable = executable
        loginDirectory = directory
        servers = Dictionary(
            uniqueKeysWithValues: sockets.enumerated().map { index, name in
                (
                    Self.socketPath(name, in: directory),
                    TmuxServerInstance(pid: Self.instance.pid + index, startTime: Self.instance.startTime)
                )
            })
    }

    // MARK: What the user does on the Host

    /// A server starts on the socket, listing `panes`. Where one was answering
    /// there, this one took its place between two asks, unnoticed by a loop.
    func startServer(
        _ name: String = "default", instance: TmuxServerInstance = ScriptedTmuxHost.instance,
        panes listed: [TmuxInventory.Pane] = []
    ) async {
        let socket = Self.socketPath(name, in: loginDirectory)
        if servers[socket] != nil { await endControlClients(on: socket) }
        servers[socket] = instance
        panes[socket] = listed
        windowSizes[socket] = nil
        windowLayouts[socket] = nil
        desktopClients[socket] = nil
        bracketedPasteFlags[socket] = nil
        paneOutputModes[socket] = nil
        foregroundPIDs[socket] = nil
        await printChanges(on: socket)
    }

    /// Stopped or killed: a socket file left behind answers no better than none.
    func stopServer(_ name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        servers[socket] = nil
        panes[socket] = nil
        windowSizes[socket] = nil
        windowLayouts[socket] = nil
        desktopClients[socket] = nil
        bracketedPasteFlags[socket] = nil
        paneOutputModes[socket] = nil
        foregroundPIDs[socket] = nil
        await endControlClients(on: socket)
        await printChanges(on: socket)
    }

    /// Lines `show-environment -g` prints. Values stay in the answer, as tmux
    /// prints them; the app is what must drop them.
    func setGlobalEnvironment(_ lines: [String], on name: String = "default") {
        globalEnvironment[Self.socketPath(name, in: loginDirectory)] = lines
    }

    /// Lines `show-environment -t` prints for one session id.
    func setSessionEnvironment(_ lines: [String], session: String, on name: String = "default") {
        let socket = Self.socketPath(name, in: loginDirectory)
        var sessions = sessionEnvironment[socket] ?? [:]
        sessions[session] = lines
        sessionEnvironment[socket] = sessions
    }

    /// The next `show-environment` fails, until this is cleared.
    func failShowEnvironment(_ failed: Bool) {
        showEnvironmentStatus = failed ? 1 : nil
    }

    /// What the server lists from now on, as a second later a loop has seen it.
    func setPanes(_ listed: [TmuxInventory.Pane], on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        panes[socket] = listed
        await printChanges(on: socket)
    }

    /// One change to what the server lists.
    func changePanes(
        on name: String = "default", _ change: @Sendable (inout [TmuxInventory.Pane]) -> Void
    ) async {
        let socket = Self.socketPath(name, in: loginDirectory)
        var listed = panes[socket] ?? []
        change(&listed)
        panes[socket] = listed
        await printChanges(on: socket)
    }

    /// The tmux moves, as a package manager's upgrade can move it.
    func moveExecutable(to path: String, version: String = "tmux 3.7b") {
        executables = [path: version]
        loginExecutable = path
    }

    func uninstall() {
        executables = [:]
        loginExecutable = nil
    }

    /// The login shell's files name another tmux directory, and the servers are there.
    func moveDirectory(to directory: String) {
        let names = servers.map { (String($0.key.dropFirst(loginDirectory.count + 1)), $0.value) }
        let listed = panes.map { (String($0.key.dropFirst(loginDirectory.count + 1)), $0.value) }
        loginDirectory = directory
        servers = Dictionary(uniqueKeysWithValues: names.map { (Self.socketPath($0.0, in: directory), $0.1) })
        panes = Dictionary(uniqueKeysWithValues: listed.map { (Self.socketPath($0.0, in: directory), $0.1) })
    }

    func failNextProbe(_ error: TransportError) {
        failures.append(error)
    }

    func answerNextProbe(stdout: String, exitStatus: Int32 = 0) {
        nextAnswers.append(GitExecResult(stdout: Data(stdout.utf8), stderr: Data(), exitStatus: exitStatus))
    }

    func failNextForeground(_ error: TransportError) {
        foregroundFailures.append(error)
    }

    func answerNextForeground(stdout: String, exitStatus: Int32 = 0) {
        nextForegroundAnswers.append(GitExecResult(stdout: Data(stdout.utf8), stderr: Data(), exitStatus: exitStatus))
    }

    /// Overrides the foreground process-group leader pid (`tpgid`) `readPaneForeground`
    /// reports for `pane`; `.some(nil)` simulates no readable live leader.
    func setForegroundPID(_ pid: Int?, of pane: String, on name: String = "default") {
        let socket = Self.socketPath(name, in: loginDirectory)
        foregroundPIDs[socket, default: [:]][pane] = .some(pid)
    }

    /// Runs right after the next `paste-buffer` executes, before its reply leaves.
    func afterNextPaste(_ hook: @escaping @Sendable () async -> Void) {
        onNextPaste = hook
    }

    func clearLog() {
        log = []
        scripts = []
        commands = []
        foregroundScripts = []
    }

    /// What discovery reports, and the OpenCode version a later launch may name.
    func setInstalled(_ executables: [String], openCodeVersion: String? = nil) {
        installedExecutables = executables
        self.openCodeVersion = openCodeVersion
    }

    // MARK: The inventory loop

    private struct Loop {
        let dial: UInt64
        let socket: String
        let executable: String
        let nonce: String
        let channel: ScriptedTmuxLoopChannel
        /// What the loop last printed, and what each pane ran when its
        /// arguments were last read.
        var printed: TmuxInventory?
        var signatures: [String: String] = [:]
    }

    /// The loops running now.
    var openLoops: Int { loops.count }

    func failNextLoop(_ error: TransportError) {
        loopFailures.append(error)
    }

    /// Every loop says it is alive, as it does every few asks with no change.
    func sayAlive() async {
        for loop in loops.values {
            await loop.channel.send(TmuxLoopText.alive(nonce: loop.nonce))
        }
    }

    /// Every loop's exec fails, as it does when its channel breaks.
    func breakLoops(_ error: TransportError = .channelFailed(detail: "the loop's channel broke")) async {
        let broken = loops
        loops = [:]
        for loop in broken.values { await loop.channel.fail(error) }
    }

    func openTmuxInventoryLoop(_ script: Data) async throws -> any WindowsTerminalExecChannel {
        try await openLoop(script, dial: 0)
    }

    private func openLoop(_ script: Data, dial: UInt64) async throws -> any WindowsTerminalExecChannel {
        let body = String(decoding: script, as: UTF8.self)
        loopScripts.append(body)
        if !loopFailures.isEmpty { throw loopFailures.removeFirst() }
        nextLoop += 1
        let id = nextLoop
        loopLog.append("open")
        let channel = ScriptedTmuxLoopChannel { [weak self] in await self?.noteLoopClosed(id) }
        loops[id] = Loop(
            dial: dial, socket: Self.assigned("s", in: body), executable: Self.assigned("t", in: body),
            nonce: Self.assigned("n", in: body), channel: channel)
        await print(id)
        return channel
    }

    /// Every exec is closed once, whichever side ended its loop.
    private func noteLoopClosed(_ id: UInt64) {
        loopLog.append("close")
        loops[id] = nil
    }

    private func printChanges(on socket: String) async {
        for (id, loop) in loops where loop.socket == socket { await print(id) }
    }

    /// One ask of one loop: a snapshot if the answer changed, and the end of
    /// the loop if nothing answered.
    private func print(_ id: UInt64) async {
        guard var loop = loops[id] else { return }
        guard let instance = servers[loop.socket], executables[loop.executable] != nil else {
            loops[id] = nil
            await loop.channel.send(TmuxLoopText.gone(nonce: loop.nonce))
            await loop.channel.finish()
            return
        }
        let listed = panes[loop.socket] ?? []
        var rows = listed
        for index in rows.indices { rows[index].foregroundArguments = nil }
        let answer = TmuxInventory(instance: instance, panes: rows)
        guard loop.printed != answer else { return }
        var signatures: [String: String] = [:]
        var arguments: [(pane: String, arguments: TmuxLoopText.Arguments)] = []
        for pane in listed where signatures[pane.paneID] == nil {
            let signature = "\(pane.processID):\(pane.isDead):\(pane.command):\(Self.reportedApp(pane.status))"
            signatures[pane.paneID] = signature
            if !pane.isDead, loop.signatures[pane.paneID] != signature {
                arguments.append((pane.paneID, pane.foregroundArguments.map { .list($0) } ?? .unreadable))
            }
        }
        loop.printed = answer
        loop.signatures = signatures
        loops[id] = loop
        await loop.channel.send(
            TmuxLoopText.snapshot(rows, instance: instance, arguments: arguments, nonce: loop.nonce))
    }

    /// The program a status names, as the loop's script reads it.
    private static func reportedApp(_ status: String) -> String {
        status.split(whereSeparator: { " :;,\t\n".contains($0) })
            .last { $0.hasPrefix("app=") }.map { String($0.dropFirst(4)) } ?? ""
    }

    /// The value a script assigns `name` on a line of its own.
    private static func assigned(_ name: String, in script: String) -> String {
        guard let line = script.split(separator: "\n").first(where: { $0.hasPrefix("\(name)='") }) else { return "" }
        return String(line.dropFirst(name.count + 2).dropLast())
    }

    private func closeLoops(ofDial dial: UInt64) async {
        let closed = loops.filter { $0.value.dial == dial }
        for (id, loop) in closed {
            loops[id] = nil
            await loop.channel.fail(.sshUnreachable(detail: "The SSH connection is closed."))
        }
    }

    // MARK: Control clients (ADR 0043)

    /// A terminal client of the user's attached to a session on the Host.
    struct DesktopClient: Equatable, Sendable {
        var name = "/dev/ttys001"
        var sessionID = "$0"
        var sessionName = "main"
        var windowID: String
        var width: Int
        var height: Int
        var status = "on"
        var ignoringSize = false
        var controlMode = false

        var statusLineCount: Int {
            switch status {
            case "off": 0
            case "on": 1
            default: max(0, Int(status) ?? 1)
            }
        }

        var windowSize: (width: Int, height: Int) {
            let lines = statusLineCount
            let rows = height > lines ? height - lines : height
            return (width: width, height: rows)
        }

        var flags: String {
            var list = ["attached", "focused"]
            if controlMode { list.append("control-mode") }
            if ignoringSize { list.append("ignore-size") }
            return list.joined(separator: ",")
        }
    }

    typealias WindowLayout = @Sendable (_ width: Int, _ height: Int) -> [String: (width: Int, height: Int)]

    /// Side-by-side panes separated by 1-column borders, as `split-window -h` lays them out.
    static func horizontalSplit(_ paneIDs: [String]) -> WindowLayout {
        { width, height in
            guard !paneIDs.isEmpty else { return [:] }
            let usable = max(paneIDs.count, width - (paneIDs.count - 1))
            let base = usable / paneIDs.count
            let extra = usable % paneIDs.count
            let rowHeight = max(1, height)
            return Dictionary(
                uniqueKeysWithValues: paneIDs.enumerated().map { index, paneID in
                    (paneID, (width: max(1, base + (index < extra ? 1 : 0)), height: rowHeight))
                })
        }
    }

    /// Stacked panes separated by 1-row borders, as `split-window -v` lays them out.
    static func verticalSplit(_ paneIDs: [String]) -> WindowLayout {
        { width, height in
            guard !paneIDs.isEmpty else { return [:] }
            let usable = max(paneIDs.count, height - (paneIDs.count - 1))
            let base = usable / paneIDs.count
            let extra = usable % paneIDs.count
            let columnWidth = max(1, width)
            return Dictionary(
                uniqueKeysWithValues: paneIDs.enumerated().map { index, paneID in
                    (paneID, (width: columnWidth, height: max(1, base + (index < extra ? 1 : 0))))
                })
        }
    }

    /// One Attach's control client, in its session of Heeler's own.
    private struct ControlClient {
        let dial: UInt64
        let executable: String
        let socket: String
        let channel: ScriptedTmuxLoopChannel
        let sessionName: String
        let sessionID: String
        /// The pane the Attach shows, as the server listed it when it attached.
        let pane: TmuxInventory.Pane
        /// The window the session links; nil while it holds only its placeholder.
        let window: String?
        var ignoringSize = false
        var windowSizes: [String: (width: Int, height: Int)] = [:]
    }

    private var controlClients: [UInt64: ControlClient] = [:]
    private var nextControlClient: UInt64 = 0
    private var nextCommandNumber: UInt64 = 1000
    private var nextSessionID = 100
    /// What each pane shows, by socket and pane id, a line a row. A pane with
    /// none shows blank rows.
    private var screens: [String: [String: [String]]] = [:]
    private var windowSizes: [String: [String: (width: Int, height: Int)]] = [:]
    private var windowLayouts: [String: [String: WindowLayout]] = [:]
    private var desktopClients: [String: [DesktopClient]] = [:]
    /// Each control client's script, and every line any of them wrote, in order.
    private(set) var controlScripts: [String] = []
    private(set) var controlCommands: [String] = []
    /// Control clients that answer nothing at all, for attaches that time out.
    private var silentControlClients = 0
    /// What `#{pane_key_mode}` reads for a pane, by pane id: `VT10x`, as under
    /// tmux's default `extended-keys off`, unless set.
    private var keyModes: [String: String] = [:]
    private var bracketedPasteFlags: [String: [String: Bool]] = [:]
    private var paneOutputModes: [String: [String: TerminalModeTracker]] = [:]
    /// The server's paste buffers, by name, and pastes still to fail.
    private(set) var buffers: [String: String] = [:]
    private var failingPastes = 0
    private var failingSendKeys = 0
    /// When true, outgoing control-mode replies wait in FIFO order while
    /// incoming commands still arrive in `controlCommands`.
    private var holdingControlReplies = false
    private var heldControlReplies: [(client: UInt64, data: Data, changedWindows: [String], socket: String)] = []

    var openControlClients: Int { controlClients.count }

    /// The names of the sessions Attaches made that are still there.
    var attachSessions: [String] { controlClients.values.map(\.sessionName).sorted() }

    func setScreen(_ rows: [String], of pane: String, on name: String = "default") {
        screens[Self.socketPath(name, in: loginDirectory), default: [:]][pane] = rows
    }

    func setWindow(
        _ window: String, width: Int, height: Int, on name: String = "default", layout: WindowLayout? = nil
    ) async {
        let socket = Self.socketPath(name, in: loginDirectory)
        windowSizes[socket, default: [:]][window] = (width, height)
        windowLayouts[socket, default: [:]][window] = layout
        applyWindowSize((width, height), to: window, on: socket)
        await notifyLayoutChanges([window], on: socket)
    }

    func setDesktopClients(_ clients: [DesktopClient], on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        let before = Set((desktopClients[socket] ?? []).map(\.windowID))
        desktopClients[socket] = clients
        let windows = before
            .union(clients.map(\.windowID))
            .union((panes[socket] ?? []).map(\.windowID))
            .union(windowSizes[socket]?.keys.map { $0 } ?? [])
        var changed: [String] = []
        for window in windows.sorted() where recalculateWindow(window, on: socket, desktopTookLatest: true) {
            changed.append(window)
        }
        await notifyLayoutChanges(changed, on: socket)
    }

    /// A client attaches or switches session without resizing the window first
    /// (as under `window-size largest`, where tmux takes Heeler's larger size):
    /// only `%client-session-changed` tells control clients to re-read clients.
    func attachDesktopClient(_ client: DesktopClient, on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        var list = desktopClients[socket] ?? []
        if let index = list.firstIndex(where: { $0.name == client.name }) {
            list[index] = client
        } else {
            list.append(client)
        }
        desktopClients[socket] = list
        for control in controlClients.values where control.socket == socket {
            await control.channel.send(
                Data("%client-session-changed \(client.name) \(client.sessionID) \(client.sessionName)\n".utf8))
        }
    }

    /// A client detaches; only `%client-detached` notifies control clients.
    func detachDesktopClient(named clientName: String, on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        desktopClients[socket]?.removeAll { $0.name == clientName }
        for control in controlClients.values where control.socket == socket {
            await control.channel.send(Data("%client-detached \(clientName)\n".utf8))
        }
    }

    /// A session switches its current window; only `%session-window-changed`
    /// notifies control clients.
    func switchDesktopWindow(sessionID: String, to windowID: String, on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        if var list = desktopClients[socket] {
            for index in list.indices where list[index].sessionID == sessionID {
                list[index].windowID = windowID
            }
            desktopClients[socket] = list
        }
        for control in controlClients.values where control.socket == socket {
            await control.channel.send(Data("%session-window-changed \(sessionID) \(windowID)\n".utf8))
        }
    }

    /// Holds or releases FIFO control-mode replies so tests can observe commands
    /// written while an earlier sizing read is still in flight.
    func holdControlReplies(_ held: Bool) async {
        holdingControlReplies = held
        guard !held else { return }
        let queued = heldControlReplies
        heldControlReplies = []
        for item in queued {
            if let client = controlClients[item.client] {
                await client.channel.send(item.data)
            }
            await notifyLayoutChanges(item.changedWindows, on: item.socket)
        }
    }

    func windowSize(_ window: String, on name: String = "default") -> (width: Int, height: Int) {
        currentWindowSize(of: window, on: Self.socketPath(name, in: loginDirectory))
    }

    func paneSize(_ pane: String, on name: String = "default") -> (width: Int, height: Int)? {
        let socket = Self.socketPath(name, in: loginDirectory)
        return panes[socket]?.first { $0.paneID == pane }.map { ($0.width, $0.height) }
    }

    func controlClientsIgnoringSize(on name: String = "default") -> [Bool] {
        let socket = Self.socketPath(name, in: loginDirectory)
        return controlClients.keys.sorted().compactMap { id in
            guard let client = controlClients[id], client.socket == socket else { return nil }
            return client.ignoringSize
        }
    }

    /// What `#{pane_key_mode}` reads for `pane` from now on: `Ext 1` or
    /// `Ext 2` once its program asked for extended keys, empty before tmux 3.5.
    func setKeyMode(_ mode: String, of pane: String) {
        keyModes[pane] = mode
    }

    /// What `#{bracket_paste_flag}` reads for `pane` on tmux 3.7 and later.
    func setBracketedPaste(_ enabled: Bool, of pane: String, on name: String = "default") {
        let socket = Self.socketPath(name, in: loginDirectory)
        bracketedPasteFlags[socket, default: [:]][pane] = enabled
    }

    /// A buffer of the user's own, which no paste of Heeler's may touch.
    func setBuffer(_ text: String, named name: String) {
        buffers[name] = text
    }

    /// The next `paste-buffer` fails, as it does when its pane went away,
    /// and leaves its buffer.
    func failNextPaste() {
        failingPastes += 1
    }

    /// The next `send-keys` fails, as it does when its pane went away.
    func failNextSendKeys() {
        failingSendKeys += 1
    }

    func silenceNextControlClient() {
        silentControlClients += 1
    }

    /// The pane prints `text`, which every client whose session links its window reads.
    func paneOutput(_ text: String, in pane: String, on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        var tracker = paneOutputModes[socket]?[pane] ?? TerminalModeTracker()
        tracker.receive(Data(text.utf8))
        paneOutputModes[socket, default: [:]][pane] = tracker
        if let setting = tracker.bracketedPasteSetting {
            bracketedPasteFlags[socket, default: [:]][pane] = setting
        }
        for client in controlClients.values where client.socket == socket && client.window == window(of: pane, client) {
            await client.channel.send(Data("%output \(pane) \(Self.escaped(text))\n".utf8))
        }
    }

    /// The client fell `pause-after` behind, and tmux paused the pane for it.
    func pause(_ pane: String, on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        for client in controlClients.values where client.socket == socket && client.pane.paneID == pane {
            await client.channel.send(Data("%pause \(pane)\n".utf8))
        }
    }

    /// The user ends every session of theirs that holds the pane's window:
    /// only Heeler's sessions hold it from then on.
    func endUserSessions(holding pane: String, on name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        guard let window = panes[socket]?.first(where: { $0.paneID == pane })?.windowID else { return }
        panes[socket]?.removeAll { $0.windowID == window }
        for client in controlClients.values where client.socket == socket && client.window == window {
            await client.channel.send(Data("%sessions-changed\n%window-close \(window)\n".utf8))
        }
        await printChanges(on: socket)
    }

    private func window(of pane: String, _ client: ControlClient) -> String? {
        panes[client.socket]?.first { $0.paneID == pane }?.windowID ?? (pane == client.pane.paneID ? client.window : nil)
    }

    func openTmuxControlClient(_ script: Data) async throws -> any WindowsTerminalExecChannel {
        try await openControlClient(script, dial: 0)
    }

    fileprivate func openControlClient(_ script: Data, dial: UInt64) async throws -> any WindowsTerminalExecChannel {
        let body = String(decoding: script, as: UTF8.self)
        controlScripts.append(body)
        nextControlClient += 1
        let id = nextControlClient
        let channel = ScriptedTmuxLoopChannel(
            onWrite: { [weak self] data in await self?.controlClientWrote(data, client: id) },
            onClose: { [weak self] in await self?.noteControlClientClosed(id) })
        if silentControlClients > 0 {
            silentControlClients -= 1
            return channel
        }
        let socket = Self.assigned("s", in: body)
        let words = body.split(separator: "\n").first { $0.hasPrefix("exec ") }?.split(separator: " ").map(String.init) ?? []
        let sessionName = words.firstIndex(of: "-s").map { words[$0 + 1] } ?? ""
        let paneID = words.firstIndex(of: "@heeler-attach").map { words[$0 + 1].replacingOccurrences(of: "'", with: "") } ?? ""
        // With `-N` and no server, tmux says so on standard error and exits.
        let executable = Self.assigned("t", in: body)
        guard servers[socket] != nil, executables[executable] != nil else {
            await channel.finish()
            return channel
        }
        nextSessionID += 1
        let sessionID = "$\(nextSessionID)"
        let pane = panes[socket]?.first { $0.paneID == paneID }
        controlClients[id] = ControlClient(
            dial: dial, executable: executable, socket: socket, channel: channel, sessionName: sessionName,
            sessionID: sessionID,
            pane: pane ?? .make(pane: Int(paneID.dropFirst()) ?? 0, command: "sleep"), window: pane?.windowID)
        // One block for each start command, up to the first that fails.
        var start = (0..<3).map { _ in block([], fromClient: false) }
        if pane != nil {
            start += [block([], fromClient: false), block([], fromClient: false)]
        } else {
            start.append(block(["can't find pane: \(paneID)"], succeeded: false, fromClient: false))
        }
        start.append("%sessions-changed\n%session-changed \(sessionID) \(sessionName)\n")
        await channel.send(Data(start.joined().utf8))
        return channel
    }

    private func block(_ lines: [String], succeeded: Bool = true, fromClient: Bool = true) -> String {
        nextCommandNumber += 1
        let fields = "1794339265 \(nextCommandNumber) \(fromClient ? 1 : 0)"
        return (["%begin \(fields)"] + lines + ["\(succeeded ? "%end" : "%error") \(fields)"]).joined(separator: "\n") + "\n"
    }

    private func controlClientWrote(_ data: Data, client id: UInt64) async {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            controlCommands.append(String(line))
            guard let client = controlClients[id] else { return }
            let words = Self.words(of: String(line))
            let (reply, changedWindows) = answer(words, from: client, id: id)
            if words.first == "paste-buffer", reply.contains("\n%end "), let hook = onNextPaste {
                onNextPaste = nil
                await hook()
            }
            let replyBytes = Data(reply.utf8)
            if holdingControlReplies {
                heldControlReplies.append(
                    (client: id, data: replyBytes, changedWindows: changedWindows, socket: client.socket))
            } else {
                await client.channel.send(replyBytes)
                await notifyLayoutChanges(changedWindows, on: client.socket)
            }
            if let ended = ending(after: words, from: client) {
                for other in ended { await endControlClient(other) }
            }
        }
    }

    /// What tmux replies to one command a client wrote, and the windows whose
    /// layout changed because of it.
    private func answer(
        _ words: [String], from client: ControlClient, id: UInt64
    ) -> (reply: String, changedWindows: [String]) {
        let listed = panes[client.socket] ?? []
        let pane = listed.first { $0.paneID == client.pane.paneID } ?? client.pane
        switch words.first {
        case "list-panes" where words.contains("-s"):
            let server = servers[client.socket].map { "\($0.pid) \($0.startTime)" } ?? "0 0"
            guard let window = client.window else { return (block(["\(server) \(client.sessionID) @99 %99"]), []) }
            let rows = Set(listed.filter { $0.windowID == window }.map(\.paneID)).union([pane.paneID]).sorted()
            return (block(rows.map { "\(server) \(client.sessionID) \(window) \($0)" }), [])
        case "list-panes":
            guard let window = client.window else { return (block([]), []) }
            let users = Set(listed.filter { $0.windowID == window }.map(\.sessionID)).sorted().map { "\($0) \(window) 0" }
            let heeler = controlClients.values.filter { $0.socket == client.socket && $0.window == window }
                .map { "\($0.sessionID) \(window) 1" }.sorted()
            return (block(users + heeler), [])
        case "list-clients" where words.contains(TmuxPaneSize.clientsFormat):
            let desktops = (desktopClients[client.socket] ?? []).map { desktop in
                "\(desktop.controlMode ? 1 : 0) \(desktop.windowID) \(desktop.width) \(desktop.height) \(desktop.status) \(desktop.flags)"
            }
            let controls = controlClients.keys.sorted().compactMap { key -> String? in
                guard let other = controlClients[key], other.socket == client.socket else { return nil }
                var flags = ["attached", "focused", "control-mode"]
                if other.ignoringSize { flags.append("ignore-size") }
                return "1 \(other.window ?? "@99") 80  on \(flags.joined(separator: ","))"
            }
            return (block(desktops + controls), [])
        case "display-message" where words.contains(TmuxKey.paneKeyModeFormat):
            let target = words.firstIndex(of: "-t").map { words[$0 + 1] } ?? pane.paneID
            return (block([keyModes[target] ?? "VT10x"]), [])
        case "display-message" where words.contains(TmuxPaneSize.geometryFormat):
            let target = Self.value(of: "-t", in: words) ?? pane.paneID
            guard let found = listed.first(where: { $0.paneID == target }) else {
                return (block(["can't find pane: \(target)"], succeeded: false), [])
            }
            let winSize = currentWindowSize(of: found.windowID, on: client.socket)
            return (
                block(["\(found.windowID) \(winSize.width) \(winSize.height) \(found.width) \(found.height)"]), []
            )
        case "display-message":
            let width = pane.width, height = pane.height
            let reportsFlag =
                executables[client.executable].flatMap(TmuxVersion.init(versionLine:))?.reportsBracketedPaste ?? true
            let bracketFlag: String
            if reportsFlag {
                bracketFlag = bracketedPasteFlags[client.socket]?[pane.paneID] == true ? "1" : "0"
            } else {
                bracketFlag = ""
            }
            return (
                block([
                    "\(pane.paneID) \(client.window ?? "@99") \(width) \(height) 0 0 0 1 0 0 0 0 \(height - 1) 0 0 0 0 0 0 0 0 1 0 \(bracketFlag)"
                ]), []
            )
        case "capture-pane":
            if words.contains("-a") { return (block([]), []) }
            let rows: [String]
            if let explicit = screens[client.socket]?[pane.paneID] {
                rows = Array(explicit.prefix(pane.height))
                    + Array(repeating: "", count: max(0, pane.height - explicit.count))
            } else {
                rows = Array(repeating: "", count: pane.height)
            }
            // With no history, tmux captures the screen's top row for the range.
            return (block(words.contains("-S") ? Array(rows.prefix(1)) : rows), [])
        case "refresh-client":
            if words.contains("-A") {
                return (block(["%continue \(pane.paneID)"]), [])
            }
            guard var updated = controlClients[id] else { return (block([]), []) }
            if let flags = Self.value(of: "-f", in: words) {
                for flag in flags.split(separator: ",").map(String.init) {
                    switch flag {
                    case "ignore-size": updated.ignoringSize = true
                    case "!ignore-size": updated.ignoringSize = false
                    default: break
                    }
                }
            }
            var touchedWindows = Set<String>()
            if let spec = Self.value(of: "-C", in: words), let parsed = Self.parseWindowSizeSpec(spec) {
                updated.windowSizes[parsed.window] = (parsed.width, parsed.height)
                touchedWindows.insert(parsed.window)
            }
            if let linked = updated.window { touchedWindows.insert(linked) }
            controlClients[id] = updated
            var changed: [String] = []
            for window in touchedWindows.sorted() where recalculateWindow(window, on: updated.socket) {
                changed.append(window)
            }
            return (block([]), changed)
        case "kill-window", "kill-session":
            return (block([]), [])
        case "send-keys":
            if failingSendKeys > 0 {
                failingSendKeys -= 1
                return (block(["can't find pane: \(Self.value(of: "-t", in: words) ?? "")"], succeeded: false), [])
            }
            return (block([]), [])
        case "set-buffer":
            guard let name = Self.value(of: "-b", in: words), let text = Self.value(of: "--", in: words) else {
                return (block(["usage: set-buffer"], succeeded: false), [])
            }
            buffers[name] = text
            return (block([]), [])
        case "paste-buffer":
            let name = Self.value(of: "-b", in: words) ?? ""
            if failingPastes > 0 {
                failingPastes -= 1
                return (block(["can't find pane: \(Self.value(of: "-t", in: words) ?? "")"], succeeded: false), [])
            }
            guard buffers[name] != nil else { return (block(["no buffer \(name)"], succeeded: false), []) }
            if words.contains("-d") { buffers[name] = nil }
            return (block([]), [])
        case "delete-buffer":
            let name = Self.value(of: "-b", in: words) ?? ""
            guard buffers.removeValue(forKey: name) != nil else {
                return (block(["unknown buffer: \(name)"], succeeded: false), [])
            }
            return (block([]), [])
        default:
            return (block(["unknown command: \(words.first ?? "")"], succeeded: false), [])
        }
    }

    private static func parseWindowSizeSpec(_ spec: String) -> (window: String, width: Int, height: Int)? {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("@") else { return nil }
        let dimensions = parts[1].split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
            width > 0, height > 0
        else { return nil }
        return (parts[0], width, height)
    }

    private func currentWindowSize(of window: String, on socket: String) -> (width: Int, height: Int) {
        if let explicit = windowSizes[socket]?[window] { return explicit }
        let windowPanes = (panes[socket] ?? []).filter { $0.windowID == window }
        return (
            width: windowPanes.map(\.width).max() ?? 80,
            height: windowPanes.map(\.height).max() ?? 24
        )
    }

    private func recalculateWindow(
        _ window: String, on socket: String, desktopTookLatest: Bool = false
    ) -> Bool {
        let previous = currentWindowSize(of: window, on: socket)
        let desktops = (desktopClients[socket] ?? []).filter { !$0.controlMode && !$0.ignoringSize }
        let controls = controlClients.values.filter { $0.socket == socket }
        let hasNonIgnoringClient =
            !desktops.isEmpty || controls.contains { !$0.ignoringSize && !$0.windowSizes.isEmpty }
        let desktopsOnWindow = desktops.filter { $0.windowID == window }
        let activeControls = controls.compactMap { control -> (width: Int, height: Int)? in
            guard control.window == window, let requested = control.windowSizes[window] else { return nil }
            if control.ignoringSize && hasNonIgnoringClient { return nil }
            return requested
        }

        let next: (width: Int, height: Int)
        if desktopTookLatest, let latestDesktop = desktopsOnWindow.last {
            var width = latestDesktop.windowSize.width
            var height = latestDesktop.windowSize.height
            for requested in activeControls {
                width = min(width, requested.width)
                height = min(height, requested.height)
            }
            next = (TmuxPaneSize.clamp(width), TmuxPaneSize.clamp(height))
        } else if !activeControls.isEmpty {
            let width = activeControls.map(\.width).min() ?? previous.width
            let height = activeControls.map(\.height).min() ?? previous.height
            next = (TmuxPaneSize.clamp(width), TmuxPaneSize.clamp(height))
        } else if let latestDesktop = desktopsOnWindow.last {
            next = (
                TmuxPaneSize.clamp(latestDesktop.windowSize.width),
                TmuxPaneSize.clamp(latestDesktop.windowSize.height)
            )
        } else {
            next = previous
        }

        windowSizes[socket, default: [:]][window] = next
        applyWindowSize(next, to: window, on: socket)
        return next != previous
    }

    private func applyWindowSize(_ size: (width: Int, height: Int), to window: String, on socket: String) {
        guard var listed = panes[socket] else { return }
        let mapped = windowLayouts[socket]?[window]?(size.width, size.height)
        for index in listed.indices where listed[index].windowID == window {
            let paneSize = mapped?[listed[index].paneID] ?? size
            listed[index].width = max(1, paneSize.width)
            listed[index].height = max(1, paneSize.height)
        }
        panes[socket] = listed
    }

    private func notifyLayoutChanges(_ windows: [String], on socket: String) async {
        guard !windows.isEmpty else { return }
        for window in windows {
            for client in controlClients.values where client.socket == socket && client.window == window {
                await client.channel.send(Data("%layout-change \(window)\n".utf8))
            }
        }
        await printChanges(on: socket)
    }

    /// The word after `flag`.
    private static func value(of flag: String, in words: [String]) -> String? {
        guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
        return words[index + 1]
    }

    /// The clients a command ended: a killed window takes the sessions that
    /// held only it, and a killed session its client.
    private func ending(after words: [String], from client: ControlClient) -> [UInt64]? {
        guard let target = words.firstIndex(of: "-t").map({ words[$0 + 1] }) else { return nil }
        switch words.first {
        case "kill-window":
            panes[client.socket]?.removeAll { $0.windowID == target }
            return controlClients.filter { $0.value.socket == client.socket && $0.value.window == target }.map(\.key)
        case "kill-session":
            return controlClients.filter { $0.value.sessionID == target }.map(\.key)
        default:
            return nil
        }
    }

    private func endControlClient(_ id: UInt64) async {
        guard let client = controlClients.removeValue(forKey: id) else { return }
        if let window = client.window, recalculateWindow(window, on: client.socket) {
            await notifyLayoutChanges([window], on: client.socket)
        }
        await client.channel.send(Data("%exit\n".utf8))
        await client.channel.finish()
    }

    private func endControlClients(on socket: String) async {
        for (id, client) in controlClients where client.socket == socket {
            controlClients[id] = nil
            await client.channel.send(Data("%exit server exited unexpectedly\n".utf8))
            await client.channel.finish()
        }
    }

    private func closeControlClients(ofDial dial: UInt64) async {
        var affected: [(socket: String, window: String)] = []
        for (id, client) in controlClients where client.dial == dial {
            controlClients[id] = nil
            if let window = client.window { affected.append((client.socket, window)) }
            await client.channel.fail(.sshUnreachable(detail: "The SSH connection is closed."))
        }
        for item in affected where recalculateWindow(item.window, on: item.socket) {
            await notifyLayoutChanges([item.window], on: item.socket)
        }
    }

    /// The exec closed: tmux read the end of its input, detached the client,
    /// and its session ended with it.
    private func noteControlClientClosed(_ id: UInt64) async {
        guard let client = controlClients.removeValue(forKey: id) else { return }
        if let window = client.window, recalculateWindow(window, on: client.socket) {
            await notifyLayoutChanges([window], on: client.socket)
        }
    }

    /// A command line's words, as tmux's parser reads the quoting Heeler
    /// writes: single quotes keep everything, and in double quotes `\n`, `\r`,
    /// `\t` and `\ooo` are control characters and `\` keeps any other.
    static func words(of line: String) -> [String] {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var inWord = false
        var scalars = line.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if let open = quote, scalar == open {
                quote = nil
            } else if quote == nil, scalar == "'" || scalar == "\"" {
                quote = scalar
                inWord = true
            } else if quote == nil, scalar == "\\", let escaped = scalars.next() {
                // `'it'\''s'` is a single quote written outside the quotes.
                word.append(escaped)
                inWord = true
            } else if quote == nil, scalar == " " {
                if inWord { words.append(String(word)) }
                word = String.UnicodeScalarView()
                inWord = false
            } else if quote == "\"", scalar == "\\", let escaped = scalars.next() {
                switch escaped {
                case "n": word.append("\n")
                case "r": word.append("\r")
                case "t": word.append("\t")
                case "0"..."3":
                    let digits = [escaped, scalars.next(), scalars.next()].compactMap { $0 }
                    let value = digits.reduce(0) { $0 * 8 + ($1.value - 0x30) }
                    if let control = Unicode.Scalar(value) { word.append(control) }
                default: word.append(escaped)
                }
            } else {
                word.append(scalar)
                inWord = true
            }
        }
        if inWord { words.append(String(word)) }
        return words
    }

    /// Pane output as `%output` writes it.
    private static func escaped(_ text: String) -> String {
        var escaped = ""
        for byte in text.utf8 {
            if byte < 0x20 || byte == 0x5C {
                let octal = String(byte, radix: 8)
                escaped += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            } else {
                escaped.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return escaped
    }

    // MARK: The connection

    var isConnected: Bool { connected }

    func close() async throws {
        log.append("close")
        connected = false
        await closeLoops(ofDial: 0)
        await closeControlClients(ofDial: 0)
    }

    /// A new connection to the Host, which closes apart from any other. A
    /// loop silent for `loopSilenceLimit` is lost, as the app's is after its own.
    func transport(
        socketName: String, storedPaths: TmuxPaths?, loopSilenceLimit: Duration = .seconds(30),
        attachStartLimit: Duration = .seconds(5)
    ) -> TmuxSSHTransport {
        nextDial += 1
        return TmuxSSHTransport(
            connection: Dial(host: self, id: nextDial), socketName: socketName, storedPaths: storedPaths,
            nonce: { Self.nonce }, loopSilenceLimit: loopSilenceLimit, attachStartLimit: attachStartLimit)
    }

    private var nextDial: UInt64 = 0
    /// Connections the network dropped.
    private var droppedDials: Set<UInt64> = []

    /// The network drops every connection open now: their execs fail, each
    /// reads closed from then on, and a new connection gets through.
    func dropConnections() async {
        guard nextDial > 0 else { return }
        for dial in UInt64(1)...nextDial where !droppedDials.contains(dial) {
            droppedDials.insert(dial)
            await closeLoops(ofDial: dial)
            await closeControlClients(ofDial: dial)
        }
    }

    fileprivate func isDropped(_ dial: UInt64) -> Bool {
        droppedDials.contains(dial)
    }

    private func noteClose(ofDial dial: UInt64) async {
        log.append("close")
        await closeLoops(ofDial: dial)
        await closeControlClients(ofDial: dial)
    }

    /// One SSH connection to the Host.
    private actor Dial: TmuxHostConnection {
        nonisolated let routeID: UUID? = nil
        private let host: ScriptedTmuxHost
        private let id: UInt64
        private var connected = true

        init(host: ScriptedTmuxHost, id: UInt64) {
            self.host = host
            self.id = id
        }

        var isConnected: Bool {
            get async {
                guard connected else { return false }
                return await !host.isDropped(id)
            }
        }

        private func requireConnected() async throws {
            guard await isConnected else { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
        }

        func runTmuxProbe(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
            if await host.isDropped(id) { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
            return try await host.runTmuxProbe(script, throughLoginShell: throughLoginShell)
        }

        func runTmuxCommand(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
            if await host.isDropped(id) { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
            return try await host.runTmuxCommand(script, throughLoginShell: throughLoginShell)
        }

        func runTmuxForeground(_ script: Data) async throws -> GitExecResult {
            if await host.isDropped(id) { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
            return try await host.runTmuxForeground(script)
        }

        func openTmuxInventoryLoop(_ script: Data) async throws -> any WindowsTerminalExecChannel {
            try await requireConnected()
            return try await host.openLoop(script, dial: id)
        }

        func openTmuxControlClient(_ script: Data) async throws -> any WindowsTerminalExecChannel {
            try await requireConnected()
            return try await host.openControlClient(script, dial: id)
        }

        func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
            try await requireConnected()
            return try await host.readHostFileRange(range)
        }

        func replaceHostTextFile(path: String, expected: Data?, contents: Data?) async throws {
            try await requireConnected()
            try await host.replaceHostTextFile(path: path, expected: expected, contents: contents)
        }

        func createHostFolder(path: String) async throws {
            try await requireConnected()
            try await host.createHostFolder(path: path)
        }

        func removeEmptyHostFolder(path: String) async throws {
            try await requireConnected()
            try await host.removeEmptyHostFolder(path: path)
        }

        func hostHomeDirectory() async throws -> String {
            try await requireConnected()
            return try await host.hostHomeDirectory()
        }

        func checkouts(for directories: [String]) async throws -> [String: HostCheckout] {
            try await requireConnected()
            return try await host.checkouts(for: directories)
        }

        func runGitCommand(_ command: GitCommand) async throws -> GitCommandResult {
            try await requireConnected()
            return try await host.runGitCommand(command)
        }

        func hostPlatform() async throws -> HostPlatform {
            try await requireConnected()
            return try await host.hostPlatform()
        }

        func readProcesses(_ request: HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts] {
            try await requireConnected()
            return try await host.readProcesses(request)
        }

        func runHostHelperScript(_ script: HostHelperScript) async throws -> GitExecResult {
            try await requireConnected()
            return try await host.runHostHelperScript(script)
        }

        func readHostHelperFile(at path: String, privateDirectory: String) async throws -> Data? {
            try await requireConnected()
            return try await host.readHostHelperFile(at: path, privateDirectory: privateDirectory)
        }

        func replaceHostHelperFile(_ contents: Data, at path: String, privateDirectory: String?) async throws {
            try await requireConnected()
            try await host.replaceHostHelperFile(contents, at: path, privateDirectory: privateDirectory)
        }

        func close() async throws {
            connected = false
            await host.noteClose(ofDial: id)
        }
    }

    func runTmuxCommand(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
        let text = String(decoding: script, as: UTF8.self)
        log.append(throughLoginShell ? "command login" : "command")
        commands.append(text)
        if let files = await hookFilesAnswer(to: text) { return files }
        if let discovery = discoveryAnswer(in: text) {
            return GitExecResult(stdout: Data(discovery.utf8), stderr: Data(), exitStatus: 0)
        }
        return await apply(text)
    }

    func runTmuxForeground(_ script: Data) async throws -> GitExecResult {
        let text = String(decoding: script, as: UTF8.self)
        log.append("foreground")
        foregroundScripts.append(text)
        if !foregroundFailures.isEmpty { throw foregroundFailures.removeFirst() }
        if !nextForegroundAnswers.isEmpty { return nextForegroundAnswers.removeFirst() }

        let executable = Self.assigned("t", in: text)
        let socket = Self.assigned("s", in: text)
        let nonce = Self.assigned("n", in: text)
        let paneID = Self.assigned("q", in: text)
        guard executables[executable] != nil, let instance = servers[socket] else {
            return GitExecResult(stdout: TmuxLoopText.gone(nonce: nonce), stderr: Data(), exitStatus: 0)
        }
        var output = Data("\(nonce) server \(instance.pid) \(instance.startTime)\n\(nonce) begin\n".utf8)
        let matching = (panes[socket] ?? []).filter { $0.paneID == paneID }
        for pane in matching { output.append(TmuxLoopText.row(pane, instance: instance)) }
        if !matching.isEmpty { output.removeLast() }
        output.append(Data("\n\(nonce) argv\n".utf8))
        if let first = matching.first, !first.isDead {
            let pidOverride = foregroundPIDs[socket]?[paneID]
            let pid: Int? =
                if let pidOverride {
                    pidOverride
                } else {
                    first.processID > 0 ? first.processID : nil
                }
            let pidWord = pid.map(String.init) ?? "-"
            let line: Data
            if let arguments = first.foregroundArguments {
                var base = TmuxLoopText.argumentLine(pane: paneID, .list(arguments))
                base.removeLast()
                line = base + Data(" \(pidWord)\n".utf8)
            } else {
                line = Data("A \(paneID) - \(pidWord)\n".utf8)
            }
            output.append(line)
        }
        output.append(Data("\(nonce) end\n".utf8))
        return GitExecResult(stdout: output, stderr: Data(), exitStatus: 0)
    }

    // MARK: The Host's files

    /// Where the Helper's `locate` script finds the data home on this kernel.
    var dataHome: String {
        kernel == "Darwin" ? "\(Self.home)/Library/Application Support" : "\(Self.home)/.local/share"
    }

    /// The Host's files a test planted, a hook placement wrote, or the Helper
    /// seam updated, by path.
    var hostFiles: [String: Data] {
        get async { await helper.files.mapValues(\.contents) }
    }

    func setHostFile(_ path: String, _ contents: Data?) async {
        if let contents {
            await helper.seedFile(path, contents)
        } else {
            await helper.removeFile(path)
        }
    }

    /// The next hook placements exit 1 and write nothing.
    func refuseHookFiles(_ refused: Bool = true) {
        refusesHookFiles = refused
    }

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        await helper.readHostFile(range)
    }

    func replaceHostTextFile(path: String, expected: Data?, contents: Data?) async throws {
        try await helper.replaceHostText(path: path, expected: expected, contents: contents)
    }

    func createHostFolder(path: String) async throws {
        await helper.createFolder(path)
    }

    func removeEmptyHostFolder(path: String) async throws {
        await helper.removeFolderIfEmpty(path)
    }

    func hostHomeDirectory() async throws -> String {
        Self.home
    }

    /// One repository a test planted, so a Worktree's git has something to ask.
    private struct PlantedRepository {
        var mainBranch = "main"
        var branches: Set<String> = []
        var linked: [String: String] = [:]
        var dirty: Set<String> = []
        var submodules: Set<String> = []
    }

    private var repositories: [String: PlantedRepository] = [:]
    /// Paths that become dirty once a pane ends, as an Agent can write on its way out.
    private var dirtyAfterKill: Set<String> = []
    /// Every git command the Host was given, in order.
    private(set) var gitCommands: [GitCommand] = []

    func plantRepository(_ main: String, branches: [String] = []) {
        repositories[main] = PlantedRepository(branches: Set(branches))
    }

    func setWorktreeDirty(_ path: String, _ dirty: Bool = true) {
        mutateRepository(containing: path) { repo in
            if dirty { repo.dirty.insert(path) } else { repo.dirty.remove(path) }
        }
    }

    func setWorktreeSubmodule(_ path: String, _ present: Bool = true) {
        mutateRepository(containing: path) { repo in
            if present { repo.submodules.insert(path) } else { repo.submodules.remove(path) }
        }
    }

    /// The next pane that ends leaves this checkout dirty.
    func markDirtyAfterAPaneEnds(_ path: String) {
        dirtyAfterKill.insert(path)
    }

    func checkouts(for directories: [String]) async throws -> [String: HostCheckout] {
        var answers: [String: HostCheckout] = [:]
        for directory in directories {
            guard let found = located(directory) else { continue }
            answers[directory] = HostCheckout(
                root: found.root, mainCheckout: found.main, isLinkedWorktree: found.root != found.main)
        }
        return answers
    }

    func runGitCommand(_ command: GitCommand) async throws -> GitCommandResult {
        gitCommands.append(command)
        guard var located = located(command.directory) else {
            return GitCommandResult(status: 128, output: "", message: "fatal: not a git repository")
        }
        let arguments = command.arguments
        switch arguments.first {
        case "show-ref":
            let branch = arguments.last.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } ?? ""
            let exists = located.repo.branches.contains(branch) || located.repo.linked.values.contains(branch)
            return GitCommandResult(status: exists ? 0 : 1, output: "", message: nil)
        case "worktree" where arguments.dropFirst().first == "add":
            let added = addedWorktree(arguments)
            located.repo.branches.insert(added.branch)
            located.repo.linked[added.path] = added.branch
            repositories[located.main] = located.repo
            return GitCommandResult(status: 0, output: "", message: nil)
        case "worktree" where arguments.dropFirst().first == "remove":
            let path = arguments.last ?? ""
            let forced = arguments.contains("--force")
            if !forced, located.repo.dirty.contains(path) || located.repo.submodules.contains(path) {
                return GitCommandResult(
                    status: 128, output: "",
                    message: "fatal: '\(path)' contains modified or untracked files, use --force to delete it")
            }
            located.repo.linked[path] = nil
            located.repo.dirty.remove(path)
            located.repo.submodules.remove(path)
            repositories[located.main] = located.repo
            return GitCommandResult(status: 0, output: "", message: nil)
        case "worktree" where arguments.contains("--porcelain"):
            return GitCommandResult(status: 0, output: porcelain(located.repo, main: located.main), message: nil)
        case "status":
            let output = located.repo.dirty.contains(command.directory) ? " M file\n" : ""
            return GitCommandResult(status: 0, output: output, message: nil)
        case "submodule":
            let output = located.repo.submodules.contains(command.directory) ? " 160000 submodule\n" : ""
            return GitCommandResult(status: 0, output: output, message: nil)
        default:
            return GitCommandResult(status: 1, output: "", message: "fatal: unsupported")
        }
    }

    private func markDirty(_ path: String) {
        mutateRepository(containing: path) { $0.dirty.insert(path) }
    }

    private func mutateRepository(containing directory: String, _ body: (inout PlantedRepository) -> Void) {
        guard var located = located(directory) else { return }
        body(&located.repo)
        repositories[located.main] = located.repo
    }

    /// The longest planted checkout that is `directory` or contains it.
    /// `/work/my` does not contain `/work/my app`.
    private func located(_ directory: String) -> (main: String, root: String, repo: PlantedRepository)? {
        var best: (main: String, root: String, repo: PlantedRepository)?
        for (main, repo) in repositories {
            let roots = [main] + repo.linked.keys
            for root in roots {
                guard directory == root || directory.hasPrefix(root + "/") else { continue }
                if best == nil || root.count > best?.root.count ?? 0 {
                    best = (main, root, repo)
                }
            }
        }
        return best
    }

    private func addedWorktree(_ arguments: [String]) -> (path: String, branch: String) {
        if let flag = arguments.firstIndex(of: "-b"), flag + 2 < arguments.count {
            return (arguments[flag + 2], arguments[flag + 1])
        }
        return (arguments.dropFirst(2).first ?? "", arguments.last ?? "")
    }

    private func porcelain(_ repo: PlantedRepository, main: String) -> String {
        var blocks = [
            "worktree \(main)",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/\(repo.mainBranch)",
        ]
        for (path, branch) in repo.linked.sorted(by: { $0.key < $1.key }) {
            blocks.append("")
            blocks.append("worktree \(path)")
            blocks.append("HEAD 2222222222222222222222222222222222222222")
            blocks.append("branch refs/heads/\(branch)")
        }
        return blocks.joined(separator: "\n") + "\n"
    }

    func hostPlatform() async throws -> HostPlatform {
        try await helper.hostPlatform()
    }

    /// Seeds one process's environment, name and parent for `readProcesses`.
    func setProcessEnvironment(
        _ variables: [String: String?], forProcess pid: Int, name: String? = nil, parent: Int? = nil
    ) {
        seededProcesses[pid] = SeededProcess(variables: variables, name: name, parent: parent)
        unavailableProcesses.remove(pid)
    }

    /// Marks `pid`, or every process when nil, unreadable by `readProcesses`.
    func makeProcessEnvironmentUnavailable(forProcess pid: Int? = nil) {
        if let pid {
            unavailableProcesses.insert(pid)
        } else {
            allProcessesUnavailable = true
        }
    }

    func readProcesses(_ request: HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts] {
        processVariableReads.append(contentsOf: request.valuesOf)
        guard !allProcessesUnavailable else { return [:] }

        func listedPane(for pid: Int) -> TmuxInventory.Pane? {
            for (socket, listed) in panes where servers[socket] != nil {
                if let pane = listed.first(where: { $0.processID == pid }) { return pane }
            }
            return nil
        }

        func exists(_ pid: Int) -> Bool {
            seededProcesses[pid] != nil || listedPane(for: pid) != nil
        }

        var walkedPIDs: [Int] = []
        if let root = request.descendantsOf {
            guard let rootPID = Int(root), exists(rootPID), !unavailableProcesses.contains(rootPID) else {
                return [:]
            }
            var queue = [rootPID]
            var seen: Set<Int> = [rootPID]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                let children = seededProcesses.keys.sorted().filter {
                    seededProcesses[$0]?.parent == current && !seen.contains($0)
                }
                for child in children {
                    seen.insert(child)
                    walkedPIDs.append(child)
                    queue.append(child)
                }
            }
        }

        let targetPIDs = Array(
            Set(request.pids.compactMap(Int.init) + walkedPIDs)
        ).sorted()
        var result: [String: HostProcessReader.Facts] = [:]
        for pid in targetPIDs where exists(pid) {
            let key = String(pid)
            var fact = HostProcessReader.Facts()
            let seeded = seededProcesses[pid]
            let pane = listedPane(for: pid)
            if request.descendantsOf != nil {
                fact.parent = String(seeded?.parent ?? 1)
                let fallback = pane?.command.isEmpty == false ? pane?.command : nil
                fact.name = seeded?.name ?? fallback ?? "grok"
                if request.descendantsOf == key {
                    fact.descendants = .value(walkedPIDs.map(String.init))
                }
            }
            let readable = !unavailableProcesses.contains(pid)
            for variable in request.valuesOf {
                if !readable {
                    fact.variables[variable] = .unavailable
                } else if let entry = seeded?.variables[variable] {
                    fact.variables[variable] = entry.map(HostProcessReader.Variable.value) ?? .unset
                } else {
                    fact.variables[variable] = .unset
                }
            }
            result[key] = fact
        }
        return result
    }

    func runHostHelperScript(_ script: HostHelperScript) async throws -> GitExecResult {
        try await helper.runHostHelperScript(script)
    }

    func readHostHelperFile(at path: String, privateDirectory: String) async throws -> Data? {
        try await helper.readHostHelperFile(at: path, privateDirectory: privateDirectory)
    }

    func replaceHostHelperFile(_ contents: Data, at path: String, privateDirectory: String?) async throws {
        try await helper.replaceHostHelperFile(contents, at: path, privateDirectory: privateDirectory)
    }

    /// The Helper's `locate` script, or a placement of Heeler's hook files.
    private func hookFilesAnswer(to script: String) async -> GitExecResult? {
        guard let first = script.split(separator: "\n").first, first.hasPrefix("printf '%s begin\\n' '") else {
            return nil
        }
        let nonce = String(first.dropFirst("printf '%s begin\\n' '".count).prefix { $0 != "'" })
        let framed = { (lines: [String]) in
            Self.succeeded((["\(nonce) begin"] + lines + ["\(nonce) end"]).joined(separator: "\n") + "\n")
        }
        if script.contains("printf 'data %s\\n'") {
            log.append("locate")
            return framed(["home \(Self.home)", "data \(dataHome)", "config \(Self.home)/.config"])
        }
        let delimiter = "__HEELER_FILE_\(nonce)"
        guard script.contains(delimiter) else { return nil }
        log.append("place hook files")
        if refusesHookFiles { return Self.failed("mkdir: Permission denied\n") }
        var path: String?
        var lines: [Substring] = []
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = path {
                if line == delimiter {
                    await helper.seedFile(open, Data((lines.joined(separator: "\n") + "\n").utf8))
                    path = nil
                    lines = []
                } else {
                    lines.append(line)
                }
            } else if line.hasPrefix("  __h_put ") {
                path = Self.words(of: String(line)).dropFirst().first
            }
        }
        return framed([])
    }

    /// Discovery's markers, with the programs a test listed and OpenCode's
    /// version when one was set. The nonce is the hex after the begin marker.
    private func discoveryAnswer(in script: String) -> String? {
        let begin = "__HEELER_AGENTS_BEGIN_"
        guard let range = script.range(of: begin) else { return nil }
        let nonce = script[range.upperBound...].prefix { $0.isHexDigit }
        guard !nonce.isEmpty else { return nil }
        var lines = ["", "\(begin)\(nonce)"]
        lines += installedExecutables.map { "agent \($0)" }
        lines.append("version \(openCodeVersion ?? "")")
        lines.append("__HEELER_AGENTS_END_\(nonce)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One `TmuxLaunch` script against the server named in it. With `-N` and no
    /// server, tmux exits. Without `-N`, only `new-session` starts one. The
    /// login wrapper is undone first, the way the probe's answer reads its body.
    private func apply(_ script: String) async -> GitExecResult {
        let body = Self.commandBody(script)
        let socket = Self.assigned("s", in: body)
        let executable = Self.assigned("t", in: body)
        guard let line = body.split(separator: "\n").first(where: { $0.hasPrefix("exec ") }),
            let invocation = Self.invocation(of: Self.words(of: String(line)))
        else { return Self.failed("tmux: The command failed.\n") }
        let knownExecutable = executables[executable] != nil
        if servers[socket] == nil || !knownExecutable {
            guard invocation.subcommand == "new-session", !invocation.hasN, knownExecutable else {
                return Self.failed("no server running\n")
            }
            servers[socket] = Self.instance
            if panes[socket] == nil { panes[socket] = [] }
        }
        if invocation.subcommand == "show-environment" {
            return environmentListing(on: socket, invocation: invocation)
        }
        var listed = panes[socket] ?? []
        let result = mutate(&listed, invocation)
        guard result.exitStatus == 0 else { return result }
        panes[socket] = listed
        await printChanges(on: socket)
        return result
    }

    /// `show-environment` does not change the panes. `-g` is the global list.
    /// `-t` answers only for a session id that is listed or planted; a name
    /// is `can't find session`.
    private func environmentListing(on socket: String, invocation: Invocation) -> GitExecResult {
        if let status = showEnvironmentStatus {
            return GitExecResult(stdout: Data(), stderr: Data("show-environment failed\n".utf8), exitStatus: status)
        }
        if invocation.global, invocation.target == nil {
            return Self.succeeded(Self.lines(globalEnvironment[socket] ?? []))
        }
        guard let target = invocation.target, target.hasPrefix("$"),
            (panes[socket] ?? []).contains(where: { $0.sessionID == target }) || sessionEnvironment[socket]?[target] != nil
        else { return Self.failed("can't find session: \(invocation.target ?? "")\n") }
        return Self.succeeded(Self.lines(sessionEnvironment[socket]?[target] ?? []))
    }

    private static func lines(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private func mutate(
        _ listed: inout [TmuxInventory.Pane], _ invocation: Invocation
    ) -> GitExecResult {
        switch invocation.subcommand {
        case "new-window":
            guard let target = invocation.target,
                let session = listed.first(where: { $0.sessionID == target || $0.sessionName == target })
            else { return Self.failed("can't find session: \(invocation.target ?? "")\n") }
            var pane = makePane(
                sessionID: session.sessionID, sessionName: session.sessionName,
                windowIndex: (listed.filter { $0.sessionID == session.sessionID }.map(\.windowIndex).max() ?? -1) + 1,
                directory: invocation.directory, program: invocation.program, in: listed)
            // A session option shows on every pane the session gains.
            if let mark = listed.first(where: { $0.sessionID == session.sessionID && !$0.worktree.isEmpty })?.worktree {
                pane.worktree = mark
            }
            listed.append(pane)
            return Self.succeeded("\(pane.paneID) \(pane.windowID)\n")
        case "new-session":
            let explicit = invocation.name.flatMap { $0.isEmpty ? nil : $0 }
            let sessionName = explicit ?? Self.numberedSessionName(in: listed)
            if explicit != nil, listed.contains(where: { $0.sessionName == sessionName }) {
                return Self.failed("duplicate session: \(sessionName)\n")
            }
            let pane = makePane(
                sessionID: "$\(Self.nextNumber(prefix: "$", in: listed))", sessionName: sessionName,
                windowIndex: 0, directory: invocation.directory, program: invocation.program, in: listed)
            listed.append(pane)
            return Self.succeeded("\(pane.paneID) \(pane.windowID) \(pane.sessionID) \(pane.sessionName)\n")
        case "rename-session":
            guard let target = invocation.target, let label = invocation.name, !label.isEmpty else {
                return Self.failed("tmux: The command failed.\n")
            }
            let matchesID = listed.contains { $0.sessionID == target }
            var renamed = false
            for index in listed.indices {
                let matches = matchesID ? listed[index].sessionID == target : listed[index].sessionName == target
                guard matches else { continue }
                listed[index].sessionName = label
                renamed = true
            }
            guard renamed else { return Self.failed("can't find session: \(target)\n") }
            return Self.succeeded("")
        case "kill-pane":
            guard let target = invocation.target else { return Self.failed("tmux: The command failed.\n") }
            let before = listed.count
            listed.removeAll { $0.paneID == target }
            guard listed.count < before else { return Self.failed("can't find pane: \(target)\n") }
            for path in dirtyAfterKill {
                markDirty(path)
            }
            return Self.succeeded("")
        case "set-option":
            guard let target = invocation.target, target.hasPrefix("$"),
                invocation.arguments.first == "@heeler-worktree",
                invocation.arguments.count >= 2
            else { return Self.failed("can't find session: \(invocation.target ?? "")\n") }
            let value = invocation.arguments[1]
            var marked = false
            for index in listed.indices where listed[index].sessionID == target {
                listed[index].worktree = value
                marked = true
            }
            guard marked else { return Self.failed("can't find session: \(target)\n") }
            return Self.succeeded("")
        case "kill-window":
            guard let target = invocation.target else { return Self.failed("tmux: The command failed.\n") }
            let before = listed.count
            listed.removeAll { $0.windowID == target }
            guard listed.count < before else { return Self.failed("can't find window: \(target)\n") }
            return Self.succeeded("")
        default:
            return Self.failed("unknown command: \(invocation.subcommand)\n")
        }
    }

    /// The pane a `new-window` or `new-session` adds. An empty program is the
    /// user's shell. An agent program drops the four shell-wrapper words, so
    /// the foreground is the program tmux execs.
    private func makePane(
        sessionID: String, sessionName: String, windowIndex: Int, directory: String?, program: [String],
        in listed: [TmuxInventory.Pane]
    ) -> TmuxInventory.Pane {
        let agent = program.isEmpty ? [] : Array(program.dropFirst(min(4, program.count)))
        let executable = agent.first ?? (program.isEmpty ? shell : program[0])
        let command = String(executable.split(separator: "/").last ?? Substring(executable))
        let arguments = program.isEmpty ? [shell] : (agent.isEmpty ? program : agent)
        nextProcessID += 1
        return .make(
            session: Self.number(sessionID) ?? 0, sessionName: sessionName,
            window: Self.nextNumber(prefix: "@", in: listed), windowIndex: windowIndex,
            windowName: command, pane: Self.nextNumber(prefix: "%", in: listed),
            processID: nextProcessID, command: command, path: directory ?? "/", arguments: arguments)
    }

    private struct Invocation {
        var hasN = false
        var global = false
        var subcommand = ""
        var target: String?
        var directory: String?
        var name: String?
        var program: [String] = []
        var arguments: [String] = []
    }

    /// The exec line's tmux command. `-N` counts only before the subcommand.
    /// A rename's new name is the word after `--` (itself possibly `--`), or,
    /// in an older script, the word after `-t` when that word is not a flag.
    /// Anywhere else, `--` starts the program.
    private static func invocation(of words: [String]) -> Invocation? {
        let commands = [
            "new-window", "new-session", "rename-session", "kill-pane", "kill-window", "show-environment",
            "set-option",
        ]
        guard let index = words.firstIndex(where: { commands.contains($0) }) else { return nil }
        var parsed = Invocation(hasN: words[..<index].contains("-N"), subcommand: words[index])
        var cursor = index + 1
        while cursor < words.count {
            let word = words[cursor]
            if word == "--" {
                if parsed.subcommand == "rename-session", cursor + 1 < words.count {
                    parsed.name = words[cursor + 1]
                } else {
                    parsed.program = Array(words[(cursor + 1)...])
                }
                break
            }
            switch word {
            case "-g":
                parsed.global = true
                cursor += 1
            case "-t", "-c", "-s":
                guard cursor + 1 < words.count else { return parsed }
                let value = words[cursor + 1]
                switch word {
                case "-t": parsed.target = value
                case "-c": parsed.directory = value
                case "-s": parsed.name = value
                default: break
                }
                cursor += 2
                if parsed.subcommand == "rename-session", word == "-t", cursor < words.count,
                    !words[cursor].hasPrefix("-")
                {
                    parsed.name = words[cursor]
                    cursor += 1
                }
            default:
                if !word.hasPrefix("-") { parsed.arguments.append(word) }
                cursor += 1
            }
        }
        return parsed
    }

    /// The script tmux runs. A Linux start stores it in `__heeler_tmux_start`
    /// as one single-quoted word, with each quote written `'\\''`.
    private static func commandBody(_ script: String) -> String {
        let marker = "__heeler_tmux_start="
        guard let start = script.range(of: marker) else { return script }
        var index = start.upperBound
        guard index < script.endIndex, script[index] == "'" else { return script }
        index = script.index(after: index)
        var value = ""
        while index < script.endIndex {
            if script[index] == "'" {
                let escaped = script.index(index, offsetBy: 4, limitedBy: script.endIndex)
                if let escaped, script[index..<escaped] == "'\\''" {
                    value.append("'")
                    index = escaped
                    continue
                }
                break
            }
            value.append(script[index])
            index = script.index(after: index)
        }
        return value
    }

    private static func nextNumber(prefix: Character, in panes: [TmuxInventory.Pane]) -> Int {
        let used = Set(panes.compactMap { pane -> Int? in
            let id: String
            switch prefix {
            case "%": id = pane.paneID
            case "@": id = pane.windowID
            case "$": id = pane.sessionID
            default: return nil
            }
            guard id.first == prefix else { return nil }
            return Int(id.dropFirst())
        })
        var number = 0
        while used.contains(number) { number += 1 }
        return number
    }

    /// The first free decimal name, starting from how many sessions there are.
    /// One session already listed is named `1`, and none is named `0`.
    private static func numberedSessionName(in panes: [TmuxInventory.Pane]) -> String {
        let used = Set(panes.map(\.sessionName))
        var number = Set(panes.map(\.sessionID)).count
        while used.contains(String(number)) { number += 1 }
        return String(number)
    }

    private static func number(_ id: String) -> Int? {
        guard let first = id.first, "$%@".contains(first) else { return nil }
        return Int(id.dropFirst())
    }

    private static func failed(_ text: String) -> GitExecResult {
        GitExecResult(stdout: Data(), stderr: Data(text.utf8), exitStatus: 1)
    }

    private static func succeeded(_ text: String) -> GitExecResult {
        GitExecResult(stdout: Data(text.utf8), stderr: Data(), exitStatus: 0)
    }

    func runTmuxProbe(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
        let body = String(decoding: script, as: UTF8.self)
        log.append(throughLoginShell ? "probe login" : "probe stored")
        scripts.append(body)
        if !failures.isEmpty { throw failures.removeFirst() }
        if !nextAnswers.isEmpty { return nextAnswers.removeFirst() }
        return GitExecResult(stdout: Data(answer(to: body).utf8), stderr: Data(), exitStatus: 0)
    }

    /// What the probe prints for the script's own request.
    private func answer(to script: String) -> String {
        // Through the login shell the body travels as one quoted word.
        let body = script.replacingOccurrences(of: "'\\''", with: "'")
            .replacingOccurrences(of: "__heeler_tmux_probe='", with: "")
        func assigned(_ name: String) -> String { Self.assigned(name, in: body) }
        let nonce = Self.nonce(in: body)
        let asked = assigned("t")
        let socket = assigned("s")
        let name = assigned("n")
        let executable = asked.isEmpty ? loginExecutable : (executables[asked] == nil ? nil : asked)
        var lines = ["", "\(nonce) tmux begin", "kernel \(kernel)", "shell \(shell)"]
        if let executable, let version = executables[executable] {
            lines += ["executable \(executable)", "version \(version)"]
        }
        if socket.isEmpty { lines.append("directory \(loginDirectory)") }
        let target = socket.isEmpty && !name.isEmpty ? Self.socketPath(name, in: loginDirectory) : socket
        if executable != nil, !target.isEmpty {
            if let instance = servers[target] { lines.append("instance \(instance.pid) \(instance.startTime)") }
        } else if executable != nil {
            let prefix = loginDirectory + "/"
            lines += servers.keys.filter { $0.hasPrefix(prefix) }.sorted().map { "socket \($0.dropFirst(prefix.count))" }
        }
        return (lines + ["", "\(nonce) tmux end", ""]).joined(separator: "\n")
    }

    private static func nonce(in script: String) -> String {
        guard let end = script.range(of: " tmux begin")?.lowerBound else { return "" }
        return String(script[..<end].reversed().prefix { $0 != "'" && $0 != "\n" }.reversed())
    }

    // MARK: Detection

    func corePlatform() async throws -> HostPlatform { .posix }

    func runWindowsCommand(_ command: String, for purpose: WindowsHostExec) async throws -> GitExecResult {
        throw TransportError.hostFeatureUnavailable(feature: "native Windows")
    }

    /// A Host with neither herdr nor a core: only the tmux part finds anything.
    func runServerKindDetection(_ script: Data) async throws -> GitExecResult {
        let body = String(decoding: script, as: UTF8.self)
        log.append("detection")
        scripts.append(body)
        if !failures.isEmpty { throw failures.removeFirst() }
        let marker = "herdr-tui begin\\n' '"
        let nonce = body.range(of: marker).map { String(body[$0.upperBound...].prefix { $0 != "'" }) } ?? ""
        var printed = "\n\(nonce) herdr-tui begin\n\n\(nonce) herdr-tui status 127\n"
        printed += answer(to: body)
        if body.contains("__session=") {
            printed += ["\(nonce) begin", "kernel \(kernel)", "default /home/dev/.herdr-core.sock", "socket-file 0", "\(nonce) end", ""]
                .joined(separator: "\n")
        }
        return GitExecResult(stdout: Data(printed.utf8), stderr: Data(), exitStatus: 0)
    }
}

/// One inventory loop's exec on a scripted Host: what the loop printed, read
/// in the pieces it was printed in.
actor ScriptedTmuxLoopChannel: WindowsTerminalExecChannel {
    private var chunks: [Data] = []
    private var ended = false
    private var failure: TransportError?
    private var closed = false
    private var waiter: (id: UInt64, continuation: CheckedContinuation<Data?, any Error>)?
    private var nextWaiter: UInt64 = 0
    private let onWrite: @Sendable (Data) async -> Void
    private let onClose: @Sendable () async -> Void
    /// Everything written to the exec's input, a write each.
    private(set) var written: [Data] = []
    var isClosed: Bool { closed }

    init(
        onWrite: @escaping @Sendable (Data) async -> Void = { _ in },
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.onWrite = onWrite
        self.onClose = onClose
    }

    func send(_ data: Data) {
        guard !ended, failure == nil, !closed else { return }
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(returning: data)
        } else {
            chunks.append(data)
        }
    }

    /// The exec ended on the Host: what it printed is read, then nothing.
    func finish() {
        ended = true
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(returning: nil)
        }
    }

    func fail(_ error: TransportError) {
        failure = error
        chunks = []
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(throwing: error)
        }
    }

    func write(_ data: Data, timeout: Duration) async throws {
        if let failure { throw failure }
        guard !closed, !ended else { throw TransportError.channelFailed(detail: "the exec ended") }
        written.append(data)
        await onWrite(data)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        if let failure { throw failure }
        if !chunks.isEmpty { return chunks.removeFirst() }
        if ended || closed { return nil }
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.timeOut(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiter = (id, $0) }
    }

    private func timeOut(_ id: UInt64) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.continuation.resume(throwing: TransportError.timedOut)
    }

    func exitStatus(timeout: Duration) async throws -> Int32 { 0 }

    func close(timeout: Duration) async throws {
        guard !closed else { return }
        closed = true
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(returning: nil)
        }
        await onClose()
    }
}
