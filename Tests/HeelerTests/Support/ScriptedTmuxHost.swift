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
/// the app's reader is the one under test. What later tickets ask of a tmux
/// server, they add here against the same servers and panes.
actor ScriptedTmuxHost: TmuxHostConnection, ServerKindDetectionConnection {
    static let nonce = "scripted-tmux-host-nonce"
    static let executable = "/opt/homebrew/bin/tmux"
    static let directory = "/private/tmp/tmux-501"
    static let instance = TmuxServerInstance(pid: 4242, startTime: 1_794_326_988)

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
    private var loops: [UInt64: Loop] = [:]
    private var nextLoop: UInt64 = 0
    private var loopFailures: [TransportError] = []
    /// Each inventory loop's exec, opened and closed, in order.
    private(set) var loopLog: [String] = []
    private(set) var loopScripts: [String] = []
    private var failures: [TransportError] = []
    private var nextAnswers: [GitExecResult] = []
    private var connected = true

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []

    /// A Mac with Homebrew's tmux, and a server on each of `sockets`.
    init(
        executable: String? = ScriptedTmuxHost.executable, version: String = "tmux 3.7b",
        directory: String = ScriptedTmuxHost.directory, sockets: [String] = ["default"],
        kernel: String = "Darwin"
    ) {
        self.kernel = kernel
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
        servers[socket] = instance
        panes[socket] = listed
        await printChanges(on: socket)
    }

    /// Stopped or killed: a socket file left behind answers no better than none.
    func stopServer(_ name: String = "default") async {
        let socket = Self.socketPath(name, in: loginDirectory)
        servers[socket] = nil
        panes[socket] = nil
        await printChanges(on: socket)
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

    func clearLog() {
        log = []
        scripts = []
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

    // MARK: The connection

    var isConnected: Bool { connected }

    func close() async throws {
        log.append("close")
        connected = false
        await closeLoops(ofDial: 0)
    }

    /// A new connection to the Host, which closes apart from any other. A
    /// loop silent for `loopSilenceLimit` is lost, as the app's is after its own.
    func transport(
        socketName: String, storedPaths: TmuxPaths?, loopSilenceLimit: Duration = .seconds(30)
    ) -> TmuxSSHTransport {
        nextDial += 1
        return TmuxSSHTransport(
            connection: Dial(host: self, id: nextDial), socketName: socketName, storedPaths: storedPaths,
            nonce: { Self.nonce }, loopSilenceLimit: loopSilenceLimit)
    }

    private var nextDial: UInt64 = 0

    private func noteClose(ofDial dial: UInt64) async {
        log.append("close")
        await closeLoops(ofDial: dial)
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

        var isConnected: Bool { connected }

        func runTmuxProbe(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
            try await host.runTmuxProbe(script, throughLoginShell: throughLoginShell)
        }

        func openTmuxInventoryLoop(_ script: Data) async throws -> any WindowsTerminalExecChannel {
            guard connected else { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
            return try await host.openLoop(script, dial: id)
        }

        func close() async throws {
            connected = false
            await host.noteClose(ofDial: id)
        }
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
        var lines = ["", "\(nonce) tmux begin", "kernel \(kernel)"]
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
    private let onClose: @Sendable () async -> Void

    init(onClose: @escaping @Sendable () async -> Void) {
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

    func write(_ data: Data, timeout: Duration) async throws {}

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
