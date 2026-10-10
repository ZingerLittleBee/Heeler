import CZeroTier
import Foundation
import Testing

@testable import HeelerOverlay

/// Brings the real libzt node online against ZeroTier's public roots. Needs
/// Internet access, so it only runs with `HEELER_OVERLAY_LIVE=1`. With
/// `HEELER_OVERLAY_ZT_NETWORK=<16 hex digits>` it also joins that network
/// (the node must be authorized there, or the join reports it).
@Suite(
    "ZeroTier live node",
    .enabled(if: ProcessInfo.processInfo.environment["HEELER_OVERLAY_LIVE"] == "1"))
struct ZeroTierLiveTests {
    /// One test, because the process's libzt node starts once: it starts with
    /// an identity minted up front, as the app does before the first join.
    @Test(.timeLimit(.minutes(2)))
    func nodeComesOnlineWithAGeneratedIdentity() async throws {
        let generated = try ZeroTierIdentity.generate()
        let nodeID = try #require(ZeroTierIdentity.nodeID(of: generated))
        let identity = try await ZeroTierRuntime.shared.startNode(
            identity: generated, deadline: OverlayDeadline(after: .seconds(90)))
        #expect(identity == generated)
        // The running node's own ID is the one the identity names.
        let runningID = await ZeroTierRuntime.call { zts_node_get_id() }
        #expect(ZeroTierNodeID.format(runningID) == nodeID)
        #expect(await ZeroTierRuntime.shared.details(joinedNetwork: nil).nodeID == nodeID)
        // Starting again is idempotent and keeps the same identity.
        let again = try await ZeroTierRuntime.shared.startNode(
            identity: nil, deadline: OverlayDeadline(after: .seconds(10)))
        #expect(again == generated)

        // The node talks to the planet's roots; they are listed as such.
        let raw = await ZeroTierRuntime.call { ZeroTierPeers.read() }
        #expect(raw.contains { $0.role == 2 })
        #expect(ZeroTierPeers.overlayPeers(raw).contains { $0.role == "planet" })

        guard let network = ProcessInfo.processInfo.environment["HEELER_OVERLAY_ZT_NETWORK"]
            .flatMap(ZeroTierNetworkID.parse)
        else { return }
        let reported = Recorder()
        let node = OverlayNodes.zerotier(
            ZeroTierConfiguration(networkID: network, identity: nil),
            identityGenerated: { reported.record($0.count) })
        try await node.start(timeout: .seconds(60))
        guard case .online(let addresses) = await node.status() else {
            Issue.record("network did not come online")
            return
        }
        #expect(!addresses.isEmpty)
        #expect(reported.values == [generated.count])
        let details = await node.details()
        #expect(details.nodeID == nodeID)
        #expect(details.addresses == addresses)
        #expect(details.peers != nil)
        await node.stop()
        #expect(await node.status() == .stopped)
    }
}
