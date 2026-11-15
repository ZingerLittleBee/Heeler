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

    /// Usage reads the catalog's records that have Usage to read: a Rex Server
    /// is never what a Host is read through or named by, and a Host whose
    /// only Server is Rex has no Usage at all.
    @Test func aRexServerIsNeverWhatUsageReadsOrNamesAHostBy() {
        let rex = Host(name: "Studio Mac", address: "studio.local", username: "dev", serverKind: .rex)
        let tmux = Host(name: "Studio Mac", address: "studio.local", username: "dev", serverKind: .tmux)
        let rexOnly = Host(name: "Rex Box", address: "rex.local", username: "dev", serverKind: .rex)
        let catalog = HostStore(volatileHosts: [rex, rexOnly, tmux])
        #expect(catalog.machines.count == 2)

        let hosts = AgentUsageHost.grouped(catalog.integratedHosts)

        #expect(hosts.map(\.id) == [tmux.id])
        #expect(hosts.map(\.name) == ["Studio Mac"])
        #expect(hosts.map { $0.records.map(\.id) } == [[tmux.id]])
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
