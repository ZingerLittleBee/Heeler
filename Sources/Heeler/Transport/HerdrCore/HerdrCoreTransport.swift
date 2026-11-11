import Foundation

/// What a herdr-core Host offers the app, beside and never through the Herdr
/// TUI `Transport` (ADR 0031). Connecting never starts a core: a Host with
/// none running reads as `TransportError.herdrCoreNotRunning`.
protocol HerdrCoreTransport: HostHelperConnection {
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

    /// What this connection has learned of the Host's kernel, reading no Host.
    func lastKernel() async -> String?

    /// Whether a Staged file goes through the core's `terminal.put` rather than
    /// over SFTP: a native Windows Host's does (ADR 0032).
    func stagesThroughCore() async throws -> Bool

    /// Writes one file beside the Terminal at `address` on the core `coreID` names,
    /// and returns the path the core gives it. Past the limit it throws before
    /// anything is sent. See `HerdrCoreStaging`.
    func putFile(_ source: HerdrCoreStaging.Source, terminal address: String, coreID: String?) async throws -> String

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
    /// cursor from its own snapshot, and no event number outlives the link. Its
    /// snapshot is what the addresses in later calls come from, so once a
    /// reopened link reaches another core those calls throw
    /// `.herdrCoreInventoryStale`, with nothing sent, until the next subscribe.
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
    /// On native Windows it is PowerShell, with no read.
    func launchShell() async throws -> String

    /// Runs installed-agent discovery in one bounded exec.
    func runAgentDiscovery(_ discovery: HerdrCoreAgentDiscovery) async throws -> GitExecResult

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

    /// The Checkout of each directory, for naming a space and knowing a Worktree,
    /// by the Host's platform. As `HostServices.checkouts`, a directory in no
    /// checkout has no entry. On native Windows it knows only the top level.
    func checkouts(for directories: [String]) async throws -> [String: HostCheckout]

    /// Closes the link, then the connection.
    func close() async throws
}

extension HerdrCoreTransport {
    func lastKernel() async -> String? {
        await lastLocation()?.kernel
    }

    /// The home folder a native Windows Host's locator reported, as that machine writes
    /// it, nil anywhere else. `RemoteFilePath.windowsForSFTP` gives the form SFTP opens.
    func locatedWindowsHome() async -> String? {
        guard let location = await lastLocation(), location.isNativeWindows else { return nil }
        return location.home
    }

    /// The Host's home folder as it writes it: the locator's on native Windows, where
    /// `HostServices.hostHomeDirectory` refuses to answer.
    func homeDirectory() async throws -> String {
        if let home = await locatedWindowsHome() { return home }
        return try await hostServices.hostHomeDirectory()
    }

    /// The core's `hello`. A channel refused with the socket file present may be
    /// a core its holder is about to restart, so it is polled before the failure
    /// is believed, without running the locator again. A missing socket file
    /// reads not running at once. `sleep` throws to stop the wait, as `isWanted`
    /// returning false does.
    func helloAcrossHolderRestart(
        policy: HerdrCoreHolderRestartPolicy,
        sleep: @Sendable (Duration) async throws -> Void,
        isWanted: @Sendable () async -> Bool
    ) async throws -> HerdrCoreServerInfo {
        do {
            return try await hello()
        } catch TransportError.herdrCoreNotRunning(socketPath: let path, socketFilePresent: true) {
            for _ in 0..<policy.polls {
                try await sleep(policy.pollInterval)
                guard await isWanted() else { throw TransportError.cancelled }
                do {
                    return try await helloAtLastLocation()
                } catch TransportError.herdrCoreNotRunning(socketPath: _, socketFilePresent: true) {
                    continue
                }
            }
            throw TransportError.herdrCoreNotRunning(socketPath: path, socketFilePresent: true)
        }
    }

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

/// Installed-agent discovery in the form its Host runs: a script for the bounded
/// runner to feed a shell, or a whole command line to exec.
enum HerdrCoreAgentDiscovery: Sendable {
    case posixScript(Data)
    case windowsCommand(String)
}

/// What a whole command line on a native Windows Host is for, which sets how long it
/// gets. Unlike the POSIX scripts, none of these needs a marker of its own: SSH reaps
/// the channel when the time is up.
enum WindowsHostExec: Sendable {
    case locator, checkoutRead, processRead, serverKindDetection, agentDiscovery

    /// PowerShell's own start takes a few seconds on a slow machine. Discovery also
    /// loads the user's profile, as its POSIX script runs startup files.
    var bound: Duration {
        self == .agentDiscovery ? .seconds(25) : .seconds(20)
    }
}

/// The parts of an SSH connection a herdr-core transport uses. Real SSH is
/// `HeelerSSHTransport`; tests script the exec and hand over a fake socket.
protocol HerdrCoreHostConnection: HostServices, HostHelperHost {
    nonisolated var routeID: UUID? { get }

    var isConnected: Bool { get async }

    /// Which path this Host takes. A platform branch, known before any channel
    /// opens, so a Unix Host's refused channel can never lead to the Windows path.
    /// Unlike `hostPlatform`, a Host whose home could not be read answers POSIX.
    func corePlatform() async throws -> HostPlatform

    /// Runs the locator's script in one bounded exec.
    func runCoreLocator(_ script: Data) async throws -> GitExecResult

    /// Runs a whole command line on a native Windows Host in one bounded exec.
    func runWindowsCommand(_ command: String, for purpose: WindowsHostExec) async throws -> GitExecResult

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

    /// Opens a native Windows Host's link as one exec under that same slot, since a
    /// pipe cannot be forwarded. The caller owes it the pipe check first (ADR 0031).
    func openCoreLinkExec(command: String) async throws -> any WindowsTerminalExecChannel

    /// The same exec for one long call beside the link, which holds that slot for its
    /// whole life, so this one must not wait for it. The caller owes it the pipe check too.
    func openCoreCallExec(command: String) async throws -> any WindowsTerminalExecChannel

    func close() async throws
}

/// The framed transport: one locator exec, then one link to the core it found,
/// over a forwarded channel on Unix and one exec of `connect` on native Windows.
/// That choice is the Host's platform, never a fallback (ADR 0031).
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
    /// Answered once per connection. A failure is not kept.
    private var platform: HostPlatform?
    private var environmentCheck: (link: HerdrCoreLink, answer: Task<Set<String>, Never>)?
    /// The core of the last subscribe. Nil before one, as on a preflight.
    private var inventoryCoreID: String?
    /// The links of calls in flight, each one call's, for `close` to end.
    private var callLinks: [HerdrCoreLink] = []

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
        let result = try await runLocator(nonce: nonce)
        if HerdrCoreLocator.wasCutShort(stdout: result.stdout, exitStatus: result.exitStatus, nonce: nonce) {
            throw TransportError.channelFailed(detail: String(localized: "herdr-core: The locator was cut short."))
        }
        guard result.exitStatus == 0 else {
            throw TransportError.malformedResponse(
                String(localized: "herdr-core: The locator exited with status \(result.exitStatus)."))
        }
        do {
            let location = try HerdrCoreLocator.parse(stdout: result.stdout, nonce: nonce)
            located = location
            return location
        } catch {
            throw TransportError.malformedResponse(
                String(localized: "herdr-core: The locator's output is unreadable."))
        }
    }

    private func runLocator(nonce: String) async throws -> GitExecResult {
        if try await resolvedPlatform() == .nativeWindows {
            do {
                return try await connection.runWindowsCommand(
                    try HerdrCoreLocator.windowsProbe(session: session, nonce: nonce), for: .locator)
            } catch is HerdrCoreLocator.SessionRefused {
                throw TransportError.herdrCoreSessionNameRefused(
                    reason: HerdrCoreSessionName.windowsRefusal(session)
                        ?? HerdrCoreSessionName.refusal(session) ?? "")
            }
        }
        do {
            return try await connection.runCoreLocator(
                try HerdrCoreLocator.script(session: session, nonce: nonce))
        } catch is HerdrCoreLocator.SessionRefused {
            throw TransportError.herdrCoreSessionNameRefused(reason: HerdrCoreSessionName.refusal(session) ?? "")
        }
    }

    private func resolvedPlatform() async throws -> HostPlatform {
        if let platform { return platform }
        let answer = try await connection.corePlatform()
        platform = answer
        return answer
    }

    var isConnected: Bool {
        get async { await connection.isConnected }
    }

    func lastLocation() async -> HerdrCoreLocator.Location? {
        located
    }

    /// A session name Windows refuses stops at the platform branch, before any
    /// locator, and a Host that can never connect still has to say what it offers.
    func lastKernel() async -> String? {
        located?.kernel ?? (platform == .nativeWindows ? HerdrCoreLocator.windowsKernel : nil)
    }

    /// The core's own clock says how long it has been up, so the elapsed time is
    /// measured here and needs no agreement between the two machines' clocks.
    func startCore() async throws -> HerdrCoreStart.Outcome {
        let location = try await locate()
        let executablePath = try Self.installedExecutable(at: location)
        guard location.appMayStartCore else {
            throw TransportError.hostFeatureUnavailable(
                feature: String(localized: "Starting herdr-core on \(location.kernel)"))
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
            let result =
                try await resolvedPlatform() == .nativeWindows
                ? try await connection.runWindowsCommand(
                    try HerdrCoreEnvironmentCheck.windowsCommand(pid: pid, nonce: nonce), for: .processRead)
                : try await connection.runHostProcessRead(
                    try HerdrCoreEnvironmentCheck.script(pid: pid, nonce: nonce))
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
        if try await resolvedPlatform() == .nativeWindows {
            let result = try await connection.runWindowsCommand(
                try HostProcessReader.windowsCommand(request, nonce: nonce), for: .processRead)
            guard result.exitStatus == 0 else { return [:] }
            return (try? HostProcessReader.parseWindows(stdout: result.stdout, nonce: nonce, request: request)) ?? [:]
        }
        let script = try HostProcessReader.script(request, nonce: nonce)
        let result = try await connection.runHostProcessRead(script)
        guard result.exitStatus == 0 else { return [:] }
        return (try? HostProcessReader.parse(stdout: result.stdout, nonce: nonce, request: request)) ?? [:]
    }

    func subscribeEvents() async throws -> HerdrCoreEventStream {
        let stream = try await onLink { link in try await link.subscribeEvents(deadline: Self.callDeadline) }
        inventoryCoreID = stream.coreID
        return stream
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        try await onInventoryLink(meaning: request.coreID) { link in
            try await HerdrCoreAttach.open(on: link, request: request, deadline: Self.callDeadline)
        }
    }

    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue {
        try await onInventoryLink { link in
            try await link.call(method, params: params, deadline: Self.callDeadline, isMutation: isMutation)
        }
    }

    func launchShell() async throws -> String {
        let location = if let located { located } else { try await locate() }
        if location.isNativeWindows { return HerdrCoreShellLaunch.windowsShell }
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
                feature: String(localized: "Starting an Agent needs your login shell, which this Host does not report"))
        }
        return shell
    }

    func runAgentDiscovery(_ discovery: HerdrCoreAgentDiscovery) async throws -> GitExecResult {
        switch discovery {
        case .posixScript(let script): try await connection.runAgentDiscovery(script)
        case .windowsCommand(let command): try await connection.runWindowsCommand(command, for: .agentDiscovery)
        }
    }

    func stagesThroughCore() async throws -> Bool {
        try await resolvedPlatform() == .nativeWindows
    }

    /// On a link of its own, closed when the call ends: one frame of up to about 11 MiB
    /// holds its link's writer for as long as the uplink takes, and a Send's Enter,
    /// Stop, Attach input and credit must not wait behind it, nor go out long after
    /// their checks (ADR 0035). The call's deadline runs from when it queues, so it
    /// covers the whole write.
    func putFile(_ source: HerdrCoreStaging.Source, terminal address: String, coreID: String?) async throws -> String {
        let params = try HerdrCoreStaging.params(for: source, terminal: try HerdrCoreWire.address(address))
        let deadline =
            Self.runDeadline + HerdrCoreLink.writeTimeout(forBytes: HerdrCoreStaging.encodedBytes(source.byteCount))
        let opened = try await establish(reusingLocation: false, forOneCall: true)
        callLinks.append(opened.link)
        defer { callLinks.removeAll { $0 === opened.link } }
        let result: Result<JSONValue, any Error>
        do {
            // It reached whichever core answers now, where the address may be another Terminal.
            if let expected = coreID ?? inventoryCoreID, opened.info.coreID != expected {
                throw TransportError.herdrCoreInventoryStale
            }
            result = .success(
                try await run(
                    { link in
                        try await link.call("terminal.put", params: params, deadline: deadline, isMutation: true)
                    }, on: opened))
        } catch {
            result = .failure(error)
        }
        await opened.link.close()
        return try HerdrCoreStaging.path(in: try result.get(), for: source)
    }

    func runTerminal(params: JSONValue) async throws -> JSONValue {
        try await onInventoryLink { link in
            try await link.call("terminal.run", params: params, deadline: Self.runDeadline, isMutation: true)
        }
    }

    func runTemplate(params: JSONValue) async throws -> JSONValue {
        try await onInventoryLink { link in
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

    func checkouts(for directories: [String]) async throws -> [String: HostCheckout] {
        guard try await resolvedPlatform() == .nativeWindows else {
            return try await connection.checkouts(for: directories)
        }
        let nonce = nonce()
        var checkouts: [String: HostCheckout] = [:]
        for batch in GitProbe.windowsCheckoutRootBatches(directories, nonce: nonce) {
            let result = try await connection.runWindowsCommand(
                GitProbe.windowsCheckoutRootsCommand(directories: batch, nonce: nonce), for: .checkoutRead)
            checkouts.merge(
                try GitProbe.parseWindowsCheckoutRoots(stdout: result.stdout, nonce: nonce, directories: batch)
            ) { _, answer in answer }
        }
        return checkouts
    }

    func close() async throws {
        let opening = opening
        self.opening = nil
        opening?.cancel()
        if let opened = try? await opening?.value { await opened.link.close() }
        for link in callLinks { await link.close() }
        try await connection.close()
    }

    private func onLink<Value: Sendable>(
        _ operation: @Sendable (HerdrCoreLink) async throws -> Value
    ) async throws -> Value {
        try await run(operation, on: try await open(reusingLocation: false))
    }

    /// For anything an inventory led to. Opening may reopen a link that ended, and
    /// another core can answer there, where the same address is another Terminal.
    /// `coreID` names the core when the caller knows it; otherwise it is the last
    /// subscribe's, which is compared after the wait so a subscribe in between counts.
    private func onInventoryLink<Value: Sendable>(
        meaning coreID: String? = nil,
        _ operation: @Sendable (HerdrCoreLink) async throws -> Value
    ) async throws -> Value {
        let opened = try await open(reusingLocation: false)
        if let expected = coreID ?? inventoryCoreID, opened.info.coreID != expected {
            throw TransportError.herdrCoreInventoryStale
        }
        return try await run(operation, on: opened)
    }

    private func run<Value: Sendable>(
        _ operation: @Sendable (HerdrCoreLink) async throws -> Value, on opened: Opened
    ) async throws -> Value {
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

    /// `forOneCall` opens beside the shared link rather than as it, which only a
    /// native Windows Host's exec can: a Unix link's channel holds the one events slot.
    private func establish(reusingLocation: Bool, forOneCall: Bool = false) async throws -> Opened {
        let location: HerdrCoreLocator.Location
        // A pipe is checked before every `connect`, since nothing else stands
        // between a stopped core and that exec starting one.
        if reusingLocation, let located, !located.isNativeWindows {
            location = located
        } else {
            location = try await locate()
        }
        let executablePath = try Self.installedExecutable(at: location)
        guard location.fitsSocketPathLimit else {
            throw TransportError.herdrCoreSocketPathTooLong(
                path: location.socketPath, limit: location.socketPathLimit)
        }
        guard !forOneCall || location.isNativeWindows else {
            throw TransportError.hostFeatureUnavailable(
                feature: String(localized: "A core call on a link of its own"))
        }
        let channel = try await openChannel(to: location, forOneCall: forOneCall)
        do {
            let (link, info) = try await HerdrCoreLink.connect(
                over: channel, helloDeadline: Self.callDeadline, sleep: sleep)
            return Opened(link: link, info: info, executablePath: executablePath)
        } catch is HerdrCoreUpdateRequired {
            throw TransportError.herdrCoreUpdateRequired(command: Self.updateCommand(executablePath))
        } catch TransportError.channelFailed(detail: HerdrCoreLink.closedDetail) where location.isNativeWindows {
            // `cmd` prints the marker before it runs `connect`, so this is `connect`
            // itself ending. Its stderr does not reach here, so why stays unknown.
            throw TransportError.channelFailed(
                detail: String(localized: "herdr-core connect exited before answering hello."))
        }
    }

    private func openChannel(
        to location: HerdrCoreLocator.Location, forOneCall: Bool
    ) async throws -> any HeelerSSHAPIChannel {
        if location.isNativeWindows {
            guard location.socketFilePresent else {
                throw TransportError.herdrCoreNotRunning(
                    socketPath: location.socketPath, socketFilePresent: false)
            }
            let command = try HerdrCoreLocator.windowsConnectCommand(session: session)
            let exec =
                forOneCall
                ? try await connection.openCoreCallExec(command: command)
                : try await connection.openCoreLinkExec(command: command)
            return BootstrappedExecChannel(
                channel: exec, startupFailure: String(localized: "The command that runs herdr-core connect did not start."))
        }
        do {
            return try await connection.openCoreLinkChannel(socketPath: location.socketPath)
        } catch TransportError.streamLocalOpenFailed {
            throw TransportError.herdrCoreNotRunning(
                socketPath: location.socketPath, socketFilePresent: location.socketFilePresent)
        }
    }

    /// A core file that did not answer `--version` is still installed: something
    /// in that exec, not the Host's setup, kept it from saying so, and a later read
    /// may hear it. Only an empty installer path reads as not installed.
    private static func installedExecutable(at location: HerdrCoreLocator.Location) throws -> String {
        if let executablePath = location.executablePath { return executablePath }
        if let unanswered = location.unansweredExecutablePath {
            throw TransportError.channelFailed(
                detail: String(localized: "herdr-core at \(unanswered) did not report its version"))
        }
        throw TransportError.herdrCoreNotInstalled
    }

    private static func updateCommand(_ executablePath: String) -> String {
        RemoteHostPath.isWindowsAbsolute(executablePath)
            ? HerdrCoreStart.windowsUpdateCommand(executablePath: executablePath)
            : HerdrCoreStart.updateCommand(executablePath: executablePath)
    }
}
