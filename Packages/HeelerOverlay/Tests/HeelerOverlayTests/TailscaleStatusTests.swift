import Foundation
import Testing

@testable import HeelerOverlay

@Suite("Tailscale status JSON")
struct TailscaleStatusTests {
    @Test func runningNodeReportsItsAddressesIPv4First() throws {
        let json = """
            {"Version":"1.94.1","TUN":false,"BackendState":"Running","HaveNodeKey":true,
             "AuthURL":"","TailscaleIPs":["fd7a:115c:a1e0::1","100.101.102.103"],
             "Self":{"ID":"n1","HostName":"heeler","Online":true},
             "Health":[],"MagicDNSSuffix":"tail1234.ts.net","Peer":{"k":{"HostName":"box"}}}
            """
        let status = try TailscaleStatus.decode(Data(json.utf8))

        #expect(status.backendState == .running)
        #expect(status.addresses == ["100.101.102.103", "fd7a:115c:a1e0::1"])
        #expect(status.progress == .online(addresses: ["100.101.102.103", "fd7a:115c:a1e0::1"]))
        #expect(status.nodeStatus == .online(addresses: ["100.101.102.103", "fd7a:115c:a1e0::1"]))
    }

    @Test func needsLoginWithAuthURLAsksForInteractiveLogin() throws {
        let json = """
            {"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc123",
             "TailscaleIPs":null}
            """
        let status = try TailscaleStatus.decode(Data(json.utf8))
        let url = try #require(URL(string: "https://login.tailscale.com/a/abc123"))

        #expect(status.backendState == .needsLogin)
        #expect(status.progress == .needsLogin(url))
        #expect(status.nodeStatus == .needsLogin(url))
        #expect(status.addresses.isEmpty)
    }

    @Test func needsLoginBeforeTheURLArrivesKeepsWaiting() throws {
        let status = try TailscaleStatus.decode(Data(#"{"BackendState":"NeedsLogin","AuthURL":""}"#.utf8))

        #expect(status.authURL == nil)
        #expect(status.progress == .waiting)
        #expect(status.nodeStatus == .starting)
    }

    @Test func authURLMustBeAWebURL() throws {
        let status = try TailscaleStatus.decode(
            Data(#"{"BackendState":"NeedsLogin","AuthURL":"file:///etc/passwd"}"#.utf8))

        #expect(status.authURL == nil)
        #expect(status.progress == .waiting)
    }

    @Test func machineAuthorizationIsAFailureTheUserMustResolve() throws {
        let status = try TailscaleStatus.decode(Data(#"{"BackendState":"NeedsMachineAuth"}"#.utf8))

        guard case .failed(let message) = status.progress else {
            Issue.record("expected a failure, got \(status.progress)")
            return
        }
        #expect(message.contains("approval"))
        // The node stays up awaiting approval, which can still arrive.
        #expect(status.nodeStatus == .waiting(message))
    }

    @Test func transientStatesWait() throws {
        for state in ["NoState", "Starting", "Stopped", "SomethingNew"] {
            let status = try TailscaleStatus.decode(Data(#"{"BackendState":"\#(state)"}"#.utf8))
            #expect(status.progress == .waiting, "\(state)")
        }
        // Running before an address is assigned is still starting.
        let running = try TailscaleStatus.decode(Data(#"{"BackendState":"Running","TailscaleIPs":[]}"#.utf8))
        #expect(running.progress == .waiting)
    }

    @Test func selfNameWaitsForTheNetworkMap() throws {
        // Before a network map, tsnet reports the OS host name, not the name
        // the tailnet will use, so no name is shown yet.
        let json = """
            {"BackendState":"NeedsLogin","Self":{"ID":"","HostName":"Someones-MacBook-Pro","DNSName":""}}
            """
        let details = try TailscaleStatus.decode(Data(json.utf8)).details
        #expect(details.hostname == nil)
    }

    @Test func detailsDescribeSelfAndPeers() throws {
        let json = """
            {"BackendState":"Running","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1"],
             "Self":{"ID":"nSelf123CNTRL","HostName":"iPhone","DNSName":"heeler-phone.tail1234.ts.net.",
                     "TailscaleIPs":["100.101.102.103"],"Online":true},
             "Peer":{
              "nodekey:bb":{"ID":"nBox","HostName":"Build Box","DNSName":"build-box.tail1234.ts.net.",
                            "TailscaleIPs":["fd7a:115c:a1e0::2","100.64.0.2"],"Online":true,"Active":true,
                            "CurAddr":"203.0.113.5:41641","Relay":"fra"},
              "nodekey:aa":{"ID":"nRelay","HostName":"relayed","DNSName":"","TailscaleIPs":["100.64.0.3"],
                            "Online":true,"Active":true,"CurAddr":"","Relay":"sfo"},
              "nodekey:cc":{"ID":"nIdle","HostName":"zz-idle","DNSName":"zz-idle.tail1234.ts.net.",
                            "TailscaleIPs":["100.64.0.4"],"Online":false,"Active":false,"CurAddr":"","Relay":"fra"},
              "nodekey:dd":{"HostName":"","DNSName":"","Active":true,"PeerRelay":"198.51.100.7:7777:1"}
             }}
            """
        let details = try TailscaleStatus.decode(Data(json.utf8)).details

        #expect(details.nodeID == "nSelf123CNTRL")
        #expect(details.hostname == "heeler-phone.tail1234.ts.net")
        #expect(details.addresses == ["100.101.102.103", "fd7a:115c:a1e0::1"])
        #expect(details.peers == [
            OverlayPeer(
                id: "nBox", name: "build-box", addresses: ["100.64.0.2", "fd7a:115c:a1e0::2"],
                isOnline: true, isDirect: true, latency: nil),
            OverlayPeer(id: "nodekey:dd", name: nil, addresses: [], isOnline: nil, isDirect: false),
            OverlayPeer(id: "nRelay", name: "relayed", addresses: ["100.64.0.3"], isOnline: true, isDirect: false),
            OverlayPeer(id: "nIdle", name: "zz-idle", addresses: ["100.64.0.4"], isOnline: false, isDirect: nil),
        ])
    }

    /// tailscale.com v1.102.5 adds a numeric `NodeID` next to the stable
    /// string `ID` on every node and `ExtraRecords` to the status; the stable
    /// ID stays the peer's identity.
    @Test func numericNodeIDAndExtraRecordsAreIgnored() throws {
        let json = """
            {"Version":"1.102.5","BackendState":"Running","TailscaleIPs":["100.101.102.103"],
             "ExtraRecords":[{"Name":"db.example.ts.net.","Type":"A","Value":"100.64.0.9"}],
             "Self":{"ID":"nSelf123CNTRL","NodeID":123456789,"DNSName":"heeler-phone.tail1234.ts.net."},
             "Peer":{"nodekey:bb":{"ID":"nBox","NodeID":987654321,"DNSName":"build-box.tail1234.ts.net.",
                                   "TailscaleIPs":["100.64.0.2"],"Online":true,"Active":true,
                                   "CurAddr":"203.0.113.5:41641"}}}
            """
        let status = try TailscaleStatus.decode(Data(json.utf8))

        #expect(status.progress == .online(addresses: ["100.101.102.103"]))
        #expect(status.details.nodeID == "nSelf123CNTRL")
        #expect(status.details.peers == [
            OverlayPeer(
                id: "nBox", name: "build-box", addresses: ["100.64.0.2"],
                isOnline: true, isDirect: true, latency: nil),
        ])
    }

    @Test func detailsOfANodeWithoutSelfOrPeers() throws {
        let details = try TailscaleStatus.decode(Data(#"{"BackendState":"NeedsLogin","Peer":null}"#.utf8)).details
        #expect(details == OverlayNodeDetails(peers: []))
    }

    @Test func missingFieldsDecodeAndMalformedJSONThrows() throws {
        let empty = try TailscaleStatus.decode(Data("{}".utf8))
        #expect(empty.backendState == .noState)
        #expect(throws: (any Error).self) {
            _ = try TailscaleStatus.decode(Data("not json".utf8))
        }
    }
}

@Suite("Tailscale log upload")
struct TailscaleLogUploadTests {
    @Test func goRuntimeSeesLogUploadDisabled() {
        // Both the envknob and logtail bits, as reported by the Go side.
        #expect(LiveTailscaleNative.logUploadDisabled)
        #expect(LiveTailscaleNative.logUploadState == 3)
    }
}

@Suite("Overlay addresses")
struct OverlayAddressTests {
    @Test func hostPortBracketsIPv6Only() {
        #expect(OverlayAddress.hostPort(host: "100.64.0.1", port: 22) == "100.64.0.1:22")
        #expect(OverlayAddress.hostPort(host: "box", port: 2222) == "box:2222")
        #expect(OverlayAddress.hostPort(host: "box.tail1234.ts.net", port: 22) == "box.tail1234.ts.net:22")
        #expect(OverlayAddress.hostPort(host: "fd7a:115c:a1e0::1", port: 22) == "[fd7a:115c:a1e0::1]:22")
        #expect(OverlayAddress.hostPort(host: "[fd7a:115c:a1e0::1]", port: 22) == "[fd7a:115c:a1e0::1]:22")
    }

    @Test func ipLiteralAcceptsOnlyAddresses() {
        #expect(OverlayAddress.ipLiteral("10.147.17.5") == "10.147.17.5")
        #expect(OverlayAddress.ipLiteral(" [fd00::1] ") == "fd00::1")
        #expect(OverlayAddress.ipLiteral("fd00::1") == "fd00::1")
        #expect(OverlayAddress.ipLiteral("host.example") == nil)
        #expect(OverlayAddress.ipLiteral("10.147.17") == nil)
        #expect(OverlayAddress.ipLiteral("") == nil)
    }
}

@Suite("ZeroTier network IDs and identities")
struct ZeroTierNetworkIDTests {
    @Test func parsesSixteenHexDigits() {
        #expect(ZeroTierNetworkID.parse("8056c2e21c000001") == 0x8056_c2e2_1c00_0001)
        #expect(ZeroTierNetworkID.parse(" 8056C2E21C000001\n") == 0x8056_c2e2_1c00_0001)
        #expect(ZeroTierNetworkID.parse("0000000000000abc") == 0xabc)
    }

    @Test func rejectsEverythingElse() {
        for text in ["", "8056c2e21c00001", "8056c2e21c0000011", "0x8056c2e21c0001",
                     "8056c2e21c00000g", "0000000000000000", "+056c2e21c000001", "8056 c2e21c00001"] {
            #expect(ZeroTierNetworkID.parse(text) == nil, "\(text)")
        }
    }

    @Test func formatsAsSixteenLowercaseDigits() {
        #expect(ZeroTierNetworkID.format(0x8056_c2e2_1c00_0001) == "8056c2e21c000001")
        #expect(ZeroTierNetworkID.format(0xabc) == "0000000000000abc")
        #expect(ZeroTierNetworkID.format(.max) == "ffffffffffffffff")
        for value: UInt64 in [1, 0xabc, 0x8056_c2e2_1c00_0001, .max] {
            #expect(ZeroTierNetworkID.parse(ZeroTierNetworkID.format(value)) == value)
        }
    }

    @Test func networkStatusFailuresAreExplained() {
        let id: UInt64 = 0x8056_c2e2_1c00_0001
        #expect(ZeroTierNetworkID.failureMessage(networkStatus: 0, networkID: id) == nil)
        #expect(ZeroTierNetworkID.failureMessage(networkStatus: 1, networkID: id) == nil)
        // Awaiting authorization is not a failure: an admin may still grant it.
        #expect(ZeroTierNetworkID.failureMessage(networkStatus: 2, networkID: id) == nil)
        #expect(ZeroTierNetworkID.failureMessage(networkStatus: 3, networkID: id)?.contains("does not exist") == true)
    }

    @Test func storedIdentityIsTrimmedAndBounded() throws {
        let text = "89e92ceee5:0:abcdef:0123"
        #expect(try ZeroTierRuntime.identityString(Data("  \(text)\n\0".utf8)) == text)
        #expect(throws: OverlayError.self) {
            _ = try ZeroTierRuntime.identityString(Data())
        }
        #expect(throws: OverlayError.self) {
            _ = try ZeroTierRuntime.identityString(Data([0xff, 0xfe]))
        }
        #expect(throws: OverlayError.self) {
            _ = try ZeroTierRuntime.identityString(Data(String(repeating: "a", count: 400).utf8))
        }

        let buffer = ZeroTierRuntime.identityBuffer(text)
        #expect(buffer.count == ZeroTierRuntime.identityBufferLength)
        #expect(buffer[text.utf8.count] == 0)
        #expect(!ZeroTierRuntime.isValidIdentity(text))
    }

    @Test func malformedConfigurationFailsBeforeTheNodeStarts() async {
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 0x8056_c2e2_1c00_0001, identity: Data("nope".utf8)),
            identityGenerated: { _ in })
        await #expect(throws: OverlayError.invalidConfiguration("The ZeroTier identity is not valid.")) {
            try await node.start(timeout: .seconds(1))
        }
        await #expect(throws: OverlayError.self) {
            _ = try await node.dial(host: "not-an-ip", port: 22, timeout: .seconds(1))
        }
        #expect(await node.status() == .failed("The ZeroTier identity is not valid."))
    }
}
