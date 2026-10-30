import Foundation

/// What a herdr-core Host offers the app, beside and never through the Herdr
/// TUI `Transport` (ADR 0031). Connecting never starts a core: a Host with
/// none running reads as `TransportError.herdrCoreNotRunning`.
protocol HerdrCoreTransport: Sendable {
    /// The route that won the dial; nil when there was only ever one way in.
    nonisolated var routeID: UUID? { get }

    /// Runs the read-only locator once. Its facts are also what `hello` acts on.
    func locate() async throws -> HerdrCoreLocator.Location

    /// What the last locator run found, for a caller that reads why `hello` failed.
    func lastLocation() async -> HerdrCoreLocator.Location?

    /// Starts the Host's own core session. Only the user's confirmed action
    /// calls this; connecting, preflight and retries never do (ADR 0031).
    func startCore() async throws -> HerdrCoreStart.Outcome

    /// Locates the core, opens the framed link and checks the core's `hello`.
    /// A later call reuses the open link.
    func hello() async throws -> HerdrCoreServerInfo

    /// `server.status` over the link, which it opens if it has to.
    func serverStatus() async throws -> HerdrCoreServerStatus

    /// Closes the link, then the connection.
    func close() async throws
}

/// The parts of an SSH connection a herdr-core transport uses. Real SSH is
/// `HeelerSSHTransport`; tests script the exec and hand over a fake socket.
protocol HerdrCoreHostConnection: Sendable {
    nonisolated var routeID: UUID? { get }

    /// Runs the locator's script in one bounded exec.
    func runCoreLocator(_ script: Data) async throws -> GitExecResult

    /// Runs the confirmed Start's script in one bounded exec.
    func runCoreStart(_ script: Data) async throws -> GitExecResult

    /// Opens a direct-streamlocal channel under the long-lived events slot.
    /// A channel nobody answers throws `TransportError.streamLocalOpenFailed`.
    func openCoreLinkChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel

    func close() async throws
}

/// The framed Unix transport: one locator exec, then one link over a forwarded
/// channel to the socket it found.
actor HerdrCoreSSHTransport: HerdrCoreTransport {
    private static let callDeadline: Duration = .seconds(10)

    nonisolated let routeID: UUID?
    private let connection: any HerdrCoreHostConnection
    private let session: String
    private let nonce: @Sendable () -> String
    /// Callers that race share one opening. A failed one is not kept, so the
    /// next call looks at the Host again.
    private var opening: Task<Opened, any Error>?
    private var located: HerdrCoreLocator.Location?

    private struct Opened {
        let link: HerdrCoreLink
        let info: HerdrCoreServerInfo
        let executablePath: String
    }

    init(
        connection: any HerdrCoreHostConnection,
        session: String,
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        routeID = connection.routeID
        self.connection = connection
        self.session = session
        self.nonce = nonce
    }

    func locate() async throws -> HerdrCoreLocator.Location {
        let nonce = nonce()
        let script: Data
        do {
            script = try HerdrCoreLocator.script(session: session, nonce: nonce)
        } catch is HerdrCoreLocator.SessionRefused {
            throw TransportError.hostFeatureUnavailable(
                feature: "herdr-core refuses the session name \"\(session)\"")
        }
        let result = try await connection.runCoreLocator(script)
        guard result.exitStatus == 0 else {
            throw TransportError.malformedResponse(
                "herdr-core: The locator exited with status \(result.exitStatus).")
        }
        do {
            let location = try HerdrCoreLocator.parse(stdout: result.stdout, nonce: nonce)
            located = location
            return location
        } catch {
            throw TransportError.malformedResponse("herdr-core: The locator's output is unreadable.")
        }
    }

    func lastLocation() async -> HerdrCoreLocator.Location? {
        located
    }

    /// The core's own clock says how long it has been up, so the elapsed time is
    /// measured here and needs no agreement between the two machines' clocks.
    func startCore() async throws -> HerdrCoreStart.Outcome {
        let location = try await locate()
        guard let executablePath = location.executablePath else {
            throw TransportError.herdrCoreNotInstalled
        }
        guard location.appMayStartCore else {
            throw TransportError.hostFeatureUnavailable(
                feature: "Starting herdr-core on \(location.kernel)")
        }
        let script = try HerdrCoreStart.script(executablePath: executablePath, session: session)
        let clock = ContinuousClock()
        let sent = clock.now
        let result = try await connection.runCoreStart(script)
        return HerdrCoreStart.outcome(
            stdout: result.stdout, stderr: result.stderr, exitStatus: result.exitStatus,
            elapsed: sent.duration(to: clock.now))
    }

    func hello() async throws -> HerdrCoreServerInfo {
        try await open().info
    }

    func serverStatus() async throws -> HerdrCoreServerStatus {
        let opened = try await open()
        do {
            return try await opened.link.serverStatus(deadline: Self.callDeadline)
        } catch is HerdrCoreUpdateRequired {
            throw TransportError.herdrCoreUpdateRequired(command: Self.updateCommand(opened.executablePath))
        }
    }

    func close() async throws {
        let opening = opening
        self.opening = nil
        opening?.cancel()
        if let opened = try? await opening?.value { await opened.link.close() }
        try await connection.close()
    }

    private func open() async throws -> Opened {
        if let opening { return try await opening.value }
        let task = Task { try await self.establish() }
        opening = task
        do {
            return try await task.value
        } catch {
            if opening == task { opening = nil }
            throw error
        }
    }

    private func establish() async throws -> Opened {
        let location = try await locate()
        guard let executablePath = location.executablePath else {
            throw TransportError.herdrCoreNotInstalled
        }
        guard location.fitsSocketPathLimit else {
            throw TransportError.herdrCoreSocketPathTooLong(
                path: location.socketPath, limit: location.socketPathLimit)
        }
        let channel: any HeelerSSHAPIChannel
        do {
            channel = try await connection.openCoreLinkChannel(socketPath: location.socketPath)
        } catch TransportError.streamLocalOpenFailed {
            throw TransportError.herdrCoreNotRunning(
                socketPath: location.socketPath, socketFilePresent: location.socketFilePresent)
        }
        do {
            let (link, info) = try await HerdrCoreLink.connect(over: channel, helloDeadline: Self.callDeadline)
            return Opened(link: link, info: info, executablePath: executablePath)
        } catch is HerdrCoreUpdateRequired {
            throw TransportError.herdrCoreUpdateRequired(command: Self.updateCommand(executablePath))
        }
    }

    private static func updateCommand(_ executablePath: String) -> String {
        "\(executablePath) update"
    }
}
