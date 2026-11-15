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
    /// more than "not found": a tmux too old to drive.
    struct Missing: Equatable, Sendable {
        let kind: ServerKind
        let note: String?
    }

    let servers: [FoundServer]
    let missing: [Missing]
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

        self.servers = servers
        self.missing = missing
    }

    var isNativeWindows: Bool { detection.isNativeWindows }

    /// What a tmux Server turned on from this look stores: its login shell just
    /// resolved both paths (ADR 0044).
    func tmuxPaths(for server: HostServerKey) -> TmuxPaths? {
        guard server.kind == .tmux else { return nil }
        return detection.tmuxPaths(socketName: server.name)
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

    /// The app's own, which every Hosts list and Add Host wizard shares.
    static let shared = HostServerDiscoveryStore()

    private static let defaultsKey = "host-server-discoveries"

    private var entries: [Entry]
    /// When each Host was last looked at in the background, found or not. Not
    /// kept across launches: a new launch may look again.
    @ObservationIgnored private var attempts: [HostMachine.ID: Date] = [:]
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        entries =
            defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
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
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
