import Foundation
import Testing
import os

@testable import Heeler

/// A herdr-core Host's Usage comes from its Host Helper (ADR 0033): one query in
/// the Helper's directory, and the Account file beside it, never the plugin's.
@Suite("Usage through the Host Helper")
@MainActor
struct AgentUsageHostHelperTests {
    private static let directory = ScriptedHelperHost.helperDirectory
    private static let accountFile = "\(directory)/\(UsageAccountFile.fileName)"

    private func console(
        _ helper: ScriptedHelperHost, session: String = ""
    ) -> (ConsoleStore, Host, ScriptedCoreHost) {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore, sessionName: session)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { ScriptedTransport(snapshot: .fixture(agents: [])) }, keepalive: nil)
            },
            connectCore: { _ in core.transport() })
        console.setHosts([host])
        return (console, host, core)
    }

    private func helperWithReport(session: String = "default") async throws -> ScriptedHelperHost {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        await helper.seedUsage(try AgentUsageFixture.reportData(refreshing: false), session: session)
        return helper
    }

    private func queries(_ helper: ScriptedHelperHost) async -> [(limits: Bool, session: String)] {
        await helper.steps.compactMap { step in
            guard case .usageQuery(_, let limits, let session) = step else { return nil }
            return (limits, session)
        }
    }

    @Test func aCoreHostWithTheHelperShowsTheHelpersReport() async throws {
        let helper = try await helperWithReport()
        let (console, host, core) = console(helper)
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .available(try AgentUsageFixture.report()))
        #expect(await queries(helper).count == 1)
        // A connection dialed for one read does not outlive it.
        #expect(await core.log == ["close"])
    }

    @Test func aReadAsksAboutTheHostsNormalizedSession() async throws {
        let helper = try await helperWithReport(session: "work")
        let (console, host, _) = console(helper, session: " work ")
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .available(try AgentUsageFixture.report()))
        #expect(await queries(helper).map(\.session) == ["work"])
    }

    @Test func claudeCodesLimitsAreRequestedOnlyWhenTurnedOnForThatHost() async throws {
        let helper = try await helperWithReport()
        let (console, host, _) = console(helper)
        let key = AgentUsageStore.claudeLimitsPreferenceKey(for: host.id)
        defer {
            console.setHosts([])
            UserDefaults.standard.removeObject(forKey: key)
        }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()
        store.claudeLimitsEnabled = true
        await store.pullToRefresh()

        #expect(await queries(helper).map(\.limits) == [false, true])
    }

    @Test func aHostWithoutTheHelperSaysUsageNeedsIt() async throws {
        let (console, host, _) = console(ScriptedHelperHost())
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .hostHelper(.notInstalled))
        #expect(AgentUsageScope.reason(for: store.state) == "Needs the Host Helper")
        #expect(AgentUsageHostHelperNeed.notInstalled.message.contains("Usage needs the Host Helper"))
    }

    @Test func aHelperFromBeforeUsageAsksForItsUpdate() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp(usage: false)
        let (console, host, _) = console(helper)
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .hostHelper(.outdated))
    }

    @Test func aNativeWindowsHostSaysUsageComesWithTheHelperAndRunsNothing() async throws {
        let helper = ScriptedHelperHost()
        await helper.configure { $0.platform = .nativeWindows }
        let (console, host, _) = console(helper)
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .hostHelper(.notOnWindows))
        let message = AgentUsageHostHelperNeed.notOnWindows.message
        #expect(message.contains("comes with the Host Helper"))
        #expect(message.contains("not available"))
        #expect(await helper.steps.isEmpty)
    }

    @Test func aHelperWithNoRecordOfTheSessionReadsAsWaitingAndAsksForIt() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        let (console, host, _) = console(helper, session: "work")
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .hostHelper(.waitingForCore))
        #expect(await helper.folders["\(Self.directory)/sessions/work"] == 0o700)
    }

    @Test func waitingKeepsReadingWithABackoffUntilTheHelperHasARecord() async throws {
        let report = try AgentUsageFixture.report()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let pauses = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let store = AgentUsageStore(
            hostID: UUID(), defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard,
            sleep: { delay in pauses.withLock { $0.append(delay) } }
        ) { _, _ in
            let read = reads.withLock { reads in
                reads += 1
                return reads
            }
            return read < 4 ? .hostHelper(.waitingForCore) : .available(report)
        }

        await store.refresh()

        #expect(store.state == .available(report))
        #expect(reads.withLock { $0 } == 4)
        #expect(pauses.withLock { $0 } == [.seconds(3), .seconds(6), .seconds(12)])
    }

    @Test func accountChangesGoToTheHelpersDirectory() async throws {
        let helper = try await helperWithReport()
        let (console, host, _) = console(helper)
        defer { console.setHosts([]) }
        await helper.seedFolder(Self.directory, mode: 0o700)

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()
        let suggestion = try JSONDecoder().decode(
            AgentUsageReport.AccountSuggestion.self,
            from: Data(#"{"directory":"/home/me/.claude-work","name":"claude-work","source":"agent"}"#.utf8))
        #expect(await store.addAccount(suggestion))

        let written = try #require(await helper.files[Self.accountFile]?.contents)
        let file = try UsageAccountFile.decode(written)
        #expect(file.accounts.map(\.directory) == ["/home/me/.claude-work"])
    }

    @Test func theBrowserAndHomeFolderUseTheHostsServices() async throws {
        let helper = try await helperWithReport()
        let (console, host, _) = console(helper)
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.loadHostHome()

        #expect(store.hostHome == ScriptedHelperHost.home)
    }
}

/// The script text itself runs in `scripts/test-host-helper-scripts.py`; this is
/// what the app makes of what it prints.
@Suite("Host Helper Usage answers")
struct HostHelperUsageAnswerTests {
    private func answer(_ body: String, status: Int = 0) -> Data {
        Data("noise\n__HEELER_USAGE_BEGIN_n\n\(body)\n__HEELER_USAGE_END_n:\(status)\nnoise".utf8)
    }

    @Test func aFramedReportDecodes() throws {
        let body = #"{"version":1,"runtime":"missing"}"#
        #expect(try AgentUsageProbe.parseHelper(stdout: answer(body), nonce: "n").runtime == "missing")
    }

    @Test func helperStatesThrowWhatTheStoreShows() throws {
        #expect(throws: AgentUsageHostHelperNeed.notInstalled) {
            try AgentUsageProbe.parseHelper(stdout: answer("helper-absent"), nonce: "n")
        }
        #expect(throws: AgentUsageHostHelperNeed.outdated) {
            try AgentUsageProbe.parseHelper(stdout: answer("helper-outdated"), nonce: "n")
        }
        #expect(AgentUsageStore.state(for: AgentUsageHostHelperNeed.outdated) == .hostHelper(.outdated))
    }

    @Test func aFailedOrUnfinishedQueryIsNoReport() {
        #expect(throws: (any Error).self) {
            try AgentUsageProbe.parseHelper(stdout: answer("{}", status: 1), nonce: "n")
        }
        #expect(throws: (any Error).self) {
            try AgentUsageProbe.parseHelper(stdout: Data("__HEELER_USAGE_BEGIN_n\n{".utf8), nonce: "n")
        }
    }

    @Test func aTimeZoneTheQueryCouldNotTakeRunsNothing() async {
        let helper = ScriptedHelperHost()
        await #expect(throws: (any Error).self) {
            _ = try await HostHelperFiles(host: helper).readUsage(timeZone: "UTC'; touch /x; '", claudeLimits: false)
        }
        #expect(await helper.steps.isEmpty)
    }
}
