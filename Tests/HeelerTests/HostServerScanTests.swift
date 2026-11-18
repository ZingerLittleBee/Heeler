import Foundation
import Testing

@testable import Heeler

@Suite("Host server scan")
struct HostServerScanTests {
    private static let tmuxPath = "/home/dev/.local/bin/tmux"
    private static let defaultTUI = HostServerKey(kind: .herdrTUI, name: "")
    private static let defaultCore = HostServerKey(kind: .herdrCore, name: "")
    private static let defaultTmux = HostServerKey(kind: .tmux, name: "")
    private static let rex = HostServerKey(kind: .rex, name: "")
    private static let macRexSocket = "/Users/dev/Library/Application Support/rex/server.sock"

    /// What `herdr session list --json` prints for `sessions`.
    private func sessionList(_ sessions: [HerdrSession]) -> ScriptedCoreHost.HerdrRead {
        let entries = sessions.map {
            #"{"name":"\#($0.name)","default":\#($0.isDefault),"running":\#($0.isRunning)}"#
        }
        return .answers(#"{"sessions":[\#(entries.joined(separator: ","))]}"#)
    }

    /// One look at a Host with nothing on it but what the arguments put there.
    private func scan(
        herdr: ScriptedCoreHost.HerdrRead = .notInstalled,
        locator: [String] = ScriptedCoreHost.locatorLines(executable: nil),
        tmux: [String]? = ScriptedCoreHost.tmuxLines(),
        rex: [String]? = nil,
        session: String = ""
    ) async throws -> HostServerScan {
        let host = ScriptedCoreHost(
            locator: locator, herdrRead: herdr, tmuxProbe: tmux, rexProbe: rex, channel: .refused)
        return HostServerScan(try await ServerKindDetection.run(over: host, session: session))
    }

    // MARK: Herdr TUI

    @Test(arguments: [true, false])
    func theDefaultHerdrSessionIsListedWhetherItRunsOrNot(isRunning: Bool) async throws {
        let found = try await scan(
            herdr: sessionList([HerdrSession(name: "default", isDefault: true, isRunning: isRunning)]))

        #expect(found.servers == [FoundServer(key: Self.defaultTUI, isRunning: isRunning, version: nil)])
        #expect(!found.missing.contains { $0.kind == .herdrTUI })
    }

    /// herdr keeps every session it ever had: a stopped one is no Server.
    @Test func aNamedHerdrSessionIsListedOnlyWhileItRuns() async throws {
        let found = try await scan(
            herdr: sessionList([
                HerdrSession(name: "play", isDefault: false, isRunning: true),
                HerdrSession(name: "default", isDefault: true, isRunning: true),
                HerdrSession(name: "work", isDefault: false, isRunning: false),
            ]))

        // The default session leads, as the Host's own list has it.
        #expect(found.servers.map(\.key) == [Self.defaultTUI, HostServerKey(kind: .herdrTUI, name: "play")])
        #expect(found.servers.map(\.key.label) == ["Herdr TUI", "Herdr TUI · play"])
        #expect(found.servers.allSatisfy { $0.isRunning })
    }

    @Test func aHerdrThatListsNoSessionGivesADefaultThatIsNotRunning() async throws {
        let found = try await scan(herdr: .answers(#"{"sessions":[]}"#))

        #expect(found.servers == [FoundServer(key: Self.defaultTUI, isRunning: false, version: nil)])
    }

    @Test func aHostWithoutHerdrNamesItMissing() async throws {
        let found = try await scan()

        #expect(found.servers.isEmpty)
        #expect(found.missing.contains(HostServerScan.Missing(kind: .herdrTUI, note: nil)))
    }

    // MARK: herdr-core

    /// The locator finds the core installed whether or not it runs: turned on,
    /// a stopped one connects once the user starts it.
    @Test func aCoreIsFoundWhetherItRunsOrNot() async throws {
        let stopped = try await scan(locator: ScriptedCoreHost.locatorLines())
        #expect(stopped.servers == [FoundServer(key: Self.defaultCore, isRunning: false, version: "0.1.13")])

        let running = try await scan(locator: ScriptedCoreHost.locatorLines(socketFile: true))
        #expect(running.servers == [FoundServer(key: Self.defaultCore, isRunning: true, version: "0.1.13")])
        #expect(!running.missing.contains { $0.kind == .herdrCore })
    }

    @Test func aCoreThatIsNotInstalledIsMissingWithNothingToAdd() async throws {
        let found = try await scan()

        #expect(found.missing.contains(HostServerScan.Missing(kind: .herdrCore, note: nil)))
    }

    /// A core no connection can reach is named with what the look saw of it.
    @Test func aCoreNoConnectionCanReachIsMissingWithWhy() async throws {
        let long = "/" + String(repeating: "a", count: 107)
        let tooLong = try await scan(locator: ScriptedCoreHost.locatorLines(defaultPath: long))
        #expect(tooLong.servers.isEmpty)
        #expect(
            tooLong.missing.contains(
                HostServerScan.Missing(kind: .herdrCore, note: "0.1.13, socket path too long")))

        let refused = try await scan(locator: ScriptedCoreHost.locatorLines(), session: "a/b")
        #expect(refused.servers.isEmpty)
        #expect(refused.missing.contains(HostServerScan.Missing(kind: .herdrCore, note: "Session name refused")))
    }

    // MARK: tmux

    @Test func eachSocketATmuxServerAnswersOnIsAServer() async throws {
        let found = try await scan(
            tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: ["default", "work"]))

        #expect(
            found.servers == [
                FoundServer(key: Self.defaultTmux, isRunning: true, version: "3.4"),
                FoundServer(key: HostServerKey(kind: .tmux, name: "work"), isRunning: true, version: "3.4"),
            ])
        #expect(found.servers.map(\.key.label) == ["tmux", "tmux · work"])
        #expect(!found.missing.contains { $0.kind == .tmux })
    }

    @Test func aTmuxWithNoServerIsADefaultThatIsNotRunning() async throws {
        let found = try await scan(tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath))

        #expect(found.servers == [FoundServer(key: Self.defaultTmux, isRunning: false, version: "3.4")])
        #expect(found.servers.first?.key.name == TmuxSocketName.defaultName)
    }

    @Test func aTmuxTooOldToDriveIsMissingWithTheVersionFound() async throws {
        let found = try await scan(
            tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, version: "tmux 3.2a", sockets: ["default"]))

        #expect(found.servers.isEmpty)
        #expect(found.missing.contains(HostServerScan.Missing(kind: .tmux, note: "3.2a, needs 3.3 or newer")))
    }

    @Test func aTmuxThatIsNotThereIsMissingWithNothingToAdd() async throws {
        let notInstalled = try await scan()
        #expect(notInstalled.missing.contains(HostServerScan.Missing(kind: .tmux, note: nil)))

        // The probe's part of the output did not read.
        let unreadable = try await scan(tmux: nil)
        #expect(unreadable.missing.contains(HostServerScan.Missing(kind: .tmux, note: nil)))
    }

    /// Heeler drives no tmux off macOS and Linux, so there is none to miss.
    @Test func aTmuxOnAKernelHeelerDoesNotDriveIsNeitherFoundNorMissing() async throws {
        let found = try await scan(
            tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, kernel: "FreeBSD", sockets: ["default"]))

        #expect(found.servers.isEmpty)
        #expect(found.missing.map(\.kind) == [.herdrTUI, .herdrCore])
    }

    @Test func aTmuxServerTakesThePathsTheLookResolved() async throws {
        let found = try await scan(
            herdr: sessionList([HerdrSession(name: "default", isDefault: true, isRunning: true)]),
            tmux: ScriptedCoreHost.tmuxLines(
                executable: Self.tmuxPath, directory: "/home/dev/run/tmux-1000", sockets: ["default"]))

        #expect(
            found.tmuxPaths(for: Self.defaultTmux)
                == TmuxPaths(executable: Self.tmuxPath, socket: "/home/dev/run/tmux-1000/default"))
        // A socket no server answers on yet has its path all the same.
        #expect(
            found.tmuxPaths(for: HostServerKey(kind: .tmux, name: "work"))
                == TmuxPaths(executable: Self.tmuxPath, socket: "/home/dev/run/tmux-1000/work"))
        #expect(found.tmuxPaths(for: Self.defaultTUI) == nil)

        let without = try await scan()
        #expect(without.tmuxPaths(for: Self.defaultTmux) == nil)
    }

    // MARK: Rex

    /// A socket this account may use is a server that runs. Installed with no
    /// socket, Rex is found as a stopped tmux is: turned on, it connects once
    /// the user starts Rex, which Heeler never does.
    @Test func aRexServerIsFoundWhetherItRunsOrNot() async throws {
        let running = try await scan(rex: ScriptedCoreHost.rexLines(sockets: [(Self.macRexSocket, true, true)]))
        #expect(running.servers == [FoundServer(key: Self.rex, isRunning: true, version: nil)])
        #expect(running.servers.first?.startsChecked == true)
        #expect(running.servers.first?.stateLine == "Running")
        #expect(!running.missing.contains { $0.kind == .rex })

        let stopped = try await scan(rex: ScriptedCoreHost.rexLines(installed: true))
        #expect(stopped.servers == [FoundServer(key: Self.rex, isRunning: false, version: nil)])
        #expect(stopped.servers.first?.startsChecked == false)
        #expect(stopped.servers.first?.stateLine == "Not running")
        #expect(!stopped.missing.contains { $0.kind == .rex })
    }

    /// One Rex Server on a Host, whichever socket it listens on: the label is
    /// the kind's, and a record maps back to the key whatever socket it holds.
    @Test func aHostHasOneRexServerWhateverItsSocket() async throws {
        let linux = try await scan(
            rex: ScriptedCoreHost.rexLines(
                kernel: "Linux",
                sockets: [("/run/rex/server.sock", false, true), ("/run/user/1000/rex/server.sock", true, true)]))
        #expect(linux.servers.map(\.key) == [Self.rex])

        let typed = HostServerKey(kind: .rex, name: "/run/rex/server.sock")
        #expect(typed == Self.rex)
        #expect(Self.rex.distinguishingName == nil)
        #expect(Self.rex.label == "Rex")
        #expect(Self.rex.badgeLabel == "Rex")
        for socket in [Self.macRexSocket, "/run/user/1000/rex/server.sock", nil] {
            let record = Host(
                address: "studio.example", username: "dev", serverKind: .rex,
                rexSocket: socket.flatMap { RexSocket(path: $0) })
            #expect(record.serverKey == Self.rex)
        }
    }

    /// The only Rex a Host names missing: a server is there, and this account
    /// cannot use its socket.
    @Test func aRexSocketThisAccountCannotUseIsMissingWithWhy() async throws {
        let found = try await scan(
            rex: ScriptedCoreHost.rexLines(kernel: "Linux", sockets: [("/run/rex/server.sock", false, false)]))

        #expect(found.servers.isEmpty)
        #expect(
            found.missing.contains(
                HostServerScan.Missing(kind: .rex, note: "Socket found, but this account cannot use it")))
    }

    /// A machine without Rex shows nothing of it, so a Host whose user never
    /// had Rex lists what it listed before Heeler looked for Rex.
    @Test func aHostWithoutRexNeitherListsNorMissesIt() async throws {
        let unread = try await scan(tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: ["default"]))
        let withoutRex: [[String]] = [
            ScriptedCoreHost.rexLines(installed: false),
            ScriptedCoreHost.rexLines(kernel: "FreeBSD", sockets: [("/var/run/rex/server.sock", true, true)]),
        ]
        for rex in withoutRex {
            let found = try await scan(
                tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: ["default"]), rex: rex)

            #expect(found.servers == unread.servers, "\(rex)")
            #expect(found.missing == unread.missing, "\(rex)")
        }
        #expect(!unread.missing.contains { $0.kind == .rex })
    }

    @Test func aRexServerTakesTheSocketTheLookFound() async throws {
        let found = try await scan(rex: ScriptedCoreHost.rexLines(sockets: [(Self.macRexSocket, true, true)]))

        #expect(found.rexSocket(for: Self.rex)?.path == Self.macRexSocket)
        #expect(found.rexSocket(for: Self.defaultTmux) == nil)
        #expect(found.tmuxPaths(for: Self.rex) == nil)

        // A Rex that is not running has no socket yet: its record looks it up.
        let stopped = try await scan(rex: ScriptedCoreHost.rexLines(installed: true))
        #expect(stopped.rexSocket(for: Self.rex) == nil)
    }

    @Test func rexIsListedAfterTheOtherKinds() async throws {
        let found = try await scan(
            herdr: sessionList([HerdrSession(name: "default", isDefault: true, isRunning: true)]),
            locator: ScriptedCoreHost.locatorLines(),
            tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: ["default"]),
            rex: ScriptedCoreHost.rexLines(sockets: [(Self.macRexSocket, true, true)]))

        #expect(found.servers.map(\.key) == [Self.defaultTUI, Self.defaultCore, Self.defaultTmux, Self.rex])
        #expect(found.missing.isEmpty)
    }

    // MARK: Every kind at once

    @Test func theServersAreListedHerdrTUIThenCoreThenTmux() async throws {
        let found = try await scan(
            herdr: sessionList([HerdrSession(name: "default", isDefault: true, isRunning: true)]),
            locator: ScriptedCoreHost.locatorLines(),
            tmux: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: ["default"]))

        #expect(found.servers.map(\.key) == [Self.defaultTUI, Self.defaultCore, Self.defaultTmux])
        #expect(found.missing.isEmpty)
        #expect(!found.isNativeWindows)
    }

    // MARK: A found Server

    /// One that runs brings its Agents at once; one that does not would only
    /// sit unreachable.
    @Test func onlyAServerThatRunsStartsChecked() {
        let running = FoundServer(key: Self.defaultTmux, isRunning: true, version: "3.5a")
        let stopped = FoundServer(key: Self.defaultCore, isRunning: false, version: "0.1.13")
        let unversioned = FoundServer(key: Self.defaultTUI, isRunning: false, version: nil)

        #expect(running.startsChecked)
        #expect(!stopped.startsChecked)
        #expect(running.stateLine == "Running · 3.5a")
        #expect(stopped.stateLine == "Not running · 0.1.13")
        #expect(unversioned.stateLine == "Not running")
    }
}
