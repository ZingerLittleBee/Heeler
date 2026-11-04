import Foundation
import Network
import Testing

@testable import Heeler

@Suite("Local network discovery")
struct LocalNetworkDiscoveryTests {
    @Test func ipv4IsSaved() throws {
        let ip = try #require(IPv4Address("192.168.1.20"))
        #expect(try DiscoveredAddress.address(for: .ipv4(ip)).get() == "192.168.1.20")
    }

    @Test func globalIPv6LosesItsScope() throws {
        let ip = try #require(IPv6Address("2001:db8::5%en0"))
        #expect(try DiscoveredAddress.address(for: .ipv6(ip)).get() == "2001:db8::5")
    }

    @Test func linkLocalIPv6IsRejected() throws {
        let ip = try #require(IPv6Address("fe80::1%en0"))
        #expect(DiscoveredAddress.address(for: .ipv6(ip)) == .failure(.linkLocalOnly))
    }

    @Test func nameOnlyIsRejected() {
        #expect(DiscoveredAddress.address(for: .name("box.local", nil)) == .failure(.noAddress))
    }

    @Test func detectsLinkLocalRange() {
        #expect(DiscoveredAddress.isLinkLocal("fe80::1"))
        #expect(DiscoveredAddress.isLinkLocal("FEB0::1"))
        #expect(!DiscoveredAddress.isLinkLocal("fec0::1"))
        #expect(!DiscoveredAddress.isLinkLocal("2001:db8::1"))
    }

    private let resolved = ResolvedMachine(name: "Studio", address: "10.0.0.7", port: 22)

    @Test func triesIPv4ThenAnyFamily() async throws {
        let seen = Versions()
        let result = try await BonjourServiceBrowser.resolveIPv4First { version in
            seen.add(version)
            if version == .v4 { throw LocalDiscoveryError.timedOut }
            return resolved
        }
        #expect(result == resolved)
        #expect(seen.values == [.v4, nil])
    }

    @Test func stopsAfterIPv4Success() async throws {
        let seen = Versions()
        _ = try await BonjourServiceBrowser.resolveIPv4First { version in
            seen.add(version)
            return resolved
        }
        #expect(seen.values == [.v4])
    }

    @Test func cancellationSkipsTheFallback() async {
        let seen = Versions()
        await #expect(throws: CancellationError.self) {
            try await BonjourServiceBrowser.resolveIPv4First { version in
                seen.add(version)
                throw CancellationError()
            }
        }
        #expect(seen.values == [.v4])
    }

    @Test func linkLocalOnlyFromFallbackIsReported() async {
        await #expect(throws: LocalDiscoveryError.linkLocalOnly) {
            try await BonjourServiceBrowser.resolveIPv4First { version in
                if version == .v4 { throw LocalDiscoveryError.timedOut }
                throw LocalDiscoveryError.linkLocalOnly
            }
        }
    }
}

@Suite("Resume gate")
struct ResumeGateTests {
    private let machine = ResolvedMachine(name: "a", address: "1.2.3.4", port: 22)

    @Test func cancelBeforeInstallDoesNotHang() async {
        let gate = ResumeGate()
        gate.resume(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                _ = gate.install(continuation)
            }
        }
    }

    @Test func firstResultWins() async throws {
        let gate = ResumeGate()
        let result = try await withCheckedThrowingContinuation { continuation in
            _ = gate.install(continuation)
            gate.resume(.success(machine))
            gate.resume(.failure(CancellationError()))
        }
        #expect(result == machine)
    }

    @Test func connectionCancelAfterTimeoutReadsAsTimeout() {
        let gate = ResumeGate()
        #expect(gate.cancellationError is CancellationError)
        #expect(gate.markTimedOut() == .timedOut)
        #expect(gate.cancellationError as? LocalDiscoveryError == .timedOut)
    }

    @Test func timeoutAfterDenialReportsPermission() {
        let gate = ResumeGate()
        gate.noteDenied()
        #expect(gate.markTimedOut() == .permissionDenied)
        #expect(gate.cancellationError as? LocalDiscoveryError == .permissionDenied)
    }

    @Test func timeoutFallsBackToAnyFamily() async throws {
        let seen = Versions()
        let gate = ResumeGate()
        let result = try await BonjourServiceBrowser.resolveIPv4First { version in
            seen.add(version)
            if version == .v4 {
                _ = gate.markTimedOut()
                throw gate.cancellationError
            }
            return machine
        }
        #expect(result == machine)
        #expect(seen.values == [.v4, nil])
    }
}

private final class Versions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NWProtocolIP.Options.Version?] = []

    func add(_ version: NWProtocolIP.Options.Version?) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(version)
    }

    var values: [NWProtocolIP.Options.Version?] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Scripted browser: each `updates()` call replays the next script.
private final class FakeBrowser: LocalServiceBrowsing, @unchecked Sendable {
    enum Script {
        case updates([LocalBrowseUpdate])
        case failure(LocalDiscoveryError)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private let resolveBehavior: @Sendable (DiscoveredMachine) async throws -> ResolvedMachine

    init(
        scripts: [Script] = [],
        resolve: @escaping @Sendable (DiscoveredMachine) async throws -> ResolvedMachine
    ) {
        self.scripts = scripts
        resolveBehavior = resolve
    }

    func updates() -> AsyncThrowingStream<LocalBrowseUpdate, Error> {
        lock.lock()
        let script = scripts.isEmpty ? Script.updates([]) : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch script {
            case .updates(let updates):
                updates.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func resolve(_ machine: DiscoveredMachine) async throws -> ResolvedMachine {
        try await resolveBehavior(machine)
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
        draft.applyDiscoveredMachine(resolved, toRoute: draft.routes[0].id)

        #expect(draft.address == "10.0.0.7")
        #expect(draft.port == "2222")
        #expect(draft.name == "Studio")
    }

    @Test func existingNameIsKept() {
        var draft = HostDraft()
        draft.name = "Mine"
        draft.routes = [HostRouteDraft()]
        draft.applyDiscoveredMachine(resolved, toRoute: draft.routes[0].id)

        #expect(draft.name == "Mine")
        #expect(draft.address == "10.0.0.7")
    }

    @Test func listsFoundMachines() async {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser(scripts: [.updates([.machines([machine])])]) { [resolved] _ in resolved })
        await model.start().value
        #expect(model.machines == [machine])
        #expect(model.searchError == nil)
        #expect(!model.isSearching)
    }

    @Test func waitingKeepsSearchingAndRecovers() {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser { [resolved] _ in resolved })
        model.start()
        model.apply(.machines([machine]))
        model.apply(.waiting(permissionDenied: true))

        #expect(model.isSearching)
        #expect(model.searchError == nil)
        #expect(model.waitingHint == .permissionDenied)
        #expect(model.machines == [machine])

        model.apply(.ready)
        #expect(model.waitingHint == nil)
        #expect(model.isSearching)

        model.apply(.waiting(permissionDenied: false))
        #expect(model.waitingHint != nil)
        model.apply(.machines([machine]))
        #expect(model.waitingHint == nil)
        model.stop()
    }

    @Test func searchFailureSetsErrorAndRetryRecovers() async {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser(
                scripts: [.failure(.failed("boom")), .updates([.machines([machine])])]
            ) { [resolved] _ in resolved })
        await model.start().value
        #expect(model.searchError == .failed("boom"))
        #expect(!model.isSearching)

        model.retry()
        await model.start().value
        #expect(model.searchError == nil)
        #expect(model.machines == [machine])
    }

    @Test func pickCallsOnPickedOnce() async {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser { [resolved] _ in resolved })
        var picked: [ResolvedMachine] = []
        await model.pick(machine) { picked.append($0) }?.value
        #expect(picked == [resolved])
        #expect(model.resolvingID == nil)
    }

    @Test func linkLocalOnlyShowsAnError() async {
        let model = LocalMachinePickerModel(
            browser: FakeBrowser { _ in throw LocalDiscoveryError.linkLocalOnly })
        var picked = false
        await model.pick(machine) { _ in picked = true }?.value
        #expect(!picked)
        #expect(model.resolveError == .linkLocalOnly)
    }

    @Test func stopDuringResolveDoesNotPick() async {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let model = LocalMachinePickerModel(
            browser: FakeBrowser { _ in
                startedContinuation.yield()
                try await Task.sleep(for: .seconds(60))
                return ResolvedMachine(name: "x", address: "1.1.1.1", port: 22)
            })
        var picked = false
        let task = model.pick(machine) { _ in picked = true }
        #expect(task != nil)
        #expect(model.resolvingID == machine.id)
        // A second pick is refused while one resolves.
        #expect(model.pick(machine) { _ in picked = true } == nil)
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        model.stop()
        await task?.value
        #expect(!picked)
        #expect(model.resolvingID == nil)
        #expect(model.resolveError == nil)
    }
}
