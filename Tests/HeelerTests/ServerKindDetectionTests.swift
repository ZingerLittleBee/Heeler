import Foundation
import Testing

@testable import Heeler

@Suite("Server Kind detection")
struct ServerKindDetectionTests {
    private static let sessionsJSON = #"""
        {
          "sessions": [
            {"name": "default", "default": true, "running": true},
            {"name": "work", "default": false, "running": false}
          ]
        }
        """#
    private static let sessions = [
        HerdrSession(name: "default", isDefault: true, isRunning: true),
        HerdrSession(name: "work", isDefault: false, isRunning: false),
    ]

    private func script(session: String = "work") -> String {
        String(decoding: ServerKindDetection.script(session: session, nonce: "n0nce"), as: UTF8.self)
    }

    private func detect(
        herdr: ScriptedCoreHost.HerdrRead = .notInstalled,
        locator: [String] = ScriptedCoreHost.locatorLines(),
        shellBanner: Data = Data(),
        session: String = "work"
    ) async throws -> ServerKindDetection {
        let host = ScriptedCoreHost(
            locator: locator, shellBanner: shellBanner, herdrRead: herdr, channel: .refused)
        return try await ServerKindDetection.run(over: host, session: session)
    }

    // MARK: The script

    @Test func oneExecRunsTheHerdrTUIReadAndTheLocator() async throws {
        let host = ScriptedCoreHost(herdrRead: .answers(Self.sessionsJSON), channel: .refused)

        _ = try await ServerKindDetection.run(over: host, session: "work")

        #expect(await host.log == ["detection"])
        let scripts = await host.scripts
        #expect(scripts.count == 1)
        let body = try #require(scripts.first)
        #expect(body.components(separatedBy: "herdr session list --json").count == 2)
        #expect(body.contains("__session='work'\n"))
        #expect(body.contains(#""$1" --version"#))
    }

    @Test func theScriptNamesNoHCAndAsksTheCoreOnlyForItsVersion() {
        let body = script()
        // `hc ` appears once, as the version text the locator accepts.
        #expect(body.components(separatedBy: "'hc '").count == 2)
        #expect(body.replacingOccurrences(of: "'hc '", with: "").range(
            of: #"\bhc\b"#, options: .regularExpression) == nil)
        for subcommand in ["server", "connect", "attach", " run ", " start", " stop"] {
            #expect(!body.contains(subcommand), "\(subcommand)")
        }
        // The one program the script runs by the core's name is the probe.
        let core = body.split(separator: "\n").filter { $0.contains("herdr-core") }
        #expect(core.allSatisfy {
            $0.contains("command -v herdr-core") || $0.contains("__probe")
                || $0.contains("/herdr-core") || $0.contains("'herdr-core '")
        }, "\(core)")
    }

    @Test func thePathFixStaysOutOfTheLocator() throws {
        let body = script()
        let locatorStart = try #require(body.range(of: "__session="))
        #expect(body[..<locatorStart.lowerBound].contains(HerdrHostPath.pathExport))
        #expect(!body[locatorStart.lowerBound...].contains("PATH="))
    }

    @Test func theLocatorReadsTheTypedSessionsLock() {
        #expect(script(session: "work team").contains("__session='work team'\n"))
        #expect(script(session: " work ").contains("__session='work'\n"))
        #expect(script(session: "").contains("__session='default'\n"))
    }

    @Test func aSessionNameHCRefusesRunsOnlyTheHerdrTUIRead() async throws {
        let body = script(session: "a/b")
        #expect(body.contains("herdr session list --json"))
        #expect(!body.contains("herdr-core"))
        #expect(!body.contains("a/b"))

        let detection = try await detect(herdr: .answers(Self.sessionsJSON), session: "a/b")

        #expect(detection.herdrTUI == .found(sessions: Self.sessions))
        #expect(detection.herdrCore == .sessionRefused(
            reason: ServerKind.herdrCore.sessionNameRefusal("a/b") ?? ""))
    }

    // MARK: What it found

    @Test func herdrTUIOnly() async throws {
        let detection = try await detect(
            herdr: .answers(Self.sessionsJSON),
            locator: ScriptedCoreHost.locatorLines(executable: nil))

        #expect(detection.herdrTUI == .found(sessions: Self.sessions))
        #expect(detection.herdrCore == .notInstalled)
        #expect(detection.foundKinds == [.herdrTUI])
    }

    @Test func neither() async throws {
        let detection = try await detect(locator: ScriptedCoreHost.locatorLines(executable: nil))

        #expect(detection.herdrTUI == .notFound)
        #expect(detection.herdrCore == .notInstalled)
        #expect(detection.foundKinds.isEmpty)
    }

    @Test func both() async throws {
        let detection = try await detect(
            herdr: .answers(Self.sessionsJSON),
            locator: ScriptedCoreHost.locatorLines(socketFile: true))

        #expect(detection.foundKinds == [.herdrTUI, .herdrCore])
    }

    @Test func herdrCoreOnlyInEachLocatorState() async throws {
        let socket = ScriptedCoreHost.socketPath
        let long = "/" + String(repeating: "a", count: 107)
        let cases: [([String], ServerKindDetection.CoreFinding)] = [
            (
                ScriptedCoreHost.locatorLines(),
                .notRunning(version: "0.1.13", socketPath: socket)
            ),
            (
                // A lock whose socket is gone outlived its core.
                ScriptedCoreHost.locatorLines(lock: "/run/old.sock", socketFile: false),
                .notRunning(version: "0.1.13", socketPath: "/run/old.sock")
            ),
            (
                ScriptedCoreHost.locatorLines(lock: "/run/live.sock", socketFile: true),
                .socketFilePresent(version: "0.1.13", socketPath: "/run/live.sock")
            ),
            (
                ScriptedCoreHost.locatorLines(socketFile: true),
                .socketFilePresent(version: "0.1.13", socketPath: socket)
            ),
            (
                ScriptedCoreHost.locatorLines(defaultPath: long),
                .socketPathTooLong(version: "0.1.13", socketPath: long, limit: 107)
            ),
        ]
        for (lines, finding) in cases {
            let detection = try await detect(locator: lines)
            #expect(detection.herdrCore == finding)
            #expect(detection.herdrTUI == .notFound)
            #expect(detection.foundKinds == [.herdrCore])
        }
    }

    /// A `herdr` that does not answer like herdr is not Herdr TUI, whatever it
    /// printed, and it costs nothing of what the locator found.
    @Test(arguments: [
        ScriptedCoreHost.HerdrRead.notInstalled,
        .fails(status: 1, output: #"{"sessions":[]}"#),
        .answers("not json"),
        .answers(#"{"sessions":[{"name":"../x","default":false,"running":false}]}"#),
        .answers(#"{"other":true}"#),
    ])
    func aHerdrThatDoesNotAnswerIsNotFound(_ read: ScriptedCoreHost.HerdrRead) async throws {
        let detection = try await detect(herdr: read)

        #expect(detection.herdrTUI == .notFound)
        #expect(detection.foundKinds == [.herdrCore])
    }

    @Test func startupOutputInAnyEncodingIsIgnored() async throws {
        let detection = try await detect(
            herdr: .answers(Self.sessionsJSON),
            shellBanner: Data("Welcome\n".utf8) + Data([0xFF, 0xFE, 0x20]))

        #expect(detection.herdrTUI == .found(sessions: Self.sessions))
    }

    @Test func outputCutShortIsNotAFinding() throws {
        let nonce = "n0nce"
        let framing = "\n\(nonce) herdr-tui begin\n{}\n"
        let whole = framing + "\n\(nonce) herdr-tui status 0\n\(nonce) begin\nkernel Linux\n"
            + "default /tmp/s.sock\nsocket-file 0\n\(nonce) end\n"
        #expect(throws: Never.self) {
            try ServerKindDetectionScript.parse(stdout: Data(whole.utf8), session: "work", nonce: nonce)
        }
        for cut in [
            Data(), Data(framing.utf8),
            Data((framing + "\n\(nonce) herdr-tui status 0\n").utf8),
            Data((framing + "\n\(nonce) herdr-tui status x\n\(nonce) begin\n\(nonce) end\n").utf8),
        ] {
            #expect(throws: (any Error).self) {
                try ServerKindDetectionScript.parse(stdout: cut, session: "work", nonce: nonce)
            }
        }
    }

    @Test func aFailedExecThrowsItsStatus() async throws {
        let host = ScriptedCoreHost(locatorStatus: 137, channel: .refused)

        await #expect(throws: TransportError.malformedResponse(
            "Server Kind detection exited with status 137.")
        ) {
            try await ServerKindDetection.run(over: host, session: "work")
        }
    }

    // MARK: What the user reads

    @Test func eachFindingSaysWhatWasFound() {
        let cases: [(ServerKindDetection.CoreFinding, String)] = [
            (.notInstalled, "Not installed"),
            (.notRunning(version: "0.1.13", socketPath: "/s"), "0.1.13, not running"),
            (.socketFilePresent(version: "0.1.13", socketPath: "/s"), "0.1.13, socket found"),
            (.socketPathTooLong(version: "0.1.13", socketPath: "/s", limit: 103), "0.1.13, socket path too long"),
            (.sessionRefused(reason: "why"), "Session name refused"),
        ]
        for (finding, summary) in cases {
            #expect(finding.summary == summary)
        }
        #expect(ServerKindDetection.HerdrTUIFinding.found(sessions: []).summary == "Found")
        #expect(ServerKindDetection.HerdrTUIFinding.notFound.summary == "Not found")
    }

    // MARK: What is offered

    @Test func theFoundKindsAreOffered() async throws {
        let both = try await detect(herdr: .answers(Self.sessionsJSON))
        #expect(both.offeredKinds == [.herdrTUI, .herdrCore])

        let tui = try await detect(
            herdr: .answers(Self.sessionsJSON),
            locator: ScriptedCoreHost.locatorLines(executable: nil))
        #expect(tui.offeredKinds == [.herdrTUI])

        let core = try await detect()
        #expect(core.offeredKinds == [.herdrCore])

        // Nothing there yet: the user may be about to install either.
        let neither = try await detect(locator: ScriptedCoreHost.locatorLines(executable: nil))
        #expect(neither.offeredKinds == [.herdrTUI, .herdrCore])
        #expect(ServerKindDetection.offeredWithoutFindings == [.herdrTUI, .herdrCore])

        // Offered, so that confirming it says why it cannot be.
        let refused = try await detect(herdr: .answers(Self.sessionsJSON), session: "a/b")
        #expect(refused.offeredKinds == [.herdrTUI, .herdrCore])
    }

    // MARK: A native Windows target

    private func detectOnWindows(
        herdr: ScriptedCoreHost.HerdrRead = .notInstalled,
        locator: [String] = ScriptedCoreHost.windowsLocatorLines(),
        shellBanner: Data = Data(), session: String = "work"
    ) async throws -> (ServerKindDetection, ScriptedCoreHost) {
        let host = ScriptedCoreHost(
            windowsLocator: locator, shellBanner: shellBanner, herdrRead: herdr, channel: .refused)
        return (try await ServerKindDetection.run(over: host, session: session), host)
    }

    @Test func aWindowsTargetsCoreIsReportedFromItsProbe() async throws {
        let (running, host) = try await detectOnWindows()
        #expect(await host.log == ["windows-detection"])
        #expect(running.herdrCore == .socketFilePresent(version: "0.1.16", socketPath: ScriptedCoreHost.windowsPipe))
        #expect(running.offeredKinds == [.herdrCore])
        #expect(running.herdrCore.summary == "0.1.16, running")

        let (stopped, _) = try await detectOnWindows(
            locator: ScriptedCoreHost.windowsLocatorLines(lock: ScriptedCoreHost.windowsPipe, pipe: false))
        #expect(stopped.herdrCore == .notRunning(version: "0.1.16", socketPath: ScriptedCoreHost.windowsPipe))
        #expect(stopped.offeredKinds == [.herdrCore])

        let (absent, _) = try await detectOnWindows(
            locator: ScriptedCoreHost.windowsLocatorLines(executable: nil, pipe: false))
        #expect(absent.herdrCore == .notInstalled)
    }

    @Test func theWindowsProbeAlsoReadsHerdrTUIInTheSameExec() async throws {
        let (detection, host) = try await detectOnWindows(
            herdr: .answers(Self.sessionsJSON), shellBanner: Data("Windows banner\r\n".utf8))

        #expect(detection.herdrTUI == .found(sessions: Self.sessions))
        #expect(detection.offeredKinds == [.herdrTUI, .herdrCore])
        let body = try #require(await host.scripts.first)
        #expect(await host.scripts.count == 1)
        #expect(body.contains("session list --json"))
        #expect(body.contains(HerdrCoreLocator.windowsExecutable))
        #expect(!body.lowercased().contains("hc.exe"))
        #expect(!body.contains("server start"))
        #expect(!body.contains("connect"))
    }

    @Test func aNameWindowsRefusesRunsNoLocatorAndSaysWhy() async throws {
        // A name Unix takes and no `cmd` line can carry.
        let (detection, host) = try await detectOnWindows(
            herdr: .answers(Self.sessionsJSON), session: "my work")

        guard case .sessionRefused(let reason) = detection.herdrCore else {
            Issue.record("expected a refusal, got \(detection.herdrCore)")
            return
        }
        #expect(reason == HerdrCoreSessionName.windowsRefusal("my work"))
        #expect(!reason.isEmpty)
        #expect(detection.herdrTUI == .found(sessions: Self.sessions))
        #expect(await host.scripts.first?.contains("$s = ") == false)
    }

    @Test func aNameHCRefusesIsRefusedOnWindowsToo() async throws {
        let (detection, _) = try await detectOnWindows(session: "a/b")

        #expect(detection.herdrCore == .sessionRefused(reason: try #require(ServerKind.herdrCore.sessionNameRefusal("a/b"))))
    }

    @Test func aWindowsProbeCutShortReadsAsAFailedRead() async throws {
        let host = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(), locatorStatus: 1, channel: .refused)

        await #expect(throws: TransportError.self) {
            _ = try await ServerKindDetection.run(over: host, session: "work")
        }
    }
}
