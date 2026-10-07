import Foundation
import Observation
import SwiftUI
import UIKit

/// How a file diff lays out. Unified is the default; Side by Side is the
/// remembered alternative where it fits. The choice is app-wide.
enum DiffLayout: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sideBySide
    case unified

    var id: Self { self }

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .unified: "Unified"
        }
    }
}

/// Whether the layout control is offered. Below the column threshold it
/// is hidden rather than disabled: a disabled segmented control shows no
/// selection on iPadOS 26, so it read as broken and could not be used.
enum DiffLayoutToggle: Equatable, Sendable {
    case hidden
    case enabled
}

struct DiffLayoutDecision: Equatable, Sendable {
    var layout: DiffLayout
    var toggle: DiffLayoutToggle
}

/// Column threshold for Side by Side. The usable width is the width the
/// diff's rows lay out in, beside or under a sidebar. With four-digit line
/// numbers at the default text size the threshold is 782 pt, so Side by
/// Side is offered on an 11-inch iPad in portrait (834 pt) and beside its
/// sidebar in landscape, but not in a narrow window.
enum DiffLayoutPolicy {
    /// Text columns each side must fit before Side by Side is offered.
    static let minimumColumnsPerSide = 40
    /// SF Mono's advance at the 13 pt footnote size (0.618 em).
    /// `@ScaledMetric` grows this with Dynamic Type.
    static let defaultColumnWidth: CGFloat = 8.03
    /// Space before a side-by-side cell's line number.
    static let gutterLeadingPadding: CGFloat = 10
    /// Space before a unified row's first line number, and after each
    /// line number, all inside the gutter's wash.
    static let numberSpacing: CGFloat = 6
    /// Space after the text.
    static let trailingPadding: CGFloat = 12
    /// One monospaced digit at the 11 pt caption2 size. `@ScaledMetric`
    /// grows it.
    static let defaultDigitWidth: CGFloat = 6.8
    /// The sign column at the footnote size. `@ScaledMetric` grows it with
    /// the text.
    static let defaultGlyphWidth: CGFloat = 14
    /// The hairline between the two columns, counted once for the row.
    static let dividerWidth: CGFloat = 1

    /// Chrome beside the text on one side: the gutter with its line number,
    /// the sign, and the trailing padding. A four-digit number is 69.2 pt
    /// at the default size (10 + 27.2 + 6 + 14 + 12).
    static func sideChrome(digitWidth: CGFloat, glyphWidth: CGFloat, numberDigits: Int) -> CGFloat {
        gutterLeadingPadding
            + digitWidth * CGFloat(max(numberDigits, 1))
            + numberSpacing
            + glyphWidth
            + trailingPadding
    }

    /// A gutter holding `numbers` line numbers, with `leading` before the
    /// first and `numberSpacing` after each.
    static func gutterWidth(leading: CGFloat, numberWidth: CGFloat, numbers: Int) -> CGFloat {
        leading + CGFloat(numbers) * (numberWidth + numberSpacing)
    }

    static func requiredWidth(
        columnWidth: CGFloat,
        digitWidth: CGFloat = defaultDigitWidth,
        glyphWidth: CGFloat = defaultGlyphWidth,
        numberDigits: Int = 1
    ) -> CGFloat {
        let text = CGFloat(minimumColumnsPerSide) * columnWidth
        let side = sideChrome(digitWidth: digitWidth, glyphWidth: glyphWidth, numberDigits: numberDigits)
        return 2 * (side + text) + dividerWidth
    }

    static func resolve(
        preference: DiffLayout,
        offersSideBySide: Bool,
        usableWidth: CGFloat,
        columnWidth: CGFloat,
        digitWidth: CGFloat = defaultDigitWidth,
        glyphWidth: CGFloat = defaultGlyphWidth,
        numberDigits: Int = 1
    ) -> DiffLayoutDecision {
        guard offersSideBySide else {
            return DiffLayoutDecision(layout: .unified, toggle: .hidden)
        }
        let required = requiredWidth(
            columnWidth: columnWidth,
            digitWidth: digitWidth,
            glyphWidth: glyphWidth,
            numberDigits: numberDigits)
        guard usableWidth >= required else {
            return DiffLayoutDecision(layout: .unified, toggle: .hidden)
        }
        return DiffLayoutDecision(layout: preference, toggle: .enabled)
    }
}

/// App-wide Side by Side or Unified choice. A Changes presentation lasts
/// for one Checkout, so the remembered choice lives here rather than on
/// `ChangesStore`. Views read it through the `diffLayoutSettings` environment
/// value, falling back to ``shared`` outside tests and demo mode.
@MainActor
@Observable
final class DiffLayoutSettings {
    private static let defaultsKey = "changes.diff-layout"

    private(set) var layout: DiffLayout
    let offersSideBySide: Bool
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, offersSideBySide: Bool) {
        self.defaults = defaults
        self.offersSideBySide = offersSideBySide
        layout =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(DiffLayout.init(rawValue:)) ?? .unified
    }

    /// Production value. Tests and demo mode inject their own instance.
    static let shared = DiffLayoutSettings(
        offersSideBySide: UIDevice.current.userInterfaceIdiom == .pad)

    func select(_ layout: DiffLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        defaults.set(layout.rawValue, forKey: Self.defaultsKey)
    }
}

extension EnvironmentValues {
    @Entry var diffLayoutSettings: DiffLayoutSettings? = nil
}
