import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Diff layout settings")
struct DiffLayoutSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-diff-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToUnified() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let settings = DiffLayoutSettings(defaults: defaults, offersSideBySide: true)

        #expect(settings.layout == .unified)
        #expect(settings.offersSideBySide)
        #expect(!DiffLayoutSettings(defaults: defaults, offersSideBySide: false).offersSideBySide)
    }

    @Test func selectionPersistsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = DiffLayoutSettings(defaults: defaults, offersSideBySide: true)

        settings.select(.sideBySide)

        #expect(defaults.string(forKey: "changes.diff-layout") == "sideBySide")
        #expect(DiffLayoutSettings(defaults: defaults, offersSideBySide: true).layout == .sideBySide)
        // A phone keeps the stored choice; the policy shows it Unified.
        #expect(DiffLayoutSettings(defaults: defaults, offersSideBySide: false).layout == .sideBySide)

        settings.select(.unified)

        #expect(defaults.string(forKey: "changes.diff-layout") == "unified")
        #expect(DiffLayoutSettings(defaults: defaults, offersSideBySide: true).layout == .unified)
    }

    @Test func unknownStoredValueFallsBackToUnified() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("columns", forKey: "changes.diff-layout")

        #expect(DiffLayoutSettings(defaults: defaults, offersSideBySide: true).layout == .unified)
    }

    @Test func segmentsAreSideBySideThenUnified() {
        #expect(DiffLayout.allCases == [.sideBySide, .unified])
        #expect(DiffLayout.allCases.map(\.title) == ["Side by Side", "Unified"])
    }
}
