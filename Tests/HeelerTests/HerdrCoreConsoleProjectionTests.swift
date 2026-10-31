import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// A core Host's Terminals in the Console, through `ConsoleStore`, replaying the
/// shared vectors captured from a fixture core wherever they have the case.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreConsoleProjectionTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func record(
        _ address: String, cwd: String = "/work/app", name: String? = nil, state: String = "live",
        pid: Int? = 7, reason: String? = nil, keep: Bool = false, title: String = ""
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string(state),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(keep), "title": .string(title),
            "cols": .number(80), "rows": .number(24),
            "name": name.map(JSONValue.string) ?? .null,
            "pid": pid.map { .number(Double($0)) } ?? .null,
            "reason": reason.map(JSONValue.string) ?? .null,
        ])
    }

    private static func subscribeResult(sequence: Int = 1, _ terminals: [JSONValue]) -> JSONValue {
        .object([
            "seq": .number(Double(sequence)), "terminals": .array(terminals), "channel": .number(1),
        ])
    }

    private static func event(
        sequence: Int, type: String, terminal: String, data: JSONValue
    ) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private func makeStore(
        _ transport: ScriptedCoreTransport, memory: HerdrCoreHostMemory = HerdrCoreHostMemory()
    ) -> ConsoleStore {
        ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(connect: { transport }, keepalive: nil)
            },
            coreHostMemory: memory)
    }

    private func started(
        _ transport: ScriptedCoreTransport, memory: HerdrCoreHostMemory = HerdrCoreHostMemory()
    ) async throws -> ConsoleStore {
        let store = makeStore(transport, memory: memory)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return store
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

    private func row(_ store: ConsoleStore, _ address: String) -> ConsoleTerminal? {
        store.terminals.first { $0.paneID == address }
    }

    private func projection(_ store: ConsoleStore) -> TerminalListProjection {
        TerminalListPresentationStore(defaults: UserDefaults(suiteName: "core-\(UUID())") ?? .standard)
            .projection(hosts: [host], console: store)
    }

    // MARK: The inventory

    @Test func theSnapshotFillsTheListWithOneWorkspacePerDirectoryAndOneTabPerTerminal() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", cwd: "/work/app", name: "server"),
                Self.record("t2", cwd: "/work/docs"),
                Self.record("t3", cwd: "/other/app"),
                Self.record("t5", cwd: "/work/app"),
            ])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }

        let cards = projection(store).workspaces()
        #expect(cards.map(\.title) == ["app", "docs", "app"])
        #expect(cards.map { $0.terminals.map(\.paneID) } == [["t1", "t5"], ["t2"], ["t3"]])
        // Every Terminal is its own Tab, and shows as a Terminal.
        #expect(Set(store.terminals.map(\.tabID)).count == 4)
        #expect(store.terminals.allSatisfy { !$0.isAgent })
        #expect(store.agents.isEmpty)
        #expect(row(store, "t1")?.displayTabTitle == "Tab 1")
        #expect(row(store, "t5")?.displayTabTitle == "Tab 2")
        #expect(row(store, "t1")?.displayTitle == "server")
        #expect(row(store, "t2")?.displayTitle == "zsh")
        // Opaque: nothing of the directory shows in the id.
        #expect(cards.allSatisfy { !$0.workspaceID.contains("work") })
        #expect(store.hostStatuses[host.id] == .connected)
    }

    @Test func aCapturedLogUpdatesRowsWithoutAskingTheCoreAgain() async throws {
        let vectors = HerdrCoreVectorFile.shared
        let transport = ScriptedCoreTransport(subscribeResults: [
            try vectors.exchange("events-subscribe").result
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        // The capture's t2 had already finished when it subscribed.
        #expect(store.terminals.map(\.paneID) == ["t1"])
        let loggedAt = "/home/user"

        await transport.deliver(try vectors.event("created"))
        try await waitUntil("t3 listed") { row(store, "t3") != nil }
        #expect(row(store, "t3")?.paneLabel == "review")
        #expect(row(store, "t3")?.cwd == loggedAt)

        await transport.deliver(try vectors.event("size"))
        try await waitUntil("t3's size") { row(store, "t3")?.gridColumns == 100 }
        #expect(row(store, "t3")?.gridRows == 30)

        await transport.deliver(try vectors.event("title"))
        try await waitUntil("t3's title") { row(store, "t3")?.title == "Working" }

        // A report from a program that does not hold the foreground, and kinds
        // the Console has no use for yet, change no row and stop nothing.
        await transport.deliver(try vectors.event("status"))
        await transport.deliver(try vectors.event("turn"))
        await transport.deliver(try vectors.event("labels"))
        await transport.deliver(try vectors.event("doc"))

        await transport.deliver(try vectors.event("foreground"))
        try await waitUntil("t3's foreground") { row(store, "t3")?.pane.foregroundCwd == loggedAt }
        #expect(row(store, "t3")?.pane.title == "zsh")

        #expect(await transport.subscribeCount == 1)
    }

    @Test func anotherMachinesTerminalNeverAppears() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("peer/t1"), Self.record("t1")])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(store.terminals.map(\.paneID) == ["t1"])

        await transport.deliver(
            Self.event(sequence: 2, type: "created", terminal: "peer/t2", data: Self.record("peer/t2")))
        await transport.deliver(
            Self.event(sequence: 3, type: "created", terminal: "t2", data: Self.record("t2")))
        try await waitUntil("t2 listed") { row(store, "t2") != nil }
        #expect(store.terminals.map(\.paneID) == ["t1", "t2"])
    }

    @Test func missedReplacesTheInventoryWholesale() async throws {
        let vectors = HerdrCoreVectorFile.shared
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("gone", cwd: "/work/gone")])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(row(store, "gone") != nil)

        let line = try vectors.event("missed")
        await transport.deliver(line)
        try await waitUntil("the old Terminal gone") { row(store, "gone") == nil }

        let envelope = try JSONDecoder().decode(JSONValue.self, from: line)
        let captured = try HerdrCoreSnapshot(result: envelope["params"] ?? .null)
        #expect(
            Set(store.terminals.map(\.paneID))
                == Set(captured.terminals.filter { !$0.hasFinished }.map(\.address)))
        #expect(!store.terminals.isEmpty)
        // Older events still on the way do not reapply over it.
        await transport.deliver(
            Self.event(sequence: 2, type: "created", terminal: "late", data: Self.record("late")))
        await transport.deliver(
            Self.event(
                sequence: captured.sequence + 1, type: "created", terminal: "next", data: Self.record("next")))
        try await waitUntil("the newer event") { row(store, "next") != nil }
        #expect(row(store, "late") == nil)
        #expect(await transport.subscribeCount == 1)
    }

    @Test func betweenConnectedAndTheFirstSnapshotTheHostReadsAsLoading() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1")])
        ])
        await transport.holdSubscribes()
        let store = makeStore(transport)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await transport.waitForSubscribe(count: 1)
        try await waitUntil("Connected") { store.hostStatuses[host.id] == .connected }

        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        let issues = projection(store).issues()
        #expect(issues.map(\.status) == ["Loading Terminals…"])
        #expect(issues.first?.message == "Loading Terminals from \(host.displayName)…")

        await transport.releaseSubscribes()
        try await waitUntil("the snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        #expect(projection(store).issues().isEmpty)
        #expect(store.terminals.map(\.paneID) == ["t1"])
    }

    @Test func anEventKindThisAppDoesNotKnowTakesAFreshSnapshot() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1")]),
            Self.subscribeResult(sequence: 9, [Self.record("t2")]),
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.deliver(Self.event(sequence: 2, type: "brand-new", terminal: "t1", data: .object([:])))
        await transport.waitForSubscribe(count: 2)
        try await waitUntil("the fresh snapshot") { row(store, "t2") != nil }
        #expect(store.terminals.map(\.paneID) == ["t2"])
        #expect(store.hostStatuses[host.id] == .connected)
    }

    // MARK: Lost, finished and kept Terminals

    @Test func lostShowsRestartingWithItsForegroundCleared() async throws {
        let vectors = HerdrCoreVectorFile.shared
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t3", cwd: "/home/user/project", keep: true)])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        await transport.deliver(
            Self.event(
                sequence: 2, type: "foreground", terminal: "t3",
                data: .object([
                    "pid": .number(9), "name": .string("vim"), "argv": .array([.string("vim")]),
                    "cwd": .string("/elsewhere"),
                ])))
        try await waitUntil("the foreground") { row(store, "t3")?.pane.title == "vim" }
        #expect(row(store, "t3")?.cwd == "/elsewhere")
        #expect(row(store, "t3")?.isRestarting == false)

        await transport.deliver(try vectors.event("lost"))
        try await waitUntil("restarting") { row(store, "t3")?.isRestarting == true }
        #expect(row(store, "t3")?.pane.foregroundCwd == nil)
        #expect(row(store, "t3")?.pane.title == "zsh")
        #expect(row(store, "t3")?.cwd == "/home/user/project")
        let terminal = try #require(row(store, "t3"))
        #expect(TerminalRowPresentation(terminal: terminal).subtitle == "Restarting · /home/user/project")
    }

    @Test func aSnapshotShowsATerminalAlreadyRestarting() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", pid: nil, reason: "holder_lost", keep: true),
                Self.record("t2", pid: nil, reason: "spawn_pending", keep: true),
                Self.record("t3"),
            ])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(row(store, "t1")?.isRestarting == true)
        #expect(row(store, "t2")?.isRestarting == false)
        #expect(row(store, "t3")?.isRestarting == false)
    }

    @Test func finishedTakesATerminalOutOfTheConsole() async throws {
        let vectors = HerdrCoreVectorFile.shared
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t4", cwd: "/work/one"), Self.record("t5", cwd: "/work/two")])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.deliver(try vectors.event("finished"))
        try await waitUntil("t4 gone") { row(store, "t4") == nil }
        #expect(store.terminals.map(\.paneID) == ["t5"])
        // Its Workspace went with it: nothing else was first seen there.
        #expect(store.workspacesByHost[host.id]?.map(\.label) == ["two"])
    }

    @Test func aFinishedRecordInASnapshotIsNotListed() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", state: "finished", pid: nil, reason: "exited"), Self.record("t2"),
            ])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(store.terminals.map(\.paneID) == ["t2"])
    }

    @Test func aKeptTerminalThatRestartsElsewhereStaysInItsWorkspaceWithItsID() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t3", cwd: "/work/app", keep: true), Self.record("t1", cwd: "/work/docs"),
            ])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        let before = try #require(row(store, "t3"))

        await transport.deliver(
            Self.event(
                sequence: 2, type: "restarted", terminal: "t3",
                data: Self.record("t3", cwd: "/somewhere/else", pid: 99, keep: true)))
        try await waitUntil("the new directory") { row(store, "t3")?.cwd == "/somewhere/else" }

        let after = try #require(row(store, "t3"))
        #expect(after.id == before.id)
        #expect(after.workspaceID == before.workspaceID)
        #expect(after.tabID == before.tabID)
        #expect(after.workspaceLabel == "app")
        #expect(after.isRestarting == false)
    }

    // MARK: Host memory

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "core-host-memory-\(UUID().uuidString)"))
    }

    @Test func firstSeenDirectoriesAndTheCoreIDSurviveARelaunch() async throws {
        let defaults = try suite()
        let first = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([Self.record("t3", cwd: "/work/app", keep: true)])
        ])
        let store = try await started(first, memory: HerdrCoreHostMemory(defaults: defaults))
        let id = try #require(row(store, "t3")).workspaceID
        await store.suspend()
        store.setHosts([host])

        // A new process, the Terminal having moved while the app was away.
        let memory = HerdrCoreHostMemory(defaults: defaults)
        #expect(memory.coreID(for: host.id) == "c1")
        #expect(memory.firstSeenDirectories(for: host.id) == ["t3": "/work/app"])
        let second = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([Self.record("t3", cwd: "/somewhere/else", keep: true)])
        ])
        let relaunched = try await started(second, memory: memory)
        defer { relaunched.setHosts([]) }
        #expect(row(relaunched, "t3")?.workspaceID == id)
        #expect(row(relaunched, "t3")?.workspaceLabel == "app")
    }

    @Test func removingTheHostForgetsItAcrossARelaunch() async throws {
        let defaults = try suite()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", cwd: "/work/app")])
        ])
        let store = try await started(transport, memory: HerdrCoreHostMemory(defaults: defaults))

        store.setHosts([])

        let memory = HerdrCoreHostMemory(defaults: defaults)
        #expect(memory.coreID(for: host.id) == nil)
        #expect(memory.firstSeenDirectories(for: host.id).isEmpty)
    }

    @Test func anotherCoreIDForgetsTheOldCoresDirectories() async throws {
        let defaults = try suite()
        let first = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([Self.record("t1", cwd: "/work/old")])
        ])
        let store = try await started(first, memory: HerdrCoreHostMemory(defaults: defaults))
        await store.suspend()

        let memory = HerdrCoreHostMemory(defaults: defaults)
        let second = ScriptedCoreTransport(coreID: "c2", subscribeResults: [
            Self.subscribeResult([Self.record("t1", cwd: "/work/new")])
        ])
        let replaced = try await started(second, memory: memory)
        defer { replaced.setHosts([]) }

        #expect(row(replaced, "t1")?.workspaceLabel == "new")
        #expect(memory.coreID(for: host.id) == "c2")
        #expect(memory.firstSeenDirectories(for: host.id) == ["t1": "/work/new"])
    }

    @Test func aRemovedTerminalsAddressStartsAgain() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", cwd: "/work/old")])
        ])
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.deliver(Self.event(sequence: 2, type: "removed", terminal: "t1", data: .object([:])))
        try await waitUntil("t1 gone") { row(store, "t1") == nil }
        await transport.deliver(
            Self.event(sequence: 3, type: "created", terminal: "t1", data: Self.record("t1", cwd: "/work/new")))
        try await waitUntil("t1 back") { row(store, "t1") != nil }
        #expect(row(store, "t1")?.workspaceLabel == "new")
    }

    // MARK: Connection

    @Test func theHostReadsDisconnectedWithoutTerminalsWhenTheConnectionFails() async throws {
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: { throw TransportError.herdrCoreNotInstalled }, keepalive: nil)
            })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the failure") {
            store.hostStatuses[host.id] == .failed(.herdrCoreNotInstalled)
        }
        #expect(store.hostStandingFailures[host.id] == .herdrCoreNotInstalled)
        #expect(store.terminals.isEmpty)
    }

    @Test func theHostFilterShowsACoreHostsTerminalsBesideAHerdrTUIHosts() async throws {
        let tui = Host.fixture()
        let core = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", cwd: "/work/app")])
        ])
        let herdr = ScriptedTransport(
            snapshot: SessionSnapshot(
                agents: [], layouts: [],
                panes: [
                    PaneInfo(
                        agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
                        tabID: "w1:t1", terminalID: "term", workspaceID: "w1", cwd: "/tui")
                ],
                protocolVersion: 17, tabs: [], version: "0.7.5-fake",
                workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { herdr }, keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { core }, keepalive: nil) })
        defer { store.setHosts([]) }
        store.setHosts([host, tui])
        await store.resume()
        try await waitUntil("both Hosts listed") { store.terminals.count == 2 }

        let catalog = HostStore(volatileHosts: [host, tui])
        #expect(catalog.consoleHosts == [host, tui])
        let list = TerminalListPresentationStore(
            defaults: UserDefaults(suiteName: "core-\(UUID())") ?? .standard
        ).projection(hosts: catalog.consoleHosts, console: store)
        #expect(list.workspaces().count == 2)
        #expect(list.workspaces(filteredHostID: host.id).flatMap(\.terminals).map(\.paneID) == ["t1"])
        #expect(list.workspaces(filteredHostID: tui.id).flatMap(\.terminals).map(\.paneID) == ["w1:p1"])
    }

    @Test func aCoreHostLendsNoNotificationTransport() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [Self.subscribeResult([])])
        let store = try await started(transport)
        defer { store.setHosts([]) }
        await #expect(throws: HeelerPluginUnavailableError.self) {
            try await store.withNotificationTransport(for: host.id) { _ in }
        }
    }
}

extension HeelerPluginUnavailableError: Equatable {}

/// The list and the pickers around a core Host, whatever else it can do.
@MainActor
@Suite struct HerdrCoreCapabilityOfferTests {
    private let core = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
    private let tui = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)

    @Test func theNewButtonsOfferEveryKindOfHost() {
        #expect([core, tui].offeringNewItem(listsTerminals: true) == [core, tui])
        #expect([core, tui].offeringNewItem(listsTerminals: false) == [core, tui])
    }

    @Test func anEmptyDetailOffersNothingEveryHostCannotStart() {
        let offered = ConsoleEmptyDetailPresentation(hasHosts: true, listsTerminals: true)
        #expect(offered.actions.contains(.newAgent))
        let notOffered = ConsoleEmptyDetailPresentation(
            hasHosts: true, listsTerminals: true, offersNewItem: false)
        #expect(!notOffered.actions.contains(.newAgent))
        #expect(notOffered.message == "Choose a terminal.")
    }

    @Test func aListOffersNewOnEveryKindOfHost() {
        for listsTerminals in [false, true] {
            #expect([Host]().offersNewItem(listsTerminals: listsTerminals))
            #expect([tui].offersNewItem(listsTerminals: listsTerminals))
            #expect([core, tui].offersNewItem(listsTerminals: listsTerminals))
            #expect([core].offersNewItem(listsTerminals: listsTerminals))
        }
    }

    @Test func theNewCommandNeitherEnablesNorRunsWhenNotOffered() {
        var started = 0
        func commands(offersNewItem: Bool) -> ConsoleCommandTarget {
            ConsoleCommandTarget(
                registry: ConsoleCommandRegistry(),
                context: {
                    .init(
                        selection: nil, agents: [], isSearchFocused: false, isCovered: false,
                        inputMode: .composer, offersNewItem: offersNewItem)
                },
                navigate: { _ in }, focusSearch: {}, newAgent: { started += 1 }, settings: {},
                hosts: {}, closeAgent: {})
        }
        let notOffered = commands(offersNewItem: false)
        #expect(!notOffered.allows(.newAgent))
        notOffered.perform(.newAgent)
        #expect(started == 0)
        for action: ConsoleCommandAction in [.focusSearch, .settings, .hosts] {
            #expect(notOffered.allows(action))
        }
        let offered = commands(offersNewItem: true)
        #expect(offered.allows(.newAgent))
        offered.perform(.newAgent)
        #expect(started == 1)
    }

    /// The File menu and ⌘N read this target, so a mounted Console is what
    /// decides whether New Agent or New Terminal is enabled.
    @Test(arguments: [(ServerKind.herdrCore, true), (ServerKind.herdrTUI, true)])
    func aMountedConsoleOffersTheNewCommandByItsHosts(
        kind: ServerKind, enabled: Bool
    ) async throws {
        let composition = DemoScreenshotComposition.make()
        let catalog = HostStore(
            volatileHosts: [Host(address: "box.example", username: "dev", serverKind: kind)])
        let probe = ConsoleCommandTargetProbe()
        let view = ConsoleView(
            hosts: catalog, console: composition.console,
            terminal: TerminalSettings(
                themes: composition.terminalThemes, zoom: composition.terminalZoom,
                fonts: composition.terminalFonts, snippets: composition.snippets),
            inputMode: composition.inputMode, detailSurface: composition.detailSurface,
            appearance: composition.appearance,
            pushRegistration: composition.pushRegistration,
            notificationPreferences: composition.notificationPreferences,
            relaySettings: composition.relaySettings,
            notificationRouter: composition.notificationRouter,
            bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
            activity: composition.activity)
        let controller = UIHostingController(
            rootView: ZStack { view; ConsoleCommandTargetProbeView(probe: probe) })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        defer { window.isHidden = true }
        let deadline = ContinuousClock.now + .seconds(5)
        while probe.target == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }
        let target = try #require(probe.target)
        #expect(target.allows(.newAgent) == enabled)
    }
}

@MainActor
private final class ConsoleCommandTargetProbe {
    var target: ConsoleCommandTarget?
}

/// Reads the target the way `ConsoleCommands` does, beside the Console.
private struct ConsoleCommandTargetProbeView: View {
    let probe: ConsoleCommandTargetProbe
    @FocusedValue(\.consoleCommandTarget) private var target

    var body: some View {
        let _ = probe.target = target
        Color.clear.allowsHitTesting(false)
    }
}
