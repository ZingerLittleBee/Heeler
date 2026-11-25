import Foundation
import Observation

/// A Server one look at a Host found: which one, and whether it answers now.
struct FoundServer: Hashable, Codable, Identifiable, Sendable {
    let key: HostServerKey
    /// False for a Server that is installed and not running. It is still found:
    /// turned on, its record connects once the user starts it.
    let isRunning: Bool
    /// The server's version, where the look read one.
    let version: String?

    var id: HostServerKey { key }

    /// Whether Add Host starts with this Server checked: one that runs brings
    /// its Agents at once, and one that does not would only sit unreachable.
    var startsChecked: Bool { isRunning }

    /// Under the Server's name while it is off: `Running · 3.5a`.
    var stateLine: String {
        let state = isRunning ? String(localized: "Running") : String(localized: "Not running")
        guard let version, !version.isEmpty else { return state }
        return "\(state) · \(version)"
    }
}

/// What one look at a Host found (ADR 0047): every Server on it, from the one
/// detection exec, and the kinds it looked for in vain.
struct HostServerScan: Equatable, Sendable {
    /// A kind the look did not find, with what it saw instead where that says
    /// more than "not found": a tmux too old to drive, a Rex socket this
    /// account cannot use.
    struct Missing: Equatable, Sendable {
        let kind: ServerKind
        let note: String?
    }

    private(set) var servers: [FoundServer]
    private(set) var missing: [Missing]
    private let detection: ServerKindDetection

    init(_ detection: ServerKindDetection) {
        self.detection = detection
        var servers: [FoundServer] = []
        var missing: [Missing] = []

        switch detection.herdrTUI {
        case .found(let sessions) where !sessions.isEmpty:
            // The default session first, as the Host's own list has it, then the
            // named ones that run. herdr keeps every session it ever had: a
            // stopped one is no Server until it is started, and by name it can
            // still be turned on.
            for session in sessions.filter(\.isDefault) + sessions.filter({ !$0.isDefault && $0.isRunning }) {
                servers.append(
                    FoundServer(
                        key: HostServerKey(kind: .herdrTUI, name: session.isDefault ? "" : session.name),
                        isRunning: session.isRunning, version: nil))
            }
        case .found:
            // herdr answers and lists no session: its default starts with it.
            servers.append(
                FoundServer(key: HostServerKey(kind: .herdrTUI, name: ""), isRunning: false, version: nil))
        case .notFound:
            missing.append(Missing(kind: .herdrTUI, note: nil))
        }

        switch detection.herdrCore {
        case .notRunning(let version, _):
            servers.append(
                FoundServer(key: HostServerKey(kind: .herdrCore, name: ""), isRunning: false, version: version))
        case .socketFilePresent(let version, _):
            servers.append(
                FoundServer(key: HostServerKey(kind: .herdrCore, name: ""), isRunning: true, version: version))
        case .socketPathTooLong, .sessionRefused:
            missing.append(Missing(kind: .herdrCore, note: detection.herdrCore.summary))
        case .notInstalled:
            missing.append(Missing(kind: .herdrCore, note: nil))
        }

        switch detection.tmux {
        case .running(let version, let sockets):
            for socket in sockets {
                servers.append(
                    FoundServer(key: HostServerKey(kind: .tmux, name: socket), isRunning: true, version: version))
            }
        case .notRunning(let version):
            servers.append(
                FoundServer(key: HostServerKey(kind: .tmux, name: ""), isRunning: false, version: version))
        case .updateRequired:
            missing.append(Missing(kind: .tmux, note: detection.tmux.summary))
        case .notInstalled, .unreadable:
            missing.append(Missing(kind: .tmux, note: nil))
        case .unsupported:
            // Heeler drives no tmux there, so there is none to miss.
            break
        }

        // A Host has one Rex Server at most: the server on the socket the look
        // prefers (ADR 0049). Installed and not running, it is found as a
        // stopped tmux is, since turned on it connects once the user starts
        // Rex. Rex is named missing only where a socket shows a server this
        // account cannot use: a machine without Rex shows nothing of it.
        switch detection.rex {
        case .socketFound:
            servers.append(FoundServer(key: HostServerKey(kind: .rex, name: ""), isRunning: true, version: nil))
        case .notRunning:
            servers.append(FoundServer(key: HostServerKey(kind: .rex, name: ""), isRunning: false, version: nil))
        case .notUsable(let path) where RexSocket.isWindowsPipeAddress(path):
            missing.append(Missing(kind: .rex, note: String(localized: "Rex runs, but rex.exe is not on this account's PATH")))
        case .notUsable:
            missing.append(
                Missing(kind: .rex, note: String(localized: "Socket found, but this account cannot use it")))
        case .notInstalled, .unreadable, .unsupported:
            break
        }

        self.servers = servers
        self.missing = missing
    }

    var isNativeWindows: Bool { detection.isNativeWindows }

    /// The same look at a Host known to run Herdr TUI: a Pairing Code shown
    /// inside one says so (ADR 0057) even where the look found no herdr, as
    /// from a login shell without it on PATH. Its default session is listed as
    /// running, which is what such a code has always added.
    func assumingHerdrTUI() -> HostServerScan {
        guard !servers.contains(where: { $0.key.kind == .herdrTUI }) else { return self }
        var scan = self
        scan.servers.insert(
            FoundServer(key: HostServerKey(kind: .herdrTUI, name: ""), isRunning: true, version: nil), at: 0)
        scan.missing.removeAll { $0.kind == .herdrTUI }
        return scan
    }

    /// What a tmux Server turned on from this look stores: its login shell just
    /// resolved both paths (ADR 0044).
    func tmuxPaths(for server: HostServerKey) -> TmuxPaths? {
        guard server.kind == .tmux else { return nil }
        return detection.tmuxPaths(socketName: server.name)
    }

    /// What a Rex Server turned on from this look stores: the socket the look
    /// found a server on. Nil while Rex is not running, which leaves the
    /// record's connections to look it up (ADR 0049).
    func rexSocket(for server: HostServerKey) -> RexSocket? {
        guard server.kind == .rex else { return nil }
        return detection.rexSocket
    }
}

/// What this device remembers of each Host's Servers between looks (ADR 0047):
/// the ones last found, so Host detail lists them at once, and the ones the
/// user has been shown, so a Server that turns up later can be pointed out
/// instead of turned on.
@MainActor
@Observable
final class HostServerDiscoveryStore {
    private struct Entry: Codable {
        var connection: HostMachine.Connection
        var found: [FoundServer]
        var shown: Set<HostServerKey>
        var lookedAt: Date
    }

    /// An entry's Rex Server, kept under a key of its own as Rex Hosts keep a
    /// catalog of their own (ADR 0049): a build before Rex reads the shared
    /// key whole, and one Rex Server in it would lose that build everything
    /// it remembers.
    private struct RexShare: Codable {
        var connection: HostMachine.Connection
        var found: [FoundServer]
        var shown: Set<HostServerKey>
    }

    /// The app's own, which every Hosts list and Add Host wizard shares.
    static let shared = HostServerDiscoveryStore()

    private static let defaultsKey = "host-server-discoveries"
    private static let rexDefaultsKey = "host-server-discoveries-rex"

    private var entries: [Entry]
    /// When each Host was last looked at in the background, found or not. Not
    /// kept across launches: a new launch may look again.
    @ObservationIgnored private var attempts: [HostMachine.ID: Date] = [:]
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        var entries =
            defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        let rexShares =
            defaults?.data(forKey: Self.rexDefaultsKey)
            .flatMap { try? JSONDecoder().decode([RexShare].self, from: $0) } ?? []
        // A Rex Server joins its Host's entry, last as a look lists it. One
        // whose Host has no entry went with it, in this build or another.
        for share in rexShares {
            guard let index = entries.firstIndex(where: { $0.connection == share.connection }) else { continue }
            let listed = Set(entries[index].found.map(\.key))
            entries[index].found += share.found.filter { !listed.contains($0.key) }
            entries[index].shown.formUnion(share.shown)
        }
        self.entries = entries
    }

    /// The Servers the last look at `host` found, none before the first.
    func found(on host: HostMachine.ID) -> [FoundServer] {
        entry(for: host)?.found ?? []
    }

    func lastLook(at host: HostMachine.ID) -> Date? {
        entry(for: host)?.lookedAt
    }

    /// Whether a background look at `host` is worth its connection: none found
    /// anything within `interval`, and none was tried within `retryInterval`.
    func isDue(
        _ host: HostMachine.ID, at date: Date = .now, interval: TimeInterval = 3600,
        retryInterval: TimeInterval = 600
    ) -> Bool {
        if let attempt = attempts[host], date.timeIntervalSince(attempt) < retryInterval { return false }
        guard let lookedAt = lastLook(at: host) else { return true }
        return date.timeIntervalSince(lookedAt) >= interval
    }

    /// A background look at `host` is starting.
    func noteAttempt(at host: HostMachine.ID, date: Date = .now) {
        attempts[host] = date
    }

    /// The Servers found running that are off and that the user has not been
    /// shown. One that is installed and not running has not turned up yet.
    func unseen(on machine: HostMachine) -> [FoundServer] {
        guard let entry = entry(for: machine.id) else { return [] }
        return entry.found.filter {
            $0.isRunning && !entry.shown.contains($0.key) && machine.record(of: $0.key) == nil
        }
    }

    /// Keeps what a look found. `shown` marks it as seen in the same stroke,
    /// for a look the user was watching.
    func note(_ scan: HostServerScan, on host: HostMachine.ID, shown: Bool = false, at date: Date = .now) {
        var entry = entry(for: host) ?? Entry(connection: host, found: [], shown: [], lookedAt: date)
        entry.found = scan.servers
        entry.lookedAt = date
        put(entry)
        if shown { markShown(on: host) }
    }

    /// The user has seen what was last found on `host`. Only a Server seen
    /// running counts: one that starts later is still news.
    func markShown(on host: HostMachine.ID) {
        guard var entry = entry(for: host) else { return }
        let before = entry.shown
        entry.shown.formUnion(entry.found.filter(\.isRunning).map(\.key))
        guard entry.shown != before else { return }
        put(entry)
    }

    /// Forgets every Host the catalog no longer has, an edited one included: its
    /// next look starts over.
    func retain(_ hosts: some Sequence<HostMachine.ID>) {
        let kept = Set(hosts)
        guard entries.contains(where: { !kept.contains($0.connection) }) else { return }
        entries.removeAll { !kept.contains($0.connection) }
        persist()
    }

    private func entry(for host: HostMachine.ID) -> Entry? {
        entries.first { $0.connection == host }
    }

    private func put(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.connection == entry.connection }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        var shared = entries
        var rexShares: [RexShare] = []
        for index in shared.indices {
            let found = shared[index].found.filter { $0.key.kind == .rex }
            let shown = shared[index].shown.filter { $0.kind == .rex }
            guard !found.isEmpty || !shown.isEmpty else { continue }
            rexShares.append(RexShare(connection: shared[index].connection, found: found, shown: shown))
            shared[index].found.removeAll { $0.key.kind == .rex }
            shared[index].shown.subtract(shown)
        }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(shared) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        if rexShares.isEmpty {
            defaults.removeObject(forKey: Self.rexDefaultsKey)
        } else if let data = try? encoder.encode(rexShares) {
            defaults.set(data, forKey: Self.rexDefaultsKey)
        }
    }
}
