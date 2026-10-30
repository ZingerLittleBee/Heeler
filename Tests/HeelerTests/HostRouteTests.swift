import Foundation
import HeelerOverlay
import HeelerSSH
import Synchronization
import Testing

@testable import Heeler

@Suite("Host routes")
struct HostRouteTests {
    @Test func aHostSavedBeforeRoutesDecodesAsItsOneRoute() throws {
        let id = UUID()
        let network = UUID()
        let legacy = """
            {"id":"\(id.uuidString)","name":"Old","address":"box.example","port":2222,
             "username":"dev","authMethod":"deviceKey","jumpAddress":"jump.example",
             "jumpPort":2022,"jumpUsername":"tunnel","overlayNetworkID":"\(network.uuidString)"}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(legacy.utf8))

        #expect(
            host.routes == [
                HostRoute(
                    id: id, address: "box.example", port: 2222, jumpAddress: "jump.example",
                    jumpPort: 2022, jumpUsername: "tunnel", overlayNetworkID: network)
            ])
    }

    @Test func routesRoundTripInOrder() throws {
        let host = Host(
            username: "dev",
            routes: [
                HostRoute(address: "192.168.1.5"),
                HostRoute(address: "100.64.0.5", overlayNetworkID: UUID()),
                HostRoute(address: "127.0.0.1", port: 2222, jumpAddress: "vps.example"),
            ])

        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))

        #expect(decoded == host)
    }

    /// A build without Routes reads the flat fields; they carry the first
    /// route, so a downgrade still connects the Host the way it did.
    @Test func thePrimaryRouteIsAlsoSavedFlatForBuildsWithoutRoutes() throws {
        let network = UUID()
        let host = Host(
            username: "dev",
            routes: [
                HostRoute(
                    address: "100.64.0.5", port: 2200, jumpAddress: "jump.example",
                    jumpPort: 2022, jumpUsername: "tunnel", overlayNetworkID: network),
                HostRoute(address: "192.168.1.5"),
            ])

        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])

        #expect(object["address"] as? String == "100.64.0.5")
        #expect(object["port"] as? Int == 2200)
        #expect(object["jumpAddress"] as? String == "jump.example")
        #expect(object["jumpPort"] as? Int == 2022)
        #expect(object["jumpUsername"] as? String == "tunnel")
        #expect(object["overlayNetworkID"] as? String == network.uuidString)
        #expect((object["routes"] as? [Any])?.count == 2)
    }

    /// A build without Routes drops them when it saves the Host; the flat
    /// fields it wrote are then the Host's one route again.
    @Test func flatFieldsWinWhenRoutesWereDropped() throws {
        let id = UUID()
        let saved = """
            {"id":"\(id.uuidString)","name":"","address":"edited.example","port":22,
             "username":"dev","authMethod":"deviceKey","routes":[]}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(saved.utf8))

        #expect(host.routes.map(\.address) == ["edited.example"])
    }

    @Test func aHostAnswersToTheAddressOfAnyRoute() {
        let host = Host(
            username: "dev",
            routes: [HostRoute(address: "192.168.1.5"), HostRoute(address: "Box.Tailnet.ts.net")])

        #expect(host.answers(toAddress: "192.168.1.5"))
        #expect(host.answers(toAddress: " box.tailnet.ts.net "))
        #expect(!host.answers(toAddress: "10.0.0.1"))
    }

    @Test func aRouteSummaryNamesItsJumpHostAndNetwork() {
        let network = UUID()
        let route = HostRoute(
            address: "127.0.0.1", port: 2222, jumpAddress: "vps.example", jumpPort: 2022,
            overlayNetworkID: network)

        #expect(
            route.summary { $0 == network ? "Home" : "?" }
                == "127.0.0.1:2222 via vps.example:2022 · Home")
        #expect(HostRoute(address: "10.0.0.5").summary { _ in "?" } == "10.0.0.5")
    }

    @Test func eachRouteKeepsItsOwnJumpAccount() {
        let host = Host(
            username: "dev",
            routes: [
                HostRoute(address: "127.0.0.1", jumpAddress: "a.example", jumpUsername: "tunnel"),
                HostRoute(address: "127.0.0.1", jumpAddress: "b.example"),
            ])

        #expect(host.jumpUsername(on: host.routes[0]) == "tunnel")
        #expect(host.jumpUsername(on: host.routes[1]) == "dev")
    }

    /// Which route a connection took is not known yet, so a Host with
    /// several never names the primary one as if it were in use.
    @Test func connectionSummaryNamesTheOnlyRouteOrCountsThem() {
        #expect(Host(address: "box.example", username: "dev").connectionSummary == "dev@box.example")
        #expect(
            Host(address: "box.example", port: 2222, username: "dev").connectionSummary
                == "dev@box.example:2222")
        #expect(
            Host(
                username: "dev",
                routes: [HostRoute(address: "192.0.2.10"), HostRoute(address: "100.64.0.5")]
            ).connectionSummary == "dev · 2 routes")
    }

    @Test(arguments: [("", "default"), ("   ", "default"), (" work ", "work")])
    func coreTransportSettingsCarryTheSelectedSession(session: String, expected: String) {
        let host = Host(
            address: "box.example", username: "dev", backend: .herdrCore, sessionName: session)
        let policy = HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false }
        let settings = SSHTransportSettings(
            host: host, credentials: .password("x"), hostKeyPolicy: policy)

        #expect(settings.backend == .herdrCore)
        #expect(settings.coreSessionName == expected)
        #expect(settings.herdrLauncher == nil)
        #expect(settings.hostKeyTrust == .host(host.id))
    }

    @Test func transportSettingsOfferEveryRouteAndTrustTheHost() {
        let host = Host(
            username: "dev",
            routes: [
                HostRoute(address: " 192.168.1.5 "),
                HostRoute(address: "127.0.0.1", port: 2222, jumpAddress: "vps.example"),
            ])
        let policy = HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false }

        let settings = SSHTransportSettings(
            host: host, credentials: .password("x"), hostKeyPolicy: policy)

        #expect(settings.routes.map(\.host) == ["192.168.1.5", "127.0.0.1"])
        #expect(settings.routes.map(\.port) == [22, 2222])
        #expect(settings.routes[0].jump == nil)
        #expect(settings.routes[1].jump?.host == "vps.example")
        #expect(settings.routes[1].jump?.username == "dev")
        #expect(settings.routes.map(\.isDirect) == [true, false])
        #expect(settings.routes.map(\.label) == ["192.168.1.5", "127.0.0.1:2222 via vps.example"])
        #expect(settings.hostKeyTrust == .host(host.id))
        #expect(settings.backend == .herdr)
    }
}

@Suite("Host draft routes")
struct HostDraftRouteTests {
    private func draft(addresses: [String]) -> HostDraft {
        var draft = HostDraft()
        draft.username = "dev"
        draft.routes = addresses.map { address in
            var route = HostRouteDraft()
            route.address = address
            return route
        }
        return draft
    }

    /// A new Host has no route until Add Route saves one.
    @Test func aNewHostStartsWithoutARouteAndCannotSave() {
        var draft = HostDraft()
        draft.username = "dev"
        #expect(draft.routes.isEmpty)
        #expect(!draft.canSave(editing: nil))

        draft.address = "192.168.1.5"
        #expect(draft.routes.count == 1)
        #expect(draft.canSave(editing: nil))
    }

    @Test func editingAHostKeepsItsRoutesInOrder() throws {
        let host = Host(
            username: "dev",
            routes: [HostRoute(address: "192.168.1.5"), HostRoute(address: "100.64.0.5")])

        let rebuilt = try #require(HostDraft(host: host).makeHost(id: host.id))

        #expect(rebuilt == host)
    }

    @Test func everyRouteMustBeValid() {
        var draft = draft(addresses: ["192.168.1.5", ""])
        #expect(!draft.isValid)
        #expect(draft.makeHost() == nil)

        draft.routes[1].address = "100.64.0.5"
        draft.routes[1].jumpAddress = "jump.example"
        draft.routes[1].jumpPort = "nope"
        #expect(!draft.isValid)

        draft.routes[1].jumpPort = "22"
        #expect(draft.isValid)
    }

    @Test func removingNeverLeavesAHostWithoutARoute() {
        var draft = draft(addresses: ["a", "b", "c"])

        draft.removeRoutes(atOffsets: [0, 2])
        #expect(draft.routes.map(\.address) == ["b"])

        draft.removeRoutes(atOffsets: [0])
        #expect(draft.routes.map(\.address) == ["b"])
    }

    @Test func movingReordersAsAListDoes() {
        var draft = draft(addresses: ["a", "b", "c"])

        draft.moveRoutes(fromOffsets: [2], toOffset: 0)
        #expect(draft.routes.map(\.address) == ["c", "a", "b"])

        draft.moveRoutes(fromOffsets: [0], toOffset: 3)
        #expect(draft.routes.map(\.address) == ["a", "b", "c"])
    }

    @Test func aPeerFillsTheRouteItWasChosenFor() {
        var draft = draft(addresses: ["192.168.1.5", ""])
        draft.routes[1].jumpAddress = ""
        let candidate = OverlayPeerCandidate(
            peer: OverlayPeer(
                id: "n1", name: "devbox", addresses: ["100.64.0.7"], isOnline: true))

        draft.applyOverlayPeer(candidate, toRoute: draft.routes[1].id)

        #expect(draft.routes.map(\.address) == ["192.168.1.5", "100.64.0.7"])
        #expect(draft.name == "devbox")
    }
}

@Suite("Route race")
struct RouteRaceTests {
    private struct Refused: Error, Equatable {
        let index: Int
    }

    /// Records which attempts started and lets a test release each one.
    private actor Script {
        private(set) var started: [Int] = []
        private var gates: [Int: CheckedContinuation<Result<String, Refused>, Never>] = [:]
        private var pending: [Int: Result<String, Refused>] = [:]

        func run(_ index: Int) async throws -> String {
            started.append(index)
            let result: Result<String, Refused>
            if let ready = pending.removeValue(forKey: index) {
                result = ready
            } else {
                result = await withCheckedContinuation { gates[index] = $0 }
            }
            return try result.get()
        }

        func finish(_ index: Int, _ result: Result<String, Refused>) {
            if let gate = gates.removeValue(forKey: index) {
                gate.resume(returning: result)
            } else {
                pending[index] = result
            }
        }
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record(comment)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aDirectWinnerNeverStartsTheDeferredRoutes() async throws {
        let script = Script()
        await script.finish(0, .success("lan"))

        let winner = try await RouteRace.first(
            count: 2, isDeferred: { $0 == 1 }, stagger: .seconds(30),
            attempt: { try await script.run($0) }, discard: { _ in })

        #expect(winner.index == 0)
        #expect(winner.value == "lan")
        #expect(await script.started == [0])
    }

    @Test func deferredRoutesStartOnceEveryDirectRouteFailed() async throws {
        let script = Script()
        await script.finish(0, .failure(Refused(index: 0)))
        await script.finish(1, .success("overlay"))

        let winner = try await RouteRace.first(
            count: 2, isDeferred: { $0 == 1 }, stagger: .seconds(30),
            attempt: { try await script.run($0) }, discard: { _ in })

        #expect(winner.index == 1)
        #expect(await script.started == [0, 1])
    }

    @Test func deferredRoutesStartAfterTheStaggerWhileADirectRouteHangs() async throws {
        let script = Script()
        await script.finish(1, .success("overlay"))
        let discarded = Mutex<[String]>([])

        let winner = try await RouteRace.first(
            count: 2, isDeferred: { $0 == 1 }, stagger: .milliseconds(20),
            attempt: { try await script.run($0) },
            discard: { value in discarded.withLock { $0.append(value) } })
        #expect(winner.index == 1)

        // The hanging route answers late: its connection is discarded.
        await script.finish(0, .success("late lan"))
        try await waitUntil("the late winner should be discarded") {
            discarded.withLock { $0 } == ["late lan"]
        }
    }

    @Test func withoutADirectRouteEveryRouteStartsAtOnce() async throws {
        let script = Script()
        await script.finish(1, .success("jump"))

        let winner = try await RouteRace.first(
            count: 2, isDeferred: { _ in false }, stagger: .seconds(30),
            attempt: { try await script.run($0) }, discard: { _ in })

        #expect(winner.index == 1)
        #expect(Set(await script.started) == [0, 1])
    }

    @Test func everyFailureIsReportedInRouteOrder() async throws {
        let script = Script()
        await script.finish(1, .failure(Refused(index: 1)))
        await script.finish(0, .failure(Refused(index: 0)))
        await script.finish(2, .failure(Refused(index: 2)))

        do {
            _ = try await RouteRace.first(
                count: 3, isDeferred: { $0 == 2 }, stagger: .seconds(30),
                attempt: { try await script.run($0) }, discard: { _ in })
            Issue.record("the race should fail")
        } catch let failure as RouteRace.Failure {
            #expect(failure.failures.compactMap { $0 as? Refused }.map(\.index) == [0, 1, 2])
        }
    }

    @Test func cancellingTheCallerCancelsTheRace() async throws {
        let script = Script()
        let race = Task {
            try await RouteRace.first(
                count: 1, isDeferred: { _ in false }, stagger: .seconds(30),
                attempt: { try await script.run($0) }, discard: { _ in })
        }
        try await waitUntil("the route should start") { await script.started == [0] }

        race.cancel()

        await #expect(throws: CancellationError.self) { try await race.value }
        await script.finish(0, .success("too late"))
    }
}

@Suite("Host key verification gate")
struct HostKeyVerificationGateTests {
    private actor Occupancy {
        private var active = 0
        private(set) var peak = 0

        func enter() {
            active += 1
            peak = max(peak, active)
        }

        func leave() {
            active -= 1
        }
    }

    @Test func verificationsRunOneAtATime() async throws {
        let gate = HostKeyVerificationGate()
        let occupancy = Occupancy()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await gate.withLock {
                        await occupancy.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await occupancy.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await occupancy.peak == 1)
    }

    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        let gate = HostKeyVerificationGate()
        let (holding, release) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await gate.withLock {
                for await _ in holding { return }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let waiter = Task { try await gate.withLock { "ran" } }
        try await Task.sleep(for: .milliseconds(20))

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        release.yield()
        release.finish()
        try await holder.value
        #expect(try await gate.withLock { "free" } == "free")
    }
}

@Suite("Host-scoped host key trust")
struct HostScopedTrustTests {
    private func hostKey(_ marker: String) -> HeelerSSH.SSHHostKey {
        let algorithm = "ssh-ed25519"
        var blob = Data()
        var length = UInt32(algorithm.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: algorithm.utf8)
        blob.append(contentsOf: marker.utf8)
        return HeelerSSH.SSHHostKey(algorithm: algorithm, key: blob)
    }

    @Test func everyRouteSharesTheTrustTheFirstConfirmed() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let hostID = UUID()
        let asked = Mutex<[String]>([])
        let policy = HostKeyPolicy(knownHosts: knownHosts) { candidate in
            asked.withLock { $0.append("\(candidate.host):\(candidate.port)") }
            return true
        }
        let key = hostKey("box")

        try await HeelerSSHHostKeyVerifier(
            host: "192.168.1.5", port: 22, trust: .host(hostID), policy: policy
        ).verify(key)
        try await HeelerSSHHostKeyVerifier(
            host: "100.64.0.5", port: 22, trust: .host(hostID), policy: policy
        ).verify(key)

        // The prompt names the endpoint dialled; the trust is the Host's.
        #expect(asked.withLock { $0 } == ["192.168.1.5:22"])
        let stored = HostKeyTrust.hostKey(hostID)
        #expect(
            await knownHosts.fingerprint(host: stored.host, port: stored.port)
                == HostKeyFingerprint(publicKeyBlob: key.key))
        #expect(await knownHosts.fingerprints(host: "192.168.1.5", port: 22).isEmpty)
    }

    /// Away from home, a LAN address may be answered by another machine;
    /// it is refused before authentication, however the route reached it.
    @Test func anotherMachineOnARouteIsAMismatch() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let hostID = UUID()
        let stored = HostKeyTrust.hostKey(hostID)
        let trusted = HostKeyFingerprint(publicKeyBlob: hostKey("box").key)
        await knownHosts.setFingerprint(trusted, host: stored.host, port: stored.port)
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in true }
        let other = hostKey("cafe-printer")

        await #expect(
            throws: TransportError.hostKeyMismatch(
                known: trusted, presented: HostKeyFingerprint(publicKeyBlob: other.key))
        ) {
            try await HeelerSSHHostKeyVerifier(
                host: "192.168.1.5", port: 22, trust: .host(hostID), policy: policy
            ).verify(other)
        }
    }

    /// A Host saved before Routes had its key trusted by endpoint; it is
    /// adopted, so upgrading never asks again.
    @Test func trustSavedByEndpointIsAdoptedWithoutAPrompt() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let hostID = UUID()
        let key = hostKey("box")
        let trusted = HostKeyFingerprint(publicKeyBlob: key.key)
        await knownHosts.setFingerprint(trusted, host: "box.example", port: 2222)
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in
            Issue.record("an adopted key must not prompt")
            return false
        }

        try await HeelerSSHHostKeyVerifier(
            host: "box.example", port: 2222, trust: .host(hostID), policy: policy
        ).verify(key)

        let stored = HostKeyTrust.hostKey(hostID)
        #expect(await knownHosts.fingerprint(host: stored.host, port: stored.port) == trusted)
    }

    @Test func endpointTrustIsNotAdoptedOnceTheHostHasItsOwn() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let hostID = UUID()
        let stored = HostKeyTrust.hostKey(hostID)
        let trusted = HostKeyFingerprint(publicKeyBlob: hostKey("box").key)
        await knownHosts.setFingerprint(trusted, host: stored.host, port: stored.port)
        let other = hostKey("other")
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: other.key), host: "127.0.0.1", port: 2222)
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in true }

        await #expect(throws: TransportError.self) {
            try await HeelerSSHHostKeyVerifier(
                host: "127.0.0.1", port: 2222, trust: .host(hostID), policy: policy
            ).verify(other)
        }
        #expect(await knownHosts.fingerprint(host: stored.host, port: stored.port) == trusted)
    }
}

@Suite("No route reached")
struct NoRouteReachedTests {
    private let mismatch = TransportError.hostKeyMismatch(
        known: HostKeyFingerprint(digest: Data(repeating: 1, count: 32)),
        presented: HostKeyFingerprint(digest: Data(repeating: 2, count: 32)))

    @Test func retryableWhileAnyRouteMayComeBack() {
        let error = TransportError.noRouteReached([
            RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: mismatch),
            RouteFailure(
                route: "100.64.0.5 over Home", mayNameAnotherMachine: false,
                error: .overlayFailed(network: "Home", reason: .timedOut)),
        ])

        #expect(error.isRetryable)
        // A LAN address answered by another machine while the overlay is
        // down is not, by itself, a security stop.
        #expect(!error.isHostKeySecurityFailure)
        #expect(error.presentation.summary == "No route reached the Host")
    }

    /// An Overlay Network address names the same machine wherever the device
    /// is, so its changed key is a security stop even while the LAN address
    /// only timed out, exactly as it is for a Host with one route.
    @Test func aChangedKeyOnAnOverlayRouteStopsTheRace() {
        let error = TransportError.noRouteReached([
            RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
            RouteFailure(route: "100.64.0.5 over Home", mayNameAnotherMachine: false, error: mismatch),
        ])

        #expect(error.isHostKeySecurityFailure)
        #expect(!error.isRetryable)
        #expect(error.presentation.summary == "The host key changed")
        #expect(
            error.presentation.detail
                == "192.168.1.5: Connection timed out; 100.64.0.5 over Home: The host key changed")
        #expect(
            error.presentation.recoverySuggestion == mismatch.presentation.recoverySuggestion)
    }

    /// The address behind a Jump Host is resolved there, wherever the device
    /// is, and the Jump Host's own key is trusted by its endpoint: either
    /// changing is a security stop.
    @Test func aChangedKeyBehindOrAtAJumpHostStopsTheRace() {
        for failure in [mismatch, .jumpHostFailed(mismatch)] {
            let error = TransportError.noRouteReached([
                RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
                RouteFailure(
                    route: "127.0.0.1:2222 via vps.example", mayNameAnotherMachine: false, error: failure),
            ])

            #expect(error.isHostKeySecurityFailure)
            #expect(!error.isRetryable)
        }
    }

    /// A public address or DNS name answers as the same machine wherever
    /// the device is, so a direct route to one is held to its key.
    @Test func aChangedKeyAtAPublicDirectAddressStopsTheRace() {
        let error = TransportError.noRouteReached([
            RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
            RouteFailure(route: "box.example", mayNameAnotherMachine: false, error: mismatch),
        ])

        #expect(error.isHostKeySecurityFailure)
        #expect(!error.isRetryable)
        #expect(error.presentation.summary == "The host key changed")
    }

    @Test func onlyADirectRouteToALocalAddressMayNameAnotherMachine() {
        let local = [
            "192.168.1.5", "10.0.0.5", "172.16.0.1", "172.31.255.1", "127.0.0.1",
            "169.254.10.1", "::1", "fd12:3456::1", "fe80::1%en0", "[fe80::1]", "nas",
            "localhost", "nas.local", "nas.local.", "box.home.arpa", "box.lan", "box.internal",
        ]
        let sameMachine = [
            "172.32.0.1", "100.64.0.5", "203.0.113.5", "2001:db8::1", "box.example",
            "vps.example.com",
        ]
        for address in local {
            #expect(SSHRoute(host: address, port: 22).mayNameAnotherMachine, "\(address)")
        }
        for address in sameMachine {
            #expect(!SSHRoute(host: address, port: 22).mayNameAnotherMachine, "\(address)")
        }

        let jump = SSHJumpSettings(
            host: "vps.example", port: 22, username: "dev", credentials: .password("x"))
        let overlay = OverlayRoute(networkName: "Home") { _, _, _ in
            throw TransportError.timedOut
        }
        #expect(!SSHRoute(host: "192.168.1.5", port: 22, jump: jump).mayNameAnotherMachine)
        #expect(!SSHRoute(host: "192.168.1.5", port: 22, overlay: overlay).mayNameAnotherMachine)
    }

    @Test func aRouteNamesItsJumpHostPort() {
        let jump = SSHJumpSettings(
            host: "vps.example", port: 2022, username: "dev", credentials: .password("x"))

        #expect(
            SSHRoute(host: "127.0.0.1", port: 2222, jump: jump).label
                == "127.0.0.1:2222 via vps.example:2022")
    }

    @Test func stopsWhenNoRouteCanRecoverOnItsOwn() {
        let error = TransportError.noRouteReached([
            RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: mismatch),
            RouteFailure(route: "100.64.0.5", mayNameAnotherMachine: false, error: mismatch),
        ])

        #expect(!error.isRetryable)
        #expect(error.isHostKeySecurityFailure)
    }

    @Test func presentationNamesEachRoute() {
        let error = TransportError.noRouteReached([
            RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
            RouteFailure(
                route: "127.0.0.1:2222 via vps.example", mayNameAnotherMachine: false,
                error: .authenticationFailed),
        ])

        #expect(error.presentation.summary == "No route reached the Host")
        #expect(
            error.presentation.detail
                == "192.168.1.5: Connection timed out; "
                + "127.0.0.1:2222 via vps.example: Authentication failed")
    }

    @Test func preflightGivesEachRouteItsOwnHint() throws {
        let report = PreflightReport.failure(
            .noRouteReached([
                RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
                RouteFailure(
                    route: "100.64.0.5 over Home", mayNameAnotherMachine: false,
                    error: .overlayFailed(network: "Home", reason: .signedOut)),
            ]),
            authMethod: .deviceKey)

        guard case .failed(let hint) = report[.connection] else {
            Issue.record("the connection check should fail")
            return
        }
        #expect(
            hint
                == "192.168.1.5: The Host did not answer in time. Check the connection and try "
                + "again.\n100.64.0.5 over Home: This device is signed out of overlay network "
                + "“Home”. Connect it again in Settings › Overlay Networks, then run the checks "
                + "again.")
    }

    @Test func aRouteWaitingForSignInOffersIt() throws {
        let url = try #require(URL(string: "https://login.tailscale.com/a/1"))
        let error = TransportError.noRouteReached([
            RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
            RouteFailure(
                route: "devbox over Home", mayNameAnotherMachine: false,
                error: .overlayFailed(network: "Home", reason: .loginRequired(url))),
        ])

        #expect(error.overlayLoginURL == url)
    }
}
