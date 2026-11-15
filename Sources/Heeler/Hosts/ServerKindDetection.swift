import Foundation

/// The SSH connection a detection runs over: one bounded exec, then close.
protocol ServerKindDetectionConnection: Sendable {
    /// Which of the two execs below this Host takes.
    func corePlatform() async throws -> HostPlatform

    func runServerKindDetection(_ script: Data) async throws -> GitExecResult

    /// A native Windows Host's, a whole command line.
    func runWindowsCommand(_ command: String, for purpose: WindowsHostExec) async throws -> GitExecResult

    func close() async throws
}

/// Which servers an SSH target runs, for the user to confirm one (ADRs 0031
/// and 0044).
struct ServerKindDetection: Equatable, Sendable {
    enum HerdrTUIFinding: Equatable, Sendable {
        case found(sessions: [HerdrSession])
        case notFound
    }

    /// What the locator says of the typed session's core. Only `hello` can prove
    /// a core answers, so a socket file is all it can report of a running one.
    enum CoreFinding: Equatable, Sendable {
        /// hc refuses the session's name, or a native Windows Host cannot carry it, so
        /// the locator did not run.
        case sessionRefused(reason: String)
        case notInstalled
        case notRunning(version: String, socketPath: String)
        case socketFilePresent(version: String, socketPath: String)
        case socketPathTooLong(version: String, socketPath: String, limit: Int)
    }

    /// What the probe says of tmux, through the login shell. A server is one
    /// that answered: a socket file a killed server left behind is not one.
    enum TmuxFinding: Equatable, Sendable {
        /// Not macOS or Linux, where Heeler drives no tmux.
        case unsupported
        /// The probe's part of the output did not read.
        case unreadable
        case notInstalled
        /// Older than `TmuxVersion.minimum`.
        case updateRequired(version: String)
        case notRunning(version: String)
        /// The sockets a server answers on, `default` first when it is one.
        case running(version: String, sockets: [String])
    }

    /// What the Rex probe says, from files alone (ADR 0048). A socket file is
    /// all it can report of a running server.
    enum RexFinding: Equatable, Sendable {
        /// Not macOS or Linux, where Heeler finds no Rex server.
        case unsupported
        /// The probe's part of the output did not read.
        case unreadable
        case notInstalled
        /// Rex is there, and no socket says a server listens.
        case notRunning
        /// Only sockets this account may not connect to, such as another
        /// account's server.
        case notUsable(socketPath: String)
        case socketFound(socketPath: String)
    }

    let herdrTUI: HerdrTUIFinding
    let herdrCore: CoreFinding
    let tmux: TmuxFinding
    let rex: RexFinding
    /// What the probe read, for the paths a confirmed tmux Host stores.
    private let tmuxReport: TmuxProbe.Report?
    /// The one fact a refused session name still leaves: which exec this Host took.
    let isNativeWindows: Bool

    /// `herdr session list --json`, as a bare exec of it runs. It only looks at
    /// each session's socket (docs/agents/herdr-compatibility.md).
    private static let herdrRead =
        "\(HerdrHostPath.pathExport); exec \(SSHTransportSettings.defaultSessionListCommand)"

    static func script(session: String, nonce: String) -> Data {
        ServerKindDetectionScript.script(session: session, nonce: nonce, herdrRead: herdrRead)
    }

    /// The one exec. It throws when the exec failed or its output was cut short,
    /// which says nothing about what the Host runs. A native Windows Host is
    /// never asked about tmux or Rex.
    static func run(
        over connection: any ServerKindDetectionConnection, session: String,
        nonce: String = UUID().uuidString
    ) async throws -> ServerKindDetection {
        let platform = try await connection.corePlatform()
        let result =
            platform == .nativeWindows
            ? try await connection.runWindowsCommand(
                ServerKindDetectionScript.windowsCommand(session: session, nonce: nonce), for: .serverKindDetection)
            : try await connection.runServerKindDetection(script(session: session, nonce: nonce))
        guard result.exitStatus == 0 else {
            throw TransportError.malformedResponse(
                String(localized: "Server Kind detection exited with status \(result.exitStatus)."))
        }
        do {
            return ServerKindDetection(
                try ServerKindDetectionScript.parse(
                    stdout: result.stdout, session: session, nonce: nonce, platform: platform),
                session: session, isNativeWindows: platform == .nativeWindows)
        } catch {
            throw TransportError.malformedResponse(String(localized: "Server Kind detection's output is unreadable."))
        }
    }

    init(_ output: ServerKindDetectionScript.Output, session: String, isNativeWindows: Bool = false) {
        self.isNativeWindows = isNativeWindows
        herdrTUI = Self.herdrTUI(status: output.herdrStatus, output: output.herdrOutput)
        herdrCore = Self.herdrCore(output.location, session: session)
        tmuxReport = output.tmux
        tmux = Self.tmux(output.tmux, isNativeWindows: isNativeWindows)
        rex = Self.rex(output.rex, isNativeWindows: isNativeWindows)
    }

    private struct SessionList: Decodable {
        let sessions: [HerdrSession]
    }

    private static func herdrTUI(status: Int32, output: Data) -> HerdrTUIFinding {
        guard status == 0, let list = try? JSONDecoder().decode(SessionList.self, from: output),
            list.sessions.allSatisfy({ HerdrSessionName.isValid($0.name) })
        else { return .notFound }
        return .found(sessions: list.sessions)
    }

    private static func herdrCore(_ location: HerdrCoreLocator.Location?, session: String) -> CoreFinding {
        guard let location else {
            return .sessionRefused(
                reason: ServerKind.herdrCore.sessionNameRefusal(session)
                    ?? HerdrCoreSessionName.windowsRefusal(session) ?? "")
        }
        guard let version = location.version, location.executablePath != nil else { return .notInstalled }
        if !location.fitsSocketPathLimit {
            return .socketPathTooLong(
                version: version, socketPath: location.socketPath, limit: location.socketPathLimit)
        }
        return location.socketFilePresent
            ? .socketFilePresent(version: version, socketPath: location.socketPath)
            : .notRunning(version: version, socketPath: location.socketPath)
    }

    private static func tmux(_ report: TmuxProbe.Report?, isNativeWindows: Bool) -> TmuxFinding {
        guard !isNativeWindows else { return .unsupported }
        guard let report else { return .unreadable }
        guard let kernel = report.kernel, tmuxKernels.contains(kernel) else { return .unsupported }
        switch report.installation {
        case .notInstalled: return .notInstalled
        case .updateRequired(let version): return .updateRequired(version: version)
        case .usable(_, let version):
            guard !report.sockets.isEmpty else { return .notRunning(version: version) }
            let defaultName = TmuxSocketName.defaultName
            let sockets =
                report.sockets.filter { $0 == defaultName } + report.sockets.filter { $0 != defaultName }
            return .running(version: version, sockets: sockets)
        }
    }

    private static let tmuxKernels = [HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel]

    /// What a Rex probe's report says. Detection and a Rex Host's checks read
    /// it the same way.
    static func rex(_ report: RexProbe.Report?, isNativeWindows: Bool = false) -> RexFinding {
        guard !isNativeWindows else { return .unsupported }
        guard let report else { return .unreadable }
        guard let kernel = report.kernel, rexKernels.contains(kernel) else { return .unsupported }
        // A path this build cannot name as one shell word is no socket it could use.
        if let usable = report.preferredSocket(where: { RexSocket(path: $0) != nil }) {
            return .socketFound(socketPath: usable.path)
        }
        if let socket = report.sockets.first {
            return .notUsable(socketPath: socket.path)
        }
        return report.isInstalled ? .notRunning : .notInstalled
    }

    private static let rexKernels = [HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel]

    /// The socket a Rex Host confirmed from this detection stores.
    var rexSocket: RexSocket? {
        guard case .socketFound(let path) = rex else { return nil }
        return RexSocket(path: path)
    }

    /// The sockets a tmux server answers on, for the user to pick one.
    var tmuxSockets: [String] {
        if case .running(_, let sockets) = tmux { sockets } else { [] }
    }

    /// The socket a confirmation starts on: the typed name when its server
    /// answers, else `default`, else the first that does. With no server
    /// answering, the typed name stands, and `default` for a blank one.
    func preselectedTmuxSocket(typed: String) -> String {
        let name = TmuxSocketName.normalized(typed)
        let sockets = tmuxSockets
        if sockets.contains(name) { return name }
        return sockets.first ?? name
    }

    /// What a tmux Host confirmed on this socket stores, from this same read:
    /// its login shell just resolved both. Nil when tmux is not there to store.
    func tmuxPaths(socketName: String) -> TmuxPaths? {
        guard let tmuxReport, case .usable(let executable, _) = tmuxReport.installation,
            let socket = tmuxReport.socketPath(named: socketName)
        else { return nil }
        return TmuxPaths(executable: executable, socket: socket)
    }

    /// The kinds this target runs, in the order the confirmation lists them.
    var foundKinds: [ServerKind] {
        var kinds: [ServerKind] = []
        if case .found = herdrTUI { kinds.append(.herdrTUI) }
        switch herdrCore {
        case .notInstalled, .sessionRefused: break
        case .notRunning, .socketFilePresent, .socketPathTooLong: kinds.append(.herdrCore)
        }
        if case .running = tmux { kinds.append(.tmux) }
        if rexSocket != nil { kinds.append(.rex) }
        return kinds
    }

    /// Every kind this target could be: all but tmux where Heeler drives none.
    /// Rex is never among them: it is offered only where its socket was found.
    var supportedKinds: [ServerKind] {
        Self.offeredWithoutFindings.filter { $0 != .tmux || tmux != .unsupported }
    }

    /// What the user may confirm. A target running nothing yet offers every kind:
    /// the user may be about to install one, and its preflight says how. A refused
    /// session name keeps herdr-core on offer, since only the name stands in its way
    /// and confirming says why. A tmux with no server running stays on offer beside
    /// whatever was found: its Host connects once the user starts one (ADR 0044).
    /// Rex is on offer exactly when a socket this account may use was found,
    /// since Heeler never starts its server (ADR 0048).
    var offeredKinds: [ServerKind] {
        if case .sessionRefused = herdrCore { return supportedKinds + (rexSocket != nil ? [.rex] : []) }
        let found = foundKinds
        guard !found.isEmpty else { return supportedKinds }
        if case .notRunning = tmux { return found + [.tmux] }
        return found
    }

    /// What is on offer when a reached Host could not be read because the exec failed.
    static let offeredWithoutFindings: [ServerKind] = [.herdrTUI, .herdrCore, .tmux]
}

extension ServerKindDetection.HerdrTUIFinding {
    var summary: String {
        switch self {
        case .found: String(localized: "Found")
        case .notFound: String(localized: "Not found")
        }
    }
}

extension ServerKindDetection.TmuxFinding {
    var summary: String {
        switch self {
        case .unsupported: String(localized: "Not supported on this Host")
        case .unreadable: String(localized: "Could not read")
        case .notInstalled: String(localized: "Not installed")
        case .updateRequired(let version):
            String(localized: "\(version), needs \(TmuxVersion.minimum) or newer")
        case .notRunning(let version): String(localized: "\(version), no server running")
        case .running(let version, _): String(localized: "\(version), running")
        }
    }
}

extension RexProbe {
    /// The probe alone, in one bounded exec, for a Rex Host's checks: what
    /// detection would say of Rex now. A native Windows Host is never asked.
    static func run(
        over connection: any ServerKindDetectionConnection, nonce: String = UUID().uuidString
    ) async throws -> ServerKindDetection.RexFinding {
        guard try await connection.corePlatform() == .posix else { return .unsupported }
        let result = try await connection.runServerKindDetection(Data(script(nonce: nonce).utf8))
        guard result.exitStatus == 0 else {
            throw TransportError.malformedResponse(
                String(localized: "Server Kind detection exited with status \(result.exitStatus)."))
        }
        return ServerKindDetection.rex(try? parse(stdout: result.stdout, nonce: nonce))
    }
}

extension ServerKindDetection.RexFinding {
    var summary: String {
        switch self {
        case .unsupported: String(localized: "Not supported on this Host")
        case .unreadable: String(localized: "Could not read")
        case .notInstalled: String(localized: "Not found")
        case .notRunning: String(localized: "Installed, not running")
        case .notUsable: String(localized: "Socket found, but this account cannot use it")
        case .socketFound: String(localized: "Socket found")
        }
    }
}

extension ServerKindDetection.CoreFinding {
    var summary: String {
        switch self {
        case .sessionRefused: String(localized: "Session name refused")
        case .notInstalled: String(localized: "Not installed")
        case .notRunning(let version, _): String(localized: "\(version), not running")
        case .socketFilePresent(let version, let path):
            HerdrCoreLocator.isWindowsPipe(path)
                ? String(localized: "\(version), running") : String(localized: "\(version), socket found")
        case .socketPathTooLong(let version, _, _): String(localized: "\(version), socket path too long")
        }
    }
}
