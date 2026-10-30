import Foundation

/// The SSH connection a detection runs over: one bounded exec, then close.
protocol ServerKindDetectionConnection: Sendable {
    func runServerKindDetection(_ script: Data) async throws -> GitExecResult

    func close() async throws
}

/// Which servers an SSH target runs, for the user to confirm one (ADR 0031).
struct ServerKindDetection: Equatable, Sendable {
    enum HerdrTUIFinding: Equatable, Sendable {
        case found(sessions: [HerdrSession])
        case notFound
    }

    /// What the locator says of the typed session's core. Only `hello` can prove
    /// a core answers, so a socket file is all it can report of a running one.
    enum CoreFinding: Equatable, Sendable {
        /// hc refuses the session's name, so the locator did not run.
        case sessionRefused(reason: String)
        case notInstalled
        case notRunning(version: String, socketPath: String)
        case socketFilePresent(version: String, socketPath: String)
        case socketPathTooLong(version: String, socketPath: String, limit: Int)
    }

    let herdrTUI: HerdrTUIFinding
    let herdrCore: CoreFinding

    /// `herdr session list --json`, as a bare exec of it runs. It only looks at
    /// each session's socket (docs/agents/herdr-compatibility.md).
    private static let herdrRead =
        "\(HerdrHostPath.pathExport); exec \(SSHTransportSettings.defaultSessionListCommand)"

    static func script(session: String, nonce: String) -> Data {
        ServerKindDetectionScript.script(session: session, nonce: nonce, herdrRead: herdrRead)
    }

    /// The one exec. It throws when the exec failed or its output was cut short,
    /// which says nothing about what the Host runs.
    static func run(
        over connection: any ServerKindDetectionConnection, session: String,
        nonce: String = UUID().uuidString
    ) async throws -> ServerKindDetection {
        let result = try await connection.runServerKindDetection(script(session: session, nonce: nonce))
        guard result.exitStatus == 0 else {
            throw TransportError.malformedResponse(
                "Server Kind detection exited with status \(result.exitStatus).")
        }
        do {
            return ServerKindDetection(
                try ServerKindDetectionScript.parse(stdout: result.stdout, session: session, nonce: nonce),
                session: session)
        } catch {
            throw TransportError.malformedResponse("Server Kind detection's output is unreadable.")
        }
    }

    init(_ output: ServerKindDetectionScript.Output, session: String) {
        herdrTUI = Self.herdrTUI(status: output.herdrStatus, output: output.herdrOutput)
        herdrCore = Self.herdrCore(output.location, session: session)
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
            return .sessionRefused(reason: ServerKind.herdrCore.sessionNameRefusal(session) ?? "")
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

    /// The kinds this target runs, in the order the confirmation lists them.
    var foundKinds: [ServerKind] {
        var kinds: [ServerKind] = []
        if case .found = herdrTUI { kinds.append(.herdrTUI) }
        switch herdrCore {
        case .notInstalled, .sessionRefused: break
        case .notRunning, .socketFilePresent, .socketPathTooLong: kinds.append(.herdrCore)
        }
        return kinds
    }

    /// What the user may confirm. A target running nothing yet offers every kind
    /// on offer: the user may be about to install one, and its preflight says how.
    /// A session name hc refuses keeps herdr-core on offer, since only the name
    /// stands in its way and confirming says why.
    func offeredKinds(offersCore: Bool) -> [ServerKind] {
        let everyKind = Self.offeredWithoutFindings(offersCore: offersCore)
        guard offersCore else { return everyKind }
        if case .sessionRefused = herdrCore { return everyKind }
        return foundKinds.isEmpty ? everyKind : foundKinds
    }

    /// What is on offer when a reached Host could not be read: the exec failed,
    /// or the Host's platform has no probe yet.
    static func offeredWithoutFindings(offersCore: Bool) -> [ServerKind] {
        offersCore ? [.herdrTUI, .herdrCore] : [.herdrTUI]
    }
}

extension ServerKindDetection.HerdrTUIFinding {
    var summary: String {
        switch self {
        case .found: "Found"
        case .notFound: "Not found"
        }
    }
}

extension ServerKindDetection.CoreFinding {
    var summary: String {
        switch self {
        case .sessionRefused: "Session name refused"
        case .notInstalled: "Not installed"
        case .notRunning(let version, _): "\(version), not running"
        case .socketFilePresent(let version, _): "\(version), socket found"
        case .socketPathTooLong(let version, _, _): "\(version), socket path too long"
        }
    }
}

extension ServerKind {
    /// Offers herdr-core when adding a Host, for lab and Simulator work.
    static let offerCoreHostsArgument = "--offer-herdr-core-hosts"

    /// Whether the confirmation offers this kind when adding a Host.
    func isOfferedOnAdd(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        switch self {
        case .herdrTUI: true
        case .herdrCore: arguments.contains(Self.offerCoreHostsArgument)
        case .unconfirmed: false
        }
    }
}
