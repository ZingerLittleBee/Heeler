import Foundation

/// What a tmux Host's server answered: which run of it, and the tmux that asked.
struct TmuxServerStatus: Equatable, Sendable {
    let instance: TmuxServerInstance
    /// The version of the tmux at `paths.executable`, as it names itself.
    let version: String
    /// The paths that reached the server, for every later command.
    let paths: TmuxPaths
}

/// What a tmux Host offers the app, beside and never through the Herdr TUI
/// `Transport` or `HerdrCoreTransport` (ADR 0042). Connecting never starts a
/// server: a Host with none running reads as `TransportError.tmuxServerNotRunning`.
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

    func close() async throws
}

/// tmux over SSH exec: its command-line client and nothing else (ADR 0042).
actor TmuxSSHTransport: TmuxTransport {
    nonisolated let routeID: UUID?
    nonisolated var hostServices: any HostServices { connection }
    private nonisolated let connection: any TmuxHostConnection
    private let socketName: String
    private let nonce: @Sendable () -> String
    /// The paths every command runs with: the Host's stored ones, until the
    /// login shell resolves others.
    private var paths: TmuxPaths?
    private var resolved: TmuxPaths?
    /// Whether the login shell resolved the paths since they last answered.
    /// Asking it again would get the same answer, at the cost of its startup
    /// files on every poll of a Host whose server is simply not running.
    private var resolvedSinceLastAnswer = false

    init(
        connection: any TmuxHostConnection,
        socketName: String,
        storedPaths: TmuxPaths?,
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        routeID = connection.routeID
        self.connection = connection
        self.socketName = TmuxSocketName.normalized(socketName)
        self.nonce = nonce
        // Paths resolved for another socket name say nothing of this one.
        paths = storedPaths.flatMap { $0.serves(socketName: socketName) ? $0 : nil }
    }

    var isConnected: Bool {
        get async { await connection.isConnected }
    }

    func resolvedPaths() -> TmuxPaths? {
        resolved
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
        do {
            return try TmuxProbe.parse(stdout: result.stdout, nonce: nonce)
        } catch {
            throw TransportError.malformedResponse(String(localized: "tmux: The probe's output is unreadable."))
        }
    }

    func close() async throws {
        try await connection.close()
    }
}
