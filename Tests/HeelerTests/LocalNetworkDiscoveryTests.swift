import Foundation
import Network
import Testing

@testable import Heeler

@Suite("Local network discovery")
struct LocalNetworkDiscoveryTests {
    @Test func ipv4IsSaved() throws {
        let ip = try #require(IPv4Address("192.168.1.20"))
        #expect(DiscoveredAddress.string(for: .ipv4(ip)) == "192.168.1.20")
    }

    @Test func globalIPv6LosesItsScope() throws {
        let ip = try #require(IPv6Address("2001:db8::5%en0"))
        #expect(DiscoveredAddress.string(for: .ipv6(ip)) == "2001:db8::5")
    }

    @Test func linkLocalIPv6KeepsItsScope() throws {
        let ip = try #require(IPv6Address("fe80::1%en0"))
        #expect(DiscoveredAddress.string(for: .ipv6(ip)) == "fe80::1%en0")
    }

    @Test func nameOnlyIsRejected() {
        #expect(DiscoveredAddress.string(for: .name("box.local", nil)) == nil)
    }

    @Test func detectsLinkLocalRange() {
        #expect(DiscoveredAddress.isLinkLocal("fe80::1"))
        #expect(DiscoveredAddress.isLinkLocal("FEB0::1"))
        #expect(!DiscoveredAddress.isLinkLocal("fec0::1"))
        #expect(!DiscoveredAddress.isLinkLocal("2001:db8::1"))
    }
}

private struct FakeBrowser: LocalServiceBrowsing {
    var found: [DiscoveredMachine] = []
    var result: Result<ResolvedMachine, LocalDiscoveryError>
    var searchFailure: LocalDiscoveryError?

    func machines() -> AsyncThrowingStream<[DiscoveredMachine], Error> {
        AsyncThrowingStream { continuation in
            if let searchFailure {
                continuation.finish(throwing: searchFailure)
            } else {
                continuation.yield(found)
                continuation.finish()
            }
        }
    }

    func resolve(_ machine: DiscoveredMachine) async throws -> ResolvedMachine {
        try result.get()
    }
}

@Suite("Local machine picker")
@MainActor
struct LocalMachinePickerTests {
    private let machine = DiscoveredMachine(name: "Studio", type: "_ssh._tcp.", domain: "local.")
    private let resolved = ResolvedMachine(name: "Studio", address: "10.0.0.7", port: 2222)

    @Test func filledRouteGetsAddressPortAndBlankName() {
        var draft = HostDraft()
        draft.routes = [HostRouteDraft()]
        let id = draft.routes[0].id
        draft.applyDiscoveredMachine(resolved, toRoute: id)

        #expect(draft.address == "10.0.0.7")
        #expect(draft.port == "2222")
        #expect(draft.name == "Studio")
    }

    @Test func existingNameIsKept() {
        var draft = HostDraft()
        draft.routes = [HostRouteDraft()]
        draft.name = "Mine"
        let id = draft.routes[0].id
        draft.applyDiscoveredMachine(resolved, toRoute: id)

        #expect(draft.name == "Mine")
        #expect(draft.address == "10.0.0.7")
    }

    @Test func listsFoundMachines() async {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser(found: [machine], result: .success(resolved)))
        model.start()
        for _ in 0..<50 where model.isSearching || model.machines.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.machines == [machine])
        #expect(model.searchError == nil)
    }

    @Test func reportsPermissionDenied() async {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser(result: .success(resolved), searchFailure: .permissionDenied))
        model.start()
        for _ in 0..<50 where model.searchError == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.searchError == .permissionDenied)
    }

    @Test func resolveReturnsMachine() async {
        let model = LocalMachinePickerModel(browser: FakeBrowser(result: .success(resolved)))
        #expect(await model.resolve(machine) == resolved)
        #expect(model.resolveError == nil)
    }

    @Test func resolveFailureSetsError() async {
        let model = LocalMachinePickerModel(browser: FakeBrowser(result: .failure(.noAddress)))
        #expect(await model.resolve(machine) == nil)
        #expect(model.resolveError == .noAddress)
    }
}
