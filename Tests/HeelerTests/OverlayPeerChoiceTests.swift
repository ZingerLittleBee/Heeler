import Foundation
import HeelerOverlay
import Synchronization
import Testing

@testable import Heeler

private let tailscalePeer = OverlayPeer(
    id: "n1", name: "devbox", addresses: ["fd7a:115c:a1e0::1", "100.64.0.7"], isOnline: true)

@Suite("Overlay peer choice")
struct OverlayPeerChoiceTests {
    @Test func tailscalePeerFillsItsIPv4AndABlankName() {
        var draft = HostDraft()
        draft.applyOverlayPeer(OverlayPeerCandidate(peer: tailscalePeer))
        #expect(draft.address == "100.64.0.7")
        #expect(draft.name == "devbox")
    }

    @Test func machineNameStyleFillsTheTailscaleName() {
        var draft = HostDraft()
        draft.applyOverlayPeer(OverlayPeerCandidate(peer: tailscalePeer), style: .machineName)
        #expect(draft.address == "devbox")
    }

    @Test func aNamelessPeerFallsBackToItsAddressForEitherStyle() {
        let candidate = OverlayPeerCandidate(peer: OverlayPeer(id: "n2", addresses: ["fd7a::2"]))
        var draft = HostDraft()
        draft.applyOverlayPeer(candidate, style: .machineName)
        #expect(draft.address == "fd7a::2")
        #expect(draft.name.isEmpty)
        #expect(candidate.displayName == "n2")
    }

    @Test func aTypedNameIsKept() {
        var draft = HostDraft()
        draft.name = "Work"
        draft.applyOverlayPeer(OverlayPeerCandidate(peer: tailscalePeer))
        #expect(draft.name == "Work")
        #expect(draft.address == "100.64.0.7")
    }

    @Test func easyTierPeerFillsItsVirtualIPv4WithoutPrefix() {
        let peer = OverlayPeer(id: "42", name: "nas", addresses: ["10.144.144.9/24"], isOnline: true)
        var draft = HostDraft()
        draft.applyOverlayPeer(OverlayPeerCandidate(peer: peer))
        #expect(draft.address == "10.144.144.9")
        #expect(draft.name == "nas")
    }

    @Test func withAJumpHostThePeerIsTheJumpHost() {
        var draft = HostDraft()
        draft.address = "127.0.0.1"
        draft.jumpAddress = "old-jump"
        #expect(draft.overlayPeerTarget == .jumpHost)
        draft.applyOverlayPeer(OverlayPeerCandidate(peer: tailscalePeer))
        #expect(draft.jumpAddress == "100.64.0.7")
        #expect(draft.address == "127.0.0.1")
        #expect(draft.name.isEmpty)
    }

    @Test func settingsPrefillNamesTheNetwork() {
        let networkID = UUID()
        let draft = HostDraft(overlayPeer: OverlayPeerCandidate(peer: tailscalePeer), networkID: networkID)
        #expect(draft.overlayNetworkID == networkID)
        #expect(draft.address == "100.64.0.7")
        #expect(draft.name == "devbox")
        #expect(draft.port == "22")
    }

    @Test func aPeerIsAHostWhenAHostOnItsNetworkDialsItsAddressOrName() {
        let networkID = UUID()
        let candidate = OverlayPeerCandidate(peer: tailscalePeer)
        let byIPv4 = Host(address: "100.64.0.7", username: "me", overlayNetworkID: networkID)
        let byIPv6 = Host(address: "[FD7A:115C:A1E0::1]", username: "me", overlayNetworkID: networkID)
        let byName = Host(address: "devbox", username: "me", overlayNetworkID: networkID)
        let byMagicDNS = Host(
            address: "DevBox.tail1234.ts.net.", username: "me", overlayNetworkID: networkID)
        let viaJump = Host(
            address: "127.0.0.1", username: "me", jumpAddress: "100.64.0.7",
            overlayNetworkID: networkID)

        for host in [byIPv4, byIPv6, byName, byMagicDNS, viaJump] {
            #expect(
                OverlayPeerList.host(for: candidate, networkID: networkID, among: [host])?.id
                    == host.id, "\(host.address) \(host.jumpAddress)")
        }
    }

    @Test func aPeerIsNotAHostElsewhereOrUnderAnotherName() {
        let networkID = UUID()
        let candidate = OverlayPeerCandidate(peer: tailscalePeer)
        let hosts = [
            // Same address, but direct or on another network.
            Host(address: "100.64.0.7", username: "me"),
            Host(address: "100.64.0.7", username: "me", overlayNetworkID: UUID()),
            // Another machine whose name starts like this one's.
            Host(address: "devbox2", username: "me", overlayNetworkID: networkID),
            // Behind a Jump Host that is another machine.
            Host(
                address: "100.64.0.7", username: "me", jumpAddress: "100.64.0.9",
                overlayNetworkID: networkID),
        ]
        #expect(OverlayPeerList.host(for: candidate, networkID: networkID, among: hosts) == nil)
    }

    /// Add on a machine in Settings fills its address, so the form's
    /// "Choose from Tailnet…" shows that machine as chosen.
    @Test func theFormsAddressChoosesItsPeerAndTheStyleItUses() {
        let other = OverlayPeerCandidate(
            peer: OverlayPeer(id: "n3", name: "nas", addresses: ["100.64.0.9"]))
        let devbox = OverlayPeerCandidate(peer: tailscalePeer)
        let candidates = [other, devbox]

        let prefilled = HostDraft(overlayPeer: devbox, networkID: UUID())
        #expect(OverlayPeerList.chosen(among: candidates, address: prefilled.overlayPeerAddress)?.id == "n1")
        #expect(OverlayPeerList.style(dialing: prefilled.overlayPeerAddress, devbox) == .ipAddress)

        for address in ["devbox", "DevBox.tail1234.ts.net."] {
            #expect(OverlayPeerList.chosen(among: candidates, address: address)?.id == "n1", "\(address)")
            #expect(OverlayPeerList.style(dialing: address, devbox) == .machineName, "\(address)")
        }
        #expect(OverlayPeerList.chosen(among: candidates, address: "[fd7a:115c:a1e0::1]")?.id == "n1")
        for address in ["", "  ", "100.64.0.8", "devbox2"] {
            #expect(OverlayPeerList.chosen(among: candidates, address: address) == nil, "\(address)")
        }
    }

    @Test func withAJumpHostTheJumpHostIsTheChosenAddress() {
        var draft = HostDraft()
        draft.address = "127.0.0.1"
        draft.jumpAddress = "100.64.0.7"
        #expect(draft.overlayPeerAddress == "100.64.0.7")
        #expect(OverlayPeerList.chosen(
            among: [OverlayPeerCandidate(peer: tailscalePeer)], address: draft.overlayPeerAddress)?.id == "n1")
    }

    @Test func onlinePeersComeFirstThenByNameAndAddresslessOnesAreDropped() {
        let peers = [
            OverlayPeer(id: "a", name: "zeta", addresses: ["100.64.0.1"], isOnline: true),
            OverlayPeer(id: "b", name: "alpha", addresses: ["100.64.0.2"], isOnline: false),
            OverlayPeer(id: "c", name: "Beta", addresses: ["100.64.0.3"], isOnline: nil),
            OverlayPeer(id: "d", name: "relay", addresses: [], isOnline: true),
            OverlayPeer(id: "e", name: "box10", addresses: ["100.64.0.5"], isOnline: true),
            OverlayPeer(id: "f", name: "box9", addresses: ["100.64.0.6"], isOnline: true),
        ]
        let names = OverlayPeerList.candidates(from: peers).map(\.displayName)
        #expect(names == ["Beta", "box9", "box10", "zeta", "alpha"])
    }

    @Test func searchMatchesNamesAndAddressesIgnoringCase() {
        let candidates = OverlayPeerList.candidates(from: [
            OverlayPeer(id: "a", name: "DevBox", addresses: ["100.64.0.1"]),
            OverlayPeer(id: "b", name: "nas", addresses: ["100.64.0.22"]),
        ])
        #expect(OverlayPeerList.filter(candidates, query: "devb").map(\.id) == ["a"])
        #expect(OverlayPeerList.filter(candidates, query: ".22").map(\.id) == ["b"])
        #expect(OverlayPeerList.filter(candidates, query: "  ").count == 2)
        #expect(OverlayPeerList.filter(candidates, query: "router").isEmpty)
    }

    @Test func configServerPeersCarryTheirNetworkForGroupingAndSearch() {
        let peers = [
            OverlayPeer(id: "i1/7", name: "box", addresses: ["10.144.144.2"], network: "home"),
            OverlayPeer(id: "i2/7", name: "box", addresses: ["10.144.144.2"], network: "lab"),
            OverlayPeer(id: "i1/8", name: "nas", addresses: ["10.144.144.3"], network: "home"),
        ]
        let groups = OverlayPeerList.groupedByNetwork(peers)
        #expect(groups.map(\.network) == ["home", "lab"])
        #expect(groups.map { $0.peers.map(\.id) } == [["i1/7", "i1/8"], ["i2/7"]])
        let candidates = OverlayPeerList.candidates(from: peers)
        // The same name and address on two networks stay two candidates.
        #expect(Set(candidates.map(\.id)) == ["i1/7", "i2/7", "i1/8"])
        #expect(OverlayPeerList.filter(candidates, query: "LAB").map(\.id) == ["i2/7"])
        #expect(candidates.first { $0.id == "i2/7" }?.network == "lab")
        // A node with one network has one unnamed group.
        let single = OverlayPeerList.groupedByNetwork([OverlayPeer(id: "a"), OverlayPeer(id: "b")])
        #expect(single.count == 1 && single[0].network == nil && single[0].peers.count == 2)
    }

    @Test func aConfigServersPeersGroupByItsNetworksInItsOrder() {
        let assigned = [
            OverlayAssignedNetwork(
                id: "i1", name: "home", isRunning: true, address: "10.144.144.9/24", peerCount: 1),
            OverlayAssignedNetwork(id: "i2", name: "lab", isRunning: false, error: "overlaps home"),
            OverlayAssignedNetwork(id: "i3", name: "", isRunning: true, address: "10.126.0.4/16"),
        ]
        let peers = [
            OverlayPeer(id: "a", network: "stray"),
            OverlayPeer(id: "b", network: "home"),
        ]
        let groups = OverlayPeerList.assignedGroups(peers, assigned: assigned)

        #expect(groups.map(\.header) == ["home · 10.144.144.0/24", "lab", "i3 · 10.126.0.0/16", "stray"])
        #expect(groups[0].peers.map(\.id) == ["b"])
        #expect(groups[1].error == "overlaps home" && groups[1].peers.isEmpty)
        #expect(groups[3].peers.map(\.id) == ["a"])
    }

    @Test func anIPv4SubnetComesFromTheAddressAndItsPrefix() {
        #expect(OverlayPeerList.ipv4Subnet("10.144.144.9/24") == "10.144.144.0/24")
        #expect(OverlayPeerList.ipv4Subnet("172.16.5.4/12") == "172.16.0.0/12")
        #expect(OverlayPeerList.ipv4Subnet("10.0.0.1/32") == "10.0.0.1/32")
        #expect(OverlayPeerList.ipv4Subnet("10.0.0.1/0") == "0.0.0.0/0")
        #expect(OverlayPeerList.ipv4Subnet("10.0.0.1") == nil)
        #expect(OverlayPeerList.ipv4Subnet("10.0..1/24") == nil)
        #expect(OverlayPeerList.ipv4Subnet("fd00::1/64") == nil)
    }

    @Test func zeroTierOffersNoPeersAndOnlyTailscaleOffersNames() {
        #expect(!OverlayPeerList.offersPeers(.zerotier))
        #expect(OverlayPeerList.offersPeers(.tailscale))
        #expect(OverlayPeerList.offersPeers(.easytier))
        #expect(OverlayPeerList.offersMachineNames(.tailscale))
        #expect(!OverlayPeerList.offersMachineNames(.easytier))
    }

    @MainActor
    @Test func pickerModelLoadsSortedCandidatesOrKeepsTheFailure() async {
        let model = OverlayPeerPickerModel { startIfNeeded in
            #expect(startIfNeeded)
            return [
                OverlayPeer(id: "b", name: "b", addresses: ["100.64.0.2"], isOnline: false),
                OverlayPeer(id: "a", name: "a", addresses: ["100.64.0.1"], isOnline: true),
            ]
        }
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.candidates(matching: "").map(\.id) == ["a", "b"])

        let failure = TransportError.overlayFailed(network: "Home", reason: .signedOut)
        let failing = OverlayPeerPickerModel { _ in throw failure }
        await failing.load()
        #expect(failing.phase == .failed(failure))
        #expect(failing.candidates(matching: "").isEmpty)
    }

    @MainActor
    @Test func pickerModelCancelsAConnectAtOnceAndCanLoadAgain() async throws {
        let hangs = HangSwitch()
        let model = OverlayPeerPickerModel { _ in
            if hangs.isOn {
                // Like a node still coming up: only cancellation ends it.
                try await Task.sleep(for: .seconds(30))
                throw TransportError.overlayFailed(network: "Home", reason: .timedOut)
            }
            return [OverlayPeer(id: "a", name: "a", addresses: ["100.64.0.1"])]
        }
        let loading = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(50))
        model.cancel()
        #expect(model.phase == .cancelled)
        await loading.value
        // The abandoned load reports nothing, least of all a timeout.
        #expect(model.phase == .cancelled)

        hangs.isOn = false
        await model.load()
        #expect(model.candidates(matching: "").map(\.id) == ["a"])
    }
}

/// A node whose start outcome and peers a test sets.
private final class PeerNode: OverlayNode, Sendable {
    struct State {
        var starts = 0
        var status: OverlayNodeStatus = .stopped
        var statusAfterStart: OverlayNodeStatus = .online(addresses: ["100.64.0.2"])
        var failure: OverlayError?
        var peers: [OverlayPeer]? = [tailscalePeer]
    }

    let kind: OverlayKind
    let state: Mutex<State>

    init(kind: OverlayKind, state: State) {
        self.kind = kind
        self.state = Mutex(state)
    }

    func start(timeout: Duration) async throws {
        let failure = state.withLock { state -> OverlayError? in
            state.starts += 1
            if state.failure == nil { state.status = state.statusAfterStart }
            return state.failure
        }
        if let failure { throw failure }
    }

    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        OverlayDialedStream(descriptor: -1, release: {})
    }

    func status() async -> OverlayNodeStatus { state.withLock { $0.status } }
    func stop() async { state.withLock { $0.status = .stopped } }
    func details() async -> OverlayNodeDetails {
        OverlayNodeDetails(peers: state.withLock { $0.peers })
    }
    func logout(timeout: Duration) async throws {}
}

/// The nodes a test runtime built.
private final class BuiltNodes: Sendable {
    private let nodes = Mutex<[PeerNode]>([])

    func append(_ node: PeerNode) { nodes.withLock { $0.append(node) } }
    var all: [PeerNode] { nodes.withLock { $0 } }
    var starts: [Int] { all.map { node in node.state.withLock { $0.starts } } }
}

@Suite("Overlay runtime peers")
struct OverlayRuntimePeersTests {
    private let network = OverlayNetwork(
        name: "Home", settings: .tailscale(hostname: "heeler", controlURL: nil))

    private func runtime(_ state: PeerNode.State) -> (OverlayNetworkRuntime, BuiltNodes) {
        let built = BuiltNodes()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(),
            stateRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("overlay-peers-\(UUID().uuidString)", isDirectory: true),
            makeNode: { spec, _ in
                let kind: OverlayKind =
                    switch spec {
                    case .tailscale: .tailscale
                    case .zerotier: .zerotier
                    case .easytier: .easytier
                    }
                let node = PeerNode(kind: kind, state: state)
                built.append(node)
                return node
            })
        runtime.publish([.init(network: network)])
        return (runtime, built)
    }

    @Test func startsAStoppedNodeThenReportsItsPeers() async throws {
        let (runtime, built) = runtime(PeerNode.State())
        let peers = try await runtime.peers(networkID: network.id, startIfNeeded: true)
        #expect(peers == [tailscalePeer])
        #expect(built.starts == [1])

        // Online now: asking again does not start it again.
        _ = try await runtime.peers(networkID: network.id, startIfNeeded: false)
        #expect(built.starts == [1])
    }

    @Test func aStoppedNodeIsNotStartedUnlessAsked() async {
        let (runtime, built) = runtime(PeerNode.State())
        await #expect(
            throws: TransportError.overlayFailed(
                network: "Home", reason: .notReady("The network is not connected"))
        ) {
            _ = try await runtime.peers(networkID: network.id, startIfNeeded: false)
        }
        #expect(built.all.isEmpty)
    }

    @Test func startFailuresMapIntoTheTransportTaxonomy() async throws {
        let login = try #require(URL(string: "https://login.tailscale.com/a/1"))
        var state = PeerNode.State()
        state.failure = .loginRequired(login)
        let (needsLogin, _) = runtime(state)
        await #expect(throws: TransportError.overlayFailed(network: "Home", reason: .loginRequired(login))) {
            _ = try await needsLogin.peers(networkID: network.id, startIfNeeded: true)
        }

        state.failure = .startFailed("bad key")
        let (failing, _) = runtime(state)
        await #expect(throws: TransportError.overlayFailed(network: "Home", reason: .notReady("bad key"))) {
            _ = try await failing.peers(networkID: network.id, startIfNeeded: true)
        }
    }

    @Test func aNodeThatStartsWithoutComingOnlineIsNotReady() async throws {
        let login = try #require(URL(string: "https://login.tailscale.com/a/2"))
        var state = PeerNode.State()
        state.statusAfterStart = .needsLogin(login)
        let (needsLogin, _) = runtime(state)
        await #expect(throws: TransportError.overlayFailed(network: "Home", reason: .loginRequired(login))) {
            _ = try await needsLogin.peers(networkID: network.id, startIfNeeded: true)
        }

        state.statusAfterStart = .waiting("Awaiting approval")
        let (waiting, _) = runtime(state)
        await #expect(
            throws: TransportError.overlayFailed(network: "Home", reason: .notReady("Awaiting approval"))
        ) {
            _ = try await waiting.peers(networkID: network.id, startIfNeeded: true)
        }
    }

    @Test func aNodeWithoutPeerReportsGivesNoPeers() async throws {
        var state = PeerNode.State()
        state.peers = nil
        let (runtime, _) = runtime(state)
        #expect(try await runtime.peers(networkID: network.id, startIfNeeded: true).isEmpty)
    }

    @Test func aSignedOutTailnetStaysSignedOut() async throws {
        let (runtime, built) = runtime(PeerNode.State())
        try await runtime.logout(networkID: network.id, timeout: .seconds(1))
        await #expect(throws: TransportError.overlayFailed(network: "Home", reason: .signedOut)) {
            _ = try await runtime.peers(networkID: network.id, startIfNeeded: true)
        }
        // Only the node built for the logout; nothing was started.
        #expect(built.starts.allSatisfy { $0 == 0 })
    }

    @Test func anUnknownNetworkIsNotConfigured() async {
        let (runtime, _) = runtime(PeerNode.State())
        await #expect(throws: TransportError.overlayFailed(network: "Overlay network", reason: .notConfigured)) {
            _ = try await runtime.peers(networkID: UUID(), startIfNeeded: true)
        }
    }
}

@MainActor
private final class HangSwitch {
    var isOn = true
}
