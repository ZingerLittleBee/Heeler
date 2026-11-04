import SwiftUI

/// What the Usage tab's figures count.
enum AgentUsageMetric: String, CaseIterable, Identifiable, Sendable {
    case cost
    case tokens

    var id: Self { self }

    var title: String {
        switch self {
        case .cost: "Est. Cost"
        case .tokens: "Tokens"
        }
    }
}

/// The Usage tab's ranges: the three totals the report carries.
enum AgentUsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case last7Days
    case last30Days

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .last7Days: "7 Days"
        case .last30Days: "30 Days"
        }
    }

    /// How many of the newest days the range covers.
    var dayCount: Int {
        switch self {
        case .today: 1
        case .last7Days: 7
        case .last30Days: 30
        }
    }
}

/// Colors and number formats every Usage surface shares, the widgets
/// included.
enum AgentUsageStyle {
    static func color(for program: String) -> Color {
        switch program {
        case "claude":
            Color(light: UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1),
                dark: UIColor(red: 0.878, green: 0.541, blue: 0.427, alpha: 1))
        case "codex":
            Color(light: UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1),
                dark: UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1))
        default:
            Color(uiColor: .systemGray)
        }
    }

    static func cost(_ value: Double?, locale: Locale) -> String {
        guard let value else { return "Unpriced" }
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(locale)
        if value > 0 && value < 0.01 { return "< \(0.01.formatted(style))" }
        return value.formatted(style)
    }

    /// Whole dollars once a figure is large enough that cents are noise.
    static func shortCost(_ value: Double?, locale: Locale) -> String {
        guard let value else { return "Unpriced" }
        guard value >= 1_000 else { return cost(value, locale: locale) }
        return value.formatted(
            FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0)).locale(locale))
    }

    static func tokens(_ value: Int64, locale: Locale) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
    }

    static func share(_ part: Double, of whole: Double, locale: Locale) -> String {
        guard whole > 0 else { return 0.0.formatted(.percent.locale(locale)) }
        return (part / whole).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// The time left before a reset, as "1h 48m" or "3d 16h".
    static func countdown(to reset: Date, now: Date, locale: Locale) -> String {
        var style = Duration.UnitsFormatStyle(
            allowedUnits: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2,
            fractionalPart: .hide(rounded: .down))
        style.locale = locale
        return Duration.seconds(max(reset.timeIntervalSince(now), 60)).formatted(style)
    }
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
