import Foundation
import Observation

/// The app-wide terminal font size, in points. Pinch-to-zoom on an Attach
/// terminal writes here, so a zoom survives leaving the screen and applies to
/// every terminal the app opens afterwards.
@MainActor
@Observable
final class TerminalZoomSettings {
    static let defaultFontSize: Float = 8
    /// Whole points only. The low end goes all the way down to libghostty's
    /// own minimum: 4 pt is unreadable, but it fits a wide TUI on screen, and
    /// zooming out for the shape of a layout is a real thing people do.
    static let range: ClosedRange<Float> = 4...32

    private static let defaultsKey = "terminal-font-size"

    private(set) var fontSize: Float
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored =
            defaults.object(forKey: Self.defaultsKey) == nil
            ? Self.defaultFontSize
            : defaults.float(forKey: Self.defaultsKey)
        fontSize = Self.clamped(stored)
    }

    func setFontSize(_ size: Float) {
        let clamped = Self.clamped(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        defaults.set(clamped, forKey: Self.defaultsKey)
    }

    func adjust(by points: Float) {
        setFontSize(fontSize + points)
    }

    /// The single clamping policy, shared by the settings control, pinch-zoom,
    /// and the keyboard shortcut so they can never disagree on a boundary.
    static func clamped(_ size: Float) -> Float {
        guard size.isFinite else { return defaultFontSize }
        return min(max(size.rounded(), range.lowerBound), range.upperBound)
    }
}
