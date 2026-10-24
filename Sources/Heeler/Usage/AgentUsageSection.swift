import SwiftUI

/// Shared content for the Host summary and the Usage page's loading states.
struct AgentUsageContent: View {
    let state: AgentUsageStore.State

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView("Loading Usage…")
        case .requirement(let message):
            Text(message).foregroundStyle(.secondary)
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
                ProgressView("Refreshing")
            }
            if report.scan?.state == "partial" {
                Text("Token Usage is still being summarized.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(report.programs ?? [], id: \.program) { program in
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.program == "claude" ? "Claude Code" : "Codex")
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

struct AgentUsageSection: View {
    let store: AgentUsageStore

    var body: some View {
        Section("Usage") {
            ClaudeUsageSettings(store: store)
            NavigationLink("View Usage Details") {
                AgentUsageView(store: store)
            }
            AgentUsageContent(state: store.state)
        }
        .task(id: store.claudeLimitsEnabled) { await store.refresh() }
    }
}


struct ClaudeUsageSettings: View {
    @Bindable var store: AgentUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Claude Code limits", isOn: $store.claudeLimitsEnabled)
                .accessibilityIdentifier("usage.claude-limits")
            Text("The plugin asks Claude Code on this computer for your plan limits. Neither the plugin nor Heeler handles your sign-in. This automated use is not officially supported.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
