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
        #expect(target == AgentActivityLink.Target(host: .id(hostID), paneID: "wV:p1"))
    }

    @Test func consoleURLRoundTripsWithoutPane() throws {
        let url = try #require(AgentActivityLink.consoleURL(hostID: hostID.uuidString))
        let target = try #require(AgentActivityLink.target(from: url))
        #expect(target == AgentActivityLink.Target(host: .id(hostID), paneID: nil))
    }

    @Test(arguments: [
        "heeler://agent/not-a-uuid/wV:p1",
        "heeler://agent",
        "heeler://other/6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
        "https://agent/6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
        "heeler://agent/6D8EC348-4DAF-455C-BA8F-5FCC41799C0E/wV:p1/extra",
        "heeler://agent?session=work&pane=w1%3Ap1",
        "heeler://agent?host=&pane=w1%3Ap1",
        "heeler://agent?host=studio.local&host=build.local&pane=w1%3Ap1",
        "heeler://agent?host=studio.local&session=work&session=default&pane=w1%3Ap1",
        "heeler://agent?host=studio.local&pane=w1%3Ap1&pane=w1%3Ap2",
    ])
    func rejectsForeignOrMalformedURLs(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(AgentActivityLink.target(from: url) == nil)
    }
}

/// Another app knows a Host only the way it reaches it, so its link names an
/// address or name and a herdr session, and the saved Hosts resolve it (#419).
@Suite("Agent link Host lookup")
struct AgentLinkHostLookupTests {
    private static let studio = Host(
        id: UUID(uuidString: "0B9E7C55-2F4A-4C77-9C1D-6A1E2B3C4D01")!,
        name: "Studio", address: "studio.local", username: "dev")
    /// The same machine's `work` session: herdr repeats pane ids per session.
    private static let studioWork = Host(
        id: UUID(uuidString: "0B9E7C55-2F4A-4C77-9C1D-6A1E2B3C4D02")!,
        address: "studio.local", username: "dev", sessionName: "work")
    private static let buildBox = Host(
        id: UUID(uuidString: "0B9E7C55-2F4A-4C77-9C1D-6A1E2B3C4D03")!,
        name: "Build Box", address: "10.0.0.7", username: "ci")
    /// Two accounts on one machine and session, so the address names neither.
    private static let pi = Host(name: "Pi", address: "pi.local", username: "pi")
    private static let piAdmin = Host(name: "Pi admin", address: "pi.local", username: "admin")
    private static let hosts = [studio, studioWork, buildBox, pi, piAdmin]

    private func opened(
        _ link: String, in hosts: [Host] = AgentLinkHostLookupTests.hosts
    ) throws -> AgentNotificationTarget? {
        let url = try #require(URL(string: link))
        return try #require(AgentActivityLink.target(from: url)).agent(in: hosts)
    }

    /// The Live Activity's Console links carry an id but no pane.
    @Test func heelerConsoleLinksOpenTheConsole() throws {
        let url = try #require(AgentActivityLink.consoleURL(hostID: Self.studio.id.uuidString))

        #expect(try opened(url.absoluteString) == nil)
    }

    @Test func heelerLinksOpenTheirHostByID() throws {
        let url = try #require(
            AgentActivityLink.agentURL(hostID: Self.studioWork.id.uuidString, paneID: "w1:p1"))

        #expect(
            try opened(url.absoluteString)
                == AgentNotificationTarget(hostID: Self.studioWork.id, paneID: "w1:p1"))
    }

    @Test func addressMatchesIgnoringCase() throws {
        #expect(
            try opened("heeler://agent?host=STUDIO.local&pane=w1%3Ap1")
                == AgentNotificationTarget(hostID: Self.studio.id, paneID: "w1:p1"))
    }

    /// No session, an empty one, and herdr's own `default` all mean the
    /// default session.
    @Test(arguments: [
        ("heeler://agent?host=studio.local&pane=w1%3Ap1", studio.id),
        ("heeler://agent?host=studio.local&session=&pane=w1%3Ap1", studio.id),
        ("heeler://agent?host=studio.local&session=default&pane=w1%3Ap1", studio.id),
        ("heeler://agent?host=studio.local&session=work&pane=w1%3Ap1", studioWork.id),
    ])
    func sessionChoosesAmongHostsOnOneAddress(link: String, hostID: UUID) throws {
        #expect(try opened(link) == AgentNotificationTarget(hostID: hostID, paneID: "w1:p1"))
    }

    @Test func nameMatchesWhenNoAddressDoes() throws {
        #expect(
            try opened("heeler://agent?host=build%20box&pane=w1%3Ap1")
                == AgentNotificationTarget(hostID: Self.buildBox.id, paneID: "w1:p1"))
    }

    /// `+` is not a space in a query item, so a form-encoded name misses.
    @Test func plusIsNotASpace() throws {
        #expect(try opened("heeler://agent?host=build+box&pane=w1%3Ap1") == nil)
    }

    @Test func nameIsLookedUpOnTheLinksSession() throws {
        let workMac = Host(name: "Mac", address: "10.0.0.20", username: "dev", sessionName: "work")
        let hosts = [workMac, Self.studio]

        #expect(try opened("heeler://agent?host=mac&pane=w1%3Ap1", in: hosts) == nil)
        #expect(
            try opened("heeler://agent?host=mac&session=work&pane=w1%3Ap1", in: hosts)
                == AgentNotificationTarget(hostID: workMac.id, paneID: "w1:p1"))
    }

    @Test func twoHostsSharingANameOpenTheConsole() throws {
        let hosts = [
            Host(name: "Lab", address: "10.0.0.30", username: "dev"),
            Host(name: "lab", address: "10.0.0.31", username: "dev"),
        ]

        #expect(try opened("heeler://agent?host=Lab&pane=w1%3Ap1", in: hosts) == nil)
    }

    @Test func addressOutranksAnotherHostsName() throws {
        let namedAfterStudio = Host(name: "studio.local", address: "10.0.0.9", username: "dev")

        #expect(
            try opened(
                "heeler://agent?host=studio.local&pane=w1%3Ap1",
                in: [namedAfterStudio, Self.studio])
                == AgentNotificationTarget(hostID: Self.studio.id, paneID: "w1:p1"))
    }

    @Test(arguments: [
        "heeler://agent?host=elsewhere.local&pane=w1%3Ap1",
        "heeler://agent?host=studio.local&session=staging&pane=w1%3Ap1",
        "heeler://agent?host=pi.local&pane=w1%3Ap1",
    ])
    func opensConsoleWhenNoSingleHostAnswers(link: String) throws {
        #expect(try opened(link) == nil)
    }

    @Test(arguments: [
        "heeler://agent?host=studio.local",
        "heeler://agent?host=studio.local&pane=",
    ])
    func opensConsoleWithoutPane(link: String) throws {
        #expect(try opened(link) == nil)
    }

    @Test func ignoresItemsItDoesNotUse() throws {
        #expect(
            try opened("heeler://agent?host=studio.local&workspace=w1&tab=w1%3At1&pane=w1%3Ap1")
                == AgentNotificationTarget(hostID: Self.studio.id, paneID: "w1:p1"))
    }
}
