import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Diff layout policy")
struct DiffLayoutPolicyTests {
    private let column = DiffLayoutPolicy.defaultColumnWidth

    @Test func defaultTextSizeFitsAnElevenInchPortraitButNotANarrowWindow() {
        for digits in 1...4 {
            let required = DiffLayoutPolicy.requiredWidth(columnWidth: column, numberDigits: digits)
            #expect(required > 694)
            #expect(required < 834)
            // 13-inch: full width, beside a 320 pt and a 380 pt sidebar, portrait.
            // 11-inch: portrait, and landscape beside a 320 pt sidebar.
            for width: CGFloat in [1376, 1056, 996, 1032, 834, 890] {
                #expect(
                    resolve(width, numberDigits: digits)
                        == DiffLayoutDecision(layout: .sideBySide, toggle: .enabled))
            }
            // A half-screen window on a 13-inch iPad in landscape.
            #expect(resolve(694, numberDigits: digits) == DiffLayoutDecision(layout: .unified, toggle: .hidden))
            #expect(resolve(required, numberDigits: digits) == DiffLayoutDecision(layout: .sideBySide, toggle: .enabled))
            #expect(resolve(required - 0.5, numberDigits: digits) == DiffLayoutDecision(layout: .unified, toggle: .hidden))
        }
    }

    @Test func anElevenInchLandscapeWithTheSidebarHiddenFits() {
        #expect(resolve(1210) == DiffLayoutDecision(layout: .sideBySide, toggle: .enabled))
    }

    @Test func theRowGutterPinsTheThreshold() {
        #expect(DiffLayoutPolicy.minimumColumnsPerSide == 40)
        #expect(DiffLayoutPolicy.defaultColumnWidth == 8.03)
        #expect(DiffLayoutPolicy.gutterLeadingPadding == 10)
        #expect(DiffLayoutPolicy.numberSpacing == 6)
        #expect(DiffLayoutPolicy.trailingPadding == 12)
        #expect(DiffLayoutPolicy.defaultDigitWidth == 6.8)
        #expect(DiffLayoutPolicy.defaultGlyphWidth == 14)
        #expect(DiffLayoutPolicy.dividerWidth == 1)
        // 10 pt lead + 27.2 pt number + 6 pt gap + 14 pt sign + 12 pt trail.
        #expect(abs(DiffLayoutPolicy.sideChrome(digitWidth: 6.8, glyphWidth: 14, numberDigits: 4) - 69.2) < 0.001)
        // 2 × (chrome + 40 columns) + the 1 pt divider. 40 × 8.03 is 321.2.
        let expected: [(digits: Int, width: CGFloat)] = [(1, 741.0), (2, 754.6), (3, 768.2), (4, 781.8)]
        for (digits, width) in expected {
            #expect(abs(DiffLayoutPolicy.requiredWidth(columnWidth: column, numberDigits: digits) - width) < 0.001)
        }
        let eightDigits = DiffLayoutPolicy.requiredWidth(columnWidth: column, numberDigits: 8)
        #expect(eightDigits > 781.8)
        #expect(eightDigits < 890)
    }

    @Test func theGutterHoldsItsNumbersAndTheirSpacing() {
        // Unified: 6 pt lead, then two numbers, each followed by 6 pt.
        #expect(abs(DiffLayoutPolicy.gutterWidth(leading: 6, numberWidth: 13.6, numbers: 2) - 45.2) < 0.001)
        // Side by side: 10 pt lead, one number, 6 pt.
        #expect(abs(DiffLayoutPolicy.gutterWidth(leading: 10, numberWidth: 13.6, numbers: 1) - 29.6) < 0.001)
    }

    @Test func accessibilityTextFallsBackToUnifiedAtTheColumnThreshold() {
        let footnote = UIFontMetrics(forTextStyle: .footnote)
        let caption = UIFontMetrics(forTextStyle: .caption2)
        let xxxTraits = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)
        let xxxLarge = footnote.scaledValue(for: column, compatibleWith: xxxTraits)
        let accessibility = footnote.scaledValue(for: column, compatibleWith: accessibilityTraits)
        #expect(xxxLarge > column)
        #expect(accessibility > xxxLarge)

        func scaledRequired(_ traits: UITraitCollection, digits: Int) -> CGFloat {
            DiffLayoutPolicy.requiredWidth(
                columnWidth: footnote.scaledValue(for: column, compatibleWith: traits),
                digitWidth: caption.scaledValue(
                    for: DiffLayoutPolicy.defaultDigitWidth, compatibleWith: traits),
                glyphWidth: footnote.scaledValue(
                    for: DiffLayoutPolicy.defaultGlyphWidth, compatibleWith: traits),
                numberDigits: digits)
        }
        for digits in [1, 4] {
            // The largest standard size still fits beside a 13-inch sidebar;
            // the first accessibility size needs the full landscape width.
            #expect(scaledRequired(xxxTraits, digits: digits) < 1056)
            #expect(scaledRequired(accessibilityTraits, digits: digits) > 1056)
            #expect(scaledRequired(accessibilityTraits, digits: digits) < 1376)
            #expect(
                resolve(
                    1056,
                    columnWidth: footnote.scaledValue(for: column, compatibleWith: accessibilityTraits),
                    digitWidth: caption.scaledValue(
                        for: DiffLayoutPolicy.defaultDigitWidth, compatibleWith: accessibilityTraits),
                    glyphWidth: footnote.scaledValue(
                        for: DiffLayoutPolicy.defaultGlyphWidth, compatibleWith: accessibilityTraits),
                    numberDigits: digits)
                    == DiffLayoutDecision(layout: .unified, toggle: .hidden))
        }

        let samples: [CGFloat] = [7, column, xxxLarge, accessibility, 40]
        let required = samples.map { DiffLayoutPolicy.requiredWidth(columnWidth: $0, numberDigits: 4) }
        for pair in zip(required, required.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
    }

    @Test func deepIndentationLeavesTheCodeHalfTheWidth() {
        #expect(DiffHangingIndentLayout.indentWidth(30, within: 300) == 30)
        #expect(DiffHangingIndentLayout.indentWidth(200, within: 300) == 150)
        #expect(DiffHangingIndentLayout.indentWidth(200, within: 301) == 150)
        #expect(DiffHangingIndentLayout.indentWidth(200, within: nil) == 200)
        #expect(DiffHangingIndentLayout.indentWidth(200, within: .infinity) == 200)
    }

    @Test func unifiedPreferenceWinsWhereSideBySideWouldFit() {
        #expect(
            resolve(1376, preference: .unified)
                == DiffLayoutDecision(layout: .unified, toggle: .enabled))
    }

    @Test func aPhoneNeverOffersTheToggle() {
        for width: CGFloat in [1376, 402] {
            for preference in DiffLayout.allCases {
                #expect(
                    resolve(width, preference: preference, offersSideBySide: false)
                        == DiffLayoutDecision(layout: .unified, toggle: .hidden))
            }
        }
    }

    private func resolve(
        _ usableWidth: CGFloat,
        preference: DiffLayout = .sideBySide,
        offersSideBySide: Bool = true,
        columnWidth: CGFloat? = nil,
        digitWidth: CGFloat = DiffLayoutPolicy.defaultDigitWidth,
        glyphWidth: CGFloat = DiffLayoutPolicy.defaultGlyphWidth,
        numberDigits: Int = 4
    ) -> DiffLayoutDecision {
        DiffLayoutPolicy.resolve(
            preference: preference,
            offersSideBySide: offersSideBySide,
            usableWidth: usableWidth,
            columnWidth: columnWidth ?? column,
            digitWidth: digitWidth,
            glyphWidth: glyphWidth,
            numberDigits: numberDigits)
    }
}
