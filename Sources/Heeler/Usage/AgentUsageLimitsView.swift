import SwiftUI

/// Program-reported account windows, kept separate from the Host's token totals.
struct AgentUsageLimitsView: View {
    let program: String
    let limits: AgentUsageReport.Program.UsageLimits
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage Limits").font(.subheadline.weight(.semibold))
            if limits.state == "ok" || limits.state == "throttled" {
                if limits.state == "throttled" {
                    Text("Last reading · \(retrySummary)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sourceSummary {
                    Text(sourceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if (limits.windows ?? []).isEmpty {
                    Text("No Usage Limits windows reported.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(limits.windows ?? []) { window in
                    windowView(window)
                }
            } else {
                Text(unavailableMessage)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func windowView(_ window: AgentUsageReport.Program.UsageLimits.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(windowName(window))
                    Spacer(minLength: 12)
                    percentage(window)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(windowName(window))
                    percentage(window)
                }
            }
            .font(.subheadline)
            if window.expired {
                Text("Expired · current usage unknown")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let percent = window.usedPercent {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .accessibilityHidden(true)
            } else {
                Text("Current usage unknown")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let reset = date(window.resetsAt) {
                Text("\(window.expired ? "Reset" : "Resets") \(timestamp(reset))")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func percentage(_ window: AgentUsageReport.Program.UsageLimits.Window) -> some View {
        if !window.expired, let percent = window.usedPercent {
            Text((percent / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale)))
                .monospacedDigit()
        }
    }

    private func windowName(_ window: AgentUsageReport.Program.UsageLimits.Window) -> String {
        if let label = window.label, !label.isEmpty { return label }
        if program == "claude" {
            switch window.id {
            case "sevenDayOpus": return "Weekly · Opus"
            case "sevenDaySonnet": return "Weekly · Sonnet"
            default: break
            }
        }
        guard let minutes = window.durationMinutes, minutes > 0 else { return "Usage window" }
        if minutes == 10_080 { return "Weekly" }
        if minutes == 1_440 { return "Daily" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    private var retrySummary: String {
        guard let retry = date(limits.retryAt) else { return "Waiting to retry" }
        return "Retry after \(timestamp(retry))"
    }

    private var programName: String { program == "claude" ? "Claude Code" : "Codex" }

    private var unavailableMessage: String {
        if limits.state == "disabled" { return "Usage Limits are off." }
        switch limits.reason {
        case "programMissing": return "\(programName) is not installed or cannot run on this Host."
        case "programTooOld": return "Update \(programName) on this Host to read Usage Limits."
        case "notSignedIn": return "Sign in to \(programName) on this Host to read Usage Limits."
        case "noPlanLimits": return "This sign-in has no plan Usage Limits."
        default: return "Usage Limits could not be read. Try refreshing."
        }
    }

    private var sourceSummary: String? {
        guard let observed = date(limits.observedAt) else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .full
        let age = relative.localizedString(for: observed, relativeTo: Date())
        if limits.source == "lastSession" {
            return "Last session · as of \(timestamp(observed)) (\(age))"
        }
        return "From \(programName) · updated \(age)"
    }

    private func timestamp(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Composed by the full Usage page alongside its coverage and pricing notes.
struct CodexUsageLimitsNote: View {
    var body: some View {
        Text("Codex shows only its default limit group.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
