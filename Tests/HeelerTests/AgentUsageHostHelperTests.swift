import Foundation
import SwiftUI
import Testing
import UIKit
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
        #expect(AgentUsageScope.exclusion(for: store.state) == .needsHostHelper)
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

    @Test func aRecordAndAServiceOnANodeThatHasGoneAskForRepair() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        await helper.seedUsage(try AgentUsageFixture.data(), session: "work")
        await helper.configure {
            $0.recordNodeGone = true
            $0.serviceNodeGone = true
        }
        let (console, host, _) = console(helper, session: "work")
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .hostHelper(.nodeGone))
        #expect(AgentUsageHostHelperNeed.nodeGone.message.contains("Repair"))
        #expect(!AgentUsageHostHelperNeed.nodeGone.message.contains("core"))
        #expect(AgentUsageScope.exclusion(for: store.state) == .repairHostHelper)
    }

    /// Repaired while no core runs: the record is rewritten at the Helper's next
    /// connection, so there is nothing more to repair.
    @Test func aRepairedServiceWaitsForTheCoreToRewriteTheRecord() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        await helper.seedUsage(try AgentUsageFixture.data(), session: "work")
        await helper.configure { $0.recordNodeGone = true }
        let (console, host, _) = console(helper, session: "work")
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        #expect(store.state == .hostHelper(.waitingForCore))
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

        let store = console.hostAccountsStore(for: host.id)
        try await store.load()
        let suggestion = try JSONDecoder().decode(
            AgentUsageReport.AccountSuggestion.self,
            from: Data(#"{"directory":"/home/me/.claude-work","name":"claude-work","source":"agent"}"#.utf8))
        #expect(await store.add(suggestion, for: .claude))

        let written = try #require(await helper.files[Self.accountFile]?.contents)
        let file = try UsageAccountFile.decode(written)
        #expect(file.accounts.map(\.directory) == ["/home/me/.claude-work"])
    }

    @Test func theBrowserAndHomeFolderUseTheHostsServices() async throws {
        let helper = try await helperWithReport()
        let (console, host, _) = console(helper)
        defer { console.setHosts([]) }

        let store = console.hostAccountsStore(for: host.id)
        try await store.load()

        #expect(store.hostHome == ScriptedHelperHost.home)
    }

    // MARK: A core Host whose Console session never connects

    /// How a Console session stays short of connected: a native Windows Host's
    /// locator refuses for good, and a stopped core is retried for as long as it
    /// stays stopped.
    enum SessionOutcome: CaseIterable, Sendable {
        case stoppedCore
        case nativeWindows

        var failure: TransportError {
            switch self {
            case .stoppedCore: .herdrCoreNotRunning(socketPath: "/run/core.sock", socketFilePresent: false)
            case .nativeWindows: .hostFeatureUnavailable(feature: "herdr-core")
            }
        }
    }

    /// A Console running its real core session against a Host whose session
    /// never reaches connected, while `connectCore` still dials for one operation.
    private func unconnectedConsole(
        _ helper: ScriptedHelperHost, session: SessionOutcome = .stoppedCore,
        usageWidgets: AgentUsageWidgetPublisher? = nil,
        host: Host = Host(address: "box.example", username: "dev", serverKind: .herdrCore),
        dial: (@Sendable () throws -> Void)? = nil
    ) async throws -> (ConsoleStore, Host) {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let failure = session.failure
        let console = ConsoleStore(
            usageWidgets: usageWidgets,
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            connectCore: { _ in
                try dial?()
                return core.transport()
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(connect: { throw failure }, keepalive: nil)
            })
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the session has failed") {
            switch console.hostStatuses[host.id] {
            case .failed, .reconnecting: true
            default: false
            }
        }
        return (console, host)
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// What the Usage tab's page says for one Host, with that Host in scope.
    private func pageLabels(_ entry: AgentUsageHostEntry, expecting text: String) async throws -> String {
        let controller = UIHostingController(rootView:
            NavigationStack {
                AgentUsageDashboard(
                    entries: [entry], scopeHostID: .constant(entry.id), metric: .constant(.cost))
            }
            .environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller)
        defer { window.isHidden = true }
        var labels = ""
        for _ in 0..<40 {
            controller.view.layoutIfNeeded()
            labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: ", ")
            if labels.contains(text) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return labels
    }

    @Test(arguments: SessionOutcome.allCases)
    func theUsageTabSaysWhatTheHelperNeedsWithoutAConsoleConnection(session: SessionOutcome) async throws {
        let helper = ScriptedHelperHost()
        if session == .nativeWindows { await helper.configure { $0.platform = .nativeWindows } }
        let (console, host) = try await unconnectedConsole(helper, session: session)
        defer { console.setHosts([]) }

        await console.agentUsageStore(for: host.id).pullToRefresh()

        let entry = console.agentUsageEntry(for: host)
        let scope = AgentUsageScope(readings: [entry.reading])
        let (reason, sentence) = session == .nativeWindows
            ? ("Comes with the Host Helper, not available yet",
               "Usage comes with the Host Helper, which is not available on native Windows yet.")
            : ("Needs the Host Helper", "Usage needs the Host Helper. See this Host's details.")
        #expect(scope.excluded.map(\.reason) == [reason])
        let labels = try await pageLabels(entry, expecting: sentence)
        #expect(labels.contains(sentence), "\(labels)")
        #expect(!labels.contains("Not connected"), "\(labels)")
    }

    @Test func theUsageTabAsksForTheCoreWhileTheHelperWaitsForIt() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        let (console, host) = try await unconnectedConsole(helper)
        defer { console.setHosts([]) }

        await console.agentUsageStore(for: host.id).pullToRefresh()

        let entry = console.agentUsageEntry(for: host)
        #expect(entry.readsOverHostHelper)
        #expect(AgentUsageScope(readings: [entry.reading]).excluded.map(\.reason) == ["Waiting for the core"])
        let sentence = "The Host Helper has not reached this session's core yet. Start the core if it is not running."
        let labels = try await pageLabels(entry, expecting: sentence)
        #expect(labels.contains(sentence), "\(labels)")
    }

    @Test func aReportReadWithoutAConsoleConnectionIsShownInFull() async throws {
        let helper = try await helperWithReport()
        let (console, host) = try await unconnectedConsole(helper)
        defer { console.setHosts([]) }

        await console.agentUsageStore(for: host.id).pullToRefresh()

        let entry = console.agentUsageEntry(for: host)
        #expect(AgentUsageScope(readings: [entry.reading]).included.map(\.name) == [host.displayName])
        // The Limits card reads the same report the totals added up.
        let limits = UIHostingController(rootView: AgentUsageLimitsSheet(entries: [entry])
            .environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: limits)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        limits.view.layoutIfNeeded()
        let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: limits.view).joined(separator: ", ")
        #expect(!labels.contains("Not connected"), "\(labels)")
    }

    @Test func aCoreHostAnsweringItsFirstReadIsLoadingNotDisconnected() async throws {
        let (console, host) = try await unconnectedConsole(ScriptedHelperHost())
        defer { console.setHosts([]) }

        let scope = AgentUsageScope(readings: [console.agentUsageEntry(for: host).reading])

        #expect(scope.loading.map(\.name) == [host.displayName])
        #expect(scope.excluded.isEmpty)
    }

    @Test func aCoreHostItsReadCannotReachReadsAsNotConnected() async throws {
        let (console, host) = try await unconnectedConsole(ScriptedHelperHost()) {
            throw TransportError.sshUnreachable(detail: "no route")
        }
        defer { console.setHosts([]) }

        await console.agentUsageStore(for: host.id).pullToRefresh()

        let scope = AgentUsageScope(readings: [console.agentUsageEntry(for: host).reading])
        #expect(scope.excluded.map(\.exclusion) == [.notConnected])
    }

    @Test func aFailedReadOfAHostThatAnswersIsNotBlamedOnTheConnection() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        await helper.seedUsage(Data("not a report".utf8), session: "default")
        let (console, host) = try await unconnectedConsole(helper)
        defer { console.setHosts([]) }

        let store = console.agentUsageStore(for: host.id)
        await store.pullToRefresh()

        let scope = AgentUsageScope(readings: [console.agentUsageEntry(for: host).reading])
        #expect(scope.excluded.map(\.reason) == ["Could not read Usage"])
        // This Server Kind has no plugin to update.
        #expect(store.state == .failed(AgentUsageStore.helperFailureMessage))
        #expect(AgentUsageStore.helperFailureMessage.contains("Host Helper"))
        #expect(!AgentUsageStore.helperFailureMessage.contains("plugin"))
    }

    @Test func aHelperReadThatFailsOnTheWayToTheHostStillBlamesTheConnection() async throws {
        struct Unreachable: HostHelperHost {
            func hostPlatform() async throws -> HostPlatform { .posix }
            func runHostHelperScript(_ script: HostHelperScript) async throws -> GitExecResult {
                throw TransportError.sshUnreachable(detail: "no route")
            }
            func readHostHelperFile(at path: String, privateDirectory: String) async throws -> Data? { nil }
            func replaceHostHelperFile(_ contents: Data, at path: String, privateDirectory: String?) async throws {}
        }
        await #expect(throws: TransportError.self) {
            _ = try await AgentUsageStore.reading(
                overHelper: Unreachable(), session: "work", timeZone: "UTC", claudeLimits: false)
        }
    }

    @Test func aHostHelperNeedDoesNotPromiseAnInstallEveryHostCanTake() {
        #expect(!AgentUsageHostHelperNeed.notInstalled.message.contains("Install"))
    }

    @Test func aHerdrTUIHostWithoutAConnectionStillReadsAsNotConnected() async throws {
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrTUI)
        let console = ConsoleStore(makeSession: { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "no route") },
                keepalive: nil)
        })
        console.setHosts([host])
        defer { console.setHosts([]) }

        #expect(AgentUsageScope(readings: [console.agentUsageEntry(for: host).reading]).excluded.map(\.reason)
            == ["Not connected"])
        await console.agentUsageStore(for: host.id).pullToRefresh()
        #expect(AgentUsageScope(readings: [console.agentUsageEntry(for: host).reading]).excluded.map(\.reason)
            == ["Not connected"])
    }

    @Test func theWidgetSaysTheSameAsTheTabWithoutAConsoleConnection() async throws {
        let widgets = try WidgetFile(installed: [])
        defer { widgets.remove() }
        let (console, host) = try await unconnectedConsole(ScriptedHelperHost(), usageWidgets: widgets.publisher())
        defer { console.setHosts([]) }

        await console.agentUsageStore(for: host.id).pullToRefresh()

        #expect(widgets.reasons == [.needsHostHelper])
    }

    // MARK: The widget, with no one opening Usage

    /// The widgets' snapshot on disk. Each `publisher()` starts from the file, as
    /// the app does on launch.
    private struct WidgetFile {
        let installed: Set<String>
        private let directory: URL
        private let store: UsageWidgetSnapshotStore

        init(installed: Set<String> = [UsageWidgetSnapshotStore.usageKind]) throws {
            self.installed = installed
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = UsageWidgetSnapshotStore(containerURL: directory)
        }

        @MainActor func publisher(installed: Set<String>? = nil) -> AgentUsageWidgetPublisher {
            let kinds = installed ?? self.installed
            return AgentUsageWidgetPublisher(store: store, reloadTimelines: {}, installedKinds: { kinds })
        }

        var snapshot: UsageWidgetSnapshot? { store.read() }
        var reasons: [AgentUsageExclusion?]? { snapshot?.hosts.map(\.excludedReason) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test(arguments: SessionOutcome.allCases)
    func theWidgetSaysWhatTheHelperNeedsWithoutOpeningUsage(session: SessionOutcome) async throws {
        let helper = ScriptedHelperHost()
        if session == .nativeWindows { await helper.configure { $0.platform = .nativeWindows } }
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let (console, _) = try await unconnectedConsole(helper, session: session, usageWidgets: widgets.publisher())
        defer { console.setHosts([]) }

        let reason: AgentUsageExclusion = session == .nativeWindows ? .hostHelperNotOnWindows : .needsHostHelper
        try await waitUntil("the widget says why") { widgets.reasons == [reason] }
    }

    @Test func theWidgetShowsTheHelpersReportWithoutOpeningUsage() async throws {
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let (console, _) = try await unconnectedConsole(
            try await helperWithReport(), usageWidgets: widgets.publisher())
        defer { console.setHosts([]) }

        try await waitUntil("the widget has the figures") { widgets.snapshot?.hosts.first?.reports == true }
    }

    @Test func theWidgetPicksUpACoreThatStartsLater() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let (console, _) = try await unconnectedConsole(helper, usageWidgets: widgets.publisher())
        defer { console.setHosts([]) }
        try await waitUntil("the widget waits") { widgets.reasons == [.waitingForCore] }

        await helper.seedUsage(try AgentUsageFixture.reportData(refreshing: false), session: "default")

        try await waitUntil("the widget has the figures") { widgets.snapshot?.hosts.first?.reports == true }
    }

    @Test func theWidgetReadsNotConnectedWhenSSHCannotReachTheHost() async throws {
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let (console, _) = try await unconnectedConsole(ScriptedHelperHost(), usageWidgets: widgets.publisher()) {
            throw TransportError.sshUnreachable(detail: "no route")
        }
        defer { console.setHosts([]) }

        try await waitUntil("the widget says not connected") { widgets.reasons == [.notConnected] }
    }

    @Test func aLaunchKeepsTheReasonTheBackgroundRefreshWrote() async throws {
        let widgets = try WidgetFile(installed: [])
        defer { widgets.remove() }
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        await AgentUsageBackgroundRefresh(read: { _, _ in .hostHelper(.notOnWindows) })
            .run(hosts: [host], publisher: widgets.publisher(), isUsageEnabled: { true })
        let reason = AgentUsageExclusion.hostHelperNotOnWindows
        #expect(widgets.reasons == [reason])

        // The next launch: nothing read yet, and no widget to read it for.
        let (console, _) = try await unconnectedConsole(
            ScriptedHelperHost(), usageWidgets: widgets.publisher(), host: host)
        defer { console.setHosts([]) }

        #expect(widgets.reasons == [reason])
    }

    @Test func aCoreHostIsDialedForTheWidgetOnceAnInterval() async throws {
        let helper = ScriptedHelperHost()
        await helper.configure { $0.platform = .nativeWindows }
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let dials = OSAllocatedUnfairLock(initialState: 0)
        let (console, _) = try await unconnectedConsole(helper, session: .nativeWindows, usageWidgets: widgets.publisher()) {
            dials.withLock { $0 += 1 }
        }
        defer { console.setHosts([]) }
        try await waitUntil("the widget says why") { (widgets.reasons?.first ?? nil) == .hostHelperNotOnWindows }

        await console.reactivate()
        try await Task.sleep(for: .milliseconds(200))

        #expect(dials.withLock { $0 } == 1)
    }

    @Test func aCoreHostAddedWhileTheAppIsOpenIsReadForTheWidget() async throws {
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let (console, host) = try await unconnectedConsole(ScriptedHelperHost(), usageWidgets: widgets.publisher())
        defer { console.setHosts([]) }
        try await waitUntil("the first Host is read") { widgets.reasons == [.needsHostHelper] }

        console.setHosts([host, Host(address: "other.example", username: "dev", serverKind: .herdrCore)])

        try await waitUntil("the added Host is read") {
            widgets.reasons == [.needsHostHelper, .needsHostHelper]
        }
    }

    @Test func leavingTheAppStopsDialingForAWaitingCore() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        let widgets = try WidgetFile()
        defer { widgets.remove() }
        let dials = OSAllocatedUnfairLock(initialState: 0)
        let (console, _) = try await unconnectedConsole(helper, usageWidgets: widgets.publisher()) {
            dials.withLock { $0 += 1 }
        }
        defer { console.setHosts([]) }
        try await waitUntil("the widget waits") { widgets.reasons == [.waitingForCore] }

        await console.suspend()
        let atSuspend = dials.withLock { $0 }
        // Past the first re-read's 3 seconds.
        try await Task.sleep(for: .seconds(3.5))

        #expect(dials.withLock { $0 } == atSuspend)
    }

    @Test func withoutAUsageWidgetACoreHostIsNotDialed() async throws {
        let widgets = try WidgetFile(installed: [])
        defer { widgets.remove() }
        let dials = OSAllocatedUnfairLock(initialState: 0)
        let (console, _) = try await unconnectedConsole(ScriptedHelperHost(), usageWidgets: widgets.publisher()) {
            dials.withLock { $0 += 1 }
        }
        defer { console.setHosts([]) }

        await console.reactivate()
        try await Task.sleep(for: .milliseconds(200))

        #expect(dials.withLock { $0 } == 0)
        #expect(widgets.reasons == [.notReadYet])
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
        #expect(throws: AgentUsageHostHelperNeed.nodeGone) {
            try AgentUsageProbe.parseHelper(stdout: answer("helper-node-gone"), nonce: "n")
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
