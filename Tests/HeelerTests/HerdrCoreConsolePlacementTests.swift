import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Desktop spaces and tabs in the Console, through `ConsoleStore` over the
/// scripted core transport. Placement follows `doc` and `labels` events without
/// a re-list, and nothing here may write the desktop app's document: the
/// transport fails any test that does.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreConsolePlacementTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func desktop(_ space: String, _ tab: String? = nil) -> [String: String] {
        var labels = ["herdr.space": space]
        if let tab { labels["herdr.tab"] = tab }
        return labels
    }

    private static func record(
        _ address: String, cwd: String = "/work/app", labels: [String: String] = [:],
        parent: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "cols": .number(80), "rows": .number(24),
            "pid": .number(7), "labels": .object(labels.mapValues(JSONValue.string)),
        ]
        if let parent { fields["parent"] = .string(parent) }
        return .object(fields)
    }

    private static func agentRecord(
        _ address: String, cwd: String, labels: [String: String] = [:]
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "cols": .number(80), "rows": .number(24),
            "pid": .number(7), "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": .object([
                "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
                "cwd": .string(cwd),
            ]),
            "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        ])
    }

    private static func subscribeResult(sequence: Int = 1, _ terminals: [JSONValue]) -> JSONValue {
        .object([
            "seq": .number(Double(sequence)), "terminals": .array(terminals), "channel": .number(1),
        ])
    }

    private static func line(_ method: String, _ params: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": params,
        ]))) ?? Data()
    }

    private static func labelsEvent(
        sequence: Int, _ terminal: String, _ labels: [String: String]
    ) -> Data {
        line(
            "event",
            .object([
                "seq": .number(Double(sequence)), "type": .string("labels"),
                "terminal": .string(terminal),
                "data": .object(["labels": .object(labels.mapValues(JSONValue.string))]),
            ]))
    }

    private static func documentEvent(
        sequence: Int, name: String = "herdr-app", version: Int, machine: String? = nil
    ) -> Data {
        var params: [String: JSONValue] = [
            "seq": .number(Double(sequence)), "type": .string("doc"),
            "data": .object(["name": .string(name), "version": .number(Double(version))]),
        ]
        if let machine { params["machine"] = .string(machine) }
        return line("event", .object(params))
    }

    private static func createdEvent(sequence: Int, _ record: JSONValue) -> Data {
        line(
            "event",
            .object([
                "seq": .number(Double(sequence)), "type": .string("created"),
                "terminal": record["address"] ?? .null, "data": record,
            ]))
    }

    private static let twoSpaces = CoreDesktopJSON.document([
        CoreDesktopJSON.space("s2", name: "Zeta", tabs: [CoreDesktopJSON.tab("tb2", name: "logs")]),
        CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")]),
    ])

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

    private func started(_ transport: ScriptedCoreTransport) async throws -> ConsoleStore {
        let store = makeStore(transport)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return store
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Each card's title and its rows' addresses, as the Terminals tab lists them.
    private func cards(_ store: ConsoleStore) -> [String] {
        TerminalListPresentationStore(defaults: UserDefaults(suiteName: "core-\(UUID())") ?? .standard)
            .projection(hosts: [host], console: store).workspaces()
            .map { "\($0.title): \($0.terminals.map(\.paneID).joined(separator: " "))" }
    }

    private func row(_ store: ConsoleStore, _ address: String) -> ConsoleTerminal? {
        store.terminals.first { $0.paneID == address }
    }

    // MARK: The document

    private final class AmuxFixtureBundle {}

    private func amuxFixture() throws -> JSONValue {
        let url = try #require(Bundle(for: AmuxFixtureBundle.self).url(
            forResource: "amux-organization-v1", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    @Test func amuxMembershipAndEmptyWorktreesAreBrowsableWithoutAdoptingCwdOrParentHints() async throws {
        let fixture = try amuxFixture()
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [
            Self.subscribeResult([
                Self.record("t9", cwd: "/elsewhere"),
                Self.record("t8", cwd: "/srv/service-fix", parent: "t3"),
                Self.record("t3", cwd: "/also-elsewhere"),
            ])
        ])
        await transport.setDocument(try #require(fixture["value"]), version: 7, name: "amux-organization")
        let store = try await started(transport)
        #expect(cards(store) == ["Service / main: ", "Service / Fix reconnect: t3 t9", "service-fix: t8"])
        #expect(row(store, "t3")?.tabLabel == "Review")
        #expect(row(store, "t9")?.tabID == row(store, "t3")?.tabID)
        #expect(row(store, "t8")?.workspaceID != row(store, "t3")?.workspaceID)
        await store.suspend()
    }

    @Test func amuxLaunchUsesTheSelectedHostPathAndLeavesShellAndAgentUnassigned() async throws {
        let fixture = try amuxFixture()
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [Self.subscribeResult([])])
        await transport.setDocument(try #require(fixture["value"]), version: 7, name: "amux-organization")
        await transport.setShell("/bin/zsh")
        let store = try await started(transport)
        defer { store.setHosts([]) }
        let main = try #require(store.workspaces(for: host.id).first { $0.label == "Service / main" })
        let fix = try #require(store.workspaces(for: host.id).first { $0.label == "Service / Fix reconnect" })
        let shell = try await store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: main.id, cwd: "/wrong-phone-directory"), on: host.id)
        let agent = try await store.startAgent(
            AgentLaunchRequest(kind: "pi", name: "phone-pi", workspaceID: fix.id, cwd: "/wrong-agent-directory"),
            on: host.id)
        #expect(row(store, shell.paneID)?.cwd == "/srv/service")
        #expect(row(store, agent.paneID)?.cwd == "/srv/service-fix")
        #expect(row(store, shell.paneID)?.workspaceID != main.id)
        #expect(row(store, agent.paneID)?.workspaceID != fix.id)
        let runs = await transport.runs
        #expect(runs.map { $0["cwd"] } == [.string("/srv/service"), .string("/srv/service-fix")])
        #expect(runs.first?["labels"] == nil)
        #expect(runs.last?["labels"]?["herdr.space"] == nil)
        #expect(runs.last?["labels"]?["herdr.tab"] == nil)

        // An independent writer can later place the shell; cwd alone did not.
        let json = String(decoding: try JSONEncoder().encode(try #require(fixture["value"])), as: UTF8.self)
        let members = String(decoding: try JSONEncoder().encode([shell.paneID]), as: UTF8.self)
        let placed = json.replacingOccurrences(
            of: "\"tabs\":[]", with: "\"tabs\":[{\"id\":\"tab-phone\",\"name\":\"Phone\",\"terminals\":\(members)}]")
        await transport.setDocument(
            try JSONDecoder().decode(JSONValue.self, from: Data(placed.utf8)), version: 8, name: "amux-organization")
        await transport.deliver(Self.documentEvent(sequence: 2, name: "amux-organization", version: 8))
        try await waitUntil("explicit placement from another client") { row(store, shell.paneID)?.workspaceID == main.id }
        #expect(row(store, shell.paneID)?.tabLabel == "Phone")
        #expect(row(store, agent.paneID)?.workspaceID != fix.id)
        #expect(await transport.documentWrites.isEmpty)
        #expect(await transport.labelWrites.isEmpty)
        #expect(await transport.desktopAppRenames.isEmpty)
    }

    @Test(arguments: ["/srv/a project's/代码", "C:\\dev\\service"])
    func amuxSpaceLaunchPreservesAbsoluteHostPathsAndIgnoresUnknownFields(_ path: String) async throws {
        let value = JSONValue.object([
            "schemaVersion": .number(1), "coreID": .string("core-a"), "future": .object(["retain": .bool(true)]),
            "spaces": .array([.object([
                "id": .string("space-a"), "name": .string("Empty repository"), "path": .string(path),
                "worktrees": .array([]),
            ])]),
        ])
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [Self.subscribeResult([])])
        await transport.setDocument(value, version: 42, name: "amux-organization")
        let store = try await started(transport)
        defer { store.setHosts([]) }
        let organization = try #require(store.amuxOrganizations[host.id])
        let space = try #require(organization.spaces.first)
        let shell = try await store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: space.workspaceID(coreID: "core-a"), cwd: "/wrong"), on: host.id)
        #expect(row(store, shell.paneID)?.cwd == path)
        #expect(await transport.runs.first?["cwd"] == .string(path))
        #expect(await transport.runs.first?["labels"] == nil)
        #expect(await transport.documentWrites.isEmpty)
    }

    @Test(arguments: [
        "schema", "core", "relative", "duplicate-space", "duplicate-worktree", "duplicate-tab",
        "duplicate-terminal", "relayed", "empty-id", "non-string-name", "oversized", "missing", "null",
    ])
    func invalidAmuxMetadataNeverBlocksOrdinaryDiscovery(_ fault: String) async throws {
        let fixture = try amuxFixture()
        let value = try #require(fixture["value"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        let changed: String
        switch fault {
        case "schema": changed = json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        case "core": changed = json.replacingOccurrences(of: "core-a", with: "core-b")
        case "relative": changed = json.replacingOccurrences(of: "/srv/service", with: "srv/service")
        case "duplicate-space": changed = json.replacingOccurrences(
            of: "\"spaces\":[", with: "\"spaces\":[{\"id\":\"space-1\",\"name\":\"Other\",\"path\":\"/other\",\"worktrees\":[]},")
        case "duplicate-worktree": changed = json.replacingOccurrences(of: "worktree-fix", with: "worktree-main")
        case "duplicate-tab": changed = json.replacingOccurrences(
            of: "\"tabs\":[]", with: "\"tabs\":[{\"id\":\"tab-review\",\"name\":\"First\",\"terminals\":[]}]")
        case "duplicate-terminal": changed = json.replacingOccurrences(of: "\"t9\"", with: "\"t3\"")
        case "relayed": changed = json.replacingOccurrences(of: "\"t9\"", with: "\"remote/t9\"")
        case "empty-id": changed = json.replacingOccurrences(of: "\"space-1\"", with: "\"\"")
        case "non-string-name": changed = json.replacingOccurrences(of: "\"name\":\"Service\"", with: "\"name\":7")
        case "oversized": changed = json.replacingOccurrences(
            of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"padding\":\"\(String(repeating: "x", count: 1_048_577))\"")
        case "missing": changed = json.replacingOccurrences(of: "\"worktrees\":", with: "\"unrecognized\":")
        default: changed = "null"
        }
        #expect(changed != json)
        let invalid = try JSONDecoder().decode(JSONValue.self, from: Data(changed.utf8))
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [
            Self.subscribeResult([Self.record("t3", labels: Self.desktop("s1", "tb1")), Self.record("t8")])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        await transport.setDocument(invalid, version: 7, name: "amux-organization")
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(store.amuxOrganizations[host.id] == nil)
        #expect(cards(store) == ["Alpha: t3", "app: t8"])
        #expect(await transport.documentWrites.isEmpty)
    }

    @Test func amuxEventsRefreshMembershipAndDeletionAndCoreReplacementRetireLaunchTargets() async throws {
        let fixture = try amuxFixture()
        let value = try #require(fixture["value"])
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [
            Self.subscribeResult([Self.record("t3"), Self.record("t9")])
        ])
        await transport.setDocument(value, version: 7, name: "amux-organization")
        let store = try await started(transport)
        defer { store.setHosts([]) }
        let target = try #require(store.workspaces(for: host.id).first { $0.label == "Service / main" })
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let renamed = try JSONDecoder().decode(JSONValue.self, from: Data(json.replacingOccurrences(of: "Review", with: "Renamed").utf8))
        await transport.setDocument(renamed, version: 8, name: "amux-organization")
        await transport.deliver(Self.documentEvent(sequence: 2, name: "amux-organization", version: 8))
        try await waitUntil("the amux rename") { row(store, "t3")?.tabLabel == "Renamed" }
        await transport.setDocument(.null, version: 9, name: "amux-organization")
        await transport.deliver(Self.documentEvent(sequence: 3, name: "amux-organization", version: 9))
        try await waitUntil("the document deletion") { store.amuxOrganizations[host.id] == nil }
        await #expect(throws: TransportError.self) {
            try await store.createShellTerminal(ShellTerminalCreationRequest(workspaceID: target.id, cwd: "/srv/service"), on: host.id)
        }
        await transport.setDocument(value, version: 1, name: "amux-organization")
        await transport.setCoreID("core-b")
        await transport.endLink()
        try await waitUntil("the replacement core") { store.hostCores[host.id] == "core-b" && !store.hostsAwaitingSnapshot.contains(host.id) }
        #expect(store.amuxOrganizations[host.id] == nil)
        #expect(Set(store.terminals.map(\.paneID)) == ["t3", "t9"])
        await #expect(throws: TransportError.self) {
            try await store.createShellTerminal(ShellTerminalCreationRequest(workspaceID: target.id, cwd: "/srv/service"), on: host.id)
        }
        #expect(await transport.runs.isEmpty)
    }

    @Test func anEmptyAmuxHostHasAWorkingBrowserEntryInConsole() async throws {
        let fixture = try amuxFixture()
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [Self.subscribeResult([])])
        await transport.setDocument(try #require(fixture["value"]), version: 7, name: "amux-organization")
        let store = try await started(transport)
        defer { store.setHosts([]) }
        let presentation = TerminalListPresentationStore(defaults: try #require(UserDefaults(suiteName: "amux-ui-\(UUID())")))
        let controller = UIHostingController(rootView: NavigationStack {
            TerminalListView(
                hosts: [host], console: store, presentation: presentation, filteredHostIDs: [],
                selection: .constant(nil), onOpen: { _ in }, onOpenHost: { _ in },
                onShowHostIssues: {}, onNewTerminal: {})
        })
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller) { window in
            let label = "amux Spaces · \(host.displayName)"
            try await waitUntil("the Console browser entry") { accessibleElement(labeled: label, in: window) != nil }
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            Attachment.record(image, named: "amux-console-empty", as: .png)
            let entry = try #require(accessibleElement(labeled: label, in: window))
            _ = entry.accessibilityActivate()
            try await waitUntil("the browser sheet") { accessibleElement(labeled: "Start in main", in: window) != nil }
            #expect(await transport.runs.isEmpty)
        }
    }

    @Test func amuxBrowserOffersReadOnlyMembershipAndLaunchesFromTheEmptyMainCheckout() async throws {
        let fixture = try amuxFixture()
        let transport = ScriptedCoreTransport(coreID: "core-a", subscribeResults: [
            Self.subscribeResult([Self.record("t3", cwd: "/srv/service-fix"), Self.record("t8", cwd: "/outside")])
        ])
        await transport.setDocument(try #require(fixture["value"]), version: 7, name: "amux-organization")
        let store = try await started(transport)
        defer { store.setHosts([]) }
        var selected: ConsoleTerminal?
        let controller = UIHostingController(rootView:
            AmuxOrganizationView(host: host, coreID: "core-a", console: store) { selected = $0 })
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller) { window in
            try await waitUntil("the amux launch menu") { accessibleElement(labeled: "Start in main", in: window) != nil }
            #expect(accessibleElements(in: window).contains { $0.accessibilityLabel?.contains("Review") == true })
            #expect(accessibleElements(in: window).contains { $0.accessibilityLabel?.contains("t9") == true })
            func capture(_ name: String) {
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                Attachment.record(image, named: name, as: .png)
            }
            capture("amux-browser-default")
            let items = try await HostedMenu.items(labeled: "Start in main", in: window)
            #expect(items == [["New Terminal", "New Agent"]])
            try await HostedMenu.select("New Terminal", labeled: "Start in main", in: window)
            try await waitUntil("the launched shell") { selected != nil }
            #expect(selected?.cwd == "/srv/service")
            #expect(selected?.workspaceLabel == "service")
            capture("amux-browser-after-launch")
            await transport.setDocument(.null, version: 8, name: "amux-organization")
            await transport.deliver(Self.documentEvent(sequence: 2, name: "amux-organization", version: 8))
            try await waitUntil("the unavailable organization") {
                accessibleElement(labeled: "Organization Unavailable", in: window) != nil
            }
            capture("amux-browser-unavailable")
            #expect(await transport.documentWrites.isEmpty)
            #expect(await transport.labelWrites.isEmpty)
        }
    }

    @Test func aSnapshotPlacesLabeledTerminalsByTheDocument() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", labels: Self.desktop("s1", "tb1")),
                Self.record("t2", labels: Self.desktop("s2", "tb2")),
                Self.record("t3", cwd: "/work/headless"),
            ])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        #expect(cards(store) == ["Zeta: t2", "Alpha: t1", "headless: t3"])
        #expect(row(store, "t1")?.displayTabTitle == "Tab \u{201C}main\u{201D}")
        #expect(await transport.documentReads.sorted() == ["amux-organization", "herdr-app"])
        #expect(await transport.documentWrites.isEmpty)
    }

    @Test func nothingShowsUntilTheFirstDocumentReadSettles() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", labels: Self.desktop("s1", "tb1"))])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let gate = ScriptedTransportCallGate()
        await transport.holdDocumentReads(using: gate)
        let store = makeStore(transport)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()

        await gate.waitForEntry()
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        #expect(store.terminals.isEmpty)

        await gate.open()
        try await waitUntil("the placed row") { !store.terminals.isEmpty }
        #expect(cards(store) == ["Alpha: t1"])
        #expect(!store.hostsAwaitingSnapshot.contains(host.id))
    }

    /// Over the real link, whose deadline is what ends the wait.
    @Test func aDocumentReadNobodyAnswersLeavesLoadingAtTheCallDeadline() async throws {
        let clock = ManualClock()
        let core = ScriptedCoreHost(
            channel: .core(
                .init(
                    terminals: [Self.record("t1", cwd: "/work/one", labels: Self.desktop("s1", "tb1"))],
                    answersDocumentReads: false)))
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: {
                        await core.setConnected(true)
                        return core.transport(sleep: clock.parkedSleep(for:))
                    },
                    keepalive: nil)
            },
            coreHostMemory: HerdrCoreHostMemory())
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()

        await core.waitForMethod("doc.get")
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        #expect(store.terminals.isEmpty)

        try await waitUntil("the deadline") {
            clock.advance(.seconds(10))
            return !store.hostsAwaitingSnapshot.contains(host.id)
        }
        #expect(store.hostStatuses[host.id] == .connected)
        #expect(cards(store) == ["one: t1"])
    }

    /// The Host's first read has settled, so a change it did not cover is an
    /// ordinary re-placement, not more loading.
    @Test func aDocumentChangeDuringTheFirstReadDoesNotHoldTheRowsBack() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", labels: Self.desktop("s1", "tb1"))])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let firstRead = ScriptedTransportCallGate()
        await transport.holdDocumentReads(using: firstRead)
        let memory = HerdrCoreHostMemory()
        let store = makeStore(transport, memory: memory)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await firstRead.waitForEntry()

        await transport.setDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space("s1", name: "Four", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
            ]), version: 4)
        await transport.deliver(Self.documentEvent(sequence: 2, version: 4))
        // Events apply in order: once t2 is remembered, the change is known.
        await transport.deliver(
            Self.createdEvent(sequence: 3, Self.record("t2", labels: Self.desktop("s1", "tb1"))))
        try await waitUntil("the events") { memory.firstSeenDirectories(for: host.id)["t2"] != nil }

        let secondRead = ScriptedTransportCallGate()
        await transport.holdDocumentReads(using: secondRead)
        await firstRead.open()
        await secondRead.waitForEntry()
        try await waitUntil("the rows") { cards(store) == ["Alpha: t1 t2"] }
        #expect(!store.hostsAwaitingSnapshot.contains(host.id))

        await secondRead.open()
        try await waitUntil("the change") { cards(store) == ["Four: t1 t2"] }
    }

    @Test func aDocumentThatCannotBeReadLeavesLabelsPlacingTerminals() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", cwd: "/work/one", labels: Self.desktop("s1", "tb1")),
                Self.record("t2", cwd: "/work/two", labels: Self.desktop("s1", "tb1")),
            ])
        ])
        await transport.setDocument(.string("not a layout"), version: 1)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        #expect(cards(store) == ["one: t1 t2"])
    }

    @Test func aDocEventRePlacesTerminalsWithoutAReList() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", labels: Self.desktop("s1", "tb1")),
                Self.record("t2", labels: Self.desktop("s2", "tb2")),
            ])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(cards(store) == ["Zeta: t2", "Alpha: t1"])

        // The desktop user moved Alpha up and renamed it.
        await transport.setDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space(
                    "s1", name: "Alpha Two", tabs: [CoreDesktopJSON.tab("tb1", name: "renamed")]),
                CoreDesktopJSON.space("s2", name: "Zeta", tabs: [CoreDesktopJSON.tab("tb2", name: "logs")]),
            ]), version: 4)
        await transport.deliver(Self.documentEvent(sequence: 2, version: 4))

        try await waitUntil("the new order") { cards(store) == ["Alpha Two: t1", "Zeta: t2"] }
        #expect(row(store, "t1")?.displayTabTitle == "Tab \u{201C}renamed\u{201D}")
        #expect(await transport.subscribeCount == 1)
        #expect(await transport.documentWrites.isEmpty)
    }

    @Test func aDeletedDocumentLeavesItsSpacesUnnamed() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", cwd: "/work/one", labels: Self.desktop("s1", "tb1"))])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(cards(store) == ["Alpha: t1"])

        await transport.setDocument(.null, version: 4)
        await transport.deliver(Self.documentEvent(sequence: 2, version: 4))

        try await waitUntil("the folder's name") { cards(store) == ["one: t1"] }
    }

    @Test func onlyANewerVersionOfThisCoresDesktopDocumentIsRead() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", labels: Self.desktop("s1", "tb1")), Self.record("t2"),
            ])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.deliver(Self.documentEvent(sequence: 2, version: 3))
        await transport.deliver(Self.documentEvent(sequence: 3, name: "notes", version: 9))
        await transport.deliver(Self.documentEvent(sequence: 4, version: 9, machine: "vps"))
        // Events apply in order: once this one shows, those were looked at.
        await transport.deliver(Self.labelsEvent(sequence: 5, "t2", Self.desktop("s2", "tb2")))
        try await waitUntil("t2 moved") { cards(store) == ["Zeta: t2", "Alpha: t1"] }

        #expect(await transport.documentReads.sorted() == ["amux-organization", "herdr-app"])
    }

    @Test func aBurstOfDocEventsCostsOneMoreRead() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", labels: Self.desktop("s1", "tb1")), Self.record("t2"),
            ])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        let gate = ScriptedTransportCallGate()
        await transport.holdDocumentReads(using: gate)
        await transport.setDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space("s1", name: "Four", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
            ]), version: 4)
        await transport.deliver(Self.documentEvent(sequence: 2, version: 4))
        await gate.waitForEntry()

        await transport.setDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space("s1", name: "Six", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
            ]), version: 6)
        await transport.deliver(Self.documentEvent(sequence: 3, version: 5))
        await transport.deliver(Self.documentEvent(sequence: 4, version: 6))
        // Events apply in order: once t2 moves, the read in flight knows of both.
        await transport.deliver(Self.labelsEvent(sequence: 5, "t2", Self.desktop("s1", "tb1")))
        try await waitUntil("t2 moved") { cards(store) == ["Alpha: t1 t2"] }
        await gate.open()

        try await waitUntil("the last name") { cards(store) == ["Six: t1 t2"] }
        #expect(await transport.documentReads.filter { $0 == "herdr-app" }.count == 3)
    }

    // MARK: Labels

    @Test func aLabelsEventRePlacesATerminalWithoutAReList() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.record("t1", cwd: "/work/headless"),
                Self.record("t2", labels: Self.desktop("s1", "tb1")),
            ])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }
        #expect(cards(store) == ["Alpha: t2", "headless: t1"])

        await transport.deliver(Self.labelsEvent(sequence: 2, "t1", Self.desktop("s2", "tb2")))
        try await waitUntil("t1 in its space") { cards(store) == ["Zeta: t1", "Alpha: t2"] }

        // Parked: the labels are gone, and so is its place in the space.
        await transport.deliver(Self.labelsEvent(sequence: 3, "t1", [:]))
        try await waitUntil("t1 back") { cards(store) == ["Alpha: t2", "headless: t1"] }

        #expect(await transport.subscribeCount == 1)
        #expect(await transport.documentReads.sorted() == ["amux-organization", "herdr-app"])
    }

    @Test func aChildStartedLaterJoinsItsParentsTabAsAnotherPane() async throws {
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.record("t1", labels: Self.desktop("s1", "tb1"))])
        ])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.deliver(
            Self.createdEvent(
                sequence: 2,
                Self.record("t2", cwd: "/somewhere/else", labels: ["heeler.source": "app"], parent: "t1")))

        try await waitUntil("the child") { row(store, "t2") != nil }
        #expect(cards(store) == ["Alpha: t1 t2"])
        #expect(row(store, "t2")?.tabID == row(store, "t1")?.tabID)
        #expect(row(store, "t2")?.workspaceID == row(store, "t1")?.workspaceID)
    }

    // MARK: A fresh snapshot

    @Test func aFreshSnapshotAfterMissedGivesTheSamePlacement() async throws {
        let inventory = [
            Self.record("t1", labels: Self.desktop("s1", "tb1")),
            Self.record("t2", labels: Self.desktop("s2", "tb2")),
            Self.record("t3", cwd: "/somewhere/else", parent: "t1"),
            Self.record("t4", cwd: "/work/headless"),
        ]
        let transport = ScriptedCoreTransport(subscribeResults: [Self.subscribeResult(inventory)])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }
        let placed = cards(store)
        #expect(placed == ["Zeta: t2", "Alpha: t1 t3", "headless: t4"])
        let tabs = Dictionary(store.terminals.map { ($0.paneID, $0.tabID) }) { first, _ in first }

        await transport.deliver(Self.line("missed", Self.subscribeResult(sequence: 40, inventory)))
        try await waitUntil("the second read") { await transport.documentReads.filter { $0 == "herdr-app" }.count == 2 }
        try await waitUntil("the placement") { cards(store) == placed }

        #expect(Dictionary(store.terminals.map { ($0.paneID, $0.tabID) }) { first, _ in first } == tabs)
        #expect(await transport.subscribeCount == 1)
    }

    @Test func aDocEventLostToMissedIsCaughtByTheFreshSnapshot() async throws {
        let inventory = [Self.record("t1", labels: Self.desktop("s1", "tb1"))]
        let transport = ScriptedCoreTransport(subscribeResults: [Self.subscribeResult(inventory)])
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.setDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space("s1", name: "Renamed", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
            ]), version: 4)
        await transport.deliver(Self.line("missed", Self.subscribeResult(sequence: 40, inventory)))

        try await waitUntil("the new name") { cards(store) == ["Renamed: t1"] }
    }

    // MARK: Checkout roots

    @Test func aLabelOnlySpaceTakesItsCheckoutsNameAndAsksOncePerDirectory() async throws {
        let services = ScriptedCoreServices(roots: ["/work/repo/src": "/work/repo"])
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.record("t1", cwd: "/work/repo/src", labels: Self.desktop("lonely", "tb7")),
                    Self.record("t2", cwd: "/elsewhere", labels: Self.desktop("lonely", "tb7")),
                ])
            ], services: services)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        try await waitUntil("the checkout's name") { cards(store) == ["repo: t1 t2"] }
        #expect(await services.checkoutCalls == [["/work/repo/src"]])

        // More reasons to rebuild, and the same directory again, ask nothing.
        await transport.deliver(Self.labelsEvent(sequence: 2, "t2", Self.desktop("lonely", "tb7")))
        await transport.deliver(
            Self.createdEvent(
                sequence: 3,
                Self.record("t3", cwd: "/work/repo/src", labels: Self.desktop("other", "tb8"))))
        try await waitUntil("a second space") { cards(store) == ["repo: t1 t2", "repo: t3"] }
        #expect(await services.checkoutCalls == [["/work/repo/src"]])
    }

    @Test func aFolderOutsideAnyCheckoutIsAskedOnceAndReadsItself() async throws {
        let services = ScriptedCoreServices()
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.record("t1", cwd: "/work/plain", labels: Self.desktop("lonely"))
                ])
            ], services: services)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        try await waitUntil("the ask") { await services.checkoutCalls.count == 1 }
        await transport.deliver(Self.labelsEvent(sequence: 2, "t1", Self.desktop("lonely", "tb1")))
        try await waitUntil("the labels") { row(store, "t1")?.tabID != "tab-t1" }

        #expect(cards(store) == ["plain: t1"])
        #expect(await services.checkoutCalls == [["/work/plain"]])
    }

    /// It keeps the document's name, and asks only to tell a Worktree from a main
    /// checkout.
    @Test func aSpaceTheDocumentNamesKeepsItsNameWhateverItsCheckoutIsCalled() async throws {
        let services = ScriptedCoreServices(roots: ["/work/app": "/work/other"])
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.record("t1", labels: Self.desktop("s1", "tb1")), Self.record("t2"),
                ])
            ], services: services)
        await transport.setDocument(Self.twoSpaces, version: 3)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        await transport.deliver(Self.labelsEvent(sequence: 2, "t2", Self.desktop("s2", "tb2")))
        try await waitUntil("t2 moved") { cards(store) == ["Zeta: t2", "Alpha: t1"] }
        try await waitUntil("the ask") { await services.checkoutCalls.count == 1 }

        #expect(cards(store) == ["Zeta: t2", "Alpha: t1"])
    }

    /// Asked once for every Workspace, whatever kind it is, so each row knows its
    /// repository and Worktree Details is offered on a linked one.
    @Test func eachWorkspaceLearnsWhichCheckoutItIs() async throws {
        let linked = "/home/dev/.herdr/worktrees/app/feature"
        let services = ScriptedCoreServices(checkouts: [
            "/work/app": HostCheckout(root: "/work/app", mainCheckout: "/work/app"),
            linked: HostCheckout(root: linked, mainCheckout: "/work/app", isLinkedWorktree: true),
        ])
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.agentRecord("t1", cwd: "/work/app"),
                    Self.agentRecord("t2", cwd: linked, labels: Self.desktop("s9", "tb9")),
                ])
            ], services: services)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        try await waitUntil("both checkouts") {
            store.agents.compactMap(\.repositoryCheckout).count == 2
        }
        let main = try #require(store.agents.first { $0.agent.paneID == "t1" })
        let worktree = try #require(store.agents.first { $0.agent.paneID == "t2" })
        #expect(!main.isLinkedWorktree)
        #expect(worktree.isLinkedWorktree)
        #expect(worktree.repositoryCheckout?.repoKey == main.repositoryCheckout?.repoKey)
        #expect(worktree.repositoryCheckout?.repoName == "app")
        #expect(worktree.repositoryCheckout?.checkoutPath == linked)
        #expect(await Set(services.checkoutCalls.joined()) == ["/work/app", linked])
    }

    @Test func manyDirectoriesAreAskedInCappedCalls() async throws {
        let count = GitProbe.checkoutRootsPerCall + 4
        let services = ScriptedCoreServices()
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult(
                    (0..<count).map {
                        Self.record("t\($0)", cwd: "/work/d\($0)", labels: Self.desktop("s\($0)"))
                    })
            ], services: services)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        try await waitUntil("every directory asked") {
            await services.checkoutCalls.joined().count >= count
        }
        let calls = await services.checkoutCalls
        #expect(calls.map(\.count) == [GitProbe.checkoutRootsPerCall, 4])
        #expect(Set(calls.joined()).count == count)
    }

    @Test func anAskWaitsItsTurnAtTheHostsGitGate() async throws {
        let services = ScriptedCoreServices(roots: ["/work/repo/src": "/work/repo"])
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.record("t1", cwd: "/work/repo/src", labels: Self.desktop("lonely"))
                ])
            ], services: services)
        let store = makeStore(transport)
        defer { store.setHosts([]) }
        let held = ScriptedTransportCallGate()
        let changes = Task { [gate = store.gitExecGate(for: host.id)] in
            try await gate.run { await held.waitUntilOpen() }
        }
        await held.waitForEntry()

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the row") { !store.terminals.isEmpty }
        // Only lets an ask that skipped the gate show up; passing never waits on it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await services.checkoutCalls.isEmpty)
        #expect(cards(store) == ["src: t1"])

        await held.open()
        try await changes.value
        try await waitUntil("the checkout's name") { cards(store) == ["repo: t1"] }
    }

    @Test func aFailedAskWaitsForTheNextConnectionAndAnAnswerOutlivesIt() async throws {
        let services = ScriptedCoreServices(roots: ["/work/one": "/work/one-repo"])
        await services.setFailure(TransportError.gitTimedOut)
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.record("t1", cwd: "/work/one", labels: Self.desktop("lonely"))
                ])
            ], services: services)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        try await waitUntil("the ask") { await services.checkoutCalls.count == 1 }
        await transport.deliver(Self.labelsEvent(sequence: 2, "t1", Self.desktop("lonely", "tb1")))
        try await waitUntil("the labels") { row(store, "t1")?.tabID != "tab-t1" }
        #expect(await services.checkoutCalls.count == 1)
        #expect(cards(store) == ["one: t1"])

        await services.setFailure(nil)
        await store.suspend()
        await store.resume()
        try await waitUntil("the answer") { cards(store) == ["one-repo: t1"] }
        #expect(await services.checkoutCalls.count == 2)

        await store.suspend()
        await store.resume()
        try await waitUntil("the row again") { cards(store) == ["one-repo: t1"] }
        #expect(await services.checkoutCalls.count == 2)
    }

    @Test func theHomeFolderReadsTildeWithoutAskingGit() async throws {
        let services = ScriptedCoreServices(home: "/home/dev")
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                Self.subscribeResult([
                    Self.record("t1", cwd: "/home/dev", labels: Self.desktop("lonely"))
                ])
            ], services: services)
        let store = try await started(transport)
        defer { store.setHosts([]) }

        try await waitUntil("the home name") { cards(store) == ["~: t1"] }
        #expect(await services.checkoutCalls.isEmpty)
    }
}
