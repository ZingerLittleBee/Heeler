import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal zoom settings")
struct TerminalZoomSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-terminal-zoom-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToEightPoints() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(TerminalZoomSettings(defaults: defaults).fontSize == 8)
    }

    @Test func fontSizePersistsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalZoomSettings(defaults: defaults)

        settings.setFontSize(21)

        #expect(TerminalZoomSettings(defaults: defaults).fontSize == 21)
    }

    @Test func adjustingStepsFromTheCurrentSize() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalZoomSettings(defaults: defaults)

        settings.adjust(by: 1)
        settings.adjust(by: 1)
        settings.adjust(by: -1)

        #expect(settings.fontSize == 9)
    }

    @Test func fractionalZoomLandsOnWholePoints() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalZoomSettings(defaults: defaults)

        settings.setFontSize(17.4)

        #expect(settings.fontSize == 17)
    }

    @Test(arguments: [(Float(-3), Float(4)), (Float(1), Float(4)), (Float(400), Float(32))])
    func outOfRangeSizesClampToTheSupportedWindow(requested: Float, expected: Float) throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalZoomSettings(defaults: defaults)

        settings.setFontSize(requested)

        #expect(settings.fontSize == expected)
    }

    @Test func persistedSizeFromAWiderRangeIsClampedOnLoad() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Float(64), forKey: "terminal-font-size")

        #expect(TerminalZoomSettings(defaults: defaults).fontSize == 32)
    }
}
