import SwiftUI

/// One Host the Usage tab can read, with the store that reads it.
@MainActor
struct AgentUsageHostEntry: Identifiable {
    let id: Host.ID
    let name: String
    let store: AgentUsageStore
    let isConnected: Bool

    var reading: AgentUsageScope.HostReading {
        .init(id: id, name: name, state: store.state, refreshFailure: store.refreshFailure,
            isRetryingRefresh: store.isRetryingRefresh, isConnected: isConnected)
    }
}

/// The Usage tab's page: Token Usage added up across the scope's Hosts,
/// read by day, with Usage Limits kept per Host.
struct AgentUsageDashboard: View {
    let entries: [AgentUsageHostEntry]
    /// nil reads every Host.
    @Binding var scopeHostID: Host.ID?
    /// Shared with an iPad's sidebar, whose figures follow it.
    @Binding var metric: AgentUsageMetric
    /// An iPad's wide layout reads Usage Limits in place of Token Usage.
    @Binding var showsLimits: Bool
    /// A widget asked for the scope's Usage Limits: the wide layout's page,
    /// or the sheet.
    @Binding var limitsRequested: Bool
    /// An iPad's detail column lays the page out in two columns when it
    /// has the width for them.
    var allowsColumns = false

    init(
        entries: [AgentUsageHostEntry], scopeHostID: Binding<Host.ID?>, metric: Binding<AgentUsageMetric>,
        showsLimits: Binding<Bool> = .constant(false), limitsRequested: Binding<Bool> = .constant(false),
        allowsColumns: Bool = false
    ) {
        self.entries = entries
        _scopeHostID = scopeHostID
        _metric = metric
        _showsLimits = showsLimits
        _limitsRequested = limitsRequested
        self.allowsColumns = allowsColumns
    }

    @State private var range = AgentUsageRange.last30Days
    /// The day the chart is held on, or, in the wide layout, the day the
    /// chart and calendar share.
    @State private var selectedDay: String?
    @State private var daySheet: AgentUsageDaySelection?
    @State private var isShowingLimits = false
    /// The Host whose Claude Code Accounts sheet is open.
    @State private var accountsHostID: Host.ID?
    @State private var breakdown = AgentUsageBreakdown.Kind.models
    @State private var width: CGFloat = 0
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var scopedEntries: [AgentUsageHostEntry] {
        guard let scopeHostID else { return entries }
        return entries.filter { $0.id == scopeHostID }
    }

    var body: some View {
        let scope = AgentUsageScope(readings: scopedEntries.map(\.reading))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isWide && showsLimits {
                    AgentUsageLimitsPage(entries: scopedEntries, showAccounts: { accountsHostID = $0 }) {
                        showsLimits = false
                    }
                } else {
                    if !isWide { controls }
                    content(scope)
                }
            }
            .padding(.horizontal, isWide ? 30 : 16)
            .padding(.bottom, 24)
            .frame(maxWidth: isWide ? 1_240 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar {
            if isWide {
                ToolbarItem(placement: .topBarTrailing) { widePicker }
                if !showsLimits {
                    ToolbarItem(placement: .topBarTrailing) { rangePicker.frame(width: 300) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .disabled(scope.refreshing)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .modifier(AgentUsageSubtitle(scope: scope))
        // Every Host polls while the page is on screen: the scope menu and
        // an iPad's sidebar show each one's figures whatever the scope.
        .background {
            ForEach(entries) { entry in
                Color.clear.task(id: entry.store.refreshKey) { await entry.store.refresh() }
            }
        }
        .refreshable { await refresh() }
        .sheet(item: $daySheet) { selection in
            AgentUsageDaySheet(scope: scope, selection: selection, isFormSheet: sizeClass == .regular)
                .presentationSizing(.form)
        }
        .sheet(isPresented: $isShowingLimits) {
            AgentUsageLimitsSheet(entries: scopedEntries)
        }
        .modifier(ClaudeAccountsSheetPresenter(hostID: $accountsHostID, entries: entries))
        .onChange(of: scopeHostID) { selectedDay = nil }
        // Waits for the first layout: until then the page cannot tell wide
        // from compact.
        .onChange(of: limitsRequested && width > 0, initial: true) { _, ready in
            guard ready else { return }
            limitsRequested = false
            if isWide { showsLimits = true } else { isShowingLimits = true }
        }
    }

    private var isWide: Bool { allowsColumns && width >= 860 }

    private func refresh() async {
        let stores = scopedEntries.map(\.store)
        await withDiscardingTaskGroup { group in
            for store in stores {
                group.addTask { await store.pullToRefresh() }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Metric", selection: $metric) {
                ForEach(AgentUsageMetric.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 148)
            rangePicker
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(AgentUsageRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// Est. Cost, Tokens or Limits.
    private var widePicker: some View {
        Picker("View", selection: Binding(
            get: { showsLimits ? nil : metric },
            set: { value in
                if let value { metric = value }
                showsLimits = value == nil
            }
        )) {
            ForEach(AgentUsageMetric.allCases) { Text($0.title).tag(Optional($0)) }
            Text("Limits").tag(AgentUsageMetric?.none)
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
    }

    @ViewBuilder
    private func content(_ scope: AgentUsageScope) -> some View {
        if scope.isEmpty {
            emptyState(scope)
        } else {
            ForEach(scope.included.filter { $0.refreshFailure != nil }) { host in
                failureBanner(host, isOnlyHost: scope.included.count == 1)
            }
            accountsNotice
            if isWide {
                AgentUsageWideColumns {
                    VStack(alignment: .leading, spacing: 0) {
                        wideHero(scope)
                        programRows(scope)
                    }
                } trailing: {
                    wideChart(scope)
                }
                AgentUsageWideColumns {
                    wideCalendar(scope)
                } trailing: {
                    wideBreakdown(scope)
                }
                .padding(.top, 30)
                AgentUsageLimitsStrip(entries: scopedEntries.filter { entry in
                    scope.included.contains { $0.id == entry.id }
                }) { showsLimits = true }
                .padding(.top, 30)
            } else {
                hero(scope)
                limitsSection(scope)
                chartCard(scope)
                calendarCard(scope)
                if showsHosts(scope) { hostsSection(scope) }
                programsSection(scope)
                breakdownSection(scope)
            }
            footer(scope)
        }
    }

    // MARK: Hero

    private func hero(_ scope: AgentUsageScope) -> some View {
        let summary = selectedDay.map(scope.day) ?? scope.total(range)
        let metricName = metric == .cost ? "Estimated API cost" : "Token Usage"
        let label: Text
        if let selectedDay {
            label = Text(AgentUsageCalendarDay.text(selectedDay, locale: locale, calendar: calendar,
                    includesYear: false, includesWeekday: true))
                .fontWeight(.semibold).foregroundStyle(.primary)
                + Text(" · \(metricName)")
        } else {
            label = Text("\(metricName) · \(rangeName)")
        }
        let place = Self.place(scope)
        return VStack(alignment: .leading, spacing: 0) {
            label
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric == .cost
                    ? AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)
                    : AgentUsageStyle.tokens(summary.tokens.total, locale: locale))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if metric == .tokens {
                    Text("tokens").font(.title3)
                }
            }
            Text(metric == .cost
                ? "\(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens \(place)"
                : "Estimated API cost \(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)) \(place)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let unpriced = summary.unpricedTokens, unpriced > 0, metric == .cost {
                Text("Includes unpriced tokens (\(AgentUsageStyle.tokens(unpriced, locale: locale)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !scope.excluded.isEmpty {
                Text(notIncluded(scope))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .onTapGesture { selectedDay = nil }
        .accessibilityElement(children: .combine)
    }

    private var rangeName: String {
        switch range {
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        }
    }

    // MARK: Usage Limits

    private func limitsSection(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Usage Limits", detail: scope.included.count > 1 ? "per Host" : nil) {
                Button("Details") { isShowingLimits = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentUsageLimitChip.chips(in: scope)) { chip in
                        Button { isShowingLimits = true } label: {
                            AgentUsageLimitChipView(chip: chip, showsHost: scope.included.count > 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
        .padding(.top, 22)
    }

    // MARK: Chart and calendar

    private func chartDates(_ scope: AgentUsageScope) -> [String] {
        Array(scope.dates.suffix(max(range.dayCount, 7)))
    }

    private func chartCard(_ scope: AgentUsageScope) -> some View {
        AgentUsageDailyChart(
            scope: scope, metric: metric, dates: chartDates(scope), selection: $selectedDay)
            .padding(16)
            .background(cardBackground)
            .padding(.top, 12)
    }

    private func calendarCard(_ scope: AgentUsageScope) -> some View {
        let dates = scope.dates
        let today = dates.last ?? ""
        let first = dates.suffix(30).first ?? today
        let values = Dictionary(uniqueKeysWithValues: dates.map { ($0, metric.value(of: scope.day($0))) })
        let coveredFrom = scope.included.compactMap { $0.report.scan?.coveredFrom }.min()
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(dayText(first)) – \(dayText(today))")
                        .font(.headline)
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        Text(metric == .cost ? "Estimated API cost per day" : "Tokens per day")
                        Text("Per day")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                AgentUsageCalendar(
                    values: values, today: today, coveredFrom: coveredFrom, selected: daySheet?.day
                ) { day in
                    daySheet = AgentUsageDaySelection(day: day, dates: Array(dates.suffix(30)))
                }
            }
            .padding(16)
            .background(cardBackground)
            if let note = scope.dayNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 7)
            }
        }
        .padding(.top, 16)
    }

    // MARK: Hosts

    private func showsHosts(_ scope: AgentUsageScope) -> Bool {
        scopeHostID == nil && entries.count > 1
    }

    private func hostsSection(_ scope: AgentUsageScope) -> some View {
        let total = scope.included.reduce(0) { $0 + metric.value(of: $1.last30Days) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Hosts", detail: "Last 30 days")
            VStack(spacing: 0) {
                ForEach(Array(scope.included.enumerated()), id: \.element.id) { index, host in
                    if index > 0 { Divider().padding(.leading, 42) }
                    Button { scopeHostID = host.id } label: {
                        hostRow(name: host.name, symbol: "desktopcomputer", tint: .accentColor,
                            subtitle: "\(AgentUsageStyle.share(metric.value(of: host.last30Days), of: total, locale: locale)) · \(AgentUsageStyle.tokens(host.last30Days.tokens.total, locale: locale)) tokens",
                            value: AgentUsageStyle.value(host.last30Days, metric: metric, locale: locale))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(scope.excluded) { host in
                    Divider().padding(.leading, 42)
                    hostRow(name: host.name, symbol: host.reason == "Not connected" ? "wifi.slash" : "desktopcomputer",
                        tint: Color(uiColor: .systemGray3), subtitle: host.reason, value: nil)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .background(cardBackground)
        }
        .padding(.top, 26)
    }

    private func hostRow(name: String, symbol: String, tint: Color, subtitle: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.body.weight(.semibold)).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 62)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    // MARK: Programs

    private func programsSection(_ scope: AgentUsageScope) -> some View {
        let summaries = scope.programs.map { (program: $0, summary: range.summary(in: $0.totals)) }
        let total = summaries.reduce(0) { $0 + metric.value(of: $1.summary) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Programs", detail: rangeName)
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(summaries, id: \.program.id) { entry in
                            AgentUsageStyle.color(for: entry.program.program)
                                .frame(width: total > 0
                                    ? max((proxy.size.width - CGFloat(summaries.count - 1) * 2)
                                        * metric.value(of: entry.summary) / total, 0) : 0)
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(.capsule)
                .accessibilityHidden(true)
                ForEach(Array(summaries.enumerated()), id: \.element.program.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 16) }
                    programRow(entry.program, summary: entry.summary, total: total)
                    accountRows(scope, program: entry.program, summary: entry.summary)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .background(cardBackground)
        }
        .padding(.top, 26)
    }

    private func programRow(
        _ program: AgentUsageScope.Program, summary: AgentUsageReport.Summary, total: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(AgentUsageStyle.color(for: program.program))
                    .frame(width: 8, height: 8)
                Text(program.displayName)
                Spacer(minLength: 8)
                Text(AgentUsageStyle.value(summary, metric: metric, locale: locale))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(isWide ? .title3 : .body)
            Text("\(AgentUsageStyle.share(metric.value(of: summary), of: total, locale: locale)) \(metric == .cost ? "of est. cost" : "of tokens") · \(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens")
                .font(isWide ? .subheadline : .footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.leading, 16)
            if let unpriced = summary.unpricedTokens, unpriced > 0 {
                Text("Includes unpriced tokens (\(AgentUsageStyle.tokens(unpriced, locale: locale)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, isWide ? 8 : 12)
        .accessibilityElement(children: .combine)
    }

    /// The program's readable Accounts for the range, when its Host has
    /// several; they add up to the program's figure.
    private func accountRows(
        _ scope: AgentUsageScope, program: AgentUsageScope.Program, summary: AgentUsageReport.Summary
    ) -> some View {
        let accounts = scope.accounts(of: program.program, range: range)
        return ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
            if index > 0 { Divider().padding(.leading, 16) }
            AgentUsageAccountRow(
                account: account, program: program, programSummary: summary, metric: metric, isWide: isWide)
        }
    }

    // MARK: Wide layout

    private func wideHero(_ scope: AgentUsageScope) -> some View {
        let summary = scope.total(range)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric == .cost
                    ? AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)
                    : AgentUsageStyle.tokens(summary.tokens.total, locale: locale))
                    .font(.system(size: 56, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if metric == .tokens { Text("tokens").font(.title2) }
            }
            Text("\(metric == .cost ? "Estimated API cost" : "Token Usage") \(Self.place(scope)) · \(rangeName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .accessibilityElement(children: .combine)
    }

    private func programRows(_ scope: AgentUsageScope) -> some View {
        let summaries = scope.programs.map { (program: $0, summary: range.summary(in: $0.totals)) }
        let total = summaries.reduce(0) { $0 + metric.value(of: $1.summary) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(summaries, id: \.program.id) { entry in
                programRow(entry.program, summary: entry.summary, total: total)
                accountRows(scope, program: entry.program, summary: entry.summary)
            }
        }
        .padding(.top, 14)
    }

    private func wideChart(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric == .cost ? "Daily estimated API cost" : "Daily tokens")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(range == .today ? "Last 7 days" : rangeName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            AgentUsageDailyChart(
                scope: scope, metric: metric, dates: chartDates(scope), selection: $selectedDay,
                pinsSelection: true)
        }
        .padding(.top, 24)
    }

    private func wideCalendar(_ scope: AgentUsageScope) -> some View {
        let dates = scope.dates
        let today = dates.last ?? ""
        let first = dates.suffix(30).first ?? today
        let values = Dictionary(uniqueKeysWithValues: dates.map { ($0, metric.value(of: scope.day($0))) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(dayText(first)) – \(dayText(today))")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(metric == .cost ? "Estimated API cost per day" : "Tokens per day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            AgentUsageCalendar(
                values: values, today: today,
                coveredFrom: scope.included.compactMap { $0.report.scan?.coveredFrom }.min(),
                selected: selectedDay, showsSelection: true,
                rangeStart: range == .last30Days ? nil : dates.suffix(range.dayCount).first
            ) { day in
                selectedDay = selectedDay == day ? nil : day
            }
            .padding(16)
            .background(cardBackground)
        }
    }

    private func wideBreakdown(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown")
                    .font(.title3.bold())
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Picker("Breakdown", selection: $breakdown) {
                    ForEach(AgentUsageBreakdown.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
            AgentUsageBreakdownTable(scope: scope, kind: breakdown, metric: metric)
                .padding(.horizontal, 16)
                .background(cardBackground)
        }
    }

    // MARK: Breakdown

    private func breakdownSection(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Breakdown", detail: "Last 30 days")
            Picker("Breakdown", selection: $breakdown) {
                ForEach(AgentUsageBreakdown.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 10)
            AgentUsageBreakdown(scope: scope, kind: breakdown, metric: metric, limit: 4)
                .padding(.horizontal, 16)
                .background(cardBackground)
        }
        .padding(.top, 26)
    }

    // MARK: Notes

    private func footer(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: isWide ? 2 : 6) {
            Text("Estimated API cost is based on recorded Token Usage, not your subscription bill.")
            // The hero and the calendar carry these on an iPhone.
            if isWide {
                if !scope.excluded.isEmpty { Text(notIncluded(scope)) }
                if let note = scope.dayNote { Text(note) }
            }
            Text(Self.coverage(hosts: scope.included.map { ($0.name, $0.report) }, locale: locale,
                calendar: calendar))
            ForEach(scope.loading) { host in
                Text("\(host.name): Loading Usage…")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }

    private func notIncluded(_ scope: AgentUsageScope) -> String {
        "Not included: \(scope.excluded.map(\.name).formatted(.list(type: .and).locale(locale)))"
    }

    /// "on this Host" or "on these 2 Hosts".
    static func place(_ scope: AgentUsageScope) -> String {
        let count = scope.included.count
        return count == 1 ? "on this Host" : "on these \(count.formatted()) Hosts"
    }

    /// What the scope's reports cover: since when, what each Host skipped,
    /// and the price table. The Hosts' time zones are the calendar's note.
    static func coverage(
        hosts: [(name: String, report: AgentUsageReport)], locale: Locale, calendar: Calendar
    ) -> String {
        let place = hosts.count == 1 ? "this Host" : "these \(hosts.count.formatted()) Hosts"
        var parts: [String] = []
        if let from = hosts.compactMap(\.report.scan?.coveredFrom).min() {
            parts.append("Recorded on \(place) since \(AgentUsageCalendarDay.text(from, locale: locale, calendar: calendar, includesYear: true)).")
        } else {
            parts.append("No Transcript coverage recorded on \(place) yet.")
        }
        for host in hosts {
            let name = hosts.count == 1 ? "" : "\(host.name): "
            let scan = host.report.scan
            if scan?.state == "partial" { parts.append("\(name)Token Usage is still being summarized.") }
            if let skipped = scan?.skippedArchives, skipped > 0 {
                parts.append("\(name)\(skipped.formatted()) compressed \(skipped == 1 ? "archive" : "archives") skipped.")
            }
            if let unreadable = scan?.unreadableFiles, unreadable > 0 {
                parts.append(unreadable == 1
                    ? "\(name)\(unreadable.formatted()) Transcript or folder could not be read. It is retried on the next refresh."
                    : "\(name)\(unreadable.formatted()) Transcripts or folders could not be read. They are retried on the next refresh.")
            }
        }
        let versions = Set(hosts.compactMap(\.report.pricingVersion))
        if !versions.isEmpty {
            parts.append("Price table: \(versions.sorted().joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: States

    @ViewBuilder
    private func emptyState(_ scope: AgentUsageScope) -> some View {
        if !entries.isEmpty && !scope.loading.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading Usage…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .accessibilityElement(children: .combine)
            .background(cardBackground)
            .padding(.top, 18)
        } else {
            message(scope)
        }
    }

    private func message(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                Text("Add a Host to read its Usage.")
            } else if let entry = scopedEntries.first, scopedEntries.count == 1, entry.isConnected {
                AgentUsageContent(state: entry.store.state)
            } else {
                Text("No Host in this scope can report Usage right now.")
                ForEach(scope.excluded) { host in
                    Text("\(host.name) · \(host.reason)")
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
        .padding(.top, 18)
    }

    /// One Host's suggested Claude Code directories, under any failure.
    @ViewBuilder
    private var accountsNotice: some View {
        if scopedEntries.count == 1, let entry = scopedEntries.first, entry.isConnected,
            let title = ClaudeAccountsListing.noticeTitle(
                state: entry.store.state, supportsAccounts: entry.store.supportsClaudeAccounts)
        {
            ClaudeAccountsNotice(title: title) { accountsHostID = entry.id }
                .padding(.top, 14)
        }
    }

    private func failureBanner(_ host: AgentUsageScope.IncludedHost, isOnlyHost: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            AgentUsageRefreshFailureNote(
                message: isOnlyHost ? (host.refreshFailure ?? "") : "\(host.name): \(host.refreshFailure ?? "")",
                isRetrying: host.isRetryingRefresh)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .padding(.top, 14)
    }

    // MARK: Pieces

    private var cardBackground: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }

    private func sectionHeader(
        _ title: String, detail: String?, @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).fontWeight(.semibold)
                + Text(detail.map { " · \($0)" } ?? "").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing()
        }
        .font(.subheadline)
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func dayText(_ day: String, includesYear: Bool = false) -> String {
        AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: includesYear)
    }
}

/// The day a calendar tap opened, and the days its sheet can step through.
struct AgentUsageDaySelection: Identifiable, Equatable {
    var day: String
    let dates: [String]
    var id: String { "day" }
}

/// Refreshing, or when the oldest report was made, under the title.
private struct AgentUsageSubtitle: ViewModifier {
    let scope: AgentUsageScope
    @Environment(\.locale) private var locale

    private var text: String? {
        if scope.refreshing { return "Refreshing" }
        let formatter = ISO8601DateFormatter()
        let oldest = scope.included.compactMap { $0.report.generatedAt.flatMap(formatter.date(from:)) }.min()
        return oldest.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

/// One readable Claude Code Account under its program in the Programs card:
/// its figure, its share of the program and a bar as long as that share.
struct AgentUsageAccountRow: View {
    let account: AgentUsageScope.AccountUsage
    let program: AgentUsageScope.Program
    /// The program's figures for the same range.
    let programSummary: AgentUsageReport.Summary
    let metric: AgentUsageMetric
    var isWide = false
    @Environment(\.locale) private var locale

    /// The bar's length at the whole program.
    private static let barWidth: CGFloat = 132

    var body: some View {
        let share = account.summary.map { Self.share($0, of: programSummary, metric: metric) } ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(account.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let summary = account.summary {
                    Text(AgentUsageStyle.value(summary, metric: metric, locale: locale))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            .font(isWide ? .body : .subheadline)
            Text(Self.detail(account, programName: program.displayName, programSummary: programSummary,
                metric: metric, locale: locale))
                .font(isWide ? .footnote : .caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            AgentUsageStyle.color(for: program.program)
                .frame(width: max(Self.barWidth * share, 2), height: 2)
                .clipShape(.capsule)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .padding(.leading, 16)
        .padding(.vertical, isWide ? 6 : 9)
        .accessibilityElement(children: .combine)
    }

    /// The Account's part of its program in the metric, from 0 to 1.
    static func share(
        _ summary: AgentUsageReport.Summary, of program: AgentUsageReport.Summary, metric: AgentUsageMetric
    ) -> Double {
        let whole = metric.value(of: program)
        guard whole > 0 else { return 0 }
        return min(max(metric.value(of: summary) / whole, 0), 1)
    }

    /// "72% of Claude Code · 211M tokens", the other metric last.
    static func detail(
        _ account: AgentUsageScope.AccountUsage, programName: String, programSummary: AgentUsageReport.Summary,
        metric: AgentUsageMetric, locale: Locale
    ) -> String {
        guard let summary = account.summary else { return "Token Usage could not be read." }
        let share = AgentUsageStyle.share(metric.value(of: summary), of: metric.value(of: programSummary),
            locale: locale)
        let other = metric == .cost
            ? "\(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens"
            : AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)
        return "\(share) of \(programName) · \(other)"
    }
}

/// Two equal columns, aligned to the top.
private struct AgentUsageWideColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            leading.frame(maxWidth: .infinity, alignment: .topLeading)
            trailing.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
