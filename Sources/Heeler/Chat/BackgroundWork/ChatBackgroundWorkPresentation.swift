import Foundation

/// How Chat shows its Background Work (ADR 0020): the rows over the
/// Composer, the line they condense to while the Composer is open, and the
/// sheet that lists everything. Work a read can't vouch for stops claiming
/// to run: with the Host away or the read failing its row freezes, and work
/// silent for longer than it runs says when it was last seen.
struct ChatBackgroundWorkPresentation: Equatable {
    /// The rows the strip shows before "+N more".
    static let stripLimit = 3

    enum Status: Equatable {
        /// Running, as a live read shows.
        case running
        /// Running as of the last read, which is not live now.
        case unconfirmed
        /// Running, with no sign of it for longer than such work runs.
        case quiet
        case completed
        case failed
        case stopped

        var isFinished: Bool {
            switch self {
            case .running, .unconfirmed, .quiet: false
            case .completed, .failed, .stopped: true
            }
        }
    }

    struct Fraction: Equatable {
        var done: Int
        var total: Int
    }

    /// One agent of a Workflow, as its journal lists it.
    struct Agent: Identifiable, Equatable {
        let id: String
        let status: Status
        let label: String
        let phase: String?
        let accessibilityLabel: String
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let kind: ChatBackgroundWorkItem.Kind
        let status: Status
        let title: String
        /// A Subagent's type, or the phase a Workflow is in.
        let caption: String
        /// What a Workflow says it does.
        let detail: String?
        /// A Workflow's agents done, of those started so far.
        let fraction: Fraction?
        /// How long the work has run, or ran; nil when the records don't
        /// say.
        let time: String?
        /// Why a running row shows no time.
        let note: String?
        /// The counts the program reported as the work ended.
        let usage: String?
        let agents: [Agent]
        let accessibilityLabel: String
    }

    /// The one line the rows condense to.
    struct Summary: Equatable {
        let status: Status
        let text: String
        let accessibilityValue: String
    }

    let rows: [Row]

    init(
        work: ChatBackgroundWork, isHostConnected: Bool, now: Date, locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let style = Style(now: now, locale: locale, calendar: calendar)
        let isLive = work.isLive && isHostConnected
        rows = work.rows.map { style.row($0, isLive: isLive) }
    }

    var stripRows: [Row] { Array(rows.prefix(Self.stripLimit)) }
    var overflow: Int { max(0, rows.count - Self.stripLimit) }
    var unfinished: [Row] { rows.filter { !$0.status.isFinished } }
    var finished: [Row] { rows.filter(\.status.isFinished) }
    /// Only running rows show a moving time.
    var ticks: Bool { rows.contains { $0.status == .running } }

    var summary: Summary? {
        guard !rows.isEmpty else { return nil }
        let running = rows.filter { $0.status == .running }
        // A Workflow's fraction says the most in one line.
        if let first = running.first(where: { $0.kind == .workflow }) ?? running.first {
            let fraction = first.fraction
            return Summary(
                status: .running,
                text: "\(running.count) running · \(first.title)" + (fraction.map { " \($0.done)/\($0.total)" } ?? ""),
                accessibilityValue: "\(running.count) running, \(first.title)"
                    + (fraction.map { ", \($0.done) of \($0.total) agents done" } ?? ""))
        }
        let notUpdating = rows.count { $0.status == .unconfirmed || $0.status == .quiet }
        let completed = rows.count { $0.status == .completed }
        let failed = rows.count { $0.status == .failed }
        let stopped = rows.count { $0.status == .stopped }
        let parts = [
            (notUpdating, "not updating"), (completed, "done"), (failed, "failed"), (stopped, "stopped"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let status: Status =
            notUpdating > 0 ? .unconfirmed : failed > 0 ? .failed : completed > 0 ? .completed : .stopped
        return Summary(
            status: status, text: parts.joined(separator: " · "),
            accessibilityValue: parts.joined(separator: ", "))
    }

    /// "38s", "2m 18s", "1h 5m": as "Thought for" reads, with hours.
    static func duration(_ seconds: TimeInterval, width: Duration.UnitsFormatStyle.UnitWidth, locale: Locale)
        -> String
    {
        let whole = seconds.isFinite ? Int64(max(0, seconds.rounded(.down))) : 0
        return Duration.seconds(whole).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: width, maximumUnitCount: 2).locale(locale))
    }

    private struct Style {
        let now: Date
        let locale: Locale
        let calendar: Calendar

        func row(_ row: ChatBackgroundWork.Row, isLive: Bool) -> Row {
            let item = row.item
            let status = Self.status(of: row, isLive: isLive)
            let fraction = Self.fraction(of: row)
            let seconds = Self.seconds(of: item, status: status, now: now)
            let lastSeen = row.lastActivity.map(time(of:))
            let note: String? =
                switch status {
                case .unconfirmed: "Not updating"
                case .quiet: lastSeen.map { "No updates since \($0)" } ?? "No recent updates"
                default: nil
                }
            let caption =
                switch item.kind {
                case .subagent: item.subtitle ?? "Subagent"
                // The phase of the agent it started last.
                case .workflow: row.progress?.agents.last?.phase ?? "Workflow"
                }
            var spoken = [item.title, kindPhrase(item), statePhrase(status, lastSeen: lastSeen)]
            if let fraction { spoken.append("\(fraction.done) of \(fraction.total) agents done") }
            if let seconds { spoken.append(ChatBackgroundWorkPresentation.duration(seconds, width: .wide, locale: locale)) }
            return Row(
                id: item.id, kind: item.kind, status: status, title: item.title, caption: caption,
                detail: item.kind == .workflow ? item.subtitle : nil, fraction: fraction,
                time: seconds.map { ChatBackgroundWorkPresentation.duration($0, width: .narrow, locale: locale) },
                note: note, usage: usage(item.usage), agents: agents(of: row, status: status),
                accessibilityLabel: spoken.joined(separator: ", "))
        }

        private static func status(of row: ChatBackgroundWork.Row, isLive: Bool) -> Status {
            switch row.item.state {
            case .running: !isLive ? .unconfirmed : row.isStale ? .quiet : .running
            case .completed: .completed
            case .failed: .failed
            case .stopped: .stopped
            }
        }

        /// The notification's counts once the Workflow ends; until then the
        /// journal's, whose total grows as agents start.
        private static func fraction(of row: ChatBackgroundWork.Row) -> Fraction? {
            guard row.item.kind == .workflow else { return nil }
            if let usage = row.item.usage, let total = usage.agents, total > 0 {
                return Fraction(done: usage.agentsDone ?? row.progress?.done ?? 0, total: total)
            }
            guard let progress = row.progress, progress.started > 0 else { return nil }
            return Fraction(done: progress.done, total: progress.started)
        }

        /// Running time from the launch, on the Host's clock, so a Host
        /// running ahead of the phone reads zero rather than negative.
        private static func seconds(of item: ChatBackgroundWorkItem, status: Status, now: Date) -> TimeInterval? {
            switch status {
            case .running:
                return item.launchedAt.map { max(0, now.timeIntervalSince($0)) }
            case .unconfirmed, .quiet:
                return nil
            case .completed, .failed, .stopped:
                if let milliseconds = item.usage?.durationMilliseconds { return TimeInterval(milliseconds) / 1_000 }
                guard let launchedAt = item.launchedAt, let endedAt = item.endedAt else { return nil }
                return max(0, endedAt.timeIntervalSince(launchedAt))
            }
        }

        private func agents(of row: ChatBackgroundWork.Row, status: Status) -> [Agent] {
            (row.progress?.agents ?? []).enumerated().map { index, agent in
                let agentStatus: Status =
                    switch agent.state {
                    case .done: .completed
                    case .failed: .failed
                    // Work that ended took its running agents with it.
                    case .running: status.isFinished ? .stopped : status == .running ? .running : .unconfirmed
                    }
                let label = agent.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent \(index + 1)"
                let spoken = [label, agent.phase, statePhrase(agentStatus, lastSeen: nil)].compactMap(\.self)
                return Agent(
                    id: agent.id, status: agentStatus, label: label, phase: agent.phase,
                    accessibilityLabel: spoken.joined(separator: ", "))
            }
        }

        private func usage(_ usage: ChatBackgroundWorkItem.Usage?) -> String? {
            guard let usage else { return nil }
            var parts: [String] = []
            if let tokens = usage.tokens {
                let count = tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
                parts.append("\(count) tokens")
            }
            if let toolUses = usage.toolUses {
                parts.append(toolUses == 1 ? "1 tool use" : "\(toolUses) tool uses")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        private func kindPhrase(_ item: ChatBackgroundWorkItem) -> String {
            switch item.kind {
            case .subagent: item.subtitle.map { "\($0) subagent" } ?? "Subagent"
            case .workflow: "Workflow"
            }
        }

        private func statePhrase(_ status: Status, lastSeen: String?) -> String {
            switch status {
            case .running: "running"
            case .unconfirmed: "not updating"
            case .quiet: lastSeen.map { "no updates since \($0)" } ?? "no recent updates"
            case .completed: "done"
            case .failed: "failed"
            case .stopped: "stopped"
            }
        }

        /// A time of day, with its date unless it is today.
        private func time(of date: Date) -> String {
            let style = Date.FormatStyle(
                date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened,
                locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return date.formatted(style)
        }
    }
}
