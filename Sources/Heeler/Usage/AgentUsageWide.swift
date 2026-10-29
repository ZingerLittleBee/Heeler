import SwiftUI

/// The breakdown as a table, for an iPad's wide layout: rank, name, Host,
/// estimated API cost and tokens.
struct AgentUsageBreakdownTable: View {
    let scope: AgentUsageScope
    let kind: AgentUsageBreakdown.Kind
    let metric: AgentUsageMetric
    var limit = 5
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private var showsHost: Bool { kind == .directories && scope.included.count > 1 }

    var body: some View {
        let rows = AgentUsageBreakdown.rows(kind, in: scope, locale: locale, calendar: calendar)
        let largest = rows.map { metric.value(of: $0.summary) }.max() ?? 0
        VStack(spacing: 0) {
            line(rank: Text("#"), name: Text(kind == .models ? "Model" : kind == .directories ? "Directory" : "Day"),
                host: Text("Host"), cost: Text("Est. cost"), tokens: Text("Tokens"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .accessibilityHidden(true)
            ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                Divider()
                rowView(row, rank: index + 1, largest: largest)
            }
            if rows.isEmpty {
                Divider()
                Text("Nothing recorded in the last 30 days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Divider()
            HStack {
                if rows.count > limit {
                    NavigationLink("Show All \(rows.count.formatted()) \(kind.title)") {
                        List {
                            AgentUsageBreakdown(scope: scope, kind: kind, metric: metric)
                        }
                        .navigationTitle("\(kind.title) · Last 30 days")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                Spacer(minLength: 8)
                Text("Last 30 days").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
    }

    private func rowView(_ row: AgentUsageBreakdown.Row, rank: Int, largest: Double) -> some View {
        // The bar under a name is relative to the largest row's.
        let share = largest > 0 ? metric.value(of: row.summary) / largest : 0
        let color = row.program.map(AgentUsageStyle.color(for:)) ?? Color.secondary
        let name = HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).opacity(row.program == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                color.frame(width: max(32 * share, 3), height: 2)
                    .clipShape(.capsule)
                    .accessibilityHidden(true)
            }
        }
        return line(
            rank: Text(rank.formatted()).foregroundStyle(.secondary),
            name: name,
            host: Text(row.host ?? "").foregroundStyle(.secondary),
            cost: Text(AgentUsageStyle.cost(row.summary.estimatedCostUSD, locale: locale)).fontWeight(.semibold),
            tokens: Text(AgentUsageStyle.tokens(row.summary.tokens.total, locale: locale)).foregroundStyle(.secondary))
            .font(.body)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
    }

    private func line(
        rank: some View, name: some View, host: some View, cost: some View, tokens: some View
    ) -> some View {
        HStack(spacing: 12) {
            rank.frame(width: 18, alignment: .leading)
            name.frame(maxWidth: .infinity, alignment: .leading)
            if showsHost {
                host.lineLimit(1).frame(width: 120, alignment: .leading)
            }
            cost.lineLimit(1).frame(width: 96, alignment: .trailing)
            tokens.lineLimit(1).frame(width: 56, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

/// Each Host's Usage Limits side by side on an iPad's wide layout: a card
/// per Host with a row per program or Claude Code Account, or, for one
/// Host with several Accounts, a card per Account and per other program.
struct AgentUsageLimitsStrip: View {
    let entries: [AgentUsageHostEntry]
    let showDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Usage Limits").font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Usage Limits are shown per Host. Two Hosts signed in to the same account show the same windows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Details", action: showDetails)
            }
            if let cards = Self.accountCards(entries) {
                AgentUsageTwoColumns(items: cards) { card in
                    readingCard(card)
                }
            } else {
                AgentUsageTwoColumns(items: entries) { entry in
                    card(entry)
                }
            }
        }
    }

    /// One Host's readings as cards when it has several Claude Code
    /// Accounts; nil keeps a card per Host.
    static func accountCards(_ entries: [AgentUsageHostEntry]) -> [AgentUsageLimitsCard]? {
        guard entries.count == 1, let entry = entries.first, entry.isConnected,
            case .available(let report) = entry.store.state
        else { return nil }
        let cards = AgentUsageLimitsCard.readings(for: report)
        return cards.contains { $0.account != nil } ? cards : nil
    }

    private func card(_ entry: AgentUsageHostEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.name, systemImage: "desktopcomputer")
                .font(.headline)
            if case .available(let report) = entry.store.state {
                ForEach(AgentUsageLimitsCard.readings(for: report)) { reading in
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        HStack(spacing: 7) {
                            Circle().fill(AgentUsageStyle.color(for: reading.program)).frame(width: 8, height: 8)
                            Text(AgentUsageProgramTitle.title(program: reading.program, account: reading.account))
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 130, alignment: .leading)
                        readingContent(reading)
                    }
                }
            } else {
                Divider()
                AgentUsageContent(state: entry.store.state).font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    /// One program's or one Account's card, for a Host with several
    /// Accounts.
    private func readingCard(_ reading: AgentUsageLimitsCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .limits(_, let program, let account, let limits) = reading {
                AgentUsageProgramTitle(program: program, account: account, plan: limits.plan)
            } else {
                AgentUsageProgramTitle(program: reading.program, account: reading.account)
            }
            Divider()
            readingContent(reading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func readingContent(_ reading: AgentUsageLimitsCard) -> some View {
        switch reading {
        case .limits(_, let program, _, let limits):
            AgentUsageLimitsView(program: program, limits: limits, showsTitle: false, style: .columns)
        case .unread(_, _, let reason):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        case .claudeToggle:
            EmptyView()
        }
    }

    private var cardBackground: some View {
        Color(uiColor: .secondarySystemGroupedBackground).clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

/// An iPad's Usage Limits view: each program's windows in full, per Host
/// and Claude Code Account, with each Host's Claude Code limits consent and
/// its Accounts.
struct AgentUsageLimitsPage: View {
    let entries: [AgentUsageHostEntry]
    /// Opens a Host's Claude Code Accounts as a form sheet.
    let showAccounts: (Host.ID) -> Void
    /// Back to Token Usage.
    let showTokenUsage: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Usage Limits").font(.title.bold())
                Text("Account windows as each service reports them")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                if entries.count > 1 {
                    Label(entry.name, systemImage: "desktopcomputer")
                        .font(.title3.bold())
                        .padding(.top, 8)
                }
                hostLimits(entry)
            }
            if entries.count == 1, let entry = entries.first,
                case .available = entry.store.state {
                tokenUsageCard(entry)
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func hostLimits(_ entry: AgentUsageHostEntry) -> some View {
        if case .available(let report) = entry.store.state {
            let cards = AgentUsageLimitsCard.cards(for: report)
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(cards.indices.filter { $0.isMultiple(of: 2) }, id: \.self) { index in
                        card(cards[index], entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(cards.indices.filter { !$0.isMultiple(of: 2) }, id: \.self) { index in
                        card(cards[index], entry: entry)
                    }
                    if entry.id == entries.first?.id { perHostCard }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            AgentUsageContent(state: entry.isConnected ? entry.store.state : .failed("Not connected"))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(cardBackground)
        }
    }

    private func card(_ card: AgentUsageLimitsCard, entry: AgentUsageHostEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                switch card {
                case .limits(_, let program, let account, let limits):
                    AgentUsageProgramTitle(program: program, account: account, plan: limits.plan)
                    AgentUsageLimitsView(program: program, limits: limits, showsTitle: false)
                case .unread(_, let account, let reason):
                    AgentUsageUncountedAccount(account: account, reason: reason)
                case .claudeToggle:
                    ClaudeUsageLimitsToggle(store: entry.store)
                    if ClaudeAccountsEntry.isShown(for: entry.store) {
                        Divider()
                        ClaudeAccountsEntry(hostName: entry.name, store: entry.store) { showAccounts(entry.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(cardBackground)
            Group {
                if card == .claudeToggle { ClaudeUsageLimitsNote() }
                if case .limits(_, "codex", _, _) = card { CodexUsageLimitsNote() }
            }
            .padding(.horizontal, 18)
        }
    }

    private var perHostCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Shown per Host").font(.headline)
                Text("Usage Limits are shown per Host. Two Hosts signed in to the same account show the same windows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    private func tokenUsageCard(_ entry: AgentUsageHostEntry) -> some View {
        let scope = AgentUsageScope(readings: [entry.reading])
        let total = scope.total(.last30Days)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Token Usage on this Host").font(.headline)
                        Text("\(AgentUsageStyle.tokens(total.tokens.total, locale: locale)) tokens recorded in this Host’s Transcripts. Separate from Usage Limits.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(AgentUsageStyle.cost(total.estimatedCostUSD, locale: locale))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text("Estimated API cost · Last 30 days")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if !scope.dates.isEmpty { AgentUsageDayStrip(scope: scope) }
                Button(action: showTokenUsage) {
                    HStack(spacing: 4) {
                        Text("Show Estimated API Cost")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        Color(uiColor: .secondarySystemGroupedBackground).clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

/// Items in two equal columns, filled left to right.
struct AgentUsageTwoColumns<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        Grid(horizontalSpacing: 30, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                GridRow(alignment: .top) {
                    content(items[start])
                    if start + 1 < items.count {
                        content(items[start + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}
