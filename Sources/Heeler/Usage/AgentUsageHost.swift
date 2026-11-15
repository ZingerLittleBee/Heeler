import Foundation

/// A Host as Usage reads it. The Servers of one Host read the same Transcripts
/// under the same account, so a reading added up for each of them would count
/// the Host once for every Server. Usage reads a Host through one of its
/// Servers and counts it once (ADR 0047).
struct AgentUsageHost: Identifiable {
    /// The record of the Host's first Server. A Usage scope and a widget name
    /// the Host by it, so both keep pointing at the Host whichever Server its
    /// reading comes from.
    let id: Host.ID
    let name: String
    /// The records of the Servers Usage can be read through, in catalog
    /// order. Never empty.
    let records: [Host]

    /// `records` as the Hosts they reach, each where its first record stands.
    static func grouped(_ records: [Host]) -> [AgentUsageHost] {
        HostMachine.grouped(records).compactMap { machine in
            machine.members.first.map { AgentUsageHost(id: $0.id, name: machine.name, records: machine.members) }
        }
    }

    /// Which of a Host's Servers stands for it, as an index into `readings`,
    /// which follow `records`: the first whose reading is in; while none is,
    /// the first that may still answer; else the first, whose reason the Host
    /// then gives.
    static func chosen(among readings: [(state: AgentUsageStore.State, isConnected: Bool)]) -> Int {
        let read = readings.firstIndex { reading in
            if case .available = reading.state { true } else { false }
        }
        if let read { return read }
        return readings.firstIndex { ($0.state == .idle || $0.state == .loading) && $0.isConnected } ?? 0
    }
}
