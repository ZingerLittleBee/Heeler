import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// The real framed transport and link on a native Windows Host, with the probe's
/// exec scripted and a fake core socket behind the exec channel and the bootstrap
/// the Herdr TUI Windows bridge uses. There is no Windows lane: this says what the
/// app does with what the owner's machine recorded, not that a machine does it.
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWindowsTransportTests {
    private let clock = ManualClock()

    private static func runningHost(_ core: ScriptedCoreHost.Core = .init()) -> ScriptedCoreHost {
        ScriptedCoreHost(windowsLocator: ScriptedCoreHost.windowsLocatorLines(), channel: .core(core))
    }

    private static func stoppedHost() -> ScriptedCoreHost {
        ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(lock: ScriptedCoreHost.windowsPipe, pipe: false),
            channel: .core(.init()))
    }

    private static let notRunning = TransportError.herdrCoreNotRunning(
        socketPath: ScriptedCoreHost.windowsPipe, socketFilePresent: false)

    private func session(on host: ScriptedCoreHost) -> HerdrCoreHostSession {
        HerdrCoreHostSession(
            connect: {
                await host.setConnected(true)
                return host.transport()
            },
            keepalive: nil,
            sleep: clock.parkedSleep(for:))
    }

    // MARK: Which path

    @Test func aRunningCoreGetsOneProbeThenOneConnectExec() async throws {
        let host = Self.runningHost()
        let transport = host.transport()

        let info = try await transport.hello()

        #expect(info.coreID == "c1")
        #expect(await host.log == ["windows-probe", "connect"])
        #expect(
            await host.connectCommands
                == [#"cmd /d /c "echo __HEELER_STREAM_READY__&& .\AppData\Local\Programs\herdr-core\herdr-core.exe connect --session work""#])
        let socket = try #require(await host.socket)
        let line = try JSONDecoder().decode(JSONValue.self, from: await socket.nextWrittenLine())
        #expect(line["params"] == .object(["generation": .number(1), "framed": .bool(true)]))
        try await transport.close()
    }

    @Test func aWindowsHostNeverOpensAForwardedChannelOrRunsThePosixLocator() async throws {
        let host = Self.runningHost()
        let transport = host.transport()

        _ = try await transport.hello()
        _ = try await transport.serverStatus()

        let log = await host.log
        #expect(!log.contains { $0.hasPrefix("open") })
        #expect(!log.contains("locator"))
        try await transport.close()
    }

    /// The refusal is one of the failures a Unix Host reads as not running, and
    /// the path it took was settled before the channel was tried.
    @Test func aUnixHostWhoseChannelIsRefusedNeverTakesTheWindowsPath() async throws {
        let host = ScriptedCoreHost(channel: .refused)
        let transport = host.transport()

        await #expect(
            throws: TransportError.herdrCoreNotRunning(
                socketPath: ScriptedCoreHost.socketPath, socketFilePresent: false)
        ) { _ = try await transport.hello() }

        #expect(await host.log == ["locator", "open \(ScriptedCoreHost.socketPath)"])
        #expect(await host.connectCommands.isEmpty)
        try await transport.close()
    }

    // MARK: The core's environment

    private static func runningHost(pid: Int, environment: [String: String]?) async -> ScriptedCoreHost {
        let host = runningHost(.init(pid: pid))
        await host.setWindowsProcesses([
            .init(pid: pid, image: "herdr-core.exe", start: "1", environment: environment)
        ])
        return host
    }

    @Test func aWindowsCoresLeakedVariablesAreReadByNameOnly() async throws {
        let host = await Self.runningHost(pid: 9001, environment: [
            "TMUX": "/tmp/secret-value",
            "herdr_pane": "secret-value-too",
            "HERDR_BLANK": "",
            "HERDR_A B": "not a name this read prints",
            "CLAUDECODE": "1",
            "PATH": #"C:\Windows"#,
        ])
        let transport = host.transport()
        _ = try await transport.hello()

        #expect(await transport.leakedEnvironmentNames() == ["TMUX", "HERDR_PANE", "CLAUDECODE"])

        #expect(await host.log.filter { $0 == "windows-process-read" }.count == 1)
        #expect(!(await host.log.contains("process-read")))
        let script = try #require(await host.scripts.last)
        #expect(script.contains("$ids=@(9001)"))
        #expect(script.contains("$want=@()"))
        try await transport.close()
    }

    /// Every failure reads as no names: the check says nothing it could not read.
    @Test func aWindowsCoreWhoseEnvironmentCannotBeReadNamesNothing() async throws {
        let unreadable = await Self.runningHost(pid: 9001, environment: nil)
        let unreadableTransport = unreadable.transport()
        _ = try await unreadableTransport.hello()
        #expect(await unreadableTransport.leakedEnvironmentNames() == [])
        try await unreadableTransport.close()

        for answer in [
            GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 1),
            GitExecResult(stdout: Data("Add-Type is not allowed here\n".utf8), stderr: Data(), exitStatus: 0),
        ] {
            let host = await Self.runningHost(pid: 9001, environment: ["TMUX": "x"])
            await host.setWindowsProcessAnswer(answer)
            let transport = host.transport()
            _ = try await transport.hello()
            #expect(await transport.leakedEnvironmentNames() == [])
            try await transport.close()
        }
    }

    // MARK: Checkouts

    @Test func aWindowsHostsCheckoutsComeFromItsOwnReadNotTheGitScript() async throws {
        let host = Self.runningHost()
        await host.setWindowsGitRoots([#"C:\repo\pkg"#: "C:/repo"])
        let transport = host.transport()

        let checkouts = try await transport.checkouts(for: [#"C:\repo\pkg"#, #"C:\notes"#])

        #expect(checkouts == [#"C:\repo\pkg"#: HostCheckout(root: #"C:\repo"#)])
        #expect(await host.log == ["windows-checkouts"])
        #expect(await host.posixCheckoutAsks == 0)
    }

    @Test func directoriesOneCommandCannotCarryTakeAnotherExec() async throws {
        let host = Self.runningHost()
        let directories = (0..<16).map { #"C:\deep\"# + String(repeating: "x", count: 240) + "\($0)" }
        await host.setWindowsGitRoots(
            Dictionary(uniqueKeysWithValues: directories.map { ($0, "C:/repo") }))
        let transport = host.transport()

        let checkouts = try await transport.checkouts(for: directories)

        #expect(Set(checkouts.keys) == Set(directories))
        let log = await host.log
        #expect(log.count > 1)
        #expect(log.allSatisfy { $0 == "windows-checkouts" })
    }

    @Test func aUnixHostsCheckoutsStayWithItsGitScript() async throws {
        let host = ScriptedCoreHost(channel: .refused)
        let transport = host.transport()

        await #expect(throws: ChangesReadError.unavailable) {
            _ = try await transport.checkouts(for: ["/work"])
        }

        #expect(await host.posixCheckoutAsks == 1)
        #expect(await host.log.isEmpty)
    }

    @Test func aHostWhosePlatformCannotBeReadRunsNothingAndRetries() async throws {
        let host = Self.runningHost()
        await host.setCorePlatformFailure(.timedOut)
        let transport = host.transport()

        await #expect(throws: TransportError.timedOut) { _ = try await transport.hello() }
        #expect(await host.log.isEmpty)

        await host.setCorePlatformFailure(nil)
        _ = try await transport.hello()
        #expect(await host.log == ["windows-probe", "connect"])
        try await transport.close()
    }

    // MARK: The pipe check

    @Test func withThePipeAbsentNoConnectRunsOnTheFirstConnect() async throws {
        let host = Self.stoppedHost()
        let transport = host.transport()

        await #expect(throws: Self.notRunning) { _ = try await transport.hello() }

        #expect(await host.log == ["windows-probe"])
        #expect(await host.connectCommands.isEmpty)
        try await transport.close()
    }

    /// `core.lock` outlives its core, so only the pipe says one runs.
    @Test func aStoppedCoresLockStillReadsNotRunning() async throws {
        let host = Self.stoppedHost()
        let location = try await host.transport().locate()
        #expect(location.socketSource == .lock)
        #expect(location.isStaleLock)
    }

    @Test func aHelloAtTheLastLocationChecksThePipeAgain() async throws {
        let host = Self.runningHost()
        let transport = host.transport()
        _ = try await transport.locate()
        await host.setWindowsLocator(ScriptedCoreHost.windowsLocatorLines(pipe: false))

        await #expect(throws: Self.notRunning) { _ = try await transport.helloAtLastLocation() }

        #expect(await host.log == ["windows-probe", "windows-probe"])
        try await transport.close()
    }

    /// No holder window: a missing pipe is believed at once, as a Unix Host's
    /// missing socket file is.
    @Test func aMissingPipeIsNotPolledAcrossAHolderRestart() async throws {
        let host = Self.stoppedHost()
        let transport = host.transport()

        await #expect(throws: Self.notRunning) {
            _ = try await transport.helloAcrossHolderRestart(
                policy: .default, sleep: { _ in Issue.record("nothing waits") }, isWanted: { true })
        }

        #expect(await host.log == ["windows-probe"])
        try await transport.close()
    }

    @Test func aStoppedCoreReadsNotRunningRetriesWithBackoffAndNeverConnects() async throws {
        let host = Self.stoppedHost()
        let session = session(on: host)
        nonisolated(unsafe) var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))

        for (attempt, delay) in [(1, Duration.seconds(1)), (2, .seconds(2)), (3, .seconds(4))] {
            #expect(
                await updates.next()
                    == .status(.reconnecting(attempt: attempt, delay: delay, failure: Self.notRunning)))
            await clock.untilParked(1)
            clock.advance(delay)
        }
        // It comes back when the user starts it on that machine.
        #expect(await updates.next() == .status(.reconnecting(attempt: 4, delay: .seconds(8), failure: Self.notRunning)))
        #expect(await host.connectCommands.isEmpty)
        await host.setWindowsLocator(ScriptedCoreHost.windowsLocatorLines())
        await clock.untilParked(1)
        clock.advance(.seconds(8))
        #expect(await updates.next() == .status(.connected))
        #expect(await host.connectCommands.count == 1)
        await session.end()
    }

    /// The boundary of ADR 0031 on this platform: a reconnect, background or not,
    /// looks first, and a core the user stopped stays stopped.
    @Test func aCoreThatStopsUnderTheLinkIsNeverConnectedToAgain() async throws {
        let host = Self.runningHost()
        let session = session(on: host)
        nonisolated(unsafe) var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        guard case .snapshot = await updates.next() else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(await host.connectCommands.count == 1)

        await host.setWindowsLocator(ScriptedCoreHost.windowsLocatorLines(lock: ScriptedCoreHost.windowsPipe, pipe: false))
        let socket = try #require(await host.socket)
        await socket.deliverEndOfFile()

        for (attempt, delay) in [(1, Duration.seconds(1)), (2, .seconds(2))] {
            var status = await updates.next()
            while case .event = status { status = await updates.next() }
            #expect(status == .status(.reconnecting(attempt: attempt, delay: delay, failure: Self.notRunning)))
            await clock.untilParked(1)
            clock.advance(delay)
        }
        _ = await updates.next()
        await session.end()

        #expect(await host.connectCommands.count == 1)
        let log = await host.log
        #expect(log.filter { $0 == "windows-probe" }.count >= 3)
        #expect(log.allSatisfy { ["windows-probe", "connect", "close"].contains($0) })
    }

    // MARK: Not installed and update required

    @Test func noExecutableReadsNotInstalledAndRunsNoConnect() async throws {
        let host = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(executable: nil, pipe: false),
            channel: .core(.init()))
        let transport = host.transport()

        await #expect(throws: TransportError.herdrCoreNotInstalled) { _ = try await transport.hello() }

        #expect(await host.connectCommands.isEmpty)
        try await transport.close()
    }

    @Test func updateRequiredNamesTheProbedPathAndIsNeverRetried() async throws {
        let host = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            channel: .answersHello(ScriptedCoreHost.helloReply(features: ["framed"])))
        let session = session(on: host)
        nonisolated(unsafe) var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))

        let command = "\(ScriptedCoreHost.windowsExecutable) update"
        #expect(await updates.next() == .status(.failed(.herdrCoreUpdateRequired(command: command))))
        // No time passing brings another try.
        clock.advance(.seconds(120))
        await session.end()
        #expect(await updates.next() == .status(.ended))
        #expect(await host.connectCommands.count == 1)
    }

    @Test func aNameTheCmdLineCannotCarryRunsNothing() async throws {
        let host = Self.runningHost()
        let transport = host.transport(session: "a&calc")

        await #expect(throws: TransportError.self) { _ = try await transport.hello() }

        #expect(await host.log.isEmpty)
        try await transport.close()
    }

    // MARK: The link

    /// `cmd` runs AutoRun and the SSH account's shell may print, and a read may
    /// hold that output, the marker and the core's answer together.
    @Test func whatTheAccountShellPrintsBeforeTheMarkerIsDropped() async throws {
        let host = Self.runningHost()
        await host.setConnectBanner(Data("Welcome\r\n\u{FEFF}{\"id\":\"hello\"}\r\n".utf8) + Data([0xFF, 0x0A]))
        let transport = host.transport()

        let info = try await transport.hello()

        #expect(info.coreID == "c1")
        try await transport.close()
    }

    @Test func helloStatusAndTheSubscribeSnapshotBehaveAsOnUnix() async throws {
        let record = JSONValue.object([
            "address": .string("t1"), "cwd": .string(#"C:\work"#), "state": .string("live"), "pid": .number(7),
        ])
        let host = Self.runningHost(.init(id: "win", sequence: 40, terminals: [record], pid: 33236))
        let transport = host.transport()

        #expect(try await transport.hello().coreID == "win")
        #expect(try await transport.serverStatus().pid == 33236)
        let stream = try await transport.subscribeEvents()

        #expect(stream.coreID == "win")
        #expect(stream.snapshot.terminals.map(\.address) == ["t1"])
        #expect(stream.snapshot.terminals.first?.cwd == #"C:\work"#)
        #expect(await host.methods == ["server.status", "events.subscribe"])
        await stream.end()
        try await transport.close()
    }

    @Test func anAttachCarriesResizeCreditAndCloseAsOnUnix() async throws {
        let host = Self.runningHost()
        let transport = host.transport()
        // The events stream takes channel 1, as it did on the captured link.
        let stream = try await transport.subscribeEvents()
        let attach = try await transport.attachTerminal(
            TerminalAttachRequest(target: .terminal("t1"), cols: 90, rows: 25))
        let (channel, params, socket) = try #require(await host.attaches.first)
        #expect(params["terminal"] == .string("t1"))
        var output = attach.output.makeAsyncIterator()

        let vectors = HerdrCoreVectorFile.windows
        func captured(_ name: String) throws -> Data {
            HerdrCoreVectorFile.bytes(hex: try #require(vectors.frames.first { $0.name == name }).bytes)
        }
        #expect(channel == 2)
        let paint = try captured("data-attach-cr-lf-crlf-ctrl-z")
        await socket.deliver(paint)
        #expect(try await output.next() == Data("crlf\r\nlf\r\ncr\rtab\tsub\u{1A}sub\r\n".utf8))

        attach.resize(cols: 90, rows: 25)
        let resize = await socket.waitForFrame(channel: channel, kind: .resize)
        #expect(try resize.encoded() == captured("resize-from-client"))

        attach.outputConsumed(277)
        let credit = await socket.waitForFrame(channel: channel, kind: .credit)
        #expect(try credit.encoded() == captured("credit-from-client"))

        attach.send(Data([0x03, 0x1A, 0x0D, 0x0A]))
        #expect(await socket.waitForFrame(channel: channel, kind: .data).payload == Data([0x03, 0x1A, 0x0D, 0x0A]))

        await attach.end()
        let close = await socket.waitForFrame(channel: channel, kind: .close)
        let unixClose = try #require(HerdrCoreVectorFile.shared.frames.first { $0.name == "close-from-client" })
        #expect(try close.encoded() == HerdrCoreVectorFile.bytes(hex: unixClose.bytes))
        await stream.end()
        try await transport.close()
    }

    /// ADR 0031: an unpaced burst reached the Mac end as a repaint with gaps, with
    /// credit for every frame, so a repaint is ordinary output.
    @Test func aRepaintFromABurstIsOrdinaryOutputAndTheLinkStaysUp() async throws {
        let host = Self.runningHost()
        let transport = host.transport()
        let attach = try await transport.attachTerminal(
            TerminalAttachRequest(target: .terminal("t1"), cols: 90, rows: 25))
        let (channel, _, socket) = try #require(await host.attaches.first)
        var output = attach.output.makeAsyncIterator()
        let repaint = Data("\u{1B}[H\u{1B}[2Jscreen".utf8)

        try await socket.deliver(HerdrCoreFrame(channel: channel, kind: .data, payload: repaint))

        #expect(try await output.next() == repaint)
        #expect(try await transport.serverStatus().pid == 4242)
        #expect(await host.connectCommands.count == 1)
        await attach.end()
        try await transport.close()
    }

    @Test func fiveTerminalsRideTheOneConnectExec() async throws {
        let host = Self.runningHost()
        let transport = host.transport()
        var attaches: [TerminalAttachSession] = []

        for index in 1...5 {
            attaches.append(
                try await transport.attachTerminal(
                    TerminalAttachRequest(target: .terminal("t\(index)"), cols: 80, rows: 24)))
        }

        #expect(await host.connectCommands.count == 1)
        #expect(await host.log.filter { $0 == "connect" }.count == 1)
        #expect(await host.attaches.map(\.channel) == [1, 2, 3, 4, 5])
        for attach in attaches { await attach.end() }
        try await transport.close()
    }

    @Test func theLinksExecHoldsOneEventsSlotWithinTheWindowsBudgetUntilItCloses() async throws {
        let admission = SSHChannelAdmission()
        await admission.useWindowsSessionBudget()

        let exec = try await admission.admitCoreExec { FakeCoreSocket() }
        #expect(await admission.snapshot().events == 1)
        #expect(await admission.snapshot().connection == 1)
        #expect(await admission.snapshot().attach == 0)

        // A second link would be a mistake here, and it would wait for the slot.
        let second = Task { try await admission.admitCoreExec { FakeCoreSocket() } }
        await Task.yield()
        #expect(await admission.snapshot().connection == 1)

        try await exec.close(timeout: .seconds(1))
        let reopened = try await second.value
        #expect(await admission.snapshot().connection == 1)
        try await reopened.close(timeout: .seconds(1))
        #expect(await admission.snapshot().connection == 0)
    }

    /// Its budget leaves the other eight slots for what really is a session.
    @Test func theLinkLeavesTheWindowsBudgetForEverythingElse() async throws {
        let admission = SSHChannelAdmission()
        await admission.useWindowsSessionBudget()
        let exec = try await admission.admitCoreExec { FakeCoreSocket() }
        var leases: [SSHChannelAdmissionLease] = []

        for _ in 0..<4 { leases.append(try await admission.acquire(.ordinarySession)) }
        for _ in 0..<4 { leases.append(try await admission.acquire(.attach)) }

        #expect(await admission.snapshot().connection == 9)
        for lease in leases { await lease.release() }
        try await exec.close(timeout: .seconds(1))
    }
}
