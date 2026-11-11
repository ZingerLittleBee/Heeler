import SwiftUI

extension AgentUsageMetric {
    func value(of summary: AgentUsageReport.Summary) -> Double {
        switch self {
        case .cost: summary.estimatedCostUSD ?? 0
        case .tokens: Double(summary.tokens.total)
        }
    }
}

extension AgentUsageRange {
    func summary(in totals: AgentUsageReport.Totals) -> AgentUsageReport.Summary {
        switch self {
        case .today: totals.today
        case .last7Days: totals.last7Days
        case .last30Days: totals.last30Days
        }
    }
}

extension AgentUsageStyle {
    /// The token types a split bar shows, darkest last: a stable id, and the
    /// legend's name.
    @MainActor static let tokenTypes: [(
        id: String, title: String, keyPath: KeyPath<AgentUsageReport.Tokens, Int64>, color: Color
    )] = [
        ("input", String(localized: "Input"), \.input,
            Color(light: UIColor(white: 0.42, alpha: 1), dark: UIColor(white: 0.63, alpha: 1))),
        ("cacheRead", String(localized: "Cache read"), \.cacheRead,
            Color(light: UIColor(white: 0.71, alpha: 1), dark: UIColor(white: 0.36, alpha: 1))),
        ("cacheWrite", String(localized: "Cache write"), \.cacheWrite,
            Color(light: UIColor(white: 0.28, alpha: 1), dark: UIColor(white: 0.79, alpha: 1))),
        ("output", String(localized: "Output"), \.output,
            Color(light: UIColor(white: 0.12, alpha: 1), dark: UIColor(white: 0.95, alpha: 1))),
    ]

    /// The figure for one summary in the chosen metric.
    static func value(
        _ summary: AgentUsageReport.Summary, metric: AgentUsageMetric, locale: Locale
    ) -> String {
        switch metric {
        case .cost: cost(summary.estimatedCostUSD, locale: locale)
        case .tokens: String(localized: "\(tokens(summary.tokens.total, locale: locale)) tokens")
        }
    }
}
