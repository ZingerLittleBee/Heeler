import Foundation

/// What a tmux Host's server answered: which run of it, and the tmux that asked.
struct TmuxServerStatus: Equatable, Sendable {
    let instance: TmuxServerInstance
    /// The version of the tmux at `paths.executable`, as it names itself.
    let version: String
    /// The paths that reached the server, for every later command.
    let paths: TmuxPaths
}

/// The paths, kernel and shell a probe last read. Paths stay the stored ones
/// until a login shell resolves others. `shell` is that probe's `$SHELL`.
struct TmuxHostFacts: Equatable, Sendable {
    var paths: TmuxPaths?
    var kernel: String?
    var shell: String?
}

/// What a tmux Host offers the app, beside and never through the Herdr TUI
/// `Transport` or `HerdrCoreTransport` (ADR 0042). Connecting never starts a
/// server. Linux New Workspace is the one launch that does, and only through
/// the user's login shell (`TmuxLaunch`). A Host with none running reads as
/// `TransportError.tmuxServerNotRunning`.
protocol TmuxTransport: Sendable {
    /// The route that won the dial; nil when there was only ever one way in.
    nonisolated var routeID: UUID? { get }

    /// The Host's exec and SFTP services, on the same SSH connection.
    nonisolated var hostServices: any HostServices { get }

    /// Whether the SSH connection is up, whatever became of the server.
    var isConnected: Bool { get async }

    /// Asks the Host's tmux server which run of it answers. The stored paths
    /// are asked first, with no shell startup file in between. Once they stop
    /// answering, the login shell resolves both again, once until they answer
    /// again, and what it finds is asked instead. Throws `.tmuxNotInstalled`,
    /// `.tmuxUpdateRequired` or `.tmuxServerNotRunning` for a Host with no
    /// server to reach.
    func status() async throws -> TmuxServerStatus

    /// The paths the login shell resolved on this connection, for the Host to
    /// store. Nil while the paths it was given still stand.
    func resolvedPaths() async -> TmuxPaths?

    /// Kernel and shell from the last probe, with the paths later commands use.
    /// Kept when the server is down, so Linux New Workspace can still start one.
    func hostFacts() async -> TmuxHostFacts

    /// One bounded exec of a script `TmuxLaunch` or agent discovery built.
    /// `throughLoginShell` is the Linux server start, which waits for the
    /// shell's startup files. The script already says how it runs.
    func runTmuxScript(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult

    /// Follows the server's inventory in one long exec (ADR 0043), with the
    /// paths the last `status()` answered on: every pane the server lists at
    /// once, then again each time something changed. The stream ends when the
    /// server stops answering, and throws when the exec fails or goes silent.
    /// Letting go of the stream closes the exec.
    func inventory() async throws -> AsyncThrowingStream<TmuxInventory, any Error>

    /// Opens an Attach on `pane` of the server the last `status()` answered
    /// (ADR 0043): a session of Heeler's own holding the Pane's window, with
    /// one control client attached to it, and the Pane's first paint. It holds
    /// one of the connection's attach slots (ADR 0017) until it ends.
    func attachPane(_ pane: String, request: TerminalAttachRequest) async throws -> TerminalAttachSession

    /// Closes the connection.
    func close() async throws
}

/// The parts of an SSH connection a tmux transport uses. Real SSH is
/// `HeelerSSHTransport`; tests script the exec.
protocol TmuxHostConnection: HostServices {
    nonisolated var routeID: UUID? { get }

    var isConnected: Bool { get async }

    /// Runs a `TmuxProbe` script in one bounded exec, with room for the login
    /// shell's startup files when the script goes through it.
    func runTmuxProbe(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult

    /// Runs one command script the same way. `throughLoginShell` only lengthens
    /// the deadline: `TmuxLaunch` has already wrapped a Linux server start.
    func runTmuxCommand(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult

    /// Opens one long exec of a `TmuxInventoryLoop` script, which runs until
    /// the channel is closed or its server stops answering. The exec holds one
    /// of the connection's four ordinary SSH sessions (ADR 0017) until then.
    func openTmuxInventoryLoop(_ script: Data) async throws -> any WindowsTerminalExecChannel

    /// Opens one long exec of a `TmuxAttachScript` script, whose control-mode
    /// client reads the exec's input after the script. It holds one of the
    /// connection's attach slots (ADR 0017) until the channel is closed. Reads
    /// and writes throw `TransportError`.
    func openTmuxControlClient(_ script: Data) async throws -> any WindowsTerminalExecChannel

    func close() async throws
}

/// tmux over SSH exec: its command-line client and nothing else (ADR 0042).
actor TmuxSSHTransport: TmuxTransport {
    nonisolated let routeID: UUID?
    nonisolated var hostServices: any HostServices { connection }
    private nonisolated let connection: any TmuxHostConnection
    private let socketName: String
    private let nonce: @Sendable () -> String
    private let loopSilenceLimit: Duration
    private let attachStartLimit: Duration
    /// The paths every command runs with: the Host's stored ones, until the
    /// login shell resolves others.
    private var paths: TmuxPaths?
    private var resolved: TmuxPaths?
    /// `uname -s` and `$SHELL` from the last probe that parsed, kept when the
    /// server is not running so a launch can still decide.
    private var kernel: String?
    private var shell: String?
    /// Whether the login shell resolved the paths since they last answered.
    /// Asking it again would get the same answer, at the cost of its startup
    /// files on every poll of a Host whose server is simply not running.
    private var resolvedSinceLastAnswer = false

    init(
        connection: any TmuxHostConnection,
        socketName: String,
        storedPaths: TmuxPaths?,
        nonce: @escaping @Sendable () -> String = { UUID().uuidString },
        loopSilenceLimit: Duration = TmuxInventoryLoop.silenceLimit,
        attachStartLimit: Duration = .seconds(15)
    ) {
        routeID = connection.routeID
        self.connection = connection
        self.socketName = TmuxSocketName.normalized(socketName)
        self.nonce = nonce
        self.loopSilenceLimit = loopSilenceLimit
        self.attachStartLimit = attachStartLimit
        // Paths resolved for another socket name say nothing of this one.
        paths = storedPaths.flatMap { $0.serves(socketName: socketName) ? $0 : nil }
    }

    var isConnected: Bool {
        get async { await connection.isConnected }
    }

    func resolvedPaths() -> TmuxPaths? {
        resolved
    }

    func hostFacts() -> TmuxHostFacts {
        TmuxHostFacts(paths: paths, kernel: kernel, shell: shell)
    }

    func runTmuxScript(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
        try await connection.runTmuxCommand(script, throughLoginShell: throughLoginShell)
    }

    func status() async throws -> TmuxServerStatus {
        var storedAnswer: TmuxProbe.Report?
        if let paths {
            let report = try await probe(.stored(executable: paths.executable, socket: paths.socket))
            if let status = Self.status(in: report, paths: paths) {
                resolvedSinceLastAnswer = false
                return status
            }
            storedAnswer = report
        }
        // A stopped server is polled with the paths in hand. A tmux that is no
        // longer there, or no longer usable, is looked up again.
        guard let storedAnswer, resolvedSinceLastAnswer, case .usable = storedAnswer.installation else {
            return try await resolve()
        }
        throw Self.failure(in: storedAnswer, socketName: socketName)
    }

    /// The login shell's answer, which replaces the paths whatever it says of
    /// the server: a tmux that moved is where the next command must look.
    private func resolve() async throws -> TmuxServerStatus {
        let report = try await probe(.resolve(socketName: socketName))
        resolvedSinceLastAnswer = true
        guard case .usable(let executable, _) = report.installation else {
            throw Self.failure(in: report, socketName: socketName)
        }
        guard let socket = report.socketPath(named: socketName),
            let found = TmuxPaths(executable: executable, socket: socket)
        else {
            throw TransportError.malformedResponse(
                String(localized: "tmux: The Host's tmux or its socket is at a path Heeler cannot use."))
        }
        if found != paths {
            paths = found
            resolved = found
        }
        guard let status = Self.status(in: report, paths: found) else {
            throw Self.failure(in: report, socketName: socketName)
        }
        resolvedSinceLastAnswer = false
        return status
    }

    private static func status(in report: TmuxProbe.Report, paths: TmuxPaths) -> TmuxServerStatus? {
        guard case .usable(_, let version) = report.installation, let instance = report.server else { return nil }
        return TmuxServerStatus(instance: instance, version: version, paths: paths)
    }

    private static func failure(in report: TmuxProbe.Report, socketName: String) -> TransportError {
        switch report.installation {
        case .notInstalled: .tmuxNotInstalled
        case .updateRequired(let version): .tmuxUpdateRequired(version: version)
        case .usable: .tmuxServerNotRunning(socketName: socketName)
        }
    }

    private func probe(_ request: TmuxProbe.Request) async throws -> TmuxProbe.Report {
        let nonce = nonce()
        let result = try await connection.runTmuxProbe(
            Data(TmuxProbe.script(request, nonce: nonce).utf8),
            throughLoginShell: request.runsThroughLoginShell)
        guard result.exitStatus == 0 else {
            throw TransportError.malformedResponse(
                String(localized: "tmux: The probe exited with status \(result.exitStatus)."))
        }
        let report: TmuxProbe.Report
        do {
            report = try TmuxProbe.parse(stdout: result.stdout, nonce: nonce)
        } catch {
            throw TransportError.malformedResponse(String(localized: "tmux: The probe's output is unreadable."))
        }
        if let kernel = report.kernel { self.kernel = kernel }
        if let shell = report.shell { self.shell = shell }
        return report
    }

    // MARK: Inventory

    func inventory() async throws -> AsyncThrowingStream<TmuxInventory, any Error> {
        guard let paths else { throw TransportError.tmuxServerNotRunning(socketName: socketName) }
        let nonce = nonce()
        let script = TmuxInventoryLoop.script(executable: paths.executable, socket: paths.socket, nonce: nonce)
        let channel = try await connection.openTmuxInventoryLoop(Data(script.utf8))
        return Self.inventories(from: channel, nonce: nonce, silenceLimit: loopSilenceLimit)
    }

    /// Reads the loop until it says its server is gone, its exec ends, or it
    /// goes silent for longer than its heartbeat allows.
    private static func inventories(
        from channel: any WindowsTerminalExecChannel, nonce: String, silenceLimit: Duration
    ) -> AsyncThrowingStream<TmuxInventory, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TmuxInventory.self)
        let reading = Task {
            var reader = TmuxInventoryLoop.Reader(nonce: nonce)
            var failure: (any Error)?
            do {
                loop: while !Task.isCancelled {
                    guard let bytes = try await channel.read(maximumBytes: 64 * 1024, timeout: silenceLimit)
                    else { break }
                    for event in reader.read(bytes) {
                        switch event {
                        case .inventory(let inventory): continuation.yield(inventory)
                        case .alive: break
                        case .gone: break loop
                        }
                    }
                }
            } catch {
                failure = error
            }
            try? await channel.close(timeout: closeTimeout)
            continuation.finish(throwing: failure)
        }
        continuation.onTermination = { _ in
            reading.cancel()
            // A read in flight ends with its channel, not with its task.
            Task { try? await channel.close(timeout: closeTimeout) }
        }
        return stream
    }

    private static let closeTimeout = Duration.seconds(2)

    // MARK: Attach

    /// Seconds a client may fall behind before tmux pauses the Pane for it,
    /// which a new first paint then resumes (ADR 0043).
    static let pauseAfter = 10

    func attachPane(_ pane: String, request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        guard let paths else { throw TransportError.tmuxServerNotRunning(socketName: socketName) }
        let session = TmuxAttachScript.sessionPrefix + String(format: "%08x", UInt32.random(in: .min ... .max))
        guard
            let script = TmuxAttachScript.script(
                paths: paths, session: session, pane: pane, pauseAfter: Self.pauseAfter)
        else { throw TransportError.tmuxPaneGone }
        let channel = try await connection.openTmuxControlClient(Data(script.utf8))
        return try await TmuxPaneAttach.open(
            channel: channel, session: session, pane: pane, request: request, startLimit: attachStartLimit)
    }

    func close() async throws {
        try await connection.close()
    }
}
