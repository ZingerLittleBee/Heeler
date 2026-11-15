import Foundation
import Testing

@testable import Heeler

/// Rex in Server Kind detection (ADR 0047): looked for on every macOS and Linux
/// Host by its socket alone, and offered only for a socket this account may use.
@Suite("Rex Server Kind detection")
struct RexServerKindDetectionTests {
    private static let macSocket = "/Users/dev/Library/Application Support/rex/server.sock"
    private static let linuxOwnSocket = "/run/user/1000/rex/server.sock"
    private static let linuxSharedSocket = "/run/rex/server.sock"

    private func script() -> String {
        String(decoding: ServerKindDetection.script(session: "work", nonce: "n0nce"), as: UTF8.self)
    }

    private func detect(
        rex: [String]?, herdr: ScriptedCoreHost.HerdrRead = .notInstalled,
        locator: [String] = ScriptedCoreHost.locatorLines(executable: nil),
        tmux: [String] = ScriptedCoreHost.tmuxLines(kernel: "Darwin"), session: String = "work"
    ) async throws -> (ServerKindDetection, ScriptedCoreHost) {
        let host = ScriptedCoreHost(
            locator: locator, herdrRead: herdr, tmuxProbe: tmux, rexProbe: rex, channel: .refused)
        return (try await ServerKindDetection.run(over: host, session: session), host)
    }

    // MARK: The script

    /// The Rex part is all that looking for Rex adds: without it, the script
    /// is the one a build before Rex Hosts runs, naming Rex nowhere.
    @Test func theRexPartIsTheOnlyPartThatNamesRex() {
        let body = script()
        #expect(body.components(separatedBy: RexProbe.script(nonce: "n0nce")).count == 2)
        let others = body.replacingOccurrences(of: RexProbe.script(nonce: "n0nce"), with: "")
        #expect(!others.contains("rex"))
        #expect(!others.contains("Rex"))
    }

    /// One exec still: the Rex part follows tmux's, in a subshell with nothing
    /// on standard input, and the locator ends the script.
    @Test func theRexPartFollowsTmuxAndPrecedesTheLocator() throws {
        let body = script()
        let tmux = try #require(body.range(of: "__heeler_tmux_probe="))
        let rex = try #require(body.range(of: "n0nce rex begin"))
        let rexEnd = try #require(body.range(of: ") </dev/null 2>/dev/null", range: rex.upperBound..<body.endIndex))
        let locator = try #require(body.range(of: "__session="))
        #expect(tmux.upperBound < rex.lowerBound && rexEnd.upperBound < locator.lowerBound)
        #expect(body.components(separatedBy: "n0nce rex begin").count == 2)
    }

    /// Detection only tests files: it never runs the Rex command-line tool,
    /// some of whose commands start a server, and asks for no autostart.
    @Test func theRexPartNeverRunsRex() {
        let part = RexProbe.script(nonce: "n0nce")
        let commands = part.replacingOccurrences(of: "n0nce rex begin", with: "")
            .replacingOccurrences(of: "n0nce rex end", with: "")
        let words = commands.components(separatedBy: CharacterSet(charactersIn: " \t\n;&|()`$\"'"))
        let runs = words.filter { $0 == "rex" }
        #expect(runs.isEmpty, "\(runs)")
        // Not even looked up: other software has a command of that name.
        #expect(!part.contains("command -v rex"))
        #expect(!part.contains("REX_AUTOSTART"))
        #expect(!part.contains("login-server.sock"))
        // Every path it names is quoted, so one with spaces stays one word.
        #expect(part.contains(#"look "$HOME/Library/Application Support/rex/server.sock""#))
    }

    // MARK: What it finds

    @Test func aMacSocketWithSpacesInItsPathIsFoundAndOffered() async throws {
        let (detection, host) = try await detect(
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]))

        #expect(await host.log == ["detection"])
        #expect(detection.rex == .socketFound(socketPath: Self.macSocket))
        #expect(detection.rex.summary == "Socket found")
        #expect(detection.rexSocket?.path == Self.macSocket)
        #expect(detection.foundKinds == [.rex])
        #expect(detection.offeredKinds == [.rex])
    }

    @Test func onLinuxTheAccountsOwnServerComesBeforeASharedOne() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(
                kernel: "Linux",
                sockets: [(Self.linuxSharedSocket, false, true), (Self.linuxOwnSocket, true, true)]))

        #expect(detection.rex == .socketFound(socketPath: Self.linuxOwnSocket))

        let (shared, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(kernel: "Linux", sockets: [(Self.linuxSharedSocket, false, true)]))
        #expect(shared.rex == .socketFound(socketPath: Self.linuxSharedSocket))
    }

    @Test func rexBesideHerdrIsOfferedBesideIt() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]),
            herdr: .answers(#"{"sessions":[{"name":"default","default":true,"running":true}]}"#))

        #expect(detection.foundKinds == [.herdrTUI, .rex])
        #expect(detection.offeredKinds == [.herdrTUI, .rex])
    }

    /// Heeler never starts Rex, so without a socket it is not on offer, and
    /// the finding says what is missing.
    @Test func installedButNotRunningIsSaidPlainlyAndNotOffered() async throws {
        let (detection, _) = try await detect(rex: ScriptedCoreHost.rexLines(installed: true))

        #expect(detection.rex == .notRunning)
        #expect(detection.rex.summary == "Installed, not running")
        #expect(detection.foundKinds.isEmpty)
        #expect(detection.offeredKinds == [.herdrTUI, .herdrCore, .tmux])
        #expect(detection.rexSocket == nil)
    }

    @Test func noRexAtAllIsNotFound() async throws {
        let (detection, _) = try await detect(rex: ScriptedCoreHost.rexLines(installed: false))

        #expect(detection.rex == .notInstalled)
        #expect(detection.rex.summary == "Not found")
        #expect(!detection.offeredKinds.contains(.rex))
    }

    /// Another account's server, or a path this build cannot name as one
    /// shell word, is no socket to offer.
    @Test func aSocketThisAccountCannotUseIsNotOffered() async throws {
        let (theirs, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(kernel: "Linux", sockets: [(Self.linuxSharedSocket, false, false)]))
        #expect(theirs.rex == .notUsable(socketPath: Self.linuxSharedSocket))
        #expect(theirs.rex.summary == "Socket found, but this account cannot use it")
        #expect(!theirs.offeredKinds.contains(.rex))

        let quoted = "/Users/it's me/Library/Application Support/rex/server.sock"
        let (unnamed, _) = try await detect(rex: ScriptedCoreHost.rexLines(sockets: [(quoted, true, true)]))
        #expect(unnamed.rex == .notUsable(socketPath: quoted))
        #expect(unnamed.rexSocket == nil)
    }

    @Test func aKernelOtherThanMacOSOrLinuxIsUnsupported() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(kernel: "FreeBSD", sockets: [("/var/run/rex/server.sock", true, true)]))

        #expect(detection.rex == .unsupported)
        #expect(!detection.offeredKinds.contains(.rex))
    }

    /// A Rex part that did not read says nothing of the others.
    @Test func anUnreadableRexPartLeavesTheOtherFindings() async throws {
        let (detection, _) = try await detect(
            rex: nil, herdr: .answers(#"{"sessions":[{"name":"default","default":true,"running":true}]}"#))

        #expect(detection.rex == .unreadable)
        #expect(detection.foundKinds == [.herdrTUI])
    }

    @Test func aRefusedSessionNameKeepsAFoundRexOnOffer() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]), session: "a/b")

        #expect(detection.offeredKinds == [.herdrTUI, .herdrCore, .tmux, .rex])
    }

    /// A Host without a Rex socket this account may use is detected as before
    /// Rex was looked for: whatever the Rex part says, the other findings and
    /// what is found and offered stay as they are, from the same one exec.
    @Test func withoutAUsableRexSocketTheOtherKindsAreDetectedAsBefore() async throws {
        let sessions = #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
        let tmuxRunning = ScriptedCoreHost.tmuxLines(
            executable: "/usr/bin/tmux", kernel: "Darwin", sockets: ["default"])
        let tmuxIdle = ScriptedCoreHost.tmuxLines(executable: "/usr/bin/tmux", kernel: "Darwin")
        let hosts: [(ScriptedCoreHost.HerdrRead, [String], [ServerKind], [ServerKind])] = [
            (.answers(sessions), tmuxRunning, [.herdrTUI, .tmux], [.herdrTUI, .tmux]),
            (.answers(sessions), tmuxIdle, [.herdrTUI], [.herdrTUI, .tmux]),
            (.notInstalled, ScriptedCoreHost.tmuxLines(kernel: "Darwin"), [], [.herdrTUI, .herdrCore, .tmux]),
        ]
        let withoutRex: [[String]?] = [
            nil,
            ScriptedCoreHost.rexLines(installed: false),
            ScriptedCoreHost.rexLines(installed: true),
            ScriptedCoreHost.rexLines(kernel: "Linux", sockets: [(Self.linuxSharedSocket, false, false)]),
            ScriptedCoreHost.rexLines(kernel: "FreeBSD", sockets: [(Self.linuxSharedSocket, true, true)]),
        ]
        for (herdr, tmux, found, offered) in hosts {
            let (unread, _) = try await detect(rex: nil, herdr: herdr, tmux: tmux)
            for rex in withoutRex {
                let (detection, host) = try await detect(rex: rex, herdr: herdr, tmux: tmux)

                #expect(await host.log == ["detection"])
                #expect(detection.foundKinds == found, "\(rex ?? [])")
                #expect(detection.offeredKinds == offered, "\(rex ?? [])")
                #expect(detection.herdrTUI == unread.herdrTUI)
                #expect(detection.herdrCore == unread.herdrCore)
                #expect(detection.tmux == unread.tmux)
                #expect(detection.tmuxSockets == unread.tmuxSockets)
                #expect(detection.rexSocket == nil)
            }
        }
    }

    @Test func aNativeWindowsHostIsNeverAskedAboutRex() async throws {
        let host = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            rexProbe: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]), channel: .refused)

        let detection = try await ServerKindDetection.run(over: host, session: "work")

        #expect(await host.log == ["windows-detection"])
        #expect(detection.rex == .unsupported)
        #expect(!detection.offeredKinds.contains(.rex))
        #expect(!ServerKindDetectionScript.windowsCommand(session: "work", nonce: "n0nce").contains("rex"))
    }

    // MARK: The probe on its own

    @Test func theProbeAloneFindsWhatDetectionWould() async throws {
        let host = ScriptedCoreHost(
            rexProbe: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]), channel: .refused)

        #expect(try await RexProbe.run(over: host) == .socketFound(socketPath: Self.macSocket))
        #expect(await host.log == ["detection"])
        let body = try #require(await host.scripts.first)
        #expect(!body.contains("herdr"))
        #expect(!body.contains("tmux"))

        let windows = ScriptedCoreHost(windowsLocator: ScriptedCoreHost.windowsLocatorLines(), channel: .refused)
        #expect(try await RexProbe.run(over: windows) == .unsupported)
        #expect(await windows.log.isEmpty)
    }

    /// Only what lies between the last pair of markers counts, and a path is
    /// taken once.
    @Test func theProbesOutputIsReadBetweenItsMarkers() throws {
        let output = """
            Welcome
            n0nce rex begin
            socket 1 1 /stale.sock
            n0nce rex end
            n0nce rex begin
            kernel Linux
            socket 0 1 /run/rex/server.sock
            socket 1 1 /run/rex/server.sock
            socket x 1 /bad.sock
            socket 1 1 relative.sock
            installed

            n0nce rex end
            """
        let report = try RexProbe.parse(stdout: Data(output.utf8), nonce: "n0nce")

        #expect(report.kernel == "Linux")
        #expect(report.isInstalled)
        #expect(report.sockets == [RexProbe.Socket(path: "/run/rex/server.sock", isOwn: false, isUsable: true)])
        #expect(throws: RexProbe.MalformedOutput.self) {
            try RexProbe.parse(stdout: Data("n0nce rex begin\nkernel Linux\n".utf8), nonce: "n0nce")
        }
    }
}

/// A Rex Host's confirmation and checks in Host onboarding (ADR 0047): the
/// checks reach the server's socket, say hello, and close with a close frame.
@MainActor
@Suite("Rex Host onboarding", .timeLimit(.minutes(1)))
struct RexHostOnboardingTests {
    static let socket = "/Users/dev/Library/Application Support/rex/server.sock"

    private func makeStore(
        _ host: Host, scripted: ScriptedCoreHost = ScriptedCoreHost(channel: .refused), rex: ScriptedRexHost = ScriptedRexHost(),
        noteRexSocket: @escaping @MainActor (Host.ID, RexSocket) -> Void = { _, _ in }
    ) -> HostOnboardingStore {
        HostOnboardingStore(
            host: host,
            connector: FakeTransportConnector(
                outcome: .connects(pingResult: .failure(.cancelled)), core: scripted, rex: rex),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            noteRexSocket: noteRexSocket)
    }

    private func failedCheck(_ store: HostOnboardingStore) -> (PreflightCheck, String)? {
        guard let report = store.report else { return nil }
        for check in PreflightCheck.cases(for: store.host.serverKind) {
            if case .failed(let hint) = report[check] { return (check, hint) }
        }
        return nil
    }

    private func rexHost(socket: String? = socket) -> Host {
        Host(
            address: "mac.example", username: "dev", serverKind: .rex,
            rexSocket: socket.flatMap { RexSocket(path: $0) })
    }

    @Test func confirmingRexStoresTheSocketDetectionFoundAndSaysHelloToIt() async throws {
        let scripted = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(executable: nil),
            rexProbe: ScriptedCoreHost.rexLines(sockets: [(Self.socket, true, true)]), channel: .refused)
        let server = FakeRexServer()
        let rex = ScriptedRexHost(control: [.server(server)])
        let host = Host(address: "mac.example", username: "dev", serverKind: .unconfirmed, sessionName: "work")
        let catalog = HostStore(volatileHosts: [host])
        let store = makeStore(host, scripted: scripted, rex: rex)

        await store.runChecks()
        #expect(store.detection?.rex == .socketFound(socketPath: Self.socket))
        #expect(store.offeredKinds == [.rex])

        await store.confirmServerKind(.rex, in: catalog)

        #expect(store.confirmationRefusal == nil)
        #expect(store.host.serverKind == .rex)
        #expect(store.host.rexSocket?.path == Self.socket)
        #expect(store.host.sessionName == "")
        #expect(catalog.hosts == [store.host])
        // Detection ran once; the checks dialed the stored socket, said hello and left.
        #expect(await scripted.log == ["detection", "close"])
        #expect(await rex.log == ["control \(Self.socket)", "close"])
        #expect(await server.nextHello()["type"] == .string("hello"))
        #expect(await server.clientClose?.code == .normalClosure)
        #expect(await server.requests.isEmpty)
        #expect(store.report == .allPassed)
        #expect(store.pluginStatus == .unsupportedServerKind)
        #expect(store.hostHelper == nil)
    }

    /// A Host without Rex is offered what it was before Rex was looked for,
    /// and the confirmation says nothing more of Rex than its finding.
    @Test func aHostWithoutRexIsOfferedWhatItWasBefore() async throws {
        let scripted = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(executable: nil),
            rexProbe: ScriptedCoreHost.rexLines(installed: false), channel: .refused)
        let host = Host(address: "box.example", username: "dev", serverKind: .unconfirmed)
        let store = makeStore(host, scripted: scripted)

        await store.runChecks()

        #expect(store.detection?.rex == .notInstalled)
        #expect(store.offeredKinds == [.herdrTUI, .herdrCore, .tmux])
        #expect(store.confirmationNote?.hasPrefix("None of them was found") == true)
        #expect(store.rexNote == nil)
        #expect(await scripted.log == ["detection", "close"])
    }

    /// Heeler never starts Rex, so an installed Rex with no server is not on
    /// offer, and the confirmation says how to make it so.
    @Test func anInstalledRexWithoutAServerSaysToStartIt() async throws {
        let sessions = #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
        let scripted = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(executable: nil), herdrRead: .answers(sessions),
            rexProbe: ScriptedCoreHost.rexLines(installed: true), channel: .refused)
        let host = Host(address: "mac.example", username: "dev", serverKind: .unconfirmed)
        let store = makeStore(host, scripted: scripted)

        await store.runChecks()

        #expect(store.detection?.rex == .notRunning)
        #expect(store.offeredKinds == [.herdrTUI])
        #expect(store.confirmationNote == nil)
        #expect(store.rexNote?.contains("start Rex") == true)

        let running = makeStore(
            host,
            scripted: ScriptedCoreHost(
                rexProbe: ScriptedCoreHost.rexLines(sockets: [(Self.socket, true, true)]), channel: .refused))
        await running.runChecks()
        #expect(running.offeredKinds.contains(.rex))
        #expect(running.rexNote == nil)
    }

    /// A Host whose socket did not read has it looked up again, and the
    /// catalog keeps what was found.
    @Test func aHostWithoutASocketHasItLookedUpAndKept() async throws {
        let found = "/run/user/1000/rex/server.sock"
        let rex = ScriptedRexHost(
            probe: ScriptedRexHost.probeFinding(found, kernel: "Linux"), control: [.server(FakeRexServer())])
        let host = rexHost(socket: nil)
        let catalog = HostStore(volatileHosts: [host])
        let store = makeStore(host, rex: rex) { id, socket in try? catalog.noteRexSocket(socket, for: id) }

        await store.runChecks()

        #expect(store.report == .allPassed)
        #expect(store.host.rexSocket?.path == found)
        #expect(catalog.hosts.first?.rexSocket?.path == found)
        #expect(await rex.log == ["probe", "control \(found)", "close"])
    }

    /// Heeler never starts Rex: the checklist says what is missing and how to fix it.
    @Test func aRexHostsChecksSayWhatIsMissing() async throws {
        let cases: [(ScriptedRexHost, String?, PreflightCheck, String)] = [
            (ScriptedRexHost(probe: ["kernel Darwin"]), nil, .herdrInstalled, "Rex was not found"),
            (ScriptedRexHost(probe: ["kernel FreeBSD"]), nil, .herdrInstalled, "macOS and Linux"),
            (
                ScriptedRexHost(probe: ["kernel Linux", "socket 0 0 /run/rex/server.sock", "installed"]), nil,
                .serverRunning, "may not use the socket"
            ),
            (ScriptedRexHost(probe: ["kernel Darwin", "installed"]), nil, .serverRunning, "Heeler does not start it"),
            (ScriptedRexHost(socketCheck: "missing", control: [.refused]), Self.socket, .serverRunning, "Heeler does not start it"),
            (
                ScriptedRexHost(socketCheck: "listening", control: [.refused]), Self.socket, .serverRunning,
                "refuses socket forwarding"
            ),
            (ScriptedRexHost(control: [.refused]), Self.socket, .serverRunning, "Rex stopped, or the SSH server"),
        ]
        for (rex, socket, check, words) in cases {
            let store = makeStore(rexHost(socket: socket), rex: rex)

            await store.runChecks()

            let failed = failedCheck(store)
            #expect(failed?.0 == check, "\(words)")
            #expect(failed?.1.contains(words) == true, "\(failed?.1 ?? "")")
            #expect(await rex.log.last == "close")
        }
    }

    @Test func aRexThatRefusesTheAccountOrSpeaksAnotherRevisionFailsItsCheck() async throws {
        let refusing = FakeRexServer()
        let refusingHost = ScriptedRexHost(control: [.server(refusing, welcome: nil)])
        let refused = makeStore(rexHost(), rex: refusingHost)
        async let refusal: Void = refused.runChecks()
        await refusing.refuseUpgrade(status: 403)
        await refusal
        #expect(failedCheck(refused)?.0 == .serverRunning)
        #expect(failedCheck(refused)?.1.contains("did not let this account in") == true)

        var newer = FakeRexServer.Welcome()
        newer.apiRevision = 13
        newer.serverRevision = 13
        let store = makeStore(rexHost(), rex: ScriptedRexHost(control: [.server(FakeRexServer(), welcome: newer)]))
        await store.runChecks()
        #expect(failedCheck(store)?.0 == .protocolCompatible)
        #expect(failedCheck(store)?.1.contains("revision 12") == true)
    }

    /// A Rex Host's checks never ask herdr or tmux, or open a detection connection.
    @Test func aRexHostsChecksIgnoreHerdrAndTmux() async throws {
        let scripted = ScriptedCoreHost(
            herdrRead: .answers(#"{"sessions":[{"name":"default","default":true,"running":true}]}"#),
            rexProbe: ScriptedCoreHost.rexLines(sockets: [(Self.socket, true, true)]), channel: .refused)
        let rex = ScriptedRexHost(control: [.server(FakeRexServer())])
        let store = makeStore(rexHost(), scripted: scripted, rex: rex)

        await store.runChecks()

        #expect(store.report == .allPassed)
        #expect(await scripted.log.isEmpty)
        #expect(await rex.log == ["control \(Self.socket)", "close"])
    }
}
