import Foundation

/// A read time describes the content on screen, never a refresh attempt.
struct ChangesFreshness: Equatable {
    let readAt: Date

    func text(
        relativeTo now: Date, locale: Locale = .current,
        calendar: Calendar = .current, timeZone: TimeZone = .current
    ) -> String {
        let readTime = Self.readTime(
            readAt, relativeTo: now, locale: locale, calendar: calendar, timeZone: timeZone)
        return String(localized: "Possibly incomplete · \(readTime)")
    }

    func accessibilitySummary(relativeTo now: Date, locale: Locale = .current) -> String {
        let readTime = Self.readTime(readAt, relativeTo: now, locale: locale)
        return String(localized: "Possibly incomplete. \(readTime).")
    }

    static func readTime(
        _ readAt: Date, relativeTo now: Date, locale: Locale = .current,
        calendar: Calendar = .current, timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        let time = formatter.string(from: readAt)
        if calendar.isDate(readAt, inSameDayAs: now) { return String(localized: "Read at \(time)") }
        formatter.timeStyle = .none
        formatter.dateStyle = .medium
        return String(localized: "Read \(formatter.string(from: readAt)) at \(time)")
    }
}
