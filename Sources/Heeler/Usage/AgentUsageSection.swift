import SwiftUI

/// Shared content for the Host summary and the Usage page's loading states.
struct AgentUsageContent: View {
    let state: AgentUsageStore.State
    var refreshFailure: String? = nil
    var isRetryingRefresh = false

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                // A List cell built off screen keeps a stopped, hidden
                // spinner once it scrolls in; a fresh one animates.
                ProgressView().id(UUID())
                Text("Loading Usage…").foregroundStyle(.secondary)
            }
        case .requirement(let message):
            Text(message).foregroundStyle(.secondary)
        case .unsupportedBackend:
            Text("Not supported on herdr-core").foregroundStyle(.secondary)
        case .unsupportedPlatform:
            Text("Not supported on Windows").foregroundStyle(.secondary)
        case .runtimeMissing:
            Text("Use any Agent on this computer once, or restart herdr, then refresh Usage.")
                .foregroundStyle(.secondary)
        case .updateRequired:
            Text("Update Heeler to read this Host's Usage format.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        case .available(let report):
            if report.refreshing == true {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Refreshing").foregroundStyle(.secondary)
                }
            }
            if let refreshFailure {
                AgentUsageRefreshFailureNote(message: refreshFailure, isRetrying: isRetryingRefresh)
            }
            if report.scan?.state == "partial" {
                Text("Token Usage is still being summarized.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(report.programs ?? [], id: \.program) { program in
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.displayName)
                        .font(.headline)
                    AgentUsageLimitsView(program: program.program, limits: program.usageLimits)
                    if program.tokenUsage.state == "ok", let totals = program.tokenUsage.totals {
                        Text("Token Usage on this Host")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Today: \(totals.today.tokens.total.formatted()) tokens")
                            .font(.subheadline)
                        AgentUsageEstimatedCost(summary: totals.today)
                        Text("Last 30 days: \(totals.last30Days.tokens.total.formatted()) tokens")
                            .font(.subheadline)
                        AgentUsageEstimatedCost(summary: totals.last30Days)
                    } else if program.tokenUsage.state == "noData" {
                        Text("No Token Usage recorded on this Host yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Token Usage could not be read.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A failed refresh keeps the earlier report on screen and says so.
struct AgentUsageRefreshFailureNote: View {
    let message: String
    let isRetrying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Last refresh failed", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(message)
            Text(isRetrying
                ? "Showing the last report while Heeler retries."
                : "Showing the last report. Pull to try again.")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct AgentUsageEstimatedCost: View {
    let summary: AgentUsageReport.Summary
    @Environment(\.locale) private var locale

    private var amount: String {
        guard let value = summary.estimatedCostUSD else { return "Unpriced" }
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(locale)
        if value > 0 && value < 0.01 {
            return "< \(0.01.formatted(style))"
        }
        return value.formatted(style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Estimated API cost: \(amount)")
            if let unpriced = summary.unpricedTokens, unpriced > 0 {
                Text("\(unpriced.formatted()) tokens unpriced")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The Host detail's Usage summary: this Host's 30 days at a glance, the
/// tightest Usage Limits window, and the way into the Usage tab.
struct AgentUsageSection: View {
    let hostID: Host.ID
    let hostName: String
    let store: AgentUsageStore
    /// Shows this Host on the Usage tab.
    var openUsage: (() -> Void)?
    @Environment(\.locale) private var locale

    var body: some View {
        Section("Usage") {
            if case .available(let report) = store.state {
                summary(report)
            } else {
                AgentUsageContent(state: store.state, refreshFailure: store.refreshFailure,
                    isRetryingRefresh: store.isRetryingRefresh)
            }
            if let openUsage {
                Button(action: openUsage) { openLabel }
                    .accessibilityIdentifier("usage.open")
            }
        }
        .task(id: store.refreshKey) { await store.refresh() }
    }

    private var entry: AgentUsageHostEntry {
        AgentUsageHostEntry(id: hostID, name: hostName, store: store, isConnected: true)
    }

    private var openLabel: some View {
        HStack {
            Label("Open in Usage", systemImage: "chart.bar.xaxis")
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func summary(_ report: AgentUsageReport) -> some View {
        let scope = AgentUsageScope(readings: [entry.reading])
        let total = scope.total(.last30Days)
        VStack(alignment: .leading, spacing: 2) {
            Text("Estimated API cost · Last 30 days")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AgentUsageStyle.cost(total.estimatedCostUSD, locale: locale))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                Text("\(AgentUsageStyle.tokens(total.tokens.total, locale: locale)) tokens on this Host")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !scope.dates.isEmpty {
                AgentUsageDayStrip(scope: scope).padding(.top, 10)
            }
            if report.refreshing == true {
                Text("Refreshing").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            if let failure = store.refreshFailure {
                AgentUsageRefreshFailureNote(message: failure, isRetrying: store.isRetryingRefresh)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        if let chip = AgentUsageLimitChip.closest(in: scope) {
            AgentUsageLimitRow(chip: chip)
        }
    }
}

/// The last 30 days as one row of cells, oldest first.
struct AgentUsageDayStrip: View {
    let scope: AgentUsageScope
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        let dates = Array(scope.dates.suffix(30))
        let values = dates.map { scope.day($0).estimatedCostUSD ?? 0 }
        let maximum = values.max() ?? 0
        VStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(AgentUsageCalendar.ramp(maximum > 0 ? Int((value / maximum * 4).rounded(.up)) : 0))
                        .overlay {
                            if index == values.count - 1 {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                }
            }
            .frame(height: 26)
            HStack {
                Text(dates.first.map {
                    AgentUsageCalendarDay.text($0, locale: locale, calendar: calendar, includesYear: false)
                } ?? "")
                Spacer()
                Text("Today")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// The tightest Usage Limits window on one Host, named "claude-2 · 5-hour"
/// for one of several Claude Code Accounts.
struct AgentUsageLimitRow: View {
    let chip: AgentUsageLimitChip
    @Environment(\.locale) private var locale

    private var title: String {
        chip.account.map { "\($0) · \(chip.title)" } ?? chip.title
    }

    private func subtitle(now: Date) -> String {
        let name = AgentUsageReport.Program.displayName(for: chip.program)
        guard let reset = chip.resetsAt, reset > now else { return name }
        return "\(name) · resets in \(AgentUsageStyle.countdown(to: reset, now: now, locale: locale))"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 3.5)
                if let percent = chip.percent {
                    Circle()
                        .trim(from: 0, to: min(max(percent / 100, 0), 1))
                        .stroke(AgentUsageStyle.color(for: chip.program),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(subtitle(now: context.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let percent = chip.percent {
                Text((percent / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One Host's consent to read Claude Code's plan limits. While it is off,
/// the row says so in place of the windows.
struct ClaudeUsageLimitsToggle: View {
    @Bindable var store: AgentUsageStore

    var body: some View {
        Toggle(isOn: $store.claudeLimitsEnabled) {
            Text("Claude Code limits")
            if !store.claudeLimitsEnabled {
                Text("Usage Limits are off.")
            }
        }
        .accessibilityIdentifier("usage.claude-limits")
    }
}

/// What turning Claude Code limits on does, shown beside the toggle.
struct ClaudeUsageLimitsNote: View {
    var body: some View {
        Text("The plugin asks Claude Code on this computer for your plan limits. Neither the plugin nor Heeler handles your sign-in. This automated use is not officially supported.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
