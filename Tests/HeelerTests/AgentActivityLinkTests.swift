import Foundation
import Testing

@testable import Heeler

@Suite("Agent activity link")
struct AgentActivityLinkTests {
    private let hostID = UUID(uuidString: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E")!

    @Test func agentURLRoundTripsPaneIDsWithColons() throws {
        let url = try #require(
            AgentActivityLink.agentURL(hostID: hostID.uuidString, paneID: "wV:p1"))
        #expect(url.absoluteString.contains("wV%3Ap1"))
        let target = try #require(AgentActivityLink.target(from: url))
        #expect(target == AgentActivityLink.Target(hostID: hostID, paneID: "wV:p1"))
    }

    @Test func consoleURLRoundTripsWithoutPane() throws {
        let url = try #require(AgentActivityLink.consoleURL(hostID: hostID.uuidString))
        let target = try #require(AgentActivityLink.target(from: url))
        #expect(target == AgentActivityLink.Target(hostID: hostID, paneID: nil))
    }

    @Test(arguments: [
        "heeler://agent/not-a-uuid/wV:p1",
        "heeler://agent",
        "heeler://other/6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
        "https://agent/6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
        "heeler://agent/6D8EC348-4DAF-455C-BA8F-5FCC41799C0E/wV:p1/extra",
    ])
    func rejectsForeignOrMalformedURLs(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(AgentActivityLink.target(from: url) == nil)
    }
}
