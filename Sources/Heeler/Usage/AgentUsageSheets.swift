import SwiftUI

/// One Host's tightest Usage Limits window for one program, as a chip.
struct AgentUsageLimitChip: Identifiable, Equatable {
    let hostID: Host.ID
    let hostName: String
    let program: String
    /// nil while there is no live reading to fill the ring with.
    let percent: Double?
    let title: String
    /// When the live window resets.
    var resetsAt: Date? = nil
    var id: String { "\(hostID)\(program)" }

    /// Live readings first, fullest first; Usage Limits stay per Host.
    static func chips(in scope: AgentUsageScope, now: Date = .now) -> [Self] {
        let chips = scope.included.flatMap { host in
            host.programs.map { program -> Self in
                let limits = program.usageLimits
                let live = (limits.windows ?? []).filter { window in
                    !window.expired && window.usedPercent != nil
                        && AgentUsageLimitsView.date(window.resetsAt).map { $0 > now } != false
                }
                let tightest = live.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
                let title: String
                if let tightest, limits.state == "ok" || limits.state == "throttled" {
                    title = AgentUsageLimitsView.windowName(tightest, program: program.program)
                } else if limits.state == "disabled" {
                    title = "Limits off"
                } else if limits.state == "unavailable" && limits.reason == "notReadYet" {
                    title = "Reading…"
                } else {
                    title = "Unavailable"
                }
                let isLive = limits.state == "ok" || limits.state == "throttled"
                return Self(
                    hostID: host.id, hostName: host.name, program: program.program,
                    percent: isLive ? tightest?.usedPercent : nil,
                    title: title,
                    resetsAt: isLive ? AgentUsageLimitsView.date(tightest?.resetsAt) : nil)
            }
        }
        return chips.enumerated().sorted { lhs, rhs in
            switch (lhs.element.percent, rhs.element.percent) {
            case (let left?, let right?): left == right ? lhs.offset < rhs.offset : left > right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }
}

struct AgentUsageLimitChipView: View {
    let chip: AgentUsageLimitChip
    let showsHost: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 3.5)
                if let percent = chip.percent {
                    Circle()
                        .trim(from: 0, to: min(max(percent / 100, 0), 1))
                        .stroke(ringColor(percent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text((percent / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(AgentUsageStyle.color(for: chip.program)).frame(width: 7, height: 7)
                    Text(showsHost ? chip.hostName
                        : AgentUsageReport.Program.displayName(for: chip.program))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(showsHost
                    ? "\(AgentUsageReport.Program.displayName(for: chip.program)) · \(chip.title)"
                    : chip.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chip.percent == nil ? .secondary : .primary)
            }
            .lineLimit(1)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 56)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Neutral until a window runs low.
    private func ringColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return AgentUsageStyle.color(for: chip.program)
    }
}

/// Models, directories, or days over the last 30 days.
struct AgentUsageBreakdown: View {
    enum Kind: String, CaseIterable, Identifiable {
        case models, directories, days
        var id: Self { self }
        var title: String {
            switch self {
            case .models: "Models"
            case .directories: "Directories"
            case .days: "Days"
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let program: String?
        let title: String
        let subtitle: String?
        /// The Host a directory is on, when the scope has several.
        var host: String? = nil
        let summary: AgentUsageReport.Summary
        let priced: Bool
    }

    let scope: AgentUsageScope
    let kind: Kind
    let metric: AgentUsageMetric
    /// Rows before Show All; nil shows every row.
    var limit: Int?
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        let rows = Self.rows(kind, in: scope, locale: locale, calendar: calendar)
        let total = rows.reduce(0) { $0 + metric.value(of: $1.summary) }
        let shown = limit.map { Array(rows.prefix($0)) } ?? rows
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 18) }
                rowView(row, total: total)
            }
            if shown.isEmpty {
                Text("Nothing recorded in the last 30 days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
            if let limit, rows.count > limit {
                Divider()
                NavigationLink {
                    List {
                        AgentUsageBreakdown(scope: scope, kind: kind, metric: metric)
                    }
                    .navigationTitle("\(kind.title) · Last 30 days")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Show All \(rows.count.formatted()) \(kind.title)")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func rowView(_ row: Row, total: Double) -> some View {
        let value = metric.value(of: row.summary)
        return HStack(spacing: 10) {
            Circle()
                .fill(row.program.map(AgentUsageStyle.color(for:)) ?? Color.secondary)
                .frame(width: 8, height: 8)
                .opacity(row.program == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let subtitle = row.subtitle {
                    (Text(row.host.map { "\($0) · " } ?? "")
                        + Text(subtitle).monospaced())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(AgentUsageStyle.value(row.summary, metric: metric, locale: locale))
                    .font(.subheadline.weight(.semibold))
                Text("\(AgentUsageStyle.share(value, of: total, locale: locale)) · \(metric == .cost ? "\(AgentUsageStyle.tokens(row.summary.tokens.total, locale: locale)) tokens" : AgentUsageStyle.cost(row.summary.estimatedCostUSD, locale: locale))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !row.priced {
                    Text("Includes unpriced tokens").font(.caption).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .layoutPriority(1)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    static func rows(_ kind: Kind, in scope: AgentUsageScope, locale: Locale, calendar: Calendar) -> [Row] {
        switch kind {
        case .models:
            return scope.programs.flatMap { program in
                program.models.map { model in
                    Row(id: "\(program.program)\(model.model)", program: program.program, title: model.model,
                        subtitle: nil, summary: model.summary,
                        priced: model.priced)
                }
            }
            .sorted { $0.summary.tokens.total > $1.summary.tokens.total }
        case .directories:
            let showsHost = scope.included.count > 1
            return scope.programs.flatMap { program in
                program.directories.map { entry in
                    let path = entry.directory.path
                    let name = (path as NSString).lastPathComponent
                    return Row(id: "\(program.program)\(entry.id)", program: program.program,
                        title: name.isEmpty ? path : name,
                        subtitle: path,
                        host: showsHost ? entry.hostName : nil,
                        summary: entry.directory.summary, priced: entry.directory.unpricedTokens == 0)
                }
            }
            .sorted { $0.summary.tokens.total > $1.summary.tokens.total }
        case .days:
            return scope.dates.suffix(30).reversed().map { day in
                Row(id: day, program: nil,
                    title: AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: false),
                    subtitle: nil, summary: scope.day(day), priced: true)
            }
        }
    }
}

/// A calendar day: the scope's total, each Host's, and each program's
/// token-type split. Models and directories exist only for 30 days.
struct AgentUsageDaySheet: View {
    let scope: AgentUsageScope
    @State var selection: AgentUsageDaySelection
    /// A regular-width page shows a form sheet: the sheet's own size class
    /// is compact, so the page decides.
    var isFormSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    let summary = scope.day(selection.day)
                    Text(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale))
                        .font(.system(size: 34, weight: .semibold))
                        .monospacedDigit()
                        .padding(.top, 10)
                    Text("Estimated API cost · \(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if scope.included.count > 1 { byHost }
                    byProgram
                    links
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // An iPhone keeps the page reachable above the sheet; a form sheet
        // floats over it at its full height.
        .presentationDetents(isFormSheet ? [.large] : [.fraction(0.65), .large])
        .presentationBackgroundInteraction(
            isFormSheet ? .disabled : .enabled(upThrough: .fraction(0.65)))
        // A partial-height sheet is glass on iOS 26, and the dashboard
        // behind it showed through the figures.
        .presentationBackground(Color(uiColor: .systemBackground))
    }

    private var header: some View {
        let index = selection.dates.firstIndex(of: selection.day)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(AgentUsageCalendarDay.text(selection.day, locale: locale, calendar: calendar,
                    includesYear: false, includesWeekday: true))
                    .font(.title2.bold())
                Text(scope.included.count == 1
                    ? "Token Usage on this Host" : "Token Usage on these \(scope.included.count.formatted()) Hosts")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Previous Day", systemImage: "chevron.left") {
                if let index, index > 0 { selection.day = selection.dates[index - 1] }
            }
            .disabled(index.map { $0 == 0 } ?? true)
            Button("Next Day", systemImage: "chevron.right") {
                if let index, index < selection.dates.count - 1 { selection.day = selection.dates[index + 1] }
            }
            .disabled(index.map { $0 >= selection.dates.count - 1 } ?? true)
            Button("Close", systemImage: "xmark") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .padding(.top, 20)
    }

    private var byHost: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Host").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(scope.included.enumerated()), id: \.element.id) { index, host in
                    if index > 0 { Divider().padding(.leading, 30) }
                    let summary = AgentUsageScope.sum(host.programs.compactMap { program in
                        program.okTotals == nil ? nil
                            : program.tokenUsage.daily?.first { $0.date == selection.day }?.summary
                    })
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(host.name).font(.subheadline.weight(.medium))
                            Text([AgentUsageCalendarDay.text(selection.day, locale: locale, calendar: calendar,
                                includesYear: false), host.report.timeZone].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale))
                                .font(.subheadline.weight(.semibold))
                            Text("\(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                    .frame(minHeight: 52)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(.top, 18)
    }

    private var byProgram: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("By program").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(scope.programs) { program in
                let summary = program.daily.first { $0.date == selection.day }?.summary
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(AgentUsageStyle.color(for: program.program)).frame(width: 8, height: 8)
                        Text(program.displayName).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(summary.map { AgentUsageStyle.cost($0.estimatedCostUSD, locale: locale) } ?? "–")
                            .font(.subheadline.weight(.semibold))
                        Text(summary.map { "\(AgentUsageStyle.tokens($0.tokens.total, locale: locale)) tokens" } ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 84, alignment: .trailing)
                    }
                    .monospacedDigit()
                    AgentUsageTokenSplit(tokens: summary?.tokens ?? .zero)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
            AgentUsageTokenLegend().padding(.top, 10)
        }
        .padding(.top, 16)
    }

    private var links: some View {
        VStack(spacing: 0) {
            ForEach([AgentUsageBreakdown.Kind.models, .directories]) { kind in
                if kind == .directories { Divider() }
                NavigationLink {
                    List { AgentUsageBreakdown(scope: scope, kind: kind, metric: .cost) }
                        .navigationTitle("\(kind.title) · Last 30 days")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    HStack {
                        Text("\(kind.title) · Last 30 days")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.top, 14)
    }
}

/// Usage Limits grouped by Host, never merged, each Host with its own
/// Claude Code limits consent.
struct AgentUsageLimitsSheet: View {
    let entries: [AgentUsageHostEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                } header: {
                    Text("Usage Limits are shown per Host. Two Hosts signed in to the same account show the same windows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .textCase(nil)
                }
                ForEach(entries) { entry in
                    AgentUsageHostLimits(entry: entry, style: .rows)
                }
                Section {
                } footer: {
                    CodexUsageLimitsNote()
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Usage Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

/// One card of a Host's Usage Limits, in the order the Usage Limits sheet
/// and an iPad's Limits view show them: Claude Code's windows, a card per
/// Account when the Host has more than one (the counted ones first), then
/// its toggle card, then each other program's. While Claude Code limits are
/// off, the toggle card stands for all of Claude Code.
enum AgentUsageLimitsCard: Identifiable, Equatable {
    /// A program's windows, or one Claude Code Account's, named when the
    /// Host has several.
    case limits(id: String, program: String, account: String?, limits: AgentUsageReport.Program.UsageLimits)
    /// A Claude Code Account that adds nothing, and why.
    case unread(id: String, account: String, reason: String)
    /// The Claude Code limits toggle and the way to the Host's Accounts.
    case claudeToggle

    var id: String {
        switch self {
        case .limits(let id, _, _, _), .unread(let id, _, _): id
        case .claudeToggle: "claude.toggle"
        }
    }

    static func cards(for report: AgentUsageReport) -> [Self] {
        (report.programs ?? []).flatMap { program -> [Self] in
            guard program.program == "claude" else {
                return [.limits(id: program.program, program: program.program, account: nil, limits: program.usageLimits)]
            }
            return claudeCards(program) + [.claudeToggle]
        }
    }

    private static func claudeCards(_ program: AgentUsageReport.Program) -> [Self] {
        guard program.usageLimits.state != "disabled" else { return [] }
        let accounts = program.accounts ?? []
        guard accounts.count > 1 else {
            return [.limits(id: "claude", program: "claude", account: nil, limits: program.usageLimits)]
        }
        // An Account the plugin counts always reports limits; without them
        // it reads as a failed reading rather than borrowing another's.
        let unknown = AgentUsageReport.Program.UsageLimits(
            state: "error", reason: nil, source: nil, observedAt: nil, retryAt: nil, plan: nil, windows: nil)
        let counted = accounts.filter(\.isReadable).map { account in
            Self.limits(
                id: "claude.\(account.id)", program: "claude", account: account.displayName,
                limits: account.usageLimits ?? (account.isDefault ? program.usageLimits : unknown))
        }
        let uncounted = accounts.filter { !$0.isReadable }.map { account in
            Self.unread(
                id: "claude.\(account.id)", account: account.displayName,
                reason: ClaudeAccountsListing.stateLine(account.state) ?? "")
        }
        return counted + uncounted
    }
}

/// One Host's Usage Limits as list sections, one per card, the Host named
/// over the first.
struct AgentUsageHostLimits: View {
    let entry: AgentUsageHostEntry
    var style = AgentUsageLimitsView.Style.rows

    var body: some View {
        if case .available(let report) = entry.store.state, entry.isConnected {
            let cards = AgentUsageLimitsCard.cards(for: report)
            ForEach(Array(cards.enumerated()), id: \.element.id) { @Sendable index, card in
                MainActorContent { section(card, isFirst: index == 0) }
            }
        } else {
            Section {
                AgentUsageContent(state: entry.isConnected ? entry.store.state : .failed("Not connected"))
            } header: {
                header
            }
        }
    }

    private var header: some View {
        Label(entry.name, systemImage: "desktopcomputer")
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.leading, -16)
    }

    private func section(_ card: AgentUsageLimitsCard, isFirst: Bool) -> some View {
        Section {
            switch card {
            case .limits(_, let program, let account, let limits):
                VStack(alignment: .leading, spacing: 6) {
                    AgentUsageProgramTitle(program: program, account: account, plan: limits.plan)
                    AgentUsageLimitsView(program: program, limits: limits, showsTitle: false, style: style)
                }
                .padding(.vertical, 4)
            case .unread(_, let account, let reason):
                AgentUsageUncountedAccount(account: account, reason: reason)
                    .padding(.vertical, 4)
            case .claudeToggle:
                ClaudeUsageLimitsToggle(store: entry.store)
                ClaudeAccountsEntry(hostName: entry.name, store: entry.store)
            }
        } header: {
            if isFirst { header }
        } footer: {
            if card == .claudeToggle { ClaudeUsageLimitsNote() }
        }
    }
}

/// A Claude Code Account that adds nothing to Usage Limits, and why.
struct AgentUsageUncountedAccount: View {
    let account: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentUsageProgramTitle(program: "claude", account: account)
            // Flush with the card's edge, like a readable card's source line.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The way from the Claude Code limits toggle to the Host's Accounts, with
/// how many there are; on an older plugin, the update they need instead.
struct ClaudeAccountsEntry: View {
    let hostName: String
    let store: AgentUsageStore
    /// Opens the Accounts as a form sheet; nil pushes them in the enclosing
    /// navigation stack.
    var open: (() -> Void)?

    /// Whether the entry shows anything on this Host.
    static func isShown(for store: AgentUsageStore) -> Bool {
        store.supportsClaudeAccounts || store.claudeAccountsRequirement != nil
    }

    var body: some View {
        if store.supportsClaudeAccounts {
            let count = ClaudeAccountsListing(state: store.state).accounts.count
            if let open {
                Button(action: open) { label(count: count, showsChevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("usage.accounts.open")
            } else {
                NavigationLink {
                    ClaudeAccountsSheet(hostName: hostName, store: store, isPushed: true)
                } label: {
                    label(count: count, showsChevron: false)
                }
                .accessibilityIdentifier("usage.accounts.open")
            }
        } else if let note = store.claudeAccountsRequirement {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code Accounts")
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func label(count: Int, showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Claude Code Accounts")
            Spacer(minLength: 8)
            if count > 0 {
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }
}

/// A program's name with its marker and, when the service reports one,
/// its plan.
struct AgentUsageProgramTitle: View {
    let program: String
    /// The Claude Code Account the card is for, named when the Host has
    /// several.
    var account: String?
    var plan: String?

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(AgentUsageStyle.color(for: program))
                .frame(width: 8, height: 8)
            Text(Self.title(program: program, account: account)).font(.headline)
            if let plan {
                Text(plan.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 5))
            }
        }
    }

    /// "Claude Code", or "Claude Code · claude-2" for one of several
    /// Accounts.
    static func title(program: String, account: String?) -> String {
        let name = AgentUsageReport.Program.displayName(for: program)
        return account.map { "\(name) · \($0)" } ?? name
    }
}
