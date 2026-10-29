import Foundation

/// What Heeler's widgets show: the Usage the app last read from each Host.
/// Widgets never reach a Host. The app rewrites this file after each
/// reading, keeping a Host's last report while it cannot read a newer one.
struct UsageWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    /// In catalog order.
    var hosts: [Host]

    struct Host: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        var name: String
        /// When the app read this Host's report; nil while it never has.
        var readAt: Date?
        /// Why All Hosts leaves this Host out; nil while it reports.
        var excludedReason: String?
        /// The zone the Host's days are counted in.
        var timeZone: String?
        /// The programs whose Token Usage read ok.
        var programs: [Program]
        /// Every program's Usage Limits, read or not.
        var limits: [Limits]

        var reports: Bool { readAt != nil && excludedReason == nil }
    }

    struct Summary: Codable, Equatable, Sendable {
        /// nil when no token in the summary could be priced.
        var cost: Double?
        var tokens: Int64

        static let zero = Self(cost: 0, tokens: 0)

        /// Unpriced throughout stays unpriced rather than becoming $0.
        static func sum(_ summaries: [Self]) -> Self {
            let priced = summaries.compactMap(\.cost)
            return Self(
                cost: priced.isEmpty && !summaries.isEmpty ? nil : priced.reduce(0, +),
                tokens: summaries.reduce(0) { $0 + $1.tokens })
        }

        func value(_ metric: AgentUsageMetric) -> Double {
            switch metric {
            case .cost: cost ?? 0
            case .tokens: Double(tokens)
            }
        }
    }

    struct Program: Codable, Equatable, Sendable, Identifiable {
        let program: String
        let name: String
        let today: Summary
        let last7Days: Summary
        let last30Days: Summary
        /// Oldest first, in the Host's own days.
        let days: [Day]

        var id: String { program }

        func summary(_ range: AgentUsageRange) -> Summary {
            switch range {
            case .today: today
            case .last7Days: last7Days
            case .last30Days: last30Days
            }
        }
    }

    struct Day: Codable, Equatable, Sendable {
        /// `YYYY-MM-DD` in the Host's time zone.
        let date: String
        let summary: Summary
    }

    struct Limits: Codable, Equatable, Sendable, Identifiable {
        enum Source: String, Codable, Sendable {
            /// The program answered for its account.
            case program
            /// Read from the program's last session on the Host.
            case lastSession
        }

        let program: String
        let name: String
        /// The Claude Code Account these limits are for, while the Host has
        /// several: each Account is an entry of its own, in the app's order.
        /// nil for a program's own, and in snapshots from before Accounts.
        let account: String?
        /// Why there are no windows to show; nil when the program reported them.
        let message: String?
        /// The program would not answer again yet: these are its last windows.
        let isLastReading: Bool
        let source: Source?
        let observedAt: Date?
        let windows: [Window]

        /// Account names are unique on a Host, the Default Account's included.
        var id: String { account.map { "\(program).\($0)" } ?? program }

        /// "Claude Code · claude-2", or the program alone.
        var title: String { account.map { "\(name) · \($0)" } ?? name }
    }

    struct Window: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let usedPercent: Double?
        let resetsAt: Date?
        /// The plugin found the window past its reset when it answered.
        let expired: Bool

        /// A reset that passes after the reading also ends the window: its
        /// usage since then is unknown.
        func isExpired(at now: Date) -> Bool {
            expired || resetsAt.map { $0 <= now } == true
        }
    }

    func host(_ id: UUID) -> Host? { hosts.first { $0.id == id } }
}

/// One Usage widget's reading of the snapshot: All Hosts, or one Host.
/// Token Usage adds up across the Hosts that report; the others are listed.
struct UsageWidgetScope: Equatable, Sendable {
    struct Program: Equatable, Sendable, Identifiable {
        let program: String
        let name: String
        let today: UsageWidgetSnapshot.Summary
        let last7Days: UsageWidgetSnapshot.Summary
        let last30Days: UsageWidgetSnapshot.Summary
        /// By date, each Host's days in its own time zone.
        let days: [String: UsageWidgetSnapshot.Summary]

        var id: String { program }

        func summary(_ range: AgentUsageRange) -> UsageWidgetSnapshot.Summary {
            switch range {
            case .today: today
            case .last7Days: last7Days
            case .last30Days: last30Days
            }
        }
    }

    /// nil reads All Hosts.
    let hostID: UUID?
    let title: String
    /// The Hosts whose figures the scope adds up.
    let included: [UsageWidgetSnapshot.Host]
    /// The Hosts it leaves out, with their reasons.
    let excluded: [UsageWidgetSnapshot.Host]
    let programs: [Program]

    /// nil when the snapshot no longer has the chosen Host.
    init?(snapshot: UsageWidgetSnapshot, hostID: UUID?) {
        let hosts: [UsageWidgetSnapshot.Host]
        if let hostID {
            guard let host = snapshot.host(hostID) else { return nil }
            hosts = [host]
            title = host.name
        } else {
            hosts = snapshot.hosts
            title = "All Hosts"
        }
        self.hostID = hostID
        included = hosts.filter(\.reports)
        excluded = hosts.filter { !$0.reports }
        programs = Self.programs(in: included)
    }

    var isEmpty: Bool { included.isEmpty }

    /// The oldest reading the figures rest on.
    var updatedAt: Date? { included.compactMap(\.readAt).min() }

    func total(_ range: AgentUsageRange) -> UsageWidgetSnapshot.Summary {
        .sum(programs.map { $0.summary(range) })
    }

    /// Every date any program reported, oldest first.
    var dates: [String] {
        Array(Set(programs.flatMap(\.days.keys))).sorted()
    }

    /// The newest days a chart of `range` shows: at least a week.
    func chartDates(_ range: AgentUsageRange) -> [String] {
        Array(dates.suffix(max(range.dayCount, 7)))
    }

    /// "2 of 4 Hosts" for All Hosts; nil for one Host.
    var coverage: String? {
        guard hostID == nil else { return nil }
        let count = included.count + excluded.count
        return "\(included.count) of \(count) \(count == 1 ? "Host" : "Hosts")"
    }

    /// The Hosts left out, as All Hosts' large widget names them.
    var excludedNote: String? {
        guard hostID == nil, !excluded.isEmpty else { return nil }
        return "Not included: \(excluded.map(\.name).formatted(.list(type: .and)))"
    }

    private static func programs(in hosts: [UsageWidgetSnapshot.Host]) -> [Program] {
        var order: [String] = []
        var byProgram: [String: [UsageWidgetSnapshot.Program]] = [:]
        for host in hosts {
            for program in host.programs {
                if byProgram[program.program] == nil { order.append(program.program) }
                byProgram[program.program, default: []].append(program)
            }
        }
        return order.compactMap { name in
            guard let entries = byProgram[name], let first = entries.first else { return nil }
            var days: [String: [UsageWidgetSnapshot.Summary]] = [:]
            for entry in entries {
                for day in entry.days { days[day.date, default: []].append(day.summary) }
            }
            return Program(
                program: name, name: first.name,
                today: .sum(entries.map(\.today)),
                last7Days: .sum(entries.map(\.last7Days)),
                last30Days: .sum(entries.map(\.last30Days)),
                days: days.mapValues { .sum($0) })
        }
    }
}

/// The snapshot's file in the app group the widget extension shares.
struct UsageWidgetSnapshotStore: Sendable {
    /// The kinds the app asks WidgetKit to reload after a write.
    static let usageKind = "dev.bybee.heeler.usage"
    static let limitsKind = "dev.bybee.heeler.usage-limits"

    /// Injectable for tests; the production value is the shared app-group
    /// container.
    var containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)

    private var fileURL: URL? {
        containerURL?.appendingPathComponent("usage-widgets.json")
    }

    /// nil when the app has not written one, or it no longer parses.
    func read() -> UsageWidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(UsageWidgetSnapshot.self, from: data),
            snapshot.version == UsageWidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// Best-effort: a failure leaves the previous snapshot in place.
    func write(_ snapshot: UsageWidgetSnapshot) {
        guard var url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            // Widgets render on the Lock Screen too, after the first unlock.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // The widgets keep the last snapshot until the next reading.
        }
    }
}

/// `heeler://usage` links a widget opens: the Usage tab on All Hosts or one
/// Host, `heeler://usage?host=<id>`, or that Host's Usage Limits,
/// `heeler://usage/limits?host=<id>`.
enum UsageWidgetLink {
    static let host = "usage"

    struct Target: Equatable, Sendable {
        /// nil opens All Hosts.
        let hostID: UUID?
        let showsLimits: Bool
    }

    static func usageURL(hostID: UUID?) -> URL? {
        url(path: "", hostID: hostID)
    }

    static func limitsURL(hostID: UUID) -> URL? {
        url(path: "/limits", hostID: hostID)
    }

    static func target(from url: URL) -> Target? {
        guard url.scheme == AgentActivityLink.scheme, url.host() == host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hostID = items.first { $0.name == "host" }?.value.flatMap(UUID.init(uuidString:))
        switch url.path() {
        case "", "/": return Target(hostID: hostID, showsLimits: false)
        case "/limits": return hostID.map { Target(hostID: $0, showsLimits: true) }
        default: return nil
        }
    }

    private static func url(path: String, hostID: UUID?) -> URL? {
        var components = URLComponents()
        components.scheme = AgentActivityLink.scheme
        components.host = host
        components.path = path
        if let hostID { components.queryItems = [URLQueryItem(name: "host", value: hostID.uuidString)] }
        return components.url
    }
}
