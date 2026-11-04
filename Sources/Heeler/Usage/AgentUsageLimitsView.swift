import SwiftUI

/// Program-reported account windows, kept separate from the Host's token totals.
struct AgentUsageLimitsView: View {
    /// How each window reads.
    enum Style {
        /// A bar under the name, the reset time and countdown below.
        case detailed
        /// One line per window: name, bar, percentage, countdown.
        case rows
        /// Windows side by side, for an iPad's Usage Limits strip.
        case columns
    }

    let program: String
    let limits: AgentUsageReport.Program.UsageLimits
    /// The Usage Limits sheet names the section itself.
    var showsTitle = true
    var style = Style.detailed
    @Environment(\.locale) private var locale

    var body: some View {
        // Ages and reset times are relative to now: re-render while the
        // page stays open so a passed reset reads as expired.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("Usage Limits").font(.subheadline.weight(.semibold))
            }
            if limits.state == "ok" || limits.state == "throttled" {
                if limits.state == "throttled" {
                    Text("Last reading · \(retrySummary)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if style != .columns, let sourceSummary = sourceSummary(now: now) {
                    Text(sourceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if (limits.windows ?? []).isEmpty {
                    Text("No Usage Limits windows reported.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                switch style {
                case .detailed:
                    ForEach(limits.windows ?? []) { window in
                        windowView(window, now: now)
                    }
                case .rows:
                    ForEach(Array((limits.windows ?? []).enumerated()), id: \.element.id) { index, window in
                        Divider().padding(.vertical, index == 0 ? 2 : 0)
                        windowRow(window, now: now)
                    }
                case .columns:
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(limits.windows ?? []) { window in
                            windowColumn(window, now: now)
                        }
                    }
                }
            } else if limits.state == "unavailable" && limits.reason == "notReadYet" {
                // Readings follow the Token Usage scan; nothing is known yet.
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading Usage Limits…")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(unavailableMessage)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func windowView(_ window: AgentUsageReport.Program.UsageLimits.Window, now: Date) -> some View {
        let reset = date(window.resetsAt)
        // The plugin decides expiry when it answers; a reset that passes
        // while the page is open expires the reading here.
        let expired = window.expired || reset.map { $0 <= now } == true
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(windowName(window))
                    Spacer(minLength: 12)
                    percentage(window, expired: expired)
                        .font(.title3.weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(windowName(window))
                    percentage(window, expired: expired)
                        .font(.title3.weight(.semibold))
                }
            }
            if expired {
                Text("Expired · current usage unknown")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let percent = window.usedPercent {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .tint(AgentUsageStyle.color(for: program))
                    .accessibilityHidden(true)
            } else {
                Text("Current usage unknown")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let reset {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(expired ? "Reset" : "Resets") \(timestamp(reset))")
                        .fixedSize(horizontal: false, vertical: true)
                    if !expired {
                        Spacer(minLength: 8)
                        Text("in \(AgentUsageStyle.countdown(to: reset, now: now, locale: locale))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func windowRow(_ window: AgentUsageReport.Program.UsageLimits.Window, now: Date) -> some View {
        let reset = date(window.resetsAt)
        let expired = window.expired || reset.map { $0 <= now } == true
        return HStack(spacing: 10) {
            Text(windowName(window))
                .frame(maxWidth: .infinity, alignment: .leading)
            if expired {
                Text("Expired · current usage unknown")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let percent = window.usedPercent {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .tint(AgentUsageStyle.color(for: program))
                    .frame(width: 100)
                    .accessibilityHidden(true)
                percentage(window, expired: false)
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, alignment: .trailing)
                countdownLabel(reset: reset, now: now)
                    .frame(minWidth: 58, alignment: .leading)
            } else {
                Text("Current usage unknown").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }

    private func windowColumn(_ window: AgentUsageReport.Program.UsageLimits.Window, now: Date) -> some View {
        let reset = date(window.resetsAt)
        let expired = window.expired || reset.map { $0 <= now } == true
        return VStack(alignment: .leading, spacing: 3) {
            Text(windowName(window))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if expired {
                Text("Expired").font(.subheadline).foregroundStyle(.secondary)
            } else if let percent = window.usedPercent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    percentage(window, expired: false)
                        .font(.subheadline.weight(.semibold))
                    if let reset {
                        Text(AgentUsageStyle.countdown(to: reset, now: now, locale: locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .tint(AgentUsageStyle.color(for: program))
                    .accessibilityHidden(true)
            } else {
                Text("Unknown").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 120, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func countdownLabel(reset: Date?, now: Date) -> some View {
        if let reset {
            Label(AgentUsageStyle.countdown(to: reset, now: now, locale: locale), systemImage: "clock")
                .labelStyle(AgentUsageCountdownLabelStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Resets in \(AgentUsageStyle.countdown(to: reset, now: now, locale: locale))")
        }
    }

    @ViewBuilder
    private func percentage(
        _ window: AgentUsageReport.Program.UsageLimits.Window, expired: Bool
    ) -> some View {
        if !expired, let percent = window.usedPercent {
            Text((percent / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale)))
                .monospacedDigit()
        }
    }

    private func windowName(_ window: AgentUsageReport.Program.UsageLimits.Window) -> String {
        Self.windowName(window, program: program)
    }

    nonisolated static func windowName(
        _ window: AgentUsageReport.Program.UsageLimits.Window, program: String
    ) -> String {
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

    private var programName: String { AgentUsageReport.Program.displayName(for: program) }

    private var unavailableMessage: String { Self.unavailableMessage(limits, program: program) }

    /// Why a program's Usage Limits have no windows to show.
    nonisolated static func unavailableMessage(
        _ limits: AgentUsageReport.Program.UsageLimits, program: String
    ) -> String {
        let programName = AgentUsageReport.Program.displayName(for: program)
        if limits.state == "disabled" { return "Usage Limits are off." }
        switch limits.reason {
        case "programMissing": return "\(programName) is not installed or cannot run on this Host."
        case "programTooOld": return "Update \(programName) on this Host to read Usage Limits."
        case "notSignedIn": return "Sign in to \(programName) on this Host to read Usage Limits."
        case "noPlanLimits": return "This sign-in has no plan Usage Limits."
        case "keychainUnavailable":
            return "\(programName) could not use this Mac’s keychain. Start herdr from a terminal on the Mac, then refresh."
        default: return "Usage Limits could not be read. Try refreshing."
        }
    }

    private func sourceSummary(now: Date) -> String? {
        guard let observed = date(limits.observedAt) else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .full
        let age = relative.localizedString(for: observed, relativeTo: now)
        if limits.source == "lastSession" {
            return "Last session · as of \(timestamp(observed)) (\(age))"
        }
        return "From \(programName) · updated \(age)"
    }

    private func timestamp(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    private func date(_ value: String?) -> Date? { Self.date(value) }

    nonisolated static func date(_ value: String?) -> Date? {
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

/// A small icon before the countdown.
private struct AgentUsageCountdownLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title.monospacedDigit()
        }
    }
}
