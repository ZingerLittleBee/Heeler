import CHeelerOverlaySupport
import CZeroTier
import Foundation
import Testing

@testable import HeelerOverlay

/// How a ZeroTier dial's native result reaches the caller, and the
/// argument checks of the CZeroTier calls `heeler_zt_connect` makes before
/// it binds a socket to its network. Routing itself needs joined networks:
/// see `ZeroTierDupIPTests`.
@Suite("ZeroTier dial results")
struct ZeroTierDialTests {
    private let networkID: UInt64 = 0x8056_c2e2_1c00_0001

    @Test func anUnreachableAddressFailsWithItsNetwork() {
        #expect(
            ZeroTierNetworkNode.dialError(
                status: Int32(HEELER_OVERLAY_ERR_NO_ROUTE), address: "192.168.77.10", networkID: networkID)
                == .dialFailed("192.168.77.10 is not reachable on ZeroTier network 8056c2e21c000001"))
    }

    @Test func otherResultsKeepTheirMeaning() {
        func error(_ status: Int32, _ address: String = "10.0.0.2") -> OverlayError {
            ZeroTierNetworkNode.dialError(status: status, address: address, networkID: networkID)
        }
        #expect(error(Int32(HEELER_OVERLAY_ERR_NO_SOURCE)) == .dialFailed(
            "This device has no IPv4 address on ZeroTier network 8056c2e21c000001 to reach 10.0.0.2 from."))
        #expect(error(Int32(HEELER_OVERLAY_ERR_NO_SOURCE), "fd00::2") == .dialFailed(
            "This device has no IPv6 address on ZeroTier network 8056c2e21c000001 to reach fd00::2 from."))
        #expect(error(Int32(HEELER_OVERLAY_ERR_TIMEOUT)) == .timedOut)
        #expect(error(Int32(HEELER_OVERLAY_ERR_CANCELLED)) == .cancelled)
        #expect(error(Int32(HEELER_OVERLAY_ERR_REFUSED))
            == .dialFailed("The peer refused or reset the connection."))
        #expect(error(Int32(HEELER_OVERLAY_ERR_SOCKET))
            == .dialFailed("Could not open a ZeroTier connection (-2)."))
    }

    @Test func noRouteIsItsOwnResultCode() {
        let codes: [Int32] = [
            Int32(HEELER_OVERLAY_ERR_ARGUMENT), Int32(HEELER_OVERLAY_ERR_SOCKET),
            Int32(HEELER_OVERLAY_ERR_TIMEOUT), Int32(HEELER_OVERLAY_ERR_REFUSED),
            Int32(HEELER_OVERLAY_ERR_RESOURCES), Int32(HEELER_OVERLAY_ERR_CANCELLED),
            Int32(HEELER_OVERLAY_ERR_NO_SOURCE), Int32(HEELER_OVERLAY_ERR_NO_ROUTE),
        ]
        #expect(Set(codes).count == codes.count)
        #expect(Int32(HEELER_OVERLAY_ERR_NO_ROUTE) == -8)
        // The CZeroTier code it translates.
        #expect(HEELER_ZT_ERR_NO_ROUTE == -110)
    }

    @Test func reachabilityAndBindingRefuseBadArguments() {
        var address = in_addr()
        inet_pton(AF_INET, "10.0.0.2", &address)
        let noNetwork = withUnsafeBytes(of: &address) {
            heeler_zt_network_reaches(0, Int32(ZTS_AF_INET), $0.baseAddress)
        }
        #expect(noNetwork == ZTS_ERR_ARG.rawValue)
        #expect(heeler_zt_network_reaches(networkID, Int32(ZTS_AF_INET), nil) == ZTS_ERR_ARG.rawValue)
        let badFamily = withUnsafeBytes(of: &address) {
            heeler_zt_network_reaches(networkID, 12345, $0.baseAddress)
        }
        #expect(badFamily == ZTS_ERR_ARG.rawValue)
    }

    @Test func aDialWithoutAnAddressOnTheNetworkNeverOpensASocket() {
        // Without the network joined there is no source address: the dial
        // stops before any reachability check or socket.
        var descriptor: Int32 = -1
        let status = heeler_zt_connect("10.0.0.2", 22, networkID, 100, nil, &descriptor)
        #expect(status == Int32(HEELER_OVERLAY_ERR_NO_SOURCE))
        #expect(descriptor == -1)
    }
}
