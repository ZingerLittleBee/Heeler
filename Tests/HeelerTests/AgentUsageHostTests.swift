import Foundation
import Testing

@testable import Heeler

/// How Usage reads a Host that runs several Servers (ADR 0047).
@MainActor
@Suite("Agent usage host")
struct AgentUsageHostTests {
    @Test func theServersOfOneHostAreOneHostUnderItsFirstRecord() {
        let herdr = Host(name: "Studio Mac", address: "studio.local", username: "dev")
        let tmux = Host(name: "Studio Mac", address: "studio.local", username: "dev", serverKind: .tmux)
        let other = Host(name: "Build Box", address: "build.local", username: "dev")

        let hosts = AgentUsageHost.grouped([herdr, other, tmux])

        #expect(hosts.map(\.id) == [herdr.id, other.id])
        #expect(hosts.map(\.name) == ["Studio Mac", "Build Box"])
        #expect(hosts.map { $0.records.map(\.id) } == [[herdr.id, tmux.id], [other.id]])
    }

    @Test func aHostIsReadThroughTheFirstServerThatReports() throws {
        let report = try AgentUsageFixture.report(refreshing: false)
        let needsPlugin = AgentUsageStore.State.requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.")

        // A Server that reports stands for the Host ahead of one that cannot.
        #expect(AgentUsageHost.chosen(among: [(needsPlugin, true), (.available(report), true)]) == 1)
        // Before any reports, a connected Server that may still answer does.
        #expect(AgentUsageHost.chosen(among: [(.idle, false), (.loading, true)]) == 1)
        // With nothing to prefer, the Host's first Server says why.
        #expect(AgentUsageHost.chosen(among: [(needsPlugin, true), (.idle, false)]) == 0)
    }
}
