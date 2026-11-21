import Foundation

/// How Chat shows its Background Work (ADR 0024): the rows over the
/// Composer, the line that counts them, which they fold to, and the sheet
/// that lists everything. Work a read can't vouch for stops claiming
/// to run: with the Host away or the read failing its row freezes, and work
/// silent for longer than it runs says when it was last seen.
struct ChatBackgroundWorkPresentation: Equatable, Sendable {
    /// The rows the strip shows before "+N more".
    static let stripLimit = 3

    enum Status: Equatable, Sendable {
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

        var badgeLabel: String {
            switch self {
            case .running:
                String(localized: "Running")
            case .unconfirmed:
                String(localized: "Not updating")
            case .quiet:
                String(localized: "No recent updates")
            case .completed:
                String(
                    localized: "Agent status Done", defaultValue: "Done",
                    comment: "Agent status, not the button that closes a sheet")
            case .failed:
                String(localized: "Failed")
            case .stopped:
                String(localized: "Stopped")
            }
        }
    }

    struct Fraction: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    /// One agent of a Workflow, as its journal lists it.
    struct Agent: Identifiable, Equatable, Sendable {
        let id: String
        let status: Status
        let label: String
        let phase: String?
        let accessibilityLabel: String
    }

    struct Row: Identifiable, Equatable, Sendable {
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
        /// The note in the strip's room: a quiet row's day without its time
        /// unless it is today.
        let shortNote: String?
        /// The counts the program reported as the work ended.
        let usage: String?
        let agents: [Agent]
        let accessibilityLabel: String

        static func singleLine(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Human-first single-line label for the floating strip above the Composer.
        var stripHeadline: String {
            if kind == .command || kind == .workflow,
                let detail,
                let cleanDetail = Optional(Self.singleLine(detail)),
                !cleanDetail.isEmpty
            {
                return cleanDetail
            }
            let cleanTitle = Self.singleLine(title)
            return cleanTitle.isEmpty ? title : cleanTitle
        }

        /// Primary title inside an activity card; nil when a Command has no
        /// separate human summary so the command is not repeated above its terminal box.
        var cardHeadline: String? {
            switch kind {
            case .command:
                guard let detail else { return nil }
                let clean = Self.singleLine(detail)
                return clean.isEmpty ? nil : clean
            case .subagent:
                let clean = Self.singleLine(title)
                return clean.isEmpty ? title : clean
            case .workflow:
                if let detail {
                    let cleanDetail = Self.singleLine(detail)
                    if !cleanDetail.isEmpty { return cleanDetail }
                }
                let clean = Self.singleLine(title)
                return clean.isEmpty ? title : clean
            }
        }

        /// Single-line normalized text for a card's recessed terminal/identifier box.
        var terminalPreview: String? {
            switch kind {
            case .command:
                let clean = Self.singleLine(title)
                return clean.isEmpty ? nil : "$ \(clean)"
            case .workflow:
                guard let detail else { return nil }
                let cleanDetail = Self.singleLine(detail)
                let cleanTitle = Self.singleLine(title)
                guard !cleanDetail.isEmpty, !cleanTitle.isEmpty, cleanDetail != cleanTitle else { return nil }
                return cleanTitle
            case .subagent:
                return nil
            }
        }

        /// Full multi-line command text when a Command card is expanded in the sheet.
        var fullTerminalText: String? {
            switch kind {
            case .command:
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "$ \(trimmed)"
            case .workflow:
                return terminalPreview
            case .subagent:
                return nil
            }
        }

        /// Whether expanding reveals multi-line command formatting that
        /// `terminalPreview` collapsed onto one line.
        var hasMultiLineTerminalText: Bool {
            guard kind == .command else { return false }
            return title.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline)
        }

        /// Whether the card has expandable content regardless of width (Workflow
        /// agents or a multi-line Command); width-dependent truncation is
        /// measured by the card view itself.
        var hasIntrinsicExpandableContent: Bool {
            !agents.isEmpty || hasMultiLineTerminalText
        }

        /// The kind in the strip's room: a Workflow's phase says more
        /// there than the word, a Subagent's type less.
        var stripKind: String {
            switch kind {
            case .command, .workflow: caption
            case .subagent: String(localized: "Subagent")
            }
        }

        var kindBadge: String {
            switch kind {
            case .command:
                return caption
            case .subagent:
                let base = String(localized: "Subagent")
                return caption.isEmpty || caption == base ? base : "\(base) · \(caption)"
            case .workflow:
                let base = String(localized: "Workflow")
                return caption.isEmpty || caption == base ? base : "\(base) · \(caption)"
            }
        }
    }

    /// The line that stands over the rows, or for them: how many are in
    /// each state.
    struct Summary: Equatable, Sendable {
        /// The rows in one state, as "2 running".
        struct Count: Equatable, Sendable {
            /// `unconfirmed` counts every row no read vouches for.
            let status: Status
            let text: String
        }

        /// The first state there is, which the line's glyph shows.
        let status: Status
        let counts: [Count]

        var text: String { counts.map(\.text).joined(separator: " · ") }
        var accessibilityValue: String { counts.map(\.text).joinedAsPhrases() }
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
    var running: [Row] { rows.filter { $0.status == .running } }
    var notUpdating: [Row] { rows.filter { $0.status == .unconfirmed || $0.status == .quiet } }
    var unfinished: [Row] { rows.filter { !$0.status.isFinished } }
    var finished: [Row] { rows.filter(\.status.isFinished) }
    var hasRunning: Bool { rows.contains { $0.status == .running } }
    var hasFailed: Bool { rows.contains { $0.status == .failed } }
    /// Only running rows show a moving time.
    var ticks: Bool { hasRunning }

    /// What still runs first, then what wants a look, then what ended well.
    var summary: Summary? {
        let running = rows.count { $0.status == .running }
        let notUpdating = rows.count { $0.status == .unconfirmed || $0.status == .quiet }
        let failed = rows.count { $0.status == .failed }
        let completed = rows.count { $0.status == .completed }
        let stopped = rows.count { $0.status == .stopped }
        // Each count with its own word, whole, as "2 failed".
        var counts: [Summary.Count] = []
        if running > 0 {
            counts.append(
                .init(
                    status: .running,
                    text: String(localized: "\(running) running", comment: "Background Work bar: items that are running")))
        }
        if notUpdating > 0 {
            counts.append(.init(status: .unconfirmed, text: String(localized: "\(notUpdating) not updating")))
        }
        if failed > 0 { counts.append(.init(status: .failed, text: String(localized: "\(failed) failed"))) }
        if completed > 0 { counts.append(.init(status: .completed, text: String(localized: "\(completed) done"))) }
        if stopped > 0 { counts.append(.init(status: .stopped, text: String(localized: "\(stopped) stopped"))) }
        guard let first = counts.first else { return nil }
        return Summary(status: first.status, counts: counts)
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
                case .unconfirmed: String(localized: "Not updating")
                case .quiet:
                    lastSeen.map { String(localized: "No updates since \($0)") }
                        ?? String(localized: "No recent updates")
                default: nil
                }
            let shortNote: String? =
                switch status {
                case .quiet: row.lastActivity.map { String(localized: "Last seen \(day(of: $0))") } ?? note
                default: note
                }
            let started = row.progress?.agents ?? []
            let caption =
                switch item.kind {
                case .subagent: item.subtitle ?? String(localized: "Subagent")
                // The phase it is in: its last running agent's, or with none
                // running, its last agent's.
                case .workflow:
                    (started.last { $0.state == .running } ?? started.last)?.phase ?? String(localized: "Workflow")
                case .command: String(localized: "Command")
                }
            var spoken = [item.title, kindPhrase(item), statePhrase(status, lastSeen: lastSeen)]
            if let fraction { spoken.append(String(localized: "\(fraction.done) of \(fraction.total) agents done")) }
            if let seconds { spoken.append(ChatBackgroundWorkPresentation.duration(seconds, width: .wide, locale: locale)) }
            return Row(
                id: item.id, kind: item.kind, status: status, title: item.title, caption: caption,
                detail: item.kind == .workflow || item.kind == .command ? item.subtitle : nil, fraction: fraction,
                time: seconds.map { ChatBackgroundWorkPresentation.duration($0, width: .narrow, locale: locale) },
                note: note, shortNote: shortNote, usage: usage(item.usage), agents: agents(of: row, status: status),
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
                let label = agent.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Agent \(index + 1)")
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
                parts.append(String(localized: "\(count) tokens"))
            }
            if let toolUses = usage.toolUses {
                parts.append(toolUses == 1 ? String(localized: "1 tool use") : String(localized: "\(toolUses) tool uses"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        private func kindPhrase(_ item: ChatBackgroundWorkItem) -> String {
            switch item.kind {
            case .subagent: item.subtitle.map { String(localized: "\($0) subagent") } ?? String(localized: "Subagent")
            case .workflow: String(localized: "Workflow")
            case .command: String(localized: "Command")
            }
        }

        /// The state as one item of a spoken list, after the name.
        private func statePhrase(_ status: Status, lastSeen: String?) -> String {
            switch status {
            case .running: String(localized: "running")
            case .unconfirmed: String(localized: "not updating")
            case .quiet:
                lastSeen.map { String(localized: "no updates since \($0)") } ?? String(localized: "no recent updates")
            case .completed: String(localized: "done")
            case .failed: String(localized: "failed")
            case .stopped: String(localized: "stopped")
            }
        }

        /// A time of day if it is today, otherwise only the day.
        private func day(of date: Date) -> String {
            guard !calendar.isDate(date, inSameDayAs: now) else { return time(of: date) }
            return date.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated)
                    .day())
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
