import Foundation

/// Which of a Host's Servers a catalog record targets: the kind, and the name
/// that picks one among several of that kind (ADR 0047).
struct HostServerKey: Hashable, Codable, Sendable {
    let kind: ServerKind
    /// The session or socket name, as the kind stores it. Blank is Herdr TUI's
    /// default session.
    let name: String
    /// The socket of a Pairing Code endpoint (ADR 0023), which is a herdr of
    /// its own beside the one on the SSH PATH.
    let endpointSocketPath: String?

    init(kind: ServerKind, name: String, endpointSocketPath: String? = nil) {
        self.kind = kind
        self.name = kind.storedSessionName(name)
        self.endpointSocketPath = endpointSocketPath
    }

    /// The name, when it is not the one the kind uses unasked.
    var distinguishingName: String? {
        switch kind {
        case .herdrTUI: name.isEmpty ? nil : name
        case .herdrCore: name == HerdrCoreSessionName.normalized("") ? nil : name
        case .tmux: name == TmuxSocketName.defaultName ? nil : name
        case .unconfirmed: nil
        }
    }

    /// What tells this Server from its Host's others: `tmux`, `tmux · work`,
    /// `Herdr TUI · work`.
    var label: String {
        guard let distinguishingName else { return kind.displayName }
        return "\(kind.displayName) · \(distinguishingName)"
    }
}

extension Host {
    /// The Server this record targets, nil while it holds a Host with none on.
    var serverKey: HostServerKey? {
        guard serverKind.isConfirmed else { return nil }
        if let herdrEndpoint {
            return HostServerKey(
                kind: .herdrTUI, name: herdrEndpoint.session, endpointSocketPath: herdrEndpoint.socketPath)
        }
        return HostServerKey(kind: serverKind, name: sessionName)
    }
}

/// A Host as the Hosts tab shows it: every catalog record that reaches one
/// machine the same way. Each Server that is on has a record of its own, so the
/// Console, notifications and older builds keep seeing one Host for each; a
/// Host with no Server on is held by one unconfirmed record (ADR 0047).
struct HostMachine: Identifiable, Hashable, Sendable {
    /// What makes two catalog records one Host: the account, how it
    /// authenticates, and the Routes in order.
    struct Connection: Hashable, Codable, Sendable {
        struct Route: Hashable, Codable, Sendable {
            let address: String
            let port: Int
            let jumpAddress: String
            let jumpPort: Int
            let jumpUsername: String
            let overlayNetworkID: UUID?

            init(_ route: HostRoute) {
                address = route.address.trimmingCharacters(in: .whitespaces).lowercased()
                port = route.port
                overlayNetworkID = route.overlayNetworkID
                // A blank jump address is no hop at all, whatever the fields
                // beside it still hold.
                if route.usesJumpHost {
                    jumpAddress = route.jumpAddress.trimmingCharacters(in: .whitespaces).lowercased()
                    jumpPort = route.jumpPort
                    jumpUsername = route.jumpUsername.trimmingCharacters(in: .whitespaces)
                } else {
                    jumpAddress = ""
                    jumpPort = 22
                    jumpUsername = ""
                }
            }
        }

        let username: String
        let authMethod: Host.AuthMethod
        let routes: [Route]

        init(_ host: Host) {
            username = host.username.trimmingCharacters(in: .whitespaces)
            authMethod = host.authMethod
            routes = host.routes.map(Route.init)
        }
    }

    let id: Connection
    /// The records in catalog order, never empty.
    let members: [Host]

    /// The records of the Servers that are on.
    var servers: [Host] { members.filter(\.serverKind.isConfirmed) }

    /// A record with no Server yet: the next Server to be turned on takes it.
    var spareRecord: Host? { members.first { !$0.serverKind.isConfirmed } }

    /// The record whose trust, password and connection settings stand for the
    /// Host's: every record of a Host holds the same.
    var representative: Host {
        // `members` is never empty; the fallback only satisfies the compiler.
        servers.first ?? members.first ?? Host(address: "", username: "")
    }

    /// The name the user gave the Host, blank when they gave none. Records
    /// named apart before they were one Host keep their own; the first names it.
    var givenName: String {
        members.lazy.map { $0.name.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// The Host's name, or `user@address`.
    var name: String {
        let givenName = givenName
        return givenName.isEmpty ? representative.machineName : givenName
    }

    var connectionSummary: String { representative.connectionSummary }

    func contains(_ id: Host.ID) -> Bool {
        members.contains { $0.id == id }
    }

    /// The record of `server`, when it is on.
    func record(of server: HostServerKey) -> Host? {
        members.first { $0.serverKey == server }
    }

    /// Whether turning `server` on adds a record to the catalog: it is off, and
    /// no record is waiting for a Server.
    func needsRecord(for server: HostServerKey) -> Bool {
        record(of: server) == nil && spareRecord == nil
    }

    /// `hosts` as the Hosts they reach, each where its first record stands.
    static func grouped(_ hosts: [Host]) -> [HostMachine] {
        var order: [Connection] = []
        var members: [Connection: [Host]] = [:]
        for host in hosts {
            let connection = Connection(host)
            if members[connection] == nil { order.append(connection) }
            members[connection, default: []].append(host)
        }
        return order.map { HostMachine(id: $0, members: members[$0] ?? []) }
    }

    /// What each record is called beside the Host's name. Only records that
    /// would read alike take one: a Host with one Server on, or records the
    /// user named apart, are told apart already.
    static func serverLabels(for hosts: [Host]) -> [Host.ID: String] {
        var labels: [Host.ID: String] = [:]
        for machine in grouped(hosts) {
            let alike = Dictionary(grouping: machine.servers, by: \.machineName)
            for records in alike.values where records.count > 1 {
                for record in records {
                    labels[record.id] = record.serverKey?.label
                }
            }
        }
        return labels
    }
}
