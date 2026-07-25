import Foundation
import Testing
import UIKit

@testable import HerdrMobile

@MainActor
@Suite("Terminal zoom settings")
struct TerminalZoomSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-terminal-zoom-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToFourteenPoints() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(TerminalZoomSettings(defaults: defaults).fontSize == 14)
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

        #expect(settings.fontSize == 15)
    }

    @Test func fractionalZoomLandsOnWholePoints() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalZoomSettings(defaults: defaults)

        settings.setFontSize(17.4)

        #expect(settings.fontSize == 17)
    }

    @Test(arguments: [(Float(-3), Float(8)), (Float(2), Float(8)), (Float(400), Float(32))])
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

    @Test func terminalStartsAtTheRequestedFontSize() {
        let terminal = TerminalScreenView.makeConfiguredTerminal(fontSize: 20)

        #expect(terminal.appliedFontSize == 20)
    }

    @Test func changingFontSizeKeepsTheExistingTerminalSession() {
        let terminal = TerminalScreenView.makeConfiguredTerminal(fontSize: 14)
        let session = terminal.terminalSession

        #expect(terminal.applyFontSize(18))
        #expect(terminal.appliedFontSize == 18)
        #expect(terminal.terminalSession === session)
    }

    /// The zoom rides the controller's configuration rather than a Ghostty
    /// binding action, so prove it reaches the live surface: a bigger font on
    /// the same view has to yield a smaller grid, which is what gets sent to
    /// the remote PTY.
    @Test func zoomingResizesTheLiveGrid() async throws {
        let observed = GridObserver()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in observed.record(columns: columns, rows: rows) },
            fontSize: 10)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.addSubview(terminal)
        terminal.frame = window.bounds
        window.isHidden = false
        terminal.layoutIfNeeded()

        let small = try #require(await observed.settled())
        terminal.applyFontSize(30)
        let large = try #require(await observed.settled(after: small))

        #expect(large.columns < small.columns)
        #expect(large.rows < small.rows)
    }

    @Test func reapplyingTheSameFontSizeIsANoOp() {
        let terminal = TerminalScreenView.makeConfiguredTerminal(fontSize: 16)

        #expect(!terminal.applyFontSize(16))
        // Rounding and clamping happen before the comparison, so neither a
        // fractional nor an out-of-range repeat rebuilds the config.
        #expect(!terminal.applyFontSize(16.2))
        #expect(terminal.applyFontSize(1_000))
        #expect(terminal.appliedFontSize == 32)
    }
}

/// Ghostty reports grid changes through a callback that hops back to the main
/// actor, so tests wait for the value to land instead of reading it inline.
@MainActor
private final class GridObserver {
    struct Grid: Equatable {
        let columns: Int
        let rows: Int
    }

    private var latest: Grid?

    func record(columns: Int, rows: Int) {
        latest = Grid(columns: columns, rows: rows)
    }

    func settled(after previous: Grid? = nil) async -> Grid? {
        for _ in 0..<100 {
            if let latest, latest != previous { return latest }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
