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

    /// One named variable of one process, in one bounded exec, for finding where
    /// that process's program keeps its configuration. Never says why it could not.
    func processVariable(_ name: String, pid: Int) async -> HostProcessReader.Variable

    /// What one request reaches, in one bounded exec. An empty answer is a read
    /// that failed on the Host; a lost connection throws.
    func readProcesses(
        _ request: HostProcessReader.Request
    ) async throws -> [String: HostProcessReader.Facts]

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

    /// Opens a live terminal as a channel of its own on the link, so several
    /// use no further SSH sessions (ADR 0031). `request.takeover` means nothing
    /// to a core; its role says how the viewer joins.
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession

    /// One channel-0 call. A mutation the link had already handed to its
    /// writer when the link ended throws `.coreMutationOutcomeUnknown`, and
    /// nothing here sends it again.
    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue

    /// The user's shell for a launch, which supplies the Agent's PATH and
    /// variables: the login shell the locator reports, else the `SHELL` the core
    /// process holds, read by name (ADR 0032). Throws when the Host says neither.
    func launchShell() async throws -> String

    /// Runs installed-agent discovery's script in one bounded exec.
    func runAgentDiscovery(_ script: Data) async throws -> GitExecResult

    /// `terminal.run`, as a mutation: with no answer it throws
    /// `.coreMutationOutcomeUnknown`, and nothing here sends it again.
    func runTerminal(params: JSONValue) async throws -> JSONValue

    /// `terminal.run` of a Template, which answers only once the program first
    /// reports, under the long deadline that wait needs. Otherwise as `runTerminal`.
    func runTemplate(params: JSONValue) async throws -> JSONValue

    /// Whether the Herdr desktop app answers `herdr-app status` on this Host, in
    /// one bounded exec. Any other outcome reads as false (ADR 0032).
    func desktopAppIsRunning() async -> Bool

    /// `herdr-app do space.rename` once, in one bounded exec. The app's refusal
    /// throws `HerdrAppControl.Refused`, and no answer throws
    /// `.coreMutationOutcomeUnknown`. Nothing here sends it again.
    func renameDesktopSpace(_ space: String, name: String) async throws

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

    /// The Terminal's record as the core knows it now, foreground included.
    func terminalRecord(_ address: String) async throws -> HerdrCoreTerminalRecord {
        try HerdrCoreWire.typed(
            await call(
                "terminal.get",
                params: .object(["terminal": .string(try HerdrCoreWire.address(address))]),
                isMutation: false))
    }

    /// `terminal.interrupt`, sent once as a mutation: the core presses the
    /// Terminal's own stop key, then watches for an effect for up to `timeout`.
    /// Its answer does not say whether the program still runs, so it is not read.
    func interruptTerminal(_ address: String, timeout: Duration) async throws {
        _ = try await call(
            "terminal.interrupt",
            params: .object([
                "terminal": .string(try HerdrCoreWire.address(address)),
                "timeout": .number(timeout / .seconds(1)),
            ]),
            isMutation: true)
    }

    /// The Templates the core can run now, from its own files on each ask.
    func listTemplates() async throws -> [AgentTemplate] {
        HerdrCoreLaunch.templates(
            result: try await call("templates.list", params: .object([:]), isMutation: false))
    }

    /// Ends a Terminal for good with `terminal.kill`, sent once as a mutation. A
    /// kill is final even on a kept Terminal, so keep stays as it is. Unless the
    /// core says the Terminal ended, or no longer knows it, this throws
    /// `.coreMutationOutcomeUnknown`: a core that gave up on a stuck program still
    /// ends the Terminal when the program goes.
    func killTerminal(_ address: String) async throws {
        let reply: JSONValue
        do {
            reply = try await call(
                "terminal.kill",
                params: .object(["terminal": .string(try HerdrCoreWire.address(address))]),
                isMutation: true)
        } catch let refusal as HerdrAPIError where refusal.code == "not_found" {
            return
        }
        guard let record = try? HerdrCoreWire.typed(reply) as HerdrCoreTerminalRecord,
            record.hasFinished
        else {
            throw TransportError.coreMutationOutcomeUnknown
        }
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

    /// Runs a script that goes through the user's interactive shell, with room
    /// for its startup files, in one bounded exec.
    func runAgentDiscovery(_ script: Data) async throws -> GitExecResult

    /// Runs a `HerdrAppControl` script in one bounded exec, with room for the
    /// five seconds the app's control socket gives its window to answer.
    func runHerdrAppControl(_ script: Data) async throws -> GitExecResult

    /// Opens a direct-streamlocal channel under the long-lived events slot.
    /// A channel nobody answers throws `TransportError.streamLocalOpenFailed`.
    func openCoreLinkChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel

    func close() async throws
}

/// The framed Unix transport: one locator exec, then one link over a forwarded
/// channel to the socket it found.
actor HerdrCoreSSHTransport: HerdrCoreTransport {
    private static let callDeadline: Duration = .seconds(10)
    /// The core itself gives a program 10 seconds to spawn, after starting a
    /// holder for the first Terminal, and says so when it fails.
    private static let runDeadline: Duration = .seconds(20)
    /// A Template's call also waits 30 seconds for the program's first report and
    /// 5 to see it start on the first message, and the spawn's 10 and a person's
    /// 3 of quiet can add to that. Past a healthy worst case, an expiry means no answer.
    private static let templateRunDeadline: Duration = .seconds(50)

    nonisolated let routeID: UUID?
    nonisolated var hostServices: any HostServices { connection }
    nonisolated var hostHelperHost: any HostHelperHost { connection }
    private nonisolated let connection: any HerdrCoreHostConnection
    private let session: String
    private let nonce: @Sendable () -> String
    private let sleep: HerdrCoreLink.Sleep
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
        nonce: @escaping @Sendable () -> String = { UUID().uuidString },
        sleep: @escaping HerdrCoreLink.Sleep = { try await Task.sleep(for: $0) }
    ) {
        routeID = connection.routeID
        self.connection = connection
        self.session = session
        self.nonce = nonce
        self.sleep = sleep
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
        if HerdrCoreLocator.wasCutShort(stdout: result.stdout, exitStatus: result.exitStatus, nonce: nonce) {
            throw TransportError.channelFailed(detail: "herdr-core: The locator was cut short.")
        }
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

    func processVariable(_ name: String, pid: Int) async -> HostProcessReader.Variable {
        do {
            let request = HostProcessReader.Request(pids: [String(pid)], valuesOf: [name])
            let nonce = nonce()
            let script = try HostProcessReader.script(request, nonce: nonce)
            let result = try await connection.runHostProcessRead(script)
            guard result.exitStatus == 0 else { return .unavailable }
            let facts = try HostProcessReader.parse(stdout: result.stdout, nonce: nonce, request: request)
            return facts[String(pid)]?.variables[name] ?? .unavailable
        } catch {
            return .unavailable
        }
    }

    func readProcesses(
        _ request: HostProcessReader.Request
    ) async throws -> [String: HostProcessReader.Facts] {
        let nonce = nonce()
        let script = try HostProcessReader.script(request, nonce: nonce)
        let result = try await connection.runHostProcessRead(script)
        guard result.exitStatus == 0 else { return [:] }
        return (try? HostProcessReader.parse(stdout: result.stdout, nonce: nonce, request: request)) ?? [:]
    }

    func subscribeEvents() async throws -> HerdrCoreEventStream {
        try await onLink { link in try await link.subscribeEvents(deadline: Self.callDeadline) }
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        try await onLink { link in
            try await HerdrCoreAttach.open(on: link, request: request, deadline: Self.callDeadline)
        }
    }

    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue {
        try await onLink { link in
            try await link.call(method, params: params, deadline: Self.callDeadline, isMutation: isMutation)
        }
    }

    func launchShell() async throws -> String {
        let location = if let located { located } else { try await locate() }
        if let shell = location.loginShell, !shell.isEmpty { return shell }
        let pid = String(try await serverStatus().pid)
        let request = HostProcessReader.Request(pids: [pid], valuesOf: ["SHELL"])
        let nonce = nonce()
        let result = try await connection.runHostProcessRead(
            try HostProcessReader.script(request, nonce: nonce))
        guard result.exitStatus == 0,
            let facts = try? HostProcessReader.parse(stdout: result.stdout, nonce: nonce, request: request),
            case .value(let shell)? = facts[pid]?.variables["SHELL"], !shell.isEmpty
        else {
            throw TransportError.hostFeatureUnavailable(
                feature: "Starting an Agent needs your login shell, which this Host does not report")
        }
        return shell
    }

    func runAgentDiscovery(_ script: Data) async throws -> GitExecResult {
        try await connection.runAgentDiscovery(script)
    }

    func runTerminal(params: JSONValue) async throws -> JSONValue {
        try await onLink { link in
            try await link.call("terminal.run", params: params, deadline: Self.runDeadline, isMutation: true)
        }
    }

    func runTemplate(params: JSONValue) async throws -> JSONValue {
        try await onLink { link in
            try await link.call(
                "terminal.run", params: params, deadline: Self.templateRunDeadline, isMutation: true)
        }
    }

    func desktopAppIsRunning() async -> Bool {
        let nonce = nonce()
        guard
            let result = try? await connection.runHerdrAppControl(
                HerdrAppControl.statusScript(nonce: nonce))
        else { return false }
        return HerdrAppControl.isRunning(result, nonce: nonce)
    }

    func renameDesktopSpace(_ space: String, name: String) async throws {
        let nonce = nonce()
        let script = try HerdrAppControl.renameScript(spaceID: space, name: name, nonce: nonce)
        let result: GitExecResult
        do {
            result = try await connection.runHerdrAppControl(script)
        } catch {
            throw TransportError.coreMutationOutcomeUnknown
        }
        switch HerdrAppControl.doOutcome(result, nonce: nonce) {
        case .done:
            return
        case .refused(let reason):
            throw HerdrAppControl.Refused(reason: reason)
        case .unknown:
            throw TransportError.coreMutationOutcomeUnknown
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
            let (link, info) = try await HerdrCoreLink.connect(
                over: channel, helloDeadline: Self.callDeadline, sleep: sleep)
            return Opened(link: link, info: info, executablePath: executablePath)
        } catch is HerdrCoreUpdateRequired {
            throw TransportError.herdrCoreUpdateRequired(command: Self.updateCommand(executablePath))
        }
    }

    private static func updateCommand(_ executablePath: String) -> String {
        "\(executablePath) update"
    }
}
