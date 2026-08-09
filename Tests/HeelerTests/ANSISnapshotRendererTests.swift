import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("ANSI snapshot renderer")
struct ANSISnapshotRendererTests {
    private struct Fixture: Sendable {
        let name: String
        let bytes: [UInt8]
        let text: String
        let runs: [ExpectedRun]
    }

    private struct ExpectedRun: Sendable {
        let text: String
        var foreground: ExpectedColor?
        var foregroundOpacity = 1.0
        var background: ExpectedColor?
        var bold = false
        var italic = false
        var underline = false
    }

    private struct RGB: Sendable {
        let red: Int
        let green: Int
        let blue: Int

        init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    private typealias Resolved = (red: Int, green: Int, blue: Int, alpha: Double)

    /// How a run's color should resolve in one appearance.
    private enum ColorExpectation: Sendable {
        /// An exact 8-bit value.
        case exact(RGB)
        /// Clamped for legibility against the snapshot surface (a foreground
        /// with no explicit background).
        case clampedOnSurface
        /// Clamped for legibility against the run's own resolved background.
        case onExplicitBackground
        /// Clamped so the appearance's label text stays legible on it (a
        /// background).
        case underLabelText
    }

    private struct ExpectedColor: Sendable {
        let light: ColorExpectation
        let dark: ColorExpectation

        static func exact(_ light: RGB, _ dark: RGB) -> ExpectedColor {
            ExpectedColor(light: .exact(light), dark: .exact(dark))
        }

        static func adaptive(light: ColorExpectation, dark: ColorExpectation) -> ExpectedColor {
            ExpectedColor(light: light, dark: dark)
        }

        static let onExplicitBackground = ExpectedColor(
            light: .onExplicitBackground, dark: .onExplicitBackground)
        static let underLabelText = ExpectedColor(
            light: .underLabelText, dark: .underLabelText)
    }

    // Mirrors the renderer's base palette sources; every value clears WCAG
    // 4.5:1 on `secondarySystemGroupedBackground` in its appearance, so a
    // foreground with no explicit background resolves to exactly these.
    private static let palette: [(light: RGB, dark: RGB)] = [
        (RGB(0x1C, 0x1C, 0x1E), RGB(0x8C, 0x8C, 0x8C)),
        (RGB(0xA3, 0x15, 0x15), RGB(0xF9, 0x75, 0x83)),
        (RGB(0x0A, 0x6E, 0x0A), RGB(0x56, 0xD3, 0x64)),
        (RGB(0x6D, 0x6D, 0x00), RGB(0xE5, 0xE5, 0x10)),
        (RGB(0x04, 0x51, 0xA5), RGB(0x57, 0x9B, 0xD5)),
        (RGB(0x8A, 0x0A, 0x8A), RGB(0xD6, 0x70, 0xD6)),
        (RGB(0x00, 0x76, 0x76), RGB(0x39, 0xC5, 0xCF)),
        (RGB(0x59, 0x59, 0x59), RGB(0xC0, 0xC0, 0xC0)),
        (RGB(0x6E, 0x6E, 0x6E), RGB(0xA0, 0xA0, 0xA0)),
        (RGB(0xD7, 0x00, 0x00), RGB(0xFF, 0x7B, 0x72)),
        (RGB(0x00, 0x7A, 0x00), RGB(0x7C, 0xE3, 0x8B)),
        (RGB(0x71, 0x71, 0x00), RGB(0xF2, 0xF9, 0x7C)),
        (RGB(0x10, 0x59, 0xD0), RGB(0x6C, 0xB6, 0xFF)),
        (RGB(0xBC, 0x05, 0xBC), RGB(0xF9, 0x82, 0xF9)),
        (RGB(0x00, 0x7A, 0x7A), RGB(0x66, 0xE0, 0xE0)),
        (RGB(0x00, 0x00, 0x00), RGB(0xFF, 0xFF, 0xFF)),
    ]

    private func paletteColor(_ index: Int) -> ExpectedColor {
        let slot = Self.palette[index]
        return .exact(slot.light, slot.dark)
    }

    @Test func rendersSixteenColorAndTextAttributeFixtures() {
        let fixtures = [
            Fixture(
                name: "standard foreground and background",
                bytes: bytes("plain \u{1B}[31;44mred on blue\u{1B}[0m plain"),
                text: "plain red on blue plain",
                runs: [
                    ExpectedRun(text: "plain "),
                    ExpectedRun(
                        text: "red on blue",
                        foreground: .onExplicitBackground,
                        background: .underLabelText),
                    ExpectedRun(text: " plain"),
                ]),
            Fixture(
                name: "bright foreground and background",
                bytes: bytes("\u{1B}[96;101mbright\u{1B}[mreset"),
                text: "brightreset",
                runs: [
                    ExpectedRun(
                        text: "bright",
                        foreground: .onExplicitBackground,
                        background: .underLabelText),
                    ExpectedRun(text: "reset"),
                ]),
            Fixture(
                name: "bold dim italic and underline",
                bytes: bytes("\u{1B}[1;2;3;4;32mstyled\u{1B}[22;23;24;39mplain"),
                text: "styledplain",
                runs: [
                    ExpectedRun(
                        text: "styled",
                        foreground: paletteColor(2),
                        foregroundOpacity: 0.5,
                        bold: true,
                        italic: true,
                        underline: true),
                    ExpectedRun(text: "plain"),
                ]),
            Fixture(
                name: "dim default foreground",
                bytes: bytes("\u{1B}[2mdim\u{1B}[22mplain"),
                text: "dimplain",
                runs: [
                    ExpectedRun(text: "dim", foregroundOpacity: 0.5),
                    ExpectedRun(text: "plain"),
                ]),
        ]

        fixtures.forEach(assertFixture)
    }

    @Test func rendersEverySixteenColorSlot() {
        for index in 0..<16 {
            let foregroundCode = index < 8 ? 30 + index : 90 + index - 8
            let backgroundCode = index < 8 ? 40 + index : 100 + index - 8
            assertFixture(
                Fixture(
                    name: "ANSI color slot \(index)",
                    bytes: bytes("\u{1B}[\(foregroundCode);\(backgroundCode)mX"),
                    text: "X",
                    runs: [
                        ExpectedRun(
                            text: "X", foreground: .onExplicitBackground,
                            background: .underLabelText)
                    ]))
        }
    }

    @Test func everyBaseSlotForegroundResolvesToPaletteAndMeetsContract() {
        for index in 0..<16 {
            let foregroundCode = index < 8 ? 30 + index : 90 + index - 8
            let rendered = ANSISnapshotRenderer.render("\u{1B}[\(foregroundCode)mX")
            let foreground = rendered.runs.first?.foregroundColor
            let slot = Self.palette[index]

            let light = resolve(foreground, style: .light)
            #expect(
                light?.red == slot.light.red && light?.green == slot.light.green
                    && light?.blue == slot.light.blue,
                "slot \(index): light foreground")
            let dark = resolve(foreground, style: .dark)
            #expect(
                dark?.red == slot.dark.red && dark?.green == slot.dark.green
                    && dark?.blue == slot.dark.blue,
                "slot \(index): dark foreground")
            assertRatio(
                light, reference: ANSISnapshotRenderer.surfaceColor(for: .light),
                label: "slot \(index) light foreground")
            assertRatio(
                dark, reference: ANSISnapshotRenderer.surfaceColor(for: .dark),
                label: "slot \(index) dark foreground")
        }
    }

    @Test func everyBaseSlotBackgroundKeepsLabelTextLegibleInBothAppearances() {
        for index in 0..<16 {
            let backgroundCode = index < 8 ? 40 + index : 100 + index - 8
            let rendered = ANSISnapshotRenderer.render("\u{1B}[\(backgroundCode)mX")
            let background = rendered.runs.first?.backgroundColor

            assertRatio(
                resolve(background, style: .light),
                reference: ANSISnapshotRenderer.labelColor(for: .light),
                label: "slot \(index) light background")
            assertRatio(
                resolve(background, style: .dark),
                reference: ANSISnapshotRenderer.labelColor(for: .dark),
                label: "slot \(index) dark background")
        }
    }

    @Test func renders256ColorFixtures() {
        let fixtures = [
            Fixture(
                name: "256-color references ANSI slots",
                bytes: bytes("\u{1B}[38;5;1;48;5;14mansi"),
                text: "ansi",
                runs: [
                    ExpectedRun(
                        text: "ansi",
                        foreground: .onExplicitBackground,
                        background: .underLabelText)
                ]),
            Fixture(
                name: "256-color cube",
                bytes: bytes("\u{1B}[38;5;21;48;5;208mcube"),
                text: "cube",
                runs: [
                    ExpectedRun(
                        text: "cube",
                        foreground: .onExplicitBackground,
                        background: .underLabelText)
                ]),
            Fixture(
                name: "256-color grayscale",
                bytes: bytes("\u{1B}[38;5;232;48;5;255mgray"),
                text: "gray",
                runs: [
                    ExpectedRun(
                        text: "gray",
                        foreground: .onExplicitBackground,
                        background: .underLabelText)
                ]),
        ]

        fixtures.forEach(assertFixture)
    }

    @Test func extendedColorForegroundWithoutBackgroundKeepsSourceWhenLegible() {
        let fixtures = [
            Fixture(
                name: "cube blue",
                bytes: bytes("\u{1B}[38;5;21mX"),
                text: "X",
                runs: [
                    ExpectedRun(
                        text: "X",
                        foreground: .adaptive(
                            light: .exact(RGB(0x00, 0x00, 0xFF)),
                            dark: .clampedOnSurface))
                ]),
            Fixture(
                name: "cube orange",
                bytes: bytes("\u{1B}[38;5;208mX"),
                text: "X",
                runs: [
                    ExpectedRun(
                        text: "X",
                        foreground: .adaptive(
                            light: .clampedOnSurface,
                            dark: .exact(RGB(0xFF, 0x87, 0x00))))
                ]),
            Fixture(
                name: "dark gray",
                bytes: bytes("\u{1B}[38;5;232mX"),
                text: "X",
                runs: [
                    ExpectedRun(
                        text: "X",
                        foreground: .adaptive(
                            light: .exact(RGB(0x08, 0x08, 0x08)),
                            dark: .clampedOnSurface))
                ]),
            Fixture(
                name: "light gray",
                bytes: bytes("\u{1B}[38;5;255mX"),
                text: "X",
                runs: [
                    ExpectedRun(
                        text: "X",
                        foreground: .adaptive(
                            light: .clampedOnSurface,
                            dark: .exact(RGB(0xEE, 0xEE, 0xEE))))
                ]),
            Fixture(
                name: "truecolor dark blue",
                bytes: bytes("\u{1B}[38;2;12;34;56mX"),
                text: "X",
                runs: [
                    ExpectedRun(
                        text: "X",
                        foreground: .adaptive(
                            light: .exact(RGB(12, 34, 56)),
                            dark: .clampedOnSurface))
                ]),
            Fixture(
                name: "truecolor tan",
                bytes: bytes("\u{1B}[38;2;210;180;140mX"),
                text: "X",
                runs: [
                    ExpectedRun(
                        text: "X",
                        foreground: .adaptive(
                            light: .clampedOnSurface,
                            dark: .exact(RGB(210, 180, 140))))
                ]),
        ]

        fixtures.forEach(assertFixture)
    }

    @Test func explicitForegroundOnExplicitBackgroundMeetsContrastContract() {
        let samples = [
            "red on blue": "\u{1B}[31;44mX",
            "bright cyan on bright red": "\u{1B}[96;101mX",
            "cube blue on cube orange": "\u{1B}[38;5;21;48;5;208mX",
            "gray on gray": "\u{1B}[38;5;232;48;5;255mX",
            "truecolor on truecolor": "\u{1B}[38;2;12;34;56;48;2;210;180;140mX",
        ]
        for (name, sample) in samples {
            let rendered = ANSISnapshotRenderer.render(sample)
            let run = rendered.runs.first
            assertPairRatio(
                resolve(run?.foregroundColor, style: .light),
                resolve(run?.backgroundColor, style: .light),
                label: "\(name) light")
            assertPairRatio(
                resolve(run?.foregroundColor, style: .dark),
                resolve(run?.backgroundColor, style: .dark),
                label: "\(name) dark")
        }
    }

    @Test func contrastRatioMatchesWCAGReferenceValues() {
        let black = ANSISnapshotRenderer.RGB(red: 0, green: 0, blue: 0)
        let white = ANSISnapshotRenderer.RGB(red: 255, green: 255, blue: 255)
        let gray = ANSISnapshotRenderer.RGB(red: 0x76, green: 0x76, blue: 0x76)

        #expect(abs(ANSISnapshotRenderer.Contrast.ratio(of: black, to: white) - 21) < 0.001)
        #expect(abs(ANSISnapshotRenderer.Contrast.ratio(of: gray, to: gray) - 1) < 0.001)
        // #767676 is the canonical lightest gray passing 4.5:1 on white.
        #expect(abs(ANSISnapshotRenderer.Contrast.ratio(of: gray, to: white) - 4.542) < 0.01)
        #expect(abs(ANSISnapshotRenderer.Contrast.relativeLuminance(of: white) - 1) < 0.001)
        #expect(abs(ANSISnapshotRenderer.Contrast.relativeLuminance(of: black)) < 0.001)
    }

    @Test func legibleClampLeavesContrastingColorsUntouched() {
        let white = ANSISnapshotRenderer.RGB(red: 255, green: 255, blue: 255)
        let darkSurface = ANSISnapshotRenderer.RGB(red: 28, green: 28, blue: 30)
        let maroon = ANSISnapshotRenderer.RGB(red: 0x80, green: 0, blue: 0)
        let silver = ANSISnapshotRenderer.RGB(red: 0xC0, green: 0xC0, blue: 0xC0)

        #expect(ANSISnapshotRenderer.Contrast.legible(maroon, on: white) == maroon)
        #expect(ANSISnapshotRenderer.Contrast.legible(silver, on: darkSurface) == silver)
    }

    @Test func legibleClampDarkensOnLightSurfacePreservingHue() {
        let white = ANSISnapshotRenderer.RGB(red: 255, green: 255, blue: 255)
        let yellow = ANSISnapshotRenderer.RGB(red: 255, green: 255, blue: 0)

        let clamped = ANSISnapshotRenderer.Contrast.legible(yellow, on: white)

        #expect(ANSISnapshotRenderer.Contrast.ratio(of: clamped, to: white) >= 4.5)
        #expect(clamped.red < yellow.red)
        #expect(clamped.red >= clamped.blue)
        #expect(clamped.green >= clamped.blue)
    }

    @Test func legibleClampLightensOnDarkSurfacePreservingHue() {
        let darkSurface = ANSISnapshotRenderer.RGB(red: 28, green: 28, blue: 30)
        let navy = ANSISnapshotRenderer.RGB(red: 0, green: 0, blue: 0x80)

        let clamped = ANSISnapshotRenderer.Contrast.legible(navy, on: darkSurface)

        #expect(ANSISnapshotRenderer.Contrast.ratio(of: clamped, to: darkSurface) >= 4.5)
        #expect(clamped.blue > navy.blue)
        #expect(clamped.blue > clamped.red)
        #expect(clamped.blue > clamped.green)
    }

    @Test func legibleClampKeepsGrayscaleNeutral() {
        let darkSurface = ANSISnapshotRenderer.RGB(red: 28, green: 28, blue: 30)
        let darkGray = ANSISnapshotRenderer.RGB(red: 8, green: 8, blue: 8)

        let clamped = ANSISnapshotRenderer.Contrast.legible(darkGray, on: darkSurface)

        #expect(ANSISnapshotRenderer.Contrast.ratio(of: clamped, to: darkSurface) >= 4.5)
        #expect(clamped.red == clamped.green)
        #expect(clamped.green == clamped.blue)
    }

    @Test func legibleClampHandlesMidLuminanceReference() {
        let reference = ANSISnapshotRenderer.RGB(red: 0x77, green: 0x77, blue: 0x77)
        // Slightly lighter than the reference: the primary direction (away
        // from the reference) cannot reach 4.5:1 here, so the clamp must
        // fall back to the other direction.
        let color = ANSISnapshotRenderer.RGB(red: 0x80, green: 0x80, blue: 0x80)

        let clamped = ANSISnapshotRenderer.Contrast.legible(color, on: reference)

        #expect(ANSISnapshotRenderer.Contrast.ratio(of: clamped, to: reference) >= 4.5)
    }

    @Test func reverseVideoSwapsExplicitForegroundAndBackground() {
        let rendered = ANSISnapshotRenderer.render("\u{1B}[31;44;7mX")
        let run = rendered.runs.first

        #expect(run?.foregroundColor != nil)
        #expect(run?.backgroundColor != nil)
        // The swapped pair must stay legible in both appearances, and the
        // fill must keep label text legible.
        assertPairRatio(
            resolve(run?.foregroundColor, style: .light),
            resolve(run?.backgroundColor, style: .light),
            label: "reverse video light pair")
        assertPairRatio(
            resolve(run?.foregroundColor, style: .dark),
            resolve(run?.backgroundColor, style: .dark),
            label: "reverse video dark pair")
        assertRatio(
            resolve(run?.backgroundColor, style: .light),
            reference: ANSISnapshotRenderer.labelColor(for: .light),
            label: "reverse video light fill")
        assertRatio(
            resolve(run?.backgroundColor, style: .dark),
            reference: ANSISnapshotRenderer.labelColor(for: .dark),
            label: "reverse video dark fill")
    }

    @Test func reverseVideoWithoutColorsUsesLegibleHighlightPair() {
        let rendered = ANSISnapshotRenderer.render("\u{1B}[7mX")
        let run = rendered.runs.first

        #expect(run?.backgroundColor != nil)
        #expect(run?.foregroundColor != nil)
        assertPairRatio(
            resolve(run?.foregroundColor, style: .light),
            resolve(run?.backgroundColor, style: .light),
            label: "reverse video light pair")
        assertPairRatio(
            resolve(run?.foregroundColor, style: .dark),
            resolve(run?.backgroundColor, style: .dark),
            label: "reverse video dark pair")
    }

    @Test func reverseVideoWithForegroundOnlyFillsSurfaceText() {
        let rendered = ANSISnapshotRenderer.render("\u{1B}[31;7mX")
        let run = rendered.runs.first

        // The text takes the surface color, clamped against the fill: exactly
        // white on the light fill, exactly black on the dark one.
        let lightForeground = resolve(run?.foregroundColor, style: .light)
        #expect(lightForeground?.red == 255)
        #expect(lightForeground?.green == 255)
        #expect(lightForeground?.blue == 255)
        let darkForeground = resolve(run?.foregroundColor, style: .dark)
        #expect(darkForeground?.red == 0)
        #expect(darkForeground?.green == 0)
        #expect(darkForeground?.blue == 0)
        assertPairRatio(
            lightForeground,
            resolve(run?.backgroundColor, style: .light),
            label: "reverse video light pair")
        assertPairRatio(
            darkForeground,
            resolve(run?.backgroundColor, style: .dark),
            label: "reverse video dark pair")
        assertRatio(
            resolve(run?.backgroundColor, style: .light),
            reference: ANSISnapshotRenderer.labelColor(for: .light),
            label: "reverse video light fill")
        assertRatio(
            resolve(run?.backgroundColor, style: .dark),
            reference: ANSISnapshotRenderer.labelColor(for: .dark),
            label: "reverse video dark fill")
    }

    @Test func reverseVideoOffAndResetClearReversal() {
        let rendered = ANSISnapshotRenderer.render(
            "\u{1B}[7mA\u{1B}[27mB\u{1B}[7mC\u{1B}[0mD")
        let runs = rendered.runs.map { run in
            (
                text: String(rendered.characters[run.range]),
                foreground: run.foregroundColor,
                background: run.backgroundColor
            )
        }

        #expect(String(rendered.characters) == "ABCD")
        #expect(runs.count == 4)
        #expect(runs[0].text == "A")
        #expect(runs[0].background != nil)
        #expect(runs[1].text == "B")
        #expect(runs[1].background == nil)
        #expect(runs[1].foreground == nil)
        #expect(runs[2].text == "C")
        #expect(runs[2].background != nil)
        #expect(runs[3].text == "D")
        #expect(runs[3].background == nil)
        #expect(runs[3].foreground == nil)
    }

    @Test func stripsUnsupportedMalformedAndTruncatedSequences() {
        let fixtures = [
            Fixture(
                name: "non-SGR CSI",
                bytes: bytes("before\u{1B}[2Jafter"),
                text: "beforeafter",
                runs: [ExpectedRun(text: "beforeafter")]),
            Fixture(
                name: "OSC terminated by bell",
                bytes: bytes("left\u{1B}]0;secret title\u{07}right"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
            Fixture(
                name: "OSC terminated by string terminator",
                bytes: bytes("left\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\right"),
                text: "leftlinkright",
                runs: [ExpectedRun(text: "leftlinkright")]),
            Fixture(
                name: "DCS terminated by string terminator",
                bytes: bytes("left\u{1B}P1;2|device control payload\u{1B}\\right"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
            Fixture(
                name: "SOS terminated by string terminator",
                bytes: bytes("left\u{1B}Xstart of string payload\u{1B}\\right"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
            Fixture(
                name: "PM terminated by string terminator",
                bytes: bytes("left\u{1B}^privacy message payload\u{1B}\\right"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
            Fixture(
                name: "APC terminated by string terminator",
                bytes: bytes("left\u{1B}_application command payload\u{1B}\\right"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
            Fixture(
                name: "malformed SGR parameters",
                bytes: bytes("left\u{1B}[38;2;999;0;0mright"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
            Fixture(
                name: "truncated CSI",
                bytes: bytes("kept\u{1B}[38;2;1"),
                text: "kept",
                runs: [ExpectedRun(text: "kept")]),
            Fixture(
                name: "truncated OSC",
                bytes: bytes("kept\u{1B}]0;unfinished"),
                text: "kept",
                runs: [ExpectedRun(text: "kept")]),
            Fixture(
                name: "truncated DCS",
                bytes: bytes("kept\u{1B}Punfinished"),
                text: "kept",
                runs: [ExpectedRun(text: "kept")]),
            Fixture(
                name: "trailing escape",
                bytes: bytes("kept\u{1B}"),
                text: "kept",
                runs: [ExpectedRun(text: "kept")]),
            Fixture(
                name: "unsupported single-character escape",
                bytes: bytes("left\u{1B}cright"),
                text: "leftright",
                runs: [ExpectedRun(text: "leftright")]),
        ]

        fixtures.forEach(assertFixture)
    }

    @Test func preservesFramedMultibyteContent() {
        let fixture = Fixture(
            name: "box drawing CJK emoji and newlines",
            bytes: [
                0xE2, 0x94, 0x8C, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x90, 0x0A,
                0xE2, 0x94, 0x82, 0x1B, 0x5B, 0x33, 0x32, 0x6D,
                0xE4, 0xBD, 0xA0, 0xF0, 0x9F, 0x90, 0x9D,
                0x1B, 0x5B, 0x30, 0x6D, 0xE2, 0x94, 0x82, 0x0A,
                0xE2, 0x94, 0x94, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x98,
            ],
            text: "┌──┐\n│你🐝│\n└──┘",
            runs: [
                ExpectedRun(text: "┌──┐\n│"),
                ExpectedRun(text: "你🐝", foreground: paletteColor(2)),
                ExpectedRun(text: "│\n└──┘"),
            ])

        assertFixture(fixture)
    }

    @Test func preservesSeparatorAndFrameLinesAroundContent() {
        let rendered = ANSISnapshotRenderer.render(
            "before\r\n────────────────\r\n│ useful content │\r\n└──────────────┘\r\nafter")

        #expect(
            String(rendered.characters)
                == "before\n────────────────\n│ useful content │\n└──────────────┘\nafter")
    }

    @Test func preservesDecorativeEdgesOnContentLines() {
        let rendered = ANSISnapshotRenderer.render(
            "──── heading\r\n─ Worked for 1m 33s ─────────────\r\n│ useful content │")

        #expect(
            String(rendered.characters)
                == "──── heading\n─ Worked for 1m 33s ─────────────\n│ useful content │")
    }

    @Test func preservesMarkdownTableIncludingSeparatorRow() {
        // The table ends the snapshot on a bottom border, exactly like a
        // chrome frame would; its content rows must protect it.
        let snapshot = """
            Results:
            │ name        │ score     │
            ├─────────────┼───────────┤
            │ bee         │ 10        │
            └─────────────┴───────────┘
            """

        let rendered = ANSISnapshotRenderer.render(snapshot)

        #expect(String(rendered.characters) == snapshot)
    }

    @Test func removesTrailingEmptyInputBoxFrameAndHintLine() {
        let rendered = ANSISnapshotRenderer.render(
            """
            ⏺ Worked for 1m 33s
            ╭──────────────────────────╮
            │ >                        │
            ╰──────────────────────────╯
              ⏵⏵ accept edits on (shift+tab to cycle)

            """)

        #expect(String(rendered.characters) == "⏺ Worked for 1m 33s")
    }

    @Test func removesTrailingInputBoxFrameWithoutHintLine() {
        let rendered = ANSISnapshotRenderer.render(
            """
            ⏺ Worked for 1m 33s
            ╭──────────────────────────╮
            │ >                        │
            ╰──────────────────────────╯
            """)

        #expect(String(rendered.characters) == "⏺ Worked for 1m 33s")
    }

    @Test func preservesEmptyFrameFollowedByMoreContent() {
        let snapshot = """
            ╭──────────────────────────╮
            │                          │
            ╰──────────────────────────╯
            still working
            """

        let rendered = ANSISnapshotRenderer.render(snapshot)

        #expect(String(rendered.characters) == snapshot)
    }

    @Test func preservesTrailingFrameWithRealContentInside() {
        let snapshot = """
            Here you go:
            ╭──────────────────────────╮
            │ remember to buy milk     │
            ╰──────────────────────────╯
            """

        let rendered = ANSISnapshotRenderer.render(snapshot)

        #expect(String(rendered.characters) == snapshot)
    }

    @Test func removesBackgroundColorFromWhitespaceOnlyRuns() {
        let rendered = ANSISnapshotRenderer.render(
            "\u{1B}[48;5;232m        \u{1B}[0m\nmessage")

        #expect(String(rendered.characters) == "        \nmessage")
        #expect(rendered.runs.first?.backgroundColor == nil)
    }

    @Test func removesBackgroundColorFromRunPadding() {
        let rendered = ANSISnapshotRenderer.render(
            "\u{1B}[48;5;232m    message    \u{1B}[0m")
        let runs = rendered.runs.map { run in
            (
                text: String(rendered.characters[run.range]),
                background: run.backgroundColor
            )
        }

        #expect(String(rendered.characters) == "    message    ")
        #expect(runs.count == 3)
        #expect(runs[0].text == "    ")
        #expect(runs[0].background == nil)
        #expect(runs[1].text == "message")
        // The surviving background is clamped so label text stays legible.
        assertRatio(
            resolve(runs[1].background, style: .light),
            reference: ANSISnapshotRenderer.labelColor(for: .light),
            label: "message background light")
        assertRatio(
            resolve(runs[1].background, style: .dark),
            reference: ANSISnapshotRenderer.labelColor(for: .dark),
            label: "message background dark")
        #expect(runs[2].text == "    ")
        #expect(runs[2].background == nil)
    }

    private func assertFixture(_ fixture: Fixture) {
        let rendered = ANSISnapshotRenderer.render(String(decoding: fixture.bytes, as: UTF8.self))
        #expect(String(rendered.characters) == fixture.text, "\(fixture.name): text")

        let actualRuns = rendered.runs.map { run in
            (
                text: String(rendered.characters[run.range]),
                foreground: run.foregroundColor,
                background: run.backgroundColor,
                emphasis: run.inlinePresentationIntent,
                underline: run.underlineStyle
            )
        }
        #expect(actualRuns.count == fixture.runs.count, "\(fixture.name): run count")

        for (actual, expected) in zip(actualRuns, fixture.runs) {
            #expect(actual.text == expected.text, "\(fixture.name): run text")
            for style in [UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark] {
                let foreground = resolve(actual.foreground, style: style)
                let background = resolve(actual.background, style: style)
                assertResolved(
                    foreground,
                    matches: expected.foreground,
                    opacity: expected.foregroundOpacity,
                    partner: background,
                    style: style,
                    label: "\(fixture.name): \(expected.text) foreground")
                assertResolved(
                    background,
                    matches: expected.background,
                    opacity: 1,
                    partner: foreground,
                    style: style,
                    label: "\(fixture.name): \(expected.text) background")
            }

            var expectedEmphasis: InlinePresentationIntent = []
            if expected.bold {
                expectedEmphasis.insert(.stronglyEmphasized)
            }
            if expected.italic {
                expectedEmphasis.insert(.emphasized)
            }
            #expect(
                actual.emphasis == (expectedEmphasis.isEmpty ? nil : expectedEmphasis),
                "\(fixture.name): \(expected.text) emphasis")
            #expect(
                actual.underline == (expected.underline ? .single : nil),
                "\(fixture.name): \(expected.text) underline")
        }
    }

    private func assertResolved(
        _ resolved: Resolved?,
        matches expected: ExpectedColor?,
        opacity: Double,
        partner: Resolved?,
        style: UIUserInterfaceStyle,
        label: String
    ) {
        let appearance = style == .dark ? "dark" : "light"
        guard let expected else {
            if opacity < 1 {
                // Dim default foreground: Color.primary at half opacity.
                let channel = style == .dark ? 255 : 0
                #expect(
                    resolved?.red == channel && resolved?.green == channel
                        && resolved?.blue == channel
                        && abs((resolved?.alpha ?? 0) - opacity) < 0.01,
                    "\(label): dim default in \(appearance)")
            } else {
                #expect(resolved == nil, "\(label): expected no color in \(appearance)")
            }
            return
        }

        switch style == .dark ? expected.dark : expected.light {
        case .exact(let rgb):
            #expect(
                resolved?.red == rgb.red && resolved?.green == rgb.green
                    && resolved?.blue == rgb.blue
                    && abs((resolved?.alpha ?? 0) - opacity) < 0.01,
                "\(label): expected \(rgb) in \(appearance), got \(String(describing: resolved))")
        case .clampedOnSurface:
            assertRatio(
                resolved,
                reference: ANSISnapshotRenderer.surfaceColor(
                    for: style == .dark ? .dark : .light),
                label: label)
        case .onExplicitBackground:
            guard let partner else {
                Issue.record("\(label): expected a resolved background partner")
                return
            }
            assertPairRatio(resolved, partner, label: label)
        case .underLabelText:
            assertRatio(
                resolved,
                reference: ANSISnapshotRenderer.labelColor(
                    for: style == .dark ? .dark : .light),
                label: label)
        }
    }

    private func assertRatio(
        _ resolved: Resolved?,
        reference: ANSISnapshotRenderer.RGB,
        label: String
    ) {
        guard let resolved else {
            Issue.record("\(label): expected a resolved color")
            return
        }
        let ratio = ANSISnapshotRenderer.Contrast.ratio(of: rgb(resolved), to: reference)
        #expect(
            ratio >= ANSISnapshotRenderer.Contrast.minimumForegroundRatio,
            "\(label): contrast \(ratio) below 4.5")
    }

    private func assertPairRatio(
        _ foreground: Resolved?,
        _ background: Resolved?,
        label: String
    ) {
        guard let foreground, let background else {
            Issue.record("\(label): expected both colors to resolve")
            return
        }
        let ratio = ANSISnapshotRenderer.Contrast.ratio(
            of: rgb(foreground), to: rgb(background))
        #expect(
            ratio >= ANSISnapshotRenderer.Contrast.minimumForegroundRatio,
            "\(label): contrast \(ratio) below 4.5")
    }

    private func rgb(_ resolved: Resolved) -> ANSISnapshotRenderer.RGB {
        ANSISnapshotRenderer.RGB(
            red: resolved.red, green: resolved.green, blue: resolved.blue)
    }

    private func resolve(
        _ color: Color?,
        style: UIUserInterfaceStyle
    ) -> Resolved? {
        guard let color else { return nil }
        let resolved = UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Double(alpha)
        )
    }

    private func bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }
}
