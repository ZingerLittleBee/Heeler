import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Changes freshness", .serialized, .timeLimit(.minutes(1)))
struct ChangesFreshnessTests {
    @Test func readTimeIncludesTheDateOnlyOutsideToday() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_US_POSIX")
        let date = Date(timeIntervalSince1970: 86_400 + 14 * 3_600 + 5 * 60)
        let freshness = ChangesFreshness(readAt: date)
        let today = freshness.text(relativeTo: date, locale: locale, calendar: calendar, timeZone: zone)
        #expect(today.hasPrefix("Possibly incomplete · Read at "))
        #expect(today.contains("2:05"))
        let yesterday = freshness.text(
            relativeTo: date.addingTimeInterval(86_400), locale: locale,
            calendar: calendar, timeZone: zone)
        #expect(yesterday.hasPrefix("Possibly incomplete · Read Jan 2, 1970 at "))
        #expect(yesterday.contains("2:05"))
    }
}
