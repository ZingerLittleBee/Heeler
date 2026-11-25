import Foundation
import Testing

@testable import Heeler

/// Rex in Server Kind detection (ADR 0049): looked for on every macOS and Linux
/// Host by its socket alone, from the one exec a look at a Host runs.
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

    /// The kind of each Server a Host lists from `detection` (ADR 0047).
    private func listedKinds(_ detection: ServerKindDetection) -> [ServerKind] {
        HostServerScan(detection).servers.map(\.key.kind)
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

    @Test func aMacSocketWithSpacesInItsPathIsFound() async throws {
        let (detection, host) = try await detect(
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]))

        #expect(await host.log == ["detection"])
        #expect(detection.rex == .socketFound(socketPath: Self.macSocket))
        #expect(detection.rexSocket?.path == Self.macSocket)
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

    @Test func rexBesideHerdrIsListedBesideIt() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]),
            herdr: .answers(#"{"sessions":[{"name":"default","default":true,"running":true}]}"#))

        #expect(listedKinds(detection) == [.herdrTUI, .rex])
        #expect(detection.rexSocket?.path == Self.macSocket)
    }

    /// Rex is there and no socket says a server listens: there is no socket
    /// to store, and Heeler starts no server to make one.
    @Test func installedButNotRunningHasNoSocket() async throws {
        let (detection, _) = try await detect(rex: ScriptedCoreHost.rexLines(installed: true))

        #expect(detection.rex == .notRunning)
        #expect(detection.rexSocket == nil)
    }

    @Test func noRexAtAllIsNotInstalled() async throws {
        let (detection, _) = try await detect(rex: ScriptedCoreHost.rexLines(installed: false))

        #expect(detection.rex == .notInstalled)
        #expect(detection.rexSocket == nil)
        #expect(listedKinds(detection).isEmpty)
    }

    /// Another account's server, or a path this build cannot name as one
    /// shell word, is no socket to store.
    @Test func aSocketThisAccountCannotUseIsNotUsable() async throws {
        let (theirs, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(kernel: "Linux", sockets: [(Self.linuxSharedSocket, false, false)]))
        #expect(theirs.rex == .notUsable(socketPath: Self.linuxSharedSocket))
        #expect(theirs.rexSocket == nil)

        let quoted = "/Users/it's me/Library/Application Support/rex/server.sock"
        let (unnamed, _) = try await detect(rex: ScriptedCoreHost.rexLines(sockets: [(quoted, true, true)]))
        #expect(unnamed.rex == .notUsable(socketPath: quoted))
        #expect(unnamed.rexSocket == nil)
    }

    @Test func aKernelOtherThanMacOSOrLinuxIsUnsupported() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(kernel: "FreeBSD", sockets: [("/var/run/rex/server.sock", true, true)]))

        #expect(detection.rex == .unsupported)
        #expect(detection.rexSocket == nil)
    }

    /// A Rex part that did not read says nothing of the others.
    @Test func anUnreadableRexPartLeavesTheOtherFindings() async throws {
        let (detection, _) = try await detect(
            rex: nil, herdr: .answers(#"{"sessions":[{"name":"default","default":true,"running":true}]}"#))

        #expect(detection.rex == .unreadable)
        #expect(listedKinds(detection) == [.herdrTUI])
    }

    @Test func aRefusedSessionNameKeepsAFoundRex() async throws {
        let (detection, _) = try await detect(
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]), session: "a/b")

        #expect(detection.rexSocket?.path == Self.macSocket)
    }

    /// Whatever the Rex part says, the other findings and the Servers a Host
    /// lists of the other kinds stay as they are, from the same one exec. A
    /// machine without Rex lists exactly what it did before Heeler looked for
    /// Rex, Rex named nowhere.
    @Test func theRexPartLeavesTheOtherKindsAsTheyWere() async throws {
        let sessions = #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
        let tmuxRunning = ScriptedCoreHost.tmuxLines(
            executable: "/usr/bin/tmux", kernel: "Darwin", sockets: ["default"])
        let tmuxIdle = ScriptedCoreHost.tmuxLines(executable: "/usr/bin/tmux", kernel: "Darwin")
        let hosts: [(ScriptedCoreHost.HerdrRead, [String])] = [
            (.answers(sessions), tmuxRunning),
            (.answers(sessions), tmuxIdle),
            (.notInstalled, ScriptedCoreHost.tmuxLines(kernel: "Darwin")),
        ]
        let rexParts: [(lines: [String]?, isOnTheMachine: Bool)] = [
            (nil, false),
            (ScriptedCoreHost.rexLines(installed: false), false),
            (ScriptedCoreHost.rexLines(kernel: "FreeBSD", sockets: [(Self.linuxSharedSocket, true, true)]), false),
            (ScriptedCoreHost.rexLines(installed: true), true),
            (ScriptedCoreHost.rexLines(kernel: "Linux", sockets: [(Self.linuxSharedSocket, false, false)]), true),
            (ScriptedCoreHost.rexLines(sockets: [(Self.macSocket, true, true)]), true),
        ]
        for (herdr, tmux) in hosts {
            let (unread, _) = try await detect(rex: nil, herdr: herdr, tmux: tmux)
            let unreadScan = HostServerScan(unread)
            for rex in rexParts {
                let (detection, host) = try await detect(rex: rex.lines, herdr: herdr, tmux: tmux)
                let scan = HostServerScan(detection)
                let comment = Comment(rawValue: "\(rex.lines ?? [])")

                #expect(await host.log == ["detection"])
                #expect(scan.servers.filter { $0.key.kind != .rex } == unreadScan.servers, comment)
                #expect(scan.missing.filter { $0.kind != .rex } == unreadScan.missing, comment)
                #expect(detection.herdrTUI == unread.herdrTUI)
                #expect(detection.herdrCore == unread.herdrCore)
                #expect(detection.tmux == unread.tmux)
                if !rex.isOnTheMachine {
                    #expect(scan.servers == unreadScan.servers, comment)
                    #expect(scan.missing == unreadScan.missing, comment)
                    #expect(detection.rexSocket == nil)
                }
            }
        }
    }

    static let windowsPipe = "npipe:////./pipe/rex-S-1-5-21-1111111111-2222222222-3333333333-1001"

    /// A native Windows Host is asked for Rex's named pipe in the same one
    /// exec, and stores the pipe's address as a Unix Host stores its socket.
    @Test func aNativeWindowsHostIsAskedForRexsPipe() async throws {
        let host = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            rexProbe: ScriptedCoreHost.rexLines(kernel: "Windows", sockets: [(Self.windowsPipe, true, true)]),
            channel: .refused)

        let detection = try await ServerKindDetection.run(over: host, session: "work")

        #expect(await host.log == ["windows-detection"])
        #expect(detection.rex == .socketFound(socketPath: Self.windowsPipe))
        #expect(detection.rexSocket?.isWindowsPipe == true)
        let body = try #require(await host.scripts.first)
        // The pipe namespace is listed by name: no pipe is opened, so the
        // server sees no client and a busy pipe still counts.
        #expect(body.contains(#"[IO.Directory]::GetFiles('\\.\pipe\')"#))
        #expect(!body.contains(#"Test-Path -LiteralPath ('\\.\pipe"#))
        // Installed reads Rex's data folder, not a `rex.exe` on PATH.
        #expect(body.contains(#"Join-Path $env:LOCALAPPDATA 'rex'"#))
        // Testing the pipe and PATH starts nothing: `rex` itself never runs.
        #expect(!body.contains("& rex"))
        #expect(!body.contains("__internal"))
    }

    @Test func aWindowsHostWithoutRexsPipeSaysWhy() async throws {
        for (lines, expected) in [
            (ScriptedCoreHost.rexLines(kernel: "Windows", installed: true), ServerKindDetection.RexFinding.notRunning),
            (ScriptedCoreHost.rexLines(kernel: "Windows", installed: false), .notInstalled),
        ] {
            let host = ScriptedCoreHost(
                windowsLocator: ScriptedCoreHost.windowsLocatorLines(), rexProbe: lines, channel: .refused)
            #expect(try await ServerKindDetection.run(over: host, session: "work").rex == expected)
        }
    }

    /// A pipe with no `rex.exe` on the exec's PATH is a server the bridge
    /// cannot reach: named missing, with why, and nothing to store.
    @Test func aWindowsPipeWithoutRexOnPathIsNotUsable() async throws {
        let host = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            rexProbe: ScriptedCoreHost.rexLines(kernel: "Windows", sockets: [(Self.windowsPipe, true, false)]),
            channel: .refused)

        let detection = try await ServerKindDetection.run(over: host, session: "work")

        #expect(detection.rex == .notUsable(socketPath: Self.windowsPipe))
        #expect(detection.rexSocket == nil)
        #expect(
            HostServerScan(detection).missing.filter { $0.kind == .rex }.map(\.note)
                == ["Rex runs, but rex.exe is not on this account's PATH"])
    }

    /// Only Rex's own name for a personal server's pipe is an address to
    /// store: it goes on a command line unquoted.
    @Test func onlyRexsPipeNameIsAWindowsAddress() {
        #expect(RexSocket(path: Self.windowsPipe)?.isWindowsPipe == true)
        #expect(RexSocket(path: Self.macSocket)?.isWindowsPipe == false)
        for refused in [
            "npipe:////./pipe/", "npipe:////./pipe/rex-", "npipe:////./pipe/other-S-1-5",
            "npipe:////./pipe/rex-S-1-5&calc", "npipe:////./pipe/rex-S 1", #"\\.\pipe\rex-S-1-5"#,
            "npipe:////./pipe/rex-S-1-5\"", "npipe:////./pipe/rex-S-1-5/..",
        ] {
            #expect(RexSocket(path: refused) == nil, Comment(rawValue: refused))
        }
        let stored = try? JSONDecoder().decode(
            RexSocket.self, from: Data(#"{"path":"\#(Self.windowsPipe)"}"#.utf8))
        #expect(stored?.path == Self.windowsPipe)
        #expect(RexWindowsDial.command(for: RexSocket(path: Self.macSocket)!) == nil)
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

        let windows = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            rexProbe: ScriptedCoreHost.rexLines(kernel: "Windows", sockets: [(Self.windowsPipe, true, true)]),
            channel: .refused)
        #expect(try await RexProbe.run(over: windows) == .socketFound(socketPath: Self.windowsPipe))
        #expect(await windows.log == ["windows-detection"])
        let windowsBody = try #require(await windows.scripts.first)
        #expect(!windowsBody.contains("herdr"))
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

/// A Rex Host's checks in Host onboarding (ADR 0049): they reach the
/// server's socket, say hello, and close with a close frame.
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

    /// A Rex Host's checks dial the socket it stores, say hello and leave,
    /// and never run detection.
    @Test func aRexHostsChecksSayHelloToItsSocketAndLeave() async throws {
        let scripted = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(executable: nil),
            rexProbe: ScriptedCoreHost.rexLines(sockets: [(Self.socket, true, true)]), channel: .refused)
        let server = FakeRexServer()
        let rex = ScriptedRexHost(control: [.server(server)])
        let host = rexHost()
        let catalog = HostStore(volatileHosts: [host])
        let store = makeStore(host, scripted: scripted, rex: rex)

        await store.runChecks()

        #expect(store.host.serverKind == .rex)
        #expect(store.host.rexSocket?.path == Self.socket)
        #expect(store.host.sessionName == "")
        #expect(catalog.hosts == [store.host])
        // The checks dialed the stored socket, said hello and left.
        #expect(await scripted.log.isEmpty)
        #expect(await rex.log == ["control \(Self.socket)", "close"])
        #expect(await server.nextHello()["type"] == .string("hello"))
        #expect(await server.clientClose?.code == .normalClosure)
        #expect(await server.requests.isEmpty)
        #expect(store.report == .allPassed)
        #expect(store.pluginStatus == .unsupportedServerKind)
        #expect(store.hostHelper == nil)
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
        newer.apiRevision = 20
        newer.serverRevision = 20
        let store = makeStore(rexHost(), rex: ScriptedRexHost(control: [.server(FakeRexServer(), welcome: newer)]))
        await store.runChecks()
        #expect(failedCheck(store)?.0 == .protocolCompatible)
        #expect(failedCheck(store)?.1.contains("revisions 12 to 19") == true)
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
