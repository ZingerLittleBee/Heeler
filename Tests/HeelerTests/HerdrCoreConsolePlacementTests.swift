import Foundation
import Testing

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

    private func makeStore(_ transport: ScriptedCoreTransport) -> ConsoleStore {
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
            coreHostMemory: HerdrCoreHostMemory())
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
        #expect(await transport.documentReads == ["herdr-app"])
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

        #expect(await transport.documentReads == ["herdr-app"])
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
        #expect(await transport.documentReads.count == 3)
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
        #expect(await transport.documentReads.count == 1)
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
        try await waitUntil("the second read") { await transport.documentReads.count == 2 }
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

    @Test func aSpaceTheDocumentNamesNeverAsksForACheckout() async throws {
        let services = ScriptedCoreServices()
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

        #expect(await services.checkoutCalls.isEmpty)
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
