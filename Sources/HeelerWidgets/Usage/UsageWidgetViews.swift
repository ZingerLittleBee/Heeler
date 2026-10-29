import Charts
import SwiftUI
import WidgetKit

// Widget views double-included in the app target, whose tests render them;
// the widgets, their intents and timelines stay extension-only.

/// One moment of a Usage widget.
struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageWidgetSnapshot?
    /// nil reads All Hosts.
    let hostID: UUID?
    let metric: AgentUsageMetric
    let range: AgentUsageRange
}

/// One moment of a Usage Limits widget.
struct UsageLimitsWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageWidgetSnapshot?
    /// nil picks the first Host that reported Usage Limits.
    let hostID: UUID?
    /// The program small and Lock Screen sizes show, nil for the one
    /// closest to its limit; medium and large show every program. Claude
    /// Code shows each of its Accounts, while the Host has several.
    let program: String?
}

// MARK: Usage

struct UsageWidgetView: View {
    let entry: UsageWidgetEntry
    let family: WidgetFamily
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .widgetURL(UsageWidgetLink.usageURL(hostID: scope?.hostID))
    }

    /// The chosen Host, or All Hosts once that Host leaves the catalog.
    private var scope: UsageWidgetScope? {
        guard let snapshot = entry.snapshot else { return nil }
        return UsageWidgetScope(snapshot: snapshot, hostID: entry.hostID)
            ?? UsageWidgetScope(snapshot: snapshot, hostID: nil)
    }

    @ViewBuilder
    private var content: some View {
        if let scope, !scope.isEmpty {
            switch family {
            case .systemMedium: medium(scope)
            case .systemLarge, .systemExtraLarge: large(scope)
            case .accessoryCircular: circular(scope)
            case .accessoryRectangular: rectangular(scope)
            case .accessoryInline: inline(scope)
            default: small(scope)
            }
        } else {
            UsageWidgetMessage(
                family: family, symbol: symbol(scope), title: header(scope),
                message: message(scope))
        }
    }

    // MARK: Home Screen

    private func small(_ scope: UsageWidgetScope) -> some View {
        let total = scope.total(entry.range)
        return VStack(alignment: .leading, spacing: 0) {
            UsageWidgetHeader(title: UsageWidgetText.range(entry.range), detail: scope.title)
            UsageFigure(summary: total, metric: entry.metric, size: 30)
                .padding(.top, 5)
            Text(metricName)
                .font(.caption).foregroundStyle(.secondary)
            if entry.metric == .cost {
                Text(UsageWidgetText.tokens(total.tokens, locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            UsageWeekBars(scope: scope, metric: entry.metric)
                .frame(height: 26)
            UsageWidgetUpdated(readAt: scope.updatedAt, now: entry.date)
                .padding(.top, 5)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ scope: UsageWidgetScope) -> some View {
        let total = scope.total(entry.range)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                UsageWidgetHeader(title: UsageWidgetText.range(entry.range), detail: scope.title)
                Spacer(minLength: 8)
                UsageWidgetUpdated(readAt: scope.updatedAt, now: entry.date)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    UsageFigure(summary: total, metric: entry.metric, size: 30)
                    Text(metricName)
                        .font(.caption).foregroundStyle(.secondary)
                    if entry.metric == .cost {
                        Text(UsageWidgetText.tokens(total.tokens, locale: locale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(scope.programs) { program in
                            UsageProgramRow(
                                program: program.program, name: program.name,
                                value: UsageWidgetText.value(program.summary(entry.range), metric: entry.metric, locale: locale))
                                .font(.caption)
                        }
                    }
                }
                .frame(width: 160, alignment: .leading)
                UsageAreaChart(scope: scope, metric: entry.metric, dates: scope.chartDates(entry.range), weekdays: false)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func large(_ scope: UsageWidgetScope) -> some View {
        let total = scope.total(entry.range)
        let dates = scope.chartDates(entry.range)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                UsageWidgetHeader(title: UsageWidgetText.range(entry.range), detail: scope.title)
                Spacer(minLength: 8)
                UsageWidgetUpdated(readAt: scope.updatedAt, now: entry.date)
            }
            UsageFigure(summary: total, metric: entry.metric, size: 36)
                .padding(.top, 6)
            Text(entry.metric == .cost
                ? "\(metricName) · \(UsageWidgetText.tokens(total.tokens, locale: locale))"
                : "\(metricName) · \(UsageWidgetText.cost(total.cost, locale: locale)) est.")
                .font(.footnote).foregroundStyle(.secondary)
            // The chart takes whatever the rows leave, so one Host's two
            // rows do not leave the bottom empty.
            UsageAreaChart(scope: scope, metric: entry.metric, dates: dates, weekdays: dates.count <= 7)
                .frame(minHeight: 104, maxHeight: .infinity)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(scope.programs) { program in
                    UsageTableRow(
                        leading: { UsageProgramDot(program: program.program) },
                        name: program.name, summary: program.summary(entry.range), metric: entry.metric)
                }
                if scope.hostID == nil {
                    Divider().padding(.leading, 16).padding(.vertical, 6)
                    ForEach(scope.included) { host in
                        Link(destination: UsageWidgetLink.usageURL(hostID: host.id) ?? URL(fileURLWithPath: "/")) {
                            UsageTableRow(
                                leading: {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                },
                                name: host.name,
                                summary: .sum(host.programs.map { $0.summary(entry.range) }),
                                metric: entry.metric)
                        }
                        .buttonStyle(.plain)
                    }
                    if let note = scope.excludedNote {
                        Text(note)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 16).padding(.top, 4)
                    }
                }
            }
            .padding(.top, 12)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock Screen

    private func circular(_ scope: UsageWidgetScope) -> some View {
        let total = scope.total(entry.range)
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(UsageWidgetText.short(total, metric: entry.metric, locale: locale))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                Text(UsageWidgetText.rangeShort(entry.range))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
        }
    }

    private func rectangular(_ scope: UsageWidgetScope) -> some View {
        let total = scope.total(entry.range)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                Text(UsageWidgetText.range(entry.range)).fontWeight(.semibold)
                Text("· \(scope.title)").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    UsageFigure(summary: total, metric: entry.metric, size: 22)
                    Text(entry.metric == .cost
                        ? UsageWidgetText.tokens(total.tokens, locale: locale)
                        : "\(UsageWidgetText.cost(total.cost, locale: locale)) est.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                UsageWeekBars(scope: scope, metric: entry.metric)
                    .frame(width: 56, height: 20)
                    .padding(.bottom, 4)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shares its line with the date, which leaves no room for "All Hosts";
    /// only a chosen Host is named, after the figure, so the tail is cut.
    private func inline(_ scope: UsageWidgetScope) -> some View {
        let total = scope.total(entry.range)
        let reading = "\(UsageWidgetText.short(total, metric: entry.metric, locale: locale)) \(UsageWidgetText.rangeInline(entry.range))"
        return Label(
            scope.hostID == nil ? reading : "\(reading) · \(scope.title)",
            systemImage: "chart.bar.fill")
    }

    // MARK: States

    private var metricName: String {
        entry.metric == .cost ? "Estimated API cost" : "Token Usage"
    }

    private func header(_ scope: UsageWidgetScope?) -> (String, String?) {
        guard let scope else { return ("Usage", nil) }
        return (UsageWidgetText.range(entry.range), scope.title)
    }

    private func symbol(_ scope: UsageWidgetScope?) -> String {
        guard let scope, let reason = scope.excluded.first?.excludedReason else { return "chart.bar.fill" }
        return reason == "Not connected" ? "wifi.slash" : "desktopcomputer"
    }

    private func message(_ scope: UsageWidgetScope?) -> String {
        guard let scope else { return "Open Heeler to load Usage." }
        if scope.hostID != nil, let reason = scope.excluded.first?.excludedReason {
            return reason == "Not read yet" ? "Open Heeler to load Usage." : reason
        }
        return "Open Heeler to load Usage."
    }
}

// MARK: Usage Limits

struct UsageLimitsWidgetView: View {
    let entry: UsageLimitsWidgetEntry
    let family: WidgetFamily

    var body: some View {
        content
            .widgetURL(host.flatMap { UsageWidgetLink.limitsURL(hostID: $0.id) } ?? UsageWidgetLink.usageURL(hostID: nil))
    }

    /// The chosen Host, or the first one with Usage Limits.
    private var host: UsageWidgetSnapshot.Host? {
        guard let snapshot = entry.snapshot else { return nil }
        if let hostID = entry.hostID { return snapshot.host(hostID) }
        return snapshot.hosts.first { !$0.limits.isEmpty } ?? snapshot.hosts.first
    }

    @ViewBuilder
    private var content: some View {
        if let host, host.reports {
            switch family {
            case .systemMedium: medium(host)
            case .systemLarge, .systemExtraLarge: large(host)
            case .accessoryCircular: circular(host)
            case .accessoryRectangular: rectangular(host)
            case .accessoryInline: inline(host)
            default: small(host)
            }
        } else {
            UsageWidgetMessage(
                family: family,
                symbol: host?.excludedReason == "Not connected" ? "wifi.slash" : "gauge.with.dots.needle.50percent",
                title: (host?.name ?? "Usage Limits", nil),
                message: host?.excludedReason.flatMap { $0 == "Not read yet" ? nil : $0 }
                    ?? "Open Heeler to read Usage Limits.")
        }
    }

    /// The chosen program's entries: its own, or each Claude Code Account's.
    private func programEntries(_ host: UsageWidgetSnapshot.Host) -> [UsageWidgetSnapshot.Limits] {
        UsageLimitsPick.entries(host.limits, preferring: entry.program, now: now)
    }

    private var now: Date { entry.date }

    // MARK: Home Screen

    @ViewBuilder
    private func small(_ host: UsageWidgetSnapshot.Host) -> some View {
        let entries = programEntries(host)
        if UsageLimitsLayout.program(entries) == .lines, let first = entries.first {
            // Each Account's tightest window; countdowns would not fit.
            VStack(alignment: .leading, spacing: 0) {
                UsageProgramTitle(program: first.program, name: first.name)
                Text(host.name)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 1)
                Spacer(minLength: 4)
                UsageAccountLines(entries: entries, now: now, barWidths: (26, 16), spacing: 5)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            smallFigure(host, limits: entries.first)
        }
    }

    @ViewBuilder
    private func smallFigure(_ host: UsageWidgetSnapshot.Host, limits: UsageWidgetSnapshot.Limits?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageProgramTitle(program: limits?.program ?? entry.program ?? "", name: limits?.name ?? programName)
            Text(host.name)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 1)
            Spacer(minLength: 4)
            if let limits, let window = UsageLimitsPick.tightest(limits.windows, now: now) {
                if window.isExpired(at: now) {
                    Text(window.name).font(.footnote.weight(.medium))
                    Text(UsageWidgetText.windowReset)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text(UsageWidgetText.percent(window.usedPercent))
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    Text(window.name).font(.footnote.weight(.medium))
                    UsageBar(fraction: (window.usedPercent ?? 0) / 100, program: limits.program)
                        .padding(.top, 8)
                    if let reset = window.resetsAt {
                        Text("resets in \(UsageWidgetText.countdown(to: reset, now: now))")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
            } else {
                Text(limits?.message ?? "No Usage Limits reported.")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func medium(_ host: UsageWidgetSnapshot.Host) -> some View {
        if UsageLimitsLayout.medium(host.limits) == .lines {
            VStack(alignment: .leading, spacing: 0) {
                mediumHeader(host)
                UsageLimitsLines(entries: host.limits, now: now)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            mediumColumns(host)
        }
    }

    private func mediumHeader(_ host: UsageWidgetSnapshot.Host) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(host.name).font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            UsageWidgetUpdated(readAt: host.readAt, now: now)
        }
    }

    private func mediumColumns(_ host: UsageWidgetSnapshot.Host) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            mediumHeader(host)
            HStack(alignment: .top, spacing: 12) {
                ForEach(host.limits.prefix(2)) { limits in
                    VStack(alignment: .leading, spacing: 0) {
                        // Both columns are Accounts or neither, so their
                        // titles share a size.
                        UsageProgramTitle(
                            program: limits.program, name: limits.name, account: limits.account,
                            size: limits.account == nil ? 13 : 11)
                        if let message = limits.message {
                            Text(message)
                                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                                .lineLimit(3)
                                .padding(.top, 8)
                        }
                        ForEach(limits.windows.prefix(3)) { window in
                            UsageWindowRow(window: window, program: limits.program, now: now, showsCountdown: true)
                                .padding(.top, 9)
                        }
                        Spacer(minLength: 0)
                        if let source = UsageWidgetText.shortSource(limits, now: now) {
                            Text(source).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 10)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func large(_ host: UsageWidgetSnapshot.Host) -> some View {
        let layout = UsageLimitsLayout.large(host.limits)
        if layout == .pairs || host.limits.contains(where: { $0.account != nil }) {
            VStack(alignment: .leading, spacing: 0) {
                largeHeader(host)
                UsageLimitsStack(entries: host.limits, now: now, layout: layout)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            largePrograms(host)
        }
    }

    private func largeHeader(_ host: UsageWidgetSnapshot.Host) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(host.name).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            UsageWidgetUpdated(readAt: host.readAt, now: now)
        }
    }

    private func largePrograms(_ host: UsageWidgetSnapshot.Host) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            largeHeader(host)
            ForEach(Array(host.limits.prefix(3).enumerated()), id: \.element.id) { index, limits in
                if index > 0 { Divider().padding(.top, 9) }
                UsageProgramTitle(program: limits.program, name: limits.name, size: 15)
                    .padding(.top, 9)
                if let message = limits.message {
                    Text(message)
                        .font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 6)
                }
                ForEach(limits.windows.prefix(4)) { window in
                    VStack(alignment: .leading, spacing: 0) {
                        UsageWindowRow(window: window, program: limits.program, now: now, showsCountdown: false, size: 13)
                        Text(UsageWidgetText.resetLine(window, now: now))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .padding(.top, 6)
                }
                if let source = UsageWidgetText.source(limits) {
                    Text(source)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock Screen

    @ViewBuilder
    private func circular(_ host: UsageWidgetSnapshot.Host) -> some View {
        if let reading = UsageLimitsPick.reading(programEntries(host), now: now) {
            let window = reading.window
            Gauge(value: min(max((window.usedPercent ?? 0) / 100, 0), 1)) {
                Text(reading.limits.account.map { "\($0) · \(window.name)" } ?? window.name)
            } currentValueLabel: {
                // Named, since the ring alone does not say which window it is.
                if let account = reading.limits.account {
                    VStack(spacing: 0) {
                        Text(account)
                            .font(.system(size: 8, weight: .medium))
                            .truncationMode(.middle)
                        Text(UsageWidgetText.percent(window.usedPercent))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                        Text(window.name)
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 0) {
                        Text(window.name)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(UsageWidgetText.percent(window.usedPercent))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.title3)
            }
        }
    }

    @ViewBuilder
    private func rectangular(_ host: UsageWidgetSnapshot.Host) -> some View {
        let entries = programEntries(host)
        if UsageLimitsLayout.program(entries) == .lines, let first = entries.first {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Text(first.name).fontWeight(.semibold)) \(Text("· \(host.name)").foregroundStyle(.secondary))")
                    .font(.system(size: 13))
                // The three it holds, in the app's order.
                UsageAccountLines(
                    entries: Array(entries.prefix(3)), now: now, size: 13, barWidths: (44, 30), spacing: 1)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            rectangularWindows(host, limits: entries.first)
        }
    }

    private func rectangularWindows(
        _ host: UsageWidgetSnapshot.Host, limits: UsageWidgetSnapshot.Limits?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The program first: Automatic can change it between readings.
            Text("\(Text(limits?.name ?? programName).fontWeight(.semibold)) \(Text("· \(host.name)").foregroundStyle(.secondary))")
                .font(.system(size: 13))
            if let limits, !limits.windows.isEmpty {
                ForEach(UsageLimitsPick.lockScreen(limits.windows, now: now)) { window in
                    UsageWindowRow(window: window, program: limits.program, now: now, showsCountdown: true, size: 13)
                }
            } else {
                Text(limits?.message ?? "No Usage Limits reported.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reading first: a long Host name is what the date's line cuts.
    private func inline(_ host: UsageWidgetSnapshot.Host) -> some View {
        let reading = UsageLimitsPick.reading(programEntries(host), now: now).map { reading in
            let figure = "\(reading.window.name) \(UsageWidgetText.percent(reading.window.usedPercent))"
            return reading.limits.account.map { "\($0) \(figure)" } ?? figure
        } ?? "Usage Limits"
        return Label("\(reading) · \(host.name)", systemImage: "gauge.with.dots.needle.50percent")
    }

    private var programName: String {
        switch entry.program {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case let program?: program
        case nil: "Usage Limits"
        }
    }
}

/// How a size lays out a Host's entries, Codex and each Claude Code Account
/// counting as one. A Host without Accounts keeps the layouts it had.
enum UsageLimitsLayout: Equatable {
    /// One program: the small size's big figure, the Lock Screen's windows.
    case figure
    /// One line per entry.
    case lines
    /// The medium size's columns, three windows each.
    case columns
    /// Up to four windows per entry.
    case windows
    /// Two windows per entry, side by side.
    case pairs

    /// The small and rectangular sizes, over the chosen program's entries.
    static func program(_ entries: [UsageWidgetSnapshot.Limits]) -> Self {
        entries.count > 1 ? .lines : .figure
    }

    static func medium(_ entries: [UsageWidgetSnapshot.Limits]) -> Self {
        entries.count > 2 ? .lines : .columns
    }

    static func large(_ entries: [UsageWidgetSnapshot.Limits]) -> Self {
        entries.count > 3 ? .pairs : .windows
    }
}

/// Which windows a size with room for one or two shows.
enum UsageLimitsPick {
    /// The chosen program, or with none chosen the one whose running window
    /// is closest to its limit, so a program with its limits off is not the
    /// default.
    static func program(
        _ limits: [UsageWidgetSnapshot.Limits], preferring program: String?, now: Date
    ) -> UsageWidgetSnapshot.Limits? {
        if let program { return limits.first { $0.program == program } ?? limits.first }
        let reporting = limits.filter { tightest($0.windows, now: now) != nil }
        return reporting.max {
            (tightest($0.windows, now: now)?.usedPercent ?? 0) < (tightest($1.windows, now: now)?.usedPercent ?? 0)
        } ?? limits.first
    }

    /// Every entry of that program: its own, or each Claude Code Account's.
    static func entries(
        _ limits: [UsageWidgetSnapshot.Limits], preferring program: String?, now: Date
    ) -> [UsageWidgetSnapshot.Limits] {
        guard let chosen = self.program(limits, preferring: program, now: now)?.program else { return [] }
        return limits.filter { $0.program == chosen }
    }

    /// The one reading the circular and inline sizes hold: a program's
    /// soonest window, or with several Accounts the running window closest
    /// to its limit, so the Account it names is the one to watch.
    static func reading(
        _ entries: [UsageWidgetSnapshot.Limits], now: Date
    ) -> (limits: UsageWidgetSnapshot.Limits, window: UsageWidgetSnapshot.Window)? {
        if entries.count > 1 {
            let closest = entries.compactMap { limits in
                running(limits.windows, now: now).max(by: lessUsed).map { (limits: limits, window: $0) }
            }
            .max { lessUsed($0.window, $1.window) }
            if let closest { return closest }
        }
        return entries.lazy.compactMap { limits in
            shortest(limits.windows, now: now).map { (limits: limits, window: $0) }
        }.first
    }

    /// The most used window still running; an ended window only when no
    /// other is left.
    static func tightest(_ windows: [UsageWidgetSnapshot.Window], now: Date) -> UsageWidgetSnapshot.Window? {
        running(windows, now: now).max(by: lessUsed) ?? windows.first
    }

    /// The window that resets soonest, the one an agent runs into first.
    static func shortest(_ windows: [UsageWidgetSnapshot.Window], now: Date) -> UsageWidgetSnapshot.Window? {
        running(windows, now: now).min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
            ?? windows.first
    }

    private static func running(_ windows: [UsageWidgetSnapshot.Window], now: Date) -> [UsageWidgetSnapshot.Window] {
        windows.filter { !$0.isExpired(at: now) && $0.usedPercent != nil }
    }

    private static func lessUsed(_ lhs: UsageWidgetSnapshot.Window, _ rhs: UsageWidgetSnapshot.Window) -> Bool {
        (lhs.usedPercent ?? 0) < (rhs.usedPercent ?? 0)
    }

    /// The soonest window, then the most used of the rest.
    static func lockScreen(_ windows: [UsageWidgetSnapshot.Window], now: Date) -> [UsageWidgetSnapshot.Window] {
        guard let first = shortest(windows, now: now) else { return [] }
        let rest = windows.filter { $0.id != first.id }
        return [first] + (tightest(rest, now: now).map { [$0] } ?? [])
    }
}

// MARK: Parts

/// A widget with nothing to add up: why, and where to go.
struct UsageWidgetMessage: View {
    let family: WidgetFamily
    let symbol: String
    let title: (String, String?)
    let message: String

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(message, systemImage: symbol)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol).font(.title3)
            }
            .accessibilityLabel(message)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(title.0).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 0) {
                UsageWidgetHeader(title: title.0, detail: title.1)
                Spacer(minLength: 8)
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// "Today · All Hosts".
struct UsageWidgetHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        (Text(title).fontWeight(.semibold)
            + Text(detail.map { " · \($0)" } ?? "").foregroundStyle(.secondary))
            .font(.footnote)
            .lineLimit(1)
    }
}

/// When the figures were read; a stale reading says so in a capsule.
struct UsageWidgetUpdated: View {
    let readAt: Date?
    let now: Date

    var body: some View {
        if let readAt {
            if UsageWidgetText.isStale(readAt, now: now) {
                Label(UsageWidgetText.updated(readAt, now: now), systemImage: "clock")
                    .labelStyle(UsageCompactLabelStyle())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: .capsule)
                    .widgetAccentable()
            } else {
                Text(UsageWidgetText.updated(readAt, now: now))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The figure a widget leads with: a cost, or a token count with its unit.
struct UsageFigure: View {
    let summary: UsageWidgetSnapshot.Summary
    let metric: AgentUsageMetric
    let size: CGFloat
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            switch metric {
            case .cost:
                Text(UsageWidgetText.cost(summary.cost, locale: locale))
            case .tokens:
                Text(AgentUsageStyle.tokens(summary.tokens, locale: locale))
                    + Text(" tokens").font(.system(size: size * 0.5, weight: .semibold))
            }
        }
        .font(.system(size: size, weight: .semibold).monospacedDigit())
        .minimumScaleFactor(0.5)
        .lineLimit(1)
    }
}

struct UsageProgramDot: View {
    let program: String
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Circle()
            .fill(UsageWidgetColor.program(program, mode: renderingMode))
            .frame(width: 8, height: 8)
            .widgetAccentable(program == "claude")
    }
}

/// A program's dot and name, heading its Usage Limits: "Claude Code ·
/// claude-2" for an Account, or the Account alone where that does not fit,
/// since the name is what tells Accounts apart.
struct UsageProgramTitle: View {
    let program: String
    let name: String
    var account: String?
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            UsageProgramDot(program: program)
            if let account {
                ViewThatFits(in: .horizontal) {
                    Text("\(name) · \(account)")
                    Text(account).truncationMode(.middle)
                }
                .font(.system(size: size, weight: .semibold))
            } else {
                Text(name).font(.system(size: size, weight: .semibold))
            }
        }
        .lineLimit(1)
    }
}

/// A program's Accounts, one line each. Every line's bar is as wide, and
/// narrows when the longest name would not fit beside it.
struct UsageAccountLines: View {
    let entries: [UsageWidgetSnapshot.Limits]
    let now: Date
    var size: CGFloat = 12
    let barWidths: (wide: CGFloat, narrow: CGFloat)
    let spacing: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            lines(barWidth: barWidths.wide)
            lines(barWidth: barWidths.narrow)
        }
    }

    private func lines(barWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(entries) { UsageAccountLine(limits: $0, now: now, size: size, barWidth: barWidth) }
        }
    }
}

/// One Claude Code Account on one line: its name, and its tightest running
/// window's bar and percentage. No reading leaves the bar empty.
struct UsageAccountLine: View {
    let limits: UsageWidgetSnapshot.Limits
    let now: Date
    var size: CGFloat = 12
    let barWidth: CGFloat

    var body: some View {
        let window = UsageLimitsPick.tightest(limits.windows, now: now).flatMap { $0.isExpired(at: now) ? nil : $0 }
        HStack(spacing: 6) {
            Text(limits.account ?? limits.name)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            UsageBar(fraction: (window?.usedPercent ?? 0) / 100, program: limits.program)
                .frame(width: barWidth)
            Text(UsageWidgetText.percent(window?.usedPercent))
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: size * 2.6, alignment: .trailing)
        }
        .font(.system(size: size))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(window))
    }

    private func accessibilityLabel(_ window: UsageWidgetSnapshot.Window?) -> String {
        let name = limits.account ?? limits.name
        guard let window else { return "\(name), \(limits.message ?? UsageWidgetText.windowReset)" }
        return "\(name), \(window.name) \(UsageWidgetText.percent(window.usedPercent))"
    }
}

/// A medium widget's entries, one line each: the window that resets
/// soonest and the most used of the rest. More entries take tighter lines.
struct UsageLimitsLines: View {
    let entries: [UsageWidgetSnapshot.Limits]
    let now: Date

    var body: some View {
        ViewThatFits(in: .vertical) {
            lines(showsProgram: true, size: 12, spacing: 7)
            lines(showsProgram: false, size: 12, spacing: 5)
            lines(showsProgram: false, size: 11, spacing: 2)
        }
    }

    private func lines(showsProgram: Bool, size: CGFloat, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(entries) { limits in
                UsageLimitsLine(limits: limits, now: now, showsProgram: showsProgram, size: size)
            }
        }
    }
}

/// An entry's name, "Claude Code" under an Account's while there is room,
/// beside its two windows or why it has none.
struct UsageLimitsLine: View {
    let limits: UsageWidgetSnapshot.Limits
    let now: Date
    let showsProgram: Bool
    let size: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    UsageProgramDot(program: limits.program)
                    Text(limits.account ?? limits.name)
                        .font(.system(size: size, weight: .semibold))
                        .truncationMode(.middle)
                }
                if showsProgram && limits.account != nil {
                    Text(limits.name)
                        .font(.system(size: size - 3))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 13)
                }
            }
            .frame(width: 70, alignment: .leading)
            if limits.windows.isEmpty {
                // As tall as a window's row, so the lines stay evenly spaced.
                VStack(alignment: .leading, spacing: 4) {
                    Text(limits.message ?? "No Usage Limits reported.")
                        .font(.system(size: size - 1))
                        .foregroundStyle(.secondary)
                    Color.clear.frame(height: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                windows
            }
        }
        .lineLimit(1)
    }

    private var windows: some View {
        let shown = UsageLimitsPick.lockScreen(limits.windows, now: now)
        return ForEach(0..<2, id: \.self) { index in
            if shown.indices.contains(index) {
                UsageWindowRow(
                    window: shown[index], program: limits.program, now: now, showsCountdown: true, size: size - 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }
}

/// A large widget's entries once a Host has Claude Code Accounts: up to
/// three keep four windows each with their countdowns inline; more, or
/// what does not fit, take two windows each side by side.
struct UsageLimitsStack: View {
    let entries: [UsageWidgetSnapshot.Limits]
    let now: Date
    let layout: UsageLimitsLayout

    var body: some View {
        ViewThatFits(in: .vertical) {
            if layout == .windows { stack(.windows) }
            stack(.pairs(resets: true))
            stack(.pairs(resets: false))
        }
    }

    private func stack(_ style: UsageLimitsEntry.Style) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, limits in
                if index > 0 { Divider().padding(.top, style == .windows ? 8 : 7) }
                UsageLimitsEntry(limits: limits, now: now, style: style)
            }
        }
    }
}

/// One entry of a large widget: its title, then its windows.
struct UsageLimitsEntry: View {
    enum Style: Equatable {
        /// Up to four, one per row.
        case windows
        /// The soonest and the most used of the rest, side by side, with
        /// when each resets while there is room.
        case pairs(resets: Bool)
    }

    let limits: UsageWidgetSnapshot.Limits
    let now: Date
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UsageProgramTitle(program: limits.program, name: limits.name, account: limits.account, size: 14)
                Spacer(minLength: 0)
                if let source = UsageWidgetText.shortSource(limits, now: now) {
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, style == .windows ? 8 : 7)
            if let message = limits.message {
                Text(message)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(style == .windows ? 2 : 1)
                    .padding(.top, 4)
            }
            switch style {
            case .windows:
                ForEach(limits.windows.prefix(4)) { window in
                    UsageWindowRow(window: window, program: limits.program, now: now, showsCountdown: true, size: 13)
                        .padding(.top, 5)
                }
            case .pairs(let resets):
                if !limits.windows.isEmpty { pairs(resets: resets).padding(.top, 5) }
            }
        }
    }

    private func pairs(resets: Bool) -> some View {
        let shown = UsageLimitsPick.lockScreen(limits.windows, now: now)
        return HStack(alignment: .top, spacing: 14) {
            ForEach(0..<2, id: \.self) { index in
                if shown.indices.contains(index) {
                    VStack(alignment: .leading, spacing: 3) {
                        UsageWindowRow(
                            window: shown[index], program: limits.program, now: now, showsCountdown: true, size: 12)
                        if resets, let reset = UsageWidgetText.resetDay(shown[index], now: now) {
                            Text(reset).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
        }
    }
}

struct UsageProgramRow: View {
    let program: String
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            UsageProgramDot(program: program)
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

/// A large Usage widget's row: the figure, and the other metric beside it.
struct UsageTableRow<Leading: View>: View {
    @ViewBuilder let leading: () -> Leading
    let name: String
    let summary: UsageWidgetSnapshot.Summary
    let metric: AgentUsageMetric
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            leading().frame(width: 8)
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(metric == .cost
                ? AgentUsageStyle.tokens(summary.tokens, locale: locale)
                : UsageWidgetText.cost(summary.cost, locale: locale))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(UsageWidgetText.value(summary, metric: metric, locale: locale))
                .fontWeight(.semibold)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .frame(height: 20)
    }
}

/// One window: name, countdown, percentage, and its bar; an ended window
/// says its usage is unknown.
struct UsageWindowRow: View {
    let window: UsageWidgetSnapshot.Window
    let program: String
    let now: Date
    let showsCountdown: Bool
    var size: CGFloat = 12

    var body: some View {
        let expired = window.isExpired(at: now)
        VStack(alignment: .leading, spacing: 4) {
            // A long name first takes a smaller size, then the countdown's
            // room; the bar and the percentage stay.
            ViewThatFits(in: .horizontal) {
                heading(expired: expired, size: size, countdown: showsCountdown)
                heading(expired: expired, size: size - 1.5, countdown: showsCountdown)
                heading(expired: expired, size: size, countdown: false)
            }
            if expired {
                Text(UsageWidgetText.windowReset)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, -2)
            } else {
                UsageBar(fraction: (window.usedPercent ?? 0) / 100, program: program)
            }
        }
        .lineLimit(1)
    }

    private func heading(expired: Bool, size: CGFloat, countdown: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(window.name).fontWeight(.medium)
                .font(.system(size: size))
            Spacer(minLength: 0)
            if !expired {
                if countdown, let reset = window.resetsAt {
                    Text(UsageWidgetText.countdown(to: reset, now: now))
                        .font(.system(size: size - 1).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(UsageWidgetText.percent(window.usedPercent))
                    .font(.system(size: self.size, weight: .semibold).monospacedDigit())
            }
        }
    }
}

struct UsageBar: View {
    let fraction: Double
    let program: String
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Capsule()
            .fill(.primary.opacity(renderingMode == .fullColor ? 0.1 : 0.25))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(UsageWidgetColor.program(program, mode: renderingMode))
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        .widgetAccentable()
                }
            }
            .frame(height: 4)
    }
}

/// The last seven days as stacked bars, today's at full strength.
struct UsageWeekBars: View {
    let scope: UsageWidgetScope
    let metric: AgentUsageMetric
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let dates = Array(scope.dates.suffix(7))
        let totals = dates.map { date in scope.programs.reduce(0) { $0 + ($1.days[date]?.value(metric) ?? 0) } }
        let maximum = max(totals.max() ?? 0, 1)
        GeometryReader { proxy in
            // The Lock Screen's strip is too narrow for gaps inside a bar.
            let narrow = proxy.size.width < 80
            HStack(alignment: .bottom, spacing: narrow ? 2 : 4) {
                ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                    VStack(spacing: narrow ? 0 : 1) {
                        // Codex below Claude Code, as the charts stack them.
                        ForEach(scope.programs) { program in
                            let value = program.days[date]?.value(metric) ?? 0
                            if value > 0 {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(UsageWidgetColor.program(program.program, mode: renderingMode))
                                    .frame(height: max(proxy.size.height * value / maximum, 1.5))
                                    .widgetAccentable(program.program == "claude")
                            }
                        }
                        if totals[index] == 0 {
                            RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.4)).frame(height: 1.5)
                        }
                    }
                    .opacity(index == dates.count - 1 ? 1 : 0.4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Days as stacked areas, Codex below Claude Code, with a few gridlines.
struct UsageAreaChart: View {
    let scope: UsageWidgetScope
    let metric: AgentUsageMetric
    let dates: [String]
    /// A week's chart names its days; a month's dates three of them.
    let weekdays: Bool
    @Environment(\.locale) private var locale
    @Environment(\.widgetRenderingMode) private var renderingMode

    private struct Band: Identifiable {
        let program: String
        let index: Int
        let lower: Double
        let upper: Double
        var id: String { "\(program)\(index)" }
    }

    var body: some View {
        let bands = bands
        Chart {
            ForEach(bands) { band in
                AreaMark(
                    x: .value("Day", band.index), yStart: .value("Start", band.lower),
                    yEnd: .value("End", band.upper), series: .value("Program", band.program))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(UsageWidgetColor.program(band.program, mode: renderingMode).opacity(0.16))
            }
            ForEach(bands) { band in
                LineMark(
                    x: .value("Day", band.index), y: .value("Value", band.upper),
                    series: .value("Program", band.program))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(UsageWidgetColor.program(band.program, mode: renderingMode))
                    .lineStyle(StrokeStyle(
                        lineWidth: 1.5, lineJoin: .round,
                        dash: renderingMode != .fullColor && band.program != "claude" ? [3, 2] : []))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(dates.count - 1, 1))
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisValueLabel(anchor: anchor(value.as(Int.self))) {
                    if let index = value.as(Int.self), dates.indices.contains(index) {
                        Text(UsageWidgetText.day(dates[index], weekday: weekdays, locale: locale))
                    }
                }
                .font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(UsageWidgetText.axis(amount, metric: metric, locale: locale))
                    }
                }
                .font(.system(size: 10))
            }
        }
        .accessibilityHidden(true)
    }

    /// Stacked bottom up in reverse program order: Codex below Claude Code.
    private var bands: [Band] {
        var bands: [Band] = []
        for (index, date) in dates.enumerated() {
            var lower = 0.0
            for program in scope.programs.reversed() {
                let value = program.days[date]?.value(metric) ?? 0
                bands.append(Band(program: program.program, index: index, lower: lower, upper: lower + value))
                lower += value
            }
        }
        return bands
    }

    private var xTicks: [Int] {
        guard dates.count > 1 else { return [0] }
        if weekdays { return Array(dates.indices) }
        return [0, (dates.count - 1) / 2, dates.count - 1]
    }

    /// Edge labels hug the plot so the chart keeps them.
    private func anchor(_ index: Int?) -> UnitPoint {
        if dates.count <= 1 { return .top }
        if index == 0 { return .topLeading }
        if index == dates.count - 1 { return .topTrailing }
        return .top
    }
}

/// Program colors, kept apart by weight when a tinted Home Screen drops
/// them to one accent.
enum UsageWidgetColor {
    static func program(_ program: String, mode: WidgetRenderingMode) -> Color {
        guard mode == .fullColor else { return program == "claude" ? .primary : .primary.opacity(0.55) }
        return AgentUsageStyle.color(for: program)
    }
}

// MARK: Copy

enum UsageWidgetText {
    static let windowReset = "Reset · usage unknown"

    /// After an hour a reading reads as stale.
    static let staleAfter: TimeInterval = 3_600

    static func isStale(_ readAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(readAt) >= staleAfter
    }

    /// "Updated 5:38 PM", or the day for an older reading.
    static func updated(_ readAt: Date, now: Date) -> String {
        Calendar.current.isDate(readAt, inSameDayAs: now)
            ? "Updated \(readAt.formatted(date: .omitted, time: .shortened))"
            : "Updated \(readAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static func range(_ range: AgentUsageRange) -> String {
        switch range {
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        }
    }

    static func rangeShort(_ range: AgentUsageRange) -> String {
        switch range {
        case .today: "Today"
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        }
    }

    static func rangeInline(_ range: AgentUsageRange) -> String {
        switch range {
        case .today: "today"
        case .last7Days: "last 7 days"
        case .last30Days: "last 30 days"
        }
    }

    static func cost(_ value: Double?, locale: Locale) -> String {
        AgentUsageStyle.cost(value, locale: locale)
    }

    static func tokens(_ value: Int64, locale: Locale) -> String {
        "\(AgentUsageStyle.tokens(value, locale: locale)) tokens"
    }

    static func value(_ summary: UsageWidgetSnapshot.Summary, metric: AgentUsageMetric, locale: Locale) -> String {
        switch metric {
        case .cost: AgentUsageStyle.cost(summary.cost, locale: locale)
        case .tokens: AgentUsageStyle.tokens(summary.tokens, locale: locale)
        }
    }

    /// A Lock Screen figure: whole dollars past $1,000.
    static func short(_ summary: UsageWidgetSnapshot.Summary, metric: AgentUsageMetric, locale: Locale) -> String {
        switch metric {
        case .cost: AgentUsageStyle.shortCost(summary.cost, locale: locale)
        case .tokens: AgentUsageStyle.tokens(summary.tokens, locale: locale)
        }
    }

    static func axis(_ value: Double, metric: AgentUsageMetric, locale: Locale) -> String {
        switch metric {
        // Compact, so thousands do not squeeze the plot: "$2K".
        case .cost:
            value.formatted(
                .currency(code: "USD").notation(.compactName).precision(.significantDigits(1...2)).locale(locale))
        case .tokens:
            AgentUsageStyle.tokens(Int64(value), locale: locale)
        }
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func countdown(to reset: Date, now: Date) -> String {
        AgentUsageStyle.countdown(to: reset, now: now, locale: .current)
    }

    /// "resets in 1h 48m · 7:26 PM", the day added when it is not today.
    static func resetLine(_ window: UsageWidgetSnapshot.Window, now: Date) -> String {
        guard let reset = window.resetsAt else { return window.isExpired(at: now) ? windowReset : "" }
        if window.isExpired(at: now) { return windowReset }
        return "resets in \(countdown(to: reset, now: now)) · \(clock(reset, now: now))"
    }

    /// "resets 7:26 PM", or "resets Oct 30" when it is not today, beside a
    /// countdown that gives the rest; nil once the window has ended.
    static func resetDay(_ window: UsageWidgetSnapshot.Window, now: Date) -> String? {
        guard let reset = window.resetsAt, !window.isExpired(at: now) else { return nil }
        let when = Calendar.current.isDate(reset, inSameDayAs: now)
            ? reset.formatted(date: .omitted, time: .shortened)
            : reset.formatted(.dateTime.month(.abbreviated).day())
        return "resets \(when)"
    }

    /// Where a program's windows came from, as clock times that a widget
    /// does not have to keep redrawing.
    static func source(_ limits: UsageWidgetSnapshot.Limits) -> String? {
        guard let observed = limits.observedAt else { return nil }
        let time = observed.formatted(date: .omitted, time: .shortened)
        if limits.isLastReading { return "Last reading · as of \(time)" }
        switch limits.source {
        case .lastSession: return "Last session · as of \(time)"
        case .program: return "From \(limits.name) · as of \(time)"
        case nil: return nil
        }
    }

    /// A medium widget's foot: only a reading that is not the program's
    /// own current answer is called out.
    static func shortSource(_ limits: UsageWidgetSnapshot.Limits, now: Date) -> String? {
        guard let observed = limits.observedAt else { return nil }
        let time = clock(observed, now: now)
        if limits.isLastReading { return "Last reading · \(time)" }
        return limits.source == .lastSession ? "Last session · \(time)" : nil
    }

    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// A chart's `YYYY-MM-DD` day, read in UTC so it never shifts again.
    static func day(_ day: String, weekday: Bool, locale: Locale) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard parts.count == 3,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt)
        return weekday
            ? date.formatted(style.weekday(.abbreviated))
            : date.formatted(style.month(.abbreviated).day())
    }
}
