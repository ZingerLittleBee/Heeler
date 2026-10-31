import Foundation
import Testing

@testable import Heeler

/// A core Agent's Pin through `ConsoleStore`, on a device whose defaults outlive
/// each launch. herdr-core never reuses an address, so unlike a Herdr TUI Pin
/// this one goes when its Terminal does (ADR 0031).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCorePinsTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
    private let otherHost = Host(address: "other.example", username: "dev", serverKind: .herdrCore)
    private let suiteName = "core-pins-\(UUID().uuidString)"

    private static func agent(
        _ address: String, state: String = "working", terminalState: String = "live", keep: Bool = false
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string(terminalState),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(keep), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "foreground": .object([
                "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
                "cwd": .string("/work/app"),
            ]),
            "status": .object(["state": .string(state), "app": .string("claude-code")]),
        ])
    }

    private static func subscribeResult(sequence: Int = 1, _ terminals: [JSONValue]) -> JSONValue {
        .object([
            "seq": .number(Double(sequence)), "terminals": .array(terminals), "channel": .number(1),
        ])
    }

    private static func event(sequence: Int, type: String, terminal: String, data: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private func device() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suiteName))
    }

    /// One launch of the app: everything it remembers is read back from `defaults`.
    private func launch(
        on defaults: UserDefaults, _ transports: [Host.ID: ScriptedCoreTransport]
    ) async throws -> ConsoleStore {
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { host in
                HerdrCoreHostSession(
                    connect: {
                        guard let transport = transports[host.id] else {
                            throw TransportError.sshUnreachable(detail: "no transport")
                        }
                        return transport
                    },
                    keepalive: nil)
            },
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
        store.setHosts(transports.keys.compactMap { id in [host, otherHost].first { $0.id == id } })
        await store.resume()
        try await waitUntil("the first snapshots") { store.hostsAwaitingSnapshot.isEmpty }
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

    private func listed(_ store: ConsoleStore, on host: Host? = nil) -> [String] {
        store.agents.filter { $0.hostID == (host ?? self.host).id }.map(\.agent.paneID)
    }

    /// What the next launch would read.
    private func persistedPins(on defaults: UserDefaults, for host: Host? = nil) -> [String] {
        PinnedAgentsStore(defaults: defaults).pinnedPaneIDs(for: (host ?? self.host).id)
    }

    // MARK: Pinning

    @Test func aPinnedCoreAgentFloatsToTheTopAndStaysThereAcrossARelaunch() async throws {
        let defaults = try device()
        let firstResult = Self.subscribeResult([Self.agent("t1"), Self.agent("t2", state: "idle")])
        let store = try await launch(
            on: defaults, [host.id: ScriptedCoreTransport(subscribeResults: [firstResult])])
        #expect(listed(store) == ["t1", "t2"])

        store.togglePin(hostID: host.id, paneID: "t2")

        #expect(listed(store) == ["t2", "t1"])
        await store.suspend()

        let relaunched = try await launch(
            on: defaults, [host.id: ScriptedCoreTransport(subscribeResults: [firstResult])])
        defer { relaunched.setHosts([]) }
        #expect(relaunched.pins.isPinned(hostID: host.id, paneID: "t2"))
        #expect(listed(relaunched) == ["t2", "t1"])
    }

    // MARK: A Terminal removed

    @Test func aRemovedEventDropsThatTerminalsPinAndLeavesTheHostsOthers() async throws {
        let defaults = try device()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.agent("t1"), Self.agent("t2"), Self.agent("t3")])
        ])
        let store = try await launch(on: defaults, [host.id: transport])
        defer { store.setHosts([]) }
        store.togglePin(hostID: host.id, paneID: "t1")
        store.togglePin(hostID: host.id, paneID: "t2")

        await transport.deliver(Self.event(sequence: 2, type: "removed", terminal: "t1", data: .object([:])))
        try await waitUntil("t1 gone") { !listed(store).contains("t1") }

        #expect(store.pins.pinnedPaneIDs(for: host.id) == ["t2"])
        #expect(persistedPins(on: defaults) == ["t2"])
        #expect(listed(store) == ["t2", "t3"])
    }

    // MARK: Snapshots from the same core

    @Test func aFreshSnapshotDropsAPinWhoseAddressItLacksAndKeepsOneItHas() async throws {
        let defaults = try device()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.agent("t1"), Self.agent("t2"), Self.agent("t3")]),
            Self.subscribeResult(sequence: 9, [Self.agent("t2"), Self.agent("t3"), Self.agent("t9")]),
        ])
        let store = try await launch(on: defaults, [host.id: transport])
        defer { store.setHosts([]) }
        store.togglePin(hostID: host.id, paneID: "t1")
        store.togglePin(hostID: host.id, paneID: "t2")

        await transport.endLink()
        try await waitUntil("the fresh snapshot") { listed(store).contains("t9") }

        #expect(store.pins.pinnedPaneIDs(for: host.id) == ["t2"])
        #expect(persistedPins(on: defaults) == ["t2"])
        #expect(listed(store).first == "t2")
    }

    @Test func aMissedSnapshotDropsAPinWhoseAddressItLacks() async throws {
        let defaults = try device()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.agent("t1"), Self.agent("t2")])
        ])
        let store = try await launch(on: defaults, [host.id: transport])
        defer { store.setHosts([]) }
        store.togglePin(hostID: host.id, paneID: "t1")
        store.togglePin(hostID: host.id, paneID: "t2")

        let line = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("missed"),
            "params": .object(["seq": .number(50), "terminals": .array([Self.agent("t2")])]),
        ]))
        await transport.deliver(line)
        try await waitUntil("t1 gone") { !listed(store).contains("t1") }

        #expect(store.pins.pinnedPaneIDs(for: host.id) == ["t2"])
    }

    @Test func aTerminalRemovedWhileTheAppWasClosedLosesItsPinAtTheNextLaunch() async throws {
        let defaults = try device()
        let store = try await launch(
            on: defaults,
            [host.id: ScriptedCoreTransport(subscribeResults: [
                Self.subscribeResult([Self.agent("t1"), Self.agent("t2")])
            ])])
        store.togglePin(hostID: host.id, paneID: "t1")
        store.togglePin(hostID: host.id, paneID: "t2")
        await store.suspend()

        let relaunched = try await launch(
            on: defaults,
            [host.id: ScriptedCoreTransport(subscribeResults: [
                Self.subscribeResult([Self.agent("t2")])
            ])])
        defer { relaunched.setHosts([]) }

        #expect(relaunched.pins.pinnedPaneIDs(for: host.id) == ["t2"])
        #expect(persistedPins(on: defaults) == ["t2"])
    }

    /// The core still knows it: only `removed` or a snapshot without it ends the Pin.
    @Test func aFinishedTerminalStillInTheSnapshotKeepsItsPin() async throws {
        let defaults = try device()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.agent("t1"), Self.agent("t2")]),
            Self.subscribeResult(
                sequence: 9,
                [Self.agent("t1", terminalState: "finished"), Self.agent("t2"), Self.agent("t9")]),
        ])
        let store = try await launch(on: defaults, [host.id: transport])
        defer { store.setHosts([]) }
        store.togglePin(hostID: host.id, paneID: "t1")

        await transport.endLink()
        try await waitUntil("the fresh snapshot") { listed(store).contains("t9") }

        #expect(!listed(store).contains("t1"))
        #expect(store.pins.isPinned(hostID: host.id, paneID: "t1"))
    }

    // MARK: A core restart

    @Test func aCoreRestartWithTheSameIDKeepsEveryPin() async throws {
        let defaults = try device()
        let transport = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([Self.agent("t1", keep: true), Self.agent("t2", keep: true)]),
            // A restarted core's sequence starts below the old one's.
            Self.subscribeResult(
                sequence: 1,
                [Self.agent("t1", keep: true), Self.agent("t2", keep: true), Self.agent("t9")]),
        ])
        let store = try await launch(on: defaults, [host.id: transport])
        defer { store.setHosts([]) }
        store.togglePin(hostID: host.id, paneID: "t1")
        store.togglePin(hostID: host.id, paneID: "t2")

        await transport.deliver(
            Self.event(
                sequence: 2, type: "lost", terminal: "t1",
                data: .object(["reason": .string("holder_lost")])))
        try await waitUntil("t1 lost") { !listed(store).contains("t1") }
        #expect(store.pins.pinnedPaneIDs(for: host.id) == ["t2", "t1"])

        await transport.endLink()
        try await waitUntil("the restarted core's snapshot") { listed(store).contains("t9") }

        #expect(store.pins.pinnedPaneIDs(for: host.id) == ["t2", "t1"])
        #expect(persistedPins(on: defaults) == ["t2", "t1"])
        #expect(listed(store) == ["t2", "t1", "t9"])
    }

    // MARK: Another core

    /// The new core's addresses start over, so its Terminals can have the same
    /// addresses as the Pins it must not inherit.
    @Test func anotherCoreIDDropsAllOfThatHostsPinsAndLeavesOtherHosts() async throws {
        let defaults = try device()
        let wiped = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([Self.agent("t1"), Self.agent("t2")]),
            Self.subscribeResult(sequence: 1, [Self.agent("t1"), Self.agent("t2"), Self.agent("t9")]),
        ])
        let other = ScriptedCoreTransport(coreID: "c1", subscribeResults: [
            Self.subscribeResult([Self.agent("t1"), Self.agent("t2")])
        ])
        let store = try await launch(on: defaults, [host.id: wiped, otherHost.id: other])
        defer { store.setHosts([]) }
        store.togglePin(hostID: host.id, paneID: "t1")
        store.togglePin(hostID: host.id, paneID: "t2")
        store.togglePin(hostID: otherHost.id, paneID: "t1")

        await wiped.setCoreID("c2")
        await wiped.endLink()
        try await waitUntil("the new core's snapshot") { listed(store).contains("t9") }

        #expect(store.pins.pinnedPaneIDs(for: host.id).isEmpty)
        #expect(persistedPins(on: defaults).isEmpty)
        #expect(store.pins.pinnedPaneIDs(for: otherHost.id) == ["t1"])
        #expect(persistedPins(on: defaults, for: otherHost) == ["t1"])
        #expect(listed(store, on: otherHost).first == "t1")
    }

    @Test func aCoreWipedWhileTheAppWasClosedLosesThePinsAtTheNextLaunch() async throws {
        let defaults = try device()
        let terminals = Self.subscribeResult([Self.agent("t1")])
        let store = try await launch(
            on: defaults, [host.id: ScriptedCoreTransport(coreID: "c1", subscribeResults: [terminals])])
        store.togglePin(hostID: host.id, paneID: "t1")
        await store.suspend()

        let relaunched = try await launch(
            on: defaults, [host.id: ScriptedCoreTransport(coreID: "c2", subscribeResults: [terminals])])
        defer { relaunched.setHosts([]) }

        #expect(relaunched.pins.pinnedPaneIDs(for: host.id).isEmpty)
        #expect(persistedPins(on: defaults).isEmpty)
    }

    /// With no core remembered, nothing says this one is another. Its snapshot
    /// still rules on each address.
    @Test func theFirstCoreRememberedForAHostIsNoOtherCore() async throws {
        let defaults = try device()
        let earlier = PinnedAgentsStore(defaults: defaults)
        earlier.togglePin(hostID: host.id, paneID: "t1")
        earlier.togglePin(hostID: host.id, paneID: "t2")

        let store = try await launch(
            on: defaults,
            [host.id: ScriptedCoreTransport(subscribeResults: [
                Self.subscribeResult([Self.agent("t1")])
            ])])
        defer { store.setHosts([]) }

        #expect(store.pins.pinnedPaneIDs(for: host.id) == ["t1"])
    }

    // MARK: Herdr TUI

    /// Its pane ids return after a herdr restart, so its Pins are never pruned.
    @Test func aHerdrTUISnapshotMissingAPinnedPaneKeepsThePin() async throws {
        let defaults = try device()
        let tuiHost = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            })
        defer { store.setHosts([]) }
        store.setHosts([tuiHost])
        await store.resume()
        try await waitUntil("the Agents") { store.agents.count == 2 }
        store.togglePin(hostID: tuiHost.id, paneID: "w1:p1")

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p2"), .fixture(paneID: "w1:p3")]))
        #expect(await transport.emit(HerdrEvent(
            kind: GlobalEventKind.paneAgentDetected.kind,
            data: .object(["pane_id": .string("w1:p3")]))) == true)
        try await waitUntil("the snapshot without it") {
            store.agents.contains { $0.agent.paneID == "w1:p3" }
                && !store.agents.contains { $0.agent.paneID == "w1:p1" }
        }

        #expect(store.pins.isPinned(hostID: tuiHost.id, paneID: "w1:p1"))
        #expect(persistedPins(on: defaults, for: tuiHost) == ["w1:p1"])

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        #expect(await transport.emit(HerdrEvent(
            kind: GlobalEventKind.paneAgentDetected.kind,
            data: .object(["pane_id": .string("w1:p1")]))) == true)
        try await waitUntil("the same pane id back, at the top") {
            store.agents.first?.agent.paneID == "w1:p1"
        }
    }
}
