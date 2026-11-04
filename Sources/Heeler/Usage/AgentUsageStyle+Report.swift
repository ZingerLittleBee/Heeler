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
    /// The token types a split bar shows, darkest last.
    @MainActor static let tokenTypes: [(label: String, keyPath: KeyPath<AgentUsageReport.Tokens, Int64>, color: Color)] = [
        ("Input", \.input, Color(light: UIColor(white: 0.42, alpha: 1), dark: UIColor(white: 0.63, alpha: 1))),
        ("Cache read", \.cacheRead, Color(light: UIColor(white: 0.71, alpha: 1), dark: UIColor(white: 0.36, alpha: 1))),
        ("Cache write", \.cacheWrite, Color(light: UIColor(white: 0.28, alpha: 1), dark: UIColor(white: 0.79, alpha: 1))),
        ("Output", \.output, Color(light: UIColor(white: 0.12, alpha: 1), dark: UIColor(white: 0.95, alpha: 1))),
    ]

    /// The figure for one summary in the chosen metric.
    static func value(
        _ summary: AgentUsageReport.Summary, metric: AgentUsageMetric, locale: Locale
    ) -> String {
        switch metric {
        case .cost: cost(summary.estimatedCostUSD, locale: locale)
        case .tokens: "\(tokens(summary.tokens.total, locale: locale)) tokens"
        }
    }
}
