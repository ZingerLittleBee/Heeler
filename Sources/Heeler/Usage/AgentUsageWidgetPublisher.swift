import Foundation
import WidgetKit

/// One Host as the app last read it, for the widgets' snapshot.
struct AgentUsageWidgetReading: Equatable {
    let id: Host.ID
    let name: String
    let state: AgentUsageStore.State
    let readAt: Date?
    let isConnected: Bool
}

/// Keeps the widgets' snapshot in step with the app's Usage readings and
/// asks WidgetKit to redraw when it changes.
@MainActor
final class AgentUsageWidgetPublisher {
    /// How old a Host's last reading may grow before the app reads it again
    /// for the widgets, without anyone opening Usage.
    nonisolated static let staleInterval: TimeInterval = 15 * 60

    private let store: UsageWidgetSnapshotStore
    private let reloadTimelines: @MainActor () -> Void
    private let installedKinds: @MainActor () async -> Set<String>
    private lazy var published: UsageWidgetSnapshot? = store.read()

    init(
        store: UsageWidgetSnapshotStore = UsageWidgetSnapshotStore(),
        reloadTimelines: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetSnapshotStore.usageKind)
            WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetSnapshotStore.limitsKind)
        },
        installedKinds: @escaping @MainActor () async -> Set<String> = {
            Set((try? await WidgetCenter.shared.currentConfigurations())?.map(\.kind) ?? [])
        }
    ) {
        self.store = store
        self.reloadTimelines = reloadTimelines
        self.installedKinds = installedKinds
    }

    /// Whether a Usage or Usage Limits widget is on the Home Screen or Lock
    /// Screen. Reading Usage only for the widgets waits on one.
    func widgetsInstalled() async -> Bool {
        let kinds = await installedKinds()
        return kinds.contains(UsageWidgetSnapshotStore.usageKind)
            || kinds.contains(UsageWidgetSnapshotStore.limitsKind)
    }

    /// Whether the widgets' figures for a Host are old enough to read again.
    /// `readAt` is the app's own last reading, which the snapshot may be newer than.
    func isStale(_ id: Host.ID, readAt: Date?, now: Date = .now) -> Bool {
        let last = [readAt, published?.host(id)?.readAt].compactMap(\.self).max()
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Self.staleInterval
    }

    /// Every catalog Host's reading, in catalog order.
    func publish(_ readings: [AgentUsageWidgetReading], now: Date = .now) {
        commit(UsageWidgetSnapshot(readings: readings, previous: published, now: now))
    }

    /// Readings for some of `hosts`; every other Host keeps what the snapshot holds.
    func publish(_ readings: [AgentUsageWidgetReading], updating hosts: [Host], now: Date = .now) {
        let read = Dictionary(readings.map { ($0.id, $0) }) { _, last in last }
        let previous = published
        commit(UsageWidgetSnapshot(hosts: hosts.map { host in
            if let reading = read[host.id] {
                return UsageWidgetSnapshot.Host(reading: reading, previous: previous, now: now)
            }
            if var kept = previous?.host(host.id) {
                kept.name = host.displayName
                return kept
            }
            return UsageWidgetSnapshot.Host(id: host.id, name: host.displayName, excludedReason: "Not read yet")
        }))
    }

    private func commit(_ next: UsageWidgetSnapshot) {
        guard next != published else { return }
        published = next
        store.write(next)
        reloadTimelines()
    }
}

extension UsageWidgetSnapshot {
    /// The snapshot after `readings`, in their order. A Host the app has no
    /// newer report for keeps the one `previous` holds, so a launch or a
    /// dropped connection does not empty the widgets; a Host that answered
    /// it cannot report loses its figures.
    init(readings: [AgentUsageWidgetReading], previous: UsageWidgetSnapshot?, now: Date) {
        self.init(hosts: readings.map { Host(reading: $0, previous: previous, now: now) })
    }
}

extension UsageWidgetSnapshot.Host {
    init(reading: AgentUsageWidgetReading, previous: UsageWidgetSnapshot?, now: Date) {
        let kept = previous?.host(reading.id).flatMap { $0.reports ? $0 : nil }
        switch reading.state {
        case .available(let report):
            let readAt = reading.readAt ?? now
            // A reading made while the app was away is newer than the
            // report the app still holds from before.
            if var kept, let keptAt = kept.readAt, keptAt > readAt {
                kept.name = reading.name
                self = kept
            } else {
                self.init(id: reading.id, name: reading.name, report: report, readAt: readAt)
            }
        case .requirement, .unsupportedPlatform, .runtimeMissing, .updateRequired:
            self.init(id: reading.id, name: reading.name, excludedReason: AgentUsageScope.reason(for: reading.state))
        case .idle, .loading, .failed:
            if var kept {
                kept.name = reading.name
                self = kept
                return
            }
            let reason = if !reading.isConnected {
                "Not connected"
            } else if case .failed = reading.state {
                AgentUsageScope.reason(for: reading.state)
            } else {
                "Not read yet"
            }
            self.init(id: reading.id, name: reading.name, excludedReason: reason)
        }
    }

    init(id: UUID, name: String, excludedReason: String) {
        self.init(id: id, name: name, readAt: nil, excludedReason: excludedReason, timeZone: nil,
            programs: [], limits: [])
    }

    init(id: UUID, name: String, report: AgentUsageReport, readAt: Date) {
        let programs = report.programs ?? []
        self.init(
            id: id, name: name, readAt: readAt, excludedReason: nil, timeZone: report.timeZone,
            programs: programs.compactMap { program in
                guard let totals = program.okTotals else { return nil }
                return UsageWidgetSnapshot.Program(
                    program: program.program, name: program.displayName,
                    today: .init(totals.today), last7Days: .init(totals.last7Days),
                    last30Days: .init(totals.last30Days),
                    days: (program.tokenUsage.daily ?? []).map { .init(date: $0.date, summary: .init($0.summary)) })
            },
            limits: AgentUsageLimitsCard.readings(for: report).compactMap(UsageWidgetSnapshot.Limits.init))
    }
}

extension UsageWidgetSnapshot.Summary {
    init(_ summary: AgentUsageReport.Summary) {
        self.init(cost: summary.estimatedCostUSD, tokens: summary.tokens.total)
    }
}

extension UsageWidgetSnapshot.Limits {
    /// A reading in the order Usage lists them: Codex's, Claude Code's, or
    /// with several Accounts each Account's, those not counted saying why.
    init?(_ card: AgentUsageLimitsCard) {
        let name = AgentUsageReport.Program.displayName(for: card.program)
        switch card {
        case .limits(_, let program, let account, let limits):
            self.init(program: program, name: name, account: account, limits: limits)
        case .unread(_, let account, let reason):
            self.init(
                program: card.program, name: name, account: account, message: reason,
                isLastReading: false, source: nil, observedAt: nil, windows: [])
        case .claudeToggle:
            return nil
        }
    }

    private init(program: String, name: String, account: String?, limits: AgentUsageReport.Program.UsageLimits) {
        let shown = limits.state == "ok" || limits.state == "throttled"
        let windows = shown ? limits.windows ?? [] : []
        let message: String? = if shown {
            windows.isEmpty ? "No Usage Limits windows reported." : nil
        } else if limits.state == "unavailable" && limits.reason == "notReadYet" {
            "Open Heeler to read Usage Limits."
        } else {
            AgentUsageLimitsView.unavailableMessage(limits, program: program)
        }
        self.init(
            program: program, name: name, account: account, message: message,
            isLastReading: limits.state == "throttled",
            source: shown ? (limits.source == "lastSession" ? .lastSession : .program) : nil,
            observedAt: AgentUsageLimitsView.date(limits.observedAt),
            windows: windows.map { window in
                UsageWidgetSnapshot.Window(
                    id: window.id, name: AgentUsageLimitsView.windowName(window, program: program),
                    usedPercent: window.usedPercent, resetsAt: AgentUsageLimitsView.date(window.resetsAt),
                    expired: window.expired)
            })
    }
}
