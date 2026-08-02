import Foundation
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("App appearance settings")
struct AppAppearanceSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-app-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToFollowingTheSystem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AppAppearanceSettings(defaults: defaults)

        #expect(settings.selection == .system)
        #expect(settings.preferredColorScheme == nil)
    }

    @Test func selectionPersistsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AppAppearanceSettings(defaults: defaults)

        settings.select(.dark)

        #expect(AppAppearanceSettings(defaults: defaults).selection == .dark)
    }

    /// A newer build's option name must not brick an older one: an unreadable
    /// stored value falls back to the system appearance rather than sticking
    /// the app in whatever was last rendered.
    @Test func unknownStoredOptionFallsBackToTheSystem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("solar-flare", forKey: "app-appearance")

        #expect(AppAppearanceSettings(defaults: defaults).selection == .system)
    }

    @Test(
        arguments: [
            (AppAppearanceOption.system, ColorScheme?.none),
            (.light, .light),
            (.dark, .dark),
        ])
    func eachOptionMapsToItsColorScheme(
        option: AppAppearanceOption, expected: ColorScheme?
    ) throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AppAppearanceSettings(defaults: defaults)

        settings.select(option)

        #expect(settings.preferredColorScheme == expected)
    }

    @Test func everyOptionIsOfferedInAStableOrder() {
        #expect(AppAppearanceOption.allCases == [.system, .light, .dark])
        #expect(AppAppearanceOption.allCases.map(\.title) == ["System", "Light", "Dark"])
    }
}
