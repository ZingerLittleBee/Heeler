import Foundation

/// What a herdr-core Host offers the app, beside and never through the Herdr
/// TUI `Transport` (ADR 0031). Connecting never starts a core: a Host with
/// none running reads as `TransportError.herdrCoreNotRunning`.
protocol HerdrCoreTransport: Sendable {
    /// The route that won the dial; nil when there was only ever one way in.
    nonisolated var routeID: UUID? { get }

    /// The Host's exec and SFTP services, on the same SSH connection.
    nonisolated var hostServices: any HostServices { get }

    /// This connection's exec and SFTP, for the Host Helper, which works with
    /// or without a running core (ADR 0033).
    nonisolated var hostHelperHost: any HostHelperHost { get }

    /// Whether the SSH connection is up, whatever became of the link on it.
    var isConnected: Bool { get async }

    /// Runs the read-only locator once. Its facts are also what `hello` acts on.
    func locate() async throws -> HerdrCoreLocator.Location

    /// What the last locator run found, for a caller that reads why `hello` failed.
    func lastLocation() async -> HerdrCoreLocator.Location?

    /// Starts the Host's own core session. Only the user's confirmed action
    /// calls this; connecting, preflight and retries never do (ADR 0031).
    func startCore() async throws -> HerdrCoreStart.Outcome

    /// Locates the core, opens the framed link and checks the core's `hello`.
    /// A later call reuses the link while it lives, and opens a new one on the
    /// same SSH connection once it ended.
    func hello() async throws -> HerdrCoreServerInfo

    /// `hello` at the socket the last locator found, without another exec, for
    /// polling a channel the core refused while its holder restarts it.
    func helloAtLastLocation() async throws -> HerdrCoreServerInfo

    /// `server.status` over the link, which it opens if it has to.
    func serverStatus() async throws -> HerdrCoreServerStatus

    /// Which variables the core process inherited, by name only (ADR 0034), from
    /// one bounded exec per link that later calls share. Empty when it could not
    /// tell, and nil when there is no live link for the answer to describe. Opens
    /// no link and never fails the connection.
    func leakedEnvironmentNames() async -> Set<String>?

    /// Subscribes to every Terminal's events. Each subscription has a fresh
    /// cursor from its own snapshot, and no event number outlives the link.
    func subscribeEvents() async throws -> HerdrCoreEventStream

    /// One channel-0 call. A mutation the link had already handed to its
    /// writer when the link ended throws `.coreMutationOutcomeUnknown`, and
    /// nothing here sends it again.
    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue

    /// Closes the link, then the connection.
    func close() async throws
}

extension HerdrCoreTransport {
    /// The Terminal's screen. Passive: `lines: 0` never scrolls a full-screen
    /// program, which asking for history would.
    func readTerminal(_ address: String) async throws -> HerdrCoreTerminalRead {
        try HerdrCoreWire.typed(
            await call(
                "terminal.read",
                params: .object(["terminal": .string(try HerdrCoreWire.address(address)), "lines": .number(0)]),
                isMutation: false))
    }
}

/// The parts of an SSH connection a herdr-core transport uses. Real SSH is
/// `HeelerSSHTransport`; tests script the exec and hand over a fake socket.
protocol HerdrCoreHostConnection: HostServices, HostHelperHost {
    nonisolated var routeID: UUID? { get }

    var isConnected: Bool { get async }

    /// Runs the locator's script in one bounded exec.
    func runCoreLocator(_ script: Data) async throws -> GitExecResult

    /// Runs the confirmed Start's script in one bounded exec.
    func runCoreStart(_ script: Data) async throws -> GitExecResult

    /// Runs a `HostProcessReader` script in one bounded exec.
    func runHostProcessRead(_ script: Data) async throws -> GitExecResult

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
    nonisolated var hostServices: any HostServices { connection }
    nonisolated var hostHelperHost: any HostHelperHost { connection }
    private nonisolated let connection: any HerdrCoreHostConnection
    private let session: String
    private let nonce: @Sendable () -> String
    /// Callers that race share one opening. A failed one is not kept, so the
    /// next call looks at the Host again.
    private var opening: Task<Opened, any Error>?
    private var located: HerdrCoreLocator.Location?
    private var environmentCheck: (link: HerdrCoreLink, answer: Task<Set<String>, Never>)?

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

    var isConnected: Bool {
        get async { await connection.isConnected }
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
        try await open(reusingLocation: false).info
    }

    func helloAtLastLocation() async throws -> HerdrCoreServerInfo {
        try await open(reusingLocation: true).info
    }

    func serverStatus() async throws -> HerdrCoreServerStatus {
        try await onLink { link in try await link.serverStatus(deadline: Self.callDeadline) }
    }

    func leakedEnvironmentNames() async -> Set<String>? {
        guard let link = try? await opening?.value.link, await link.isOpen else { return nil }
        let answer: Task<Set<String>, Never>
        if let check = environmentCheck, check.link === link {
            answer = check.answer
        } else {
            answer = Task { await self.readLeakedEnvironment(on: link) }
            environmentCheck = (link, answer)
        }
        let names = await answer.value
        // A core that restarted meanwhile may be a different one.
        guard environmentCheck?.link === link, await link.isOpen else { return nil }
        return names
    }

    private func readLeakedEnvironment(on link: HerdrCoreLink) async -> Set<String> {
        do {
            let pid = try await link.serverStatus(deadline: Self.callDeadline).pid
            let nonce = nonce()
            let script = try HerdrCoreEnvironmentCheck.script(pid: pid, nonce: nonce)
            let result = try await connection.runHostProcessRead(script)
            guard result.exitStatus == 0 else { return [] }
            return HerdrCoreEnvironmentCheck.leakedNames(stdout: result.stdout, nonce: nonce, pid: pid)
        } catch {
            return []
        }
    }

    func subscribeEvents() async throws -> HerdrCoreEventStream {
        try await onLink { link in try await link.subscribeEvents(deadline: Self.callDeadline) }
    }

    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue {
        try await onLink { link in
            try await link.call(method, params: params, deadline: Self.callDeadline, isMutation: isMutation)
        }
    }

    func close() async throws {
        let opening = opening
        self.opening = nil
        opening?.cancel()
        if let opened = try? await opening?.value { await opened.link.close() }
        try await connection.close()
    }

    private func onLink<Value: Sendable>(
        _ operation: @Sendable (HerdrCoreLink) async throws -> Value
    ) async throws -> Value {
        let opened = try await open(reusingLocation: false)
        do {
            return try await operation(opened.link)
        } catch is HerdrCoreUpdateRequired {
            throw TransportError.herdrCoreUpdateRequired(command: Self.updateCommand(opened.executablePath))
        }
    }

    private func open(reusingLocation: Bool) async throws -> Opened {
        while let current = opening {
            let opened = try await current.value
            if await opened.link.isOpen { return opened }
            // A link that ended stays ended: the next one is a new channel.
            if opening == current { opening = nil }
            await opened.link.close()
        }
        let task = Task { try await self.establish(reusingLocation: reusingLocation) }
        opening = task
        do {
            return try await task.value
        } catch {
            if opening == task { opening = nil }
            throw error
        }
    }

    private func establish(reusingLocation: Bool) async throws -> Opened {
        let location: HerdrCoreLocator.Location
        if reusingLocation, let located {
            location = located
        } else {
            location = try await locate()
        }
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
