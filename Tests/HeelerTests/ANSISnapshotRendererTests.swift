import Foundation
import SwiftUI
import Testing

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
        var foreground: RGB?
        var foregroundOpacity = 1.0
        var background: RGB?
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

        var color: Color {
            Color(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255)
        }
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
                        foreground: RGB(0x80, 0x00, 0x00),
                        background: RGB(0x00, 0x00, 0x80)),
                    ExpectedRun(text: " plain"),
                ]),
            Fixture(
                name: "bright foreground and background",
                bytes: bytes("\u{1B}[96;101mbright\u{1B}[mreset"),
                text: "brightreset",
                runs: [
                    ExpectedRun(
                        text: "bright",
                        foreground: RGB(0x00, 0xFF, 0xFF),
                        background: RGB(0xFF, 0x00, 0x00)),
                    ExpectedRun(text: "reset"),
                ]),
            Fixture(
                name: "bold dim italic and underline",
                bytes: bytes("\u{1B}[1;2;3;4;32mstyled\u{1B}[22;23;24;39mplain"),
                text: "styledplain",
                runs: [
                    ExpectedRun(
                        text: "styled",
                        foreground: RGB(0x00, 0x80, 0x00),
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
        let expected = [
            RGB(0x00, 0x00, 0x00), RGB(0x80, 0x00, 0x00),
            RGB(0x00, 0x80, 0x00), RGB(0x80, 0x80, 0x00),
            RGB(0x00, 0x00, 0x80), RGB(0x80, 0x00, 0x80),
            RGB(0x00, 0x80, 0x80), RGB(0xC0, 0xC0, 0xC0),
            RGB(0x80, 0x80, 0x80), RGB(0xFF, 0x00, 0x00),
            RGB(0x00, 0xFF, 0x00), RGB(0xFF, 0xFF, 0x00),
            RGB(0x00, 0x00, 0xFF), RGB(0xFF, 0x00, 0xFF),
            RGB(0x00, 0xFF, 0xFF), RGB(0xFF, 0xFF, 0xFF),
        ]

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
                            text: "X", foreground: expected[index],
                            background: expected[index])
                    ]))
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
                        foreground: RGB(0x80, 0x00, 0x00),
                        background: RGB(0x00, 0xFF, 0xFF))
                ]),
            Fixture(
                name: "256-color cube",
                bytes: bytes("\u{1B}[38;5;21;48;5;208mcube"),
                text: "cube",
                runs: [
                    ExpectedRun(
                        text: "cube",
                        foreground: RGB(0x00, 0x00, 0xFF),
                        background: RGB(0xFF, 0x87, 0x00))
                ]),
            Fixture(
                name: "256-color grayscale",
                bytes: bytes("\u{1B}[38;5;232;48;5;255mgray"),
                text: "gray",
                runs: [
                    ExpectedRun(
                        text: "gray",
                        foreground: RGB(0x08, 0x08, 0x08),
                        background: RGB(0xEE, 0xEE, 0xEE))
                ]),
        ]

        fixtures.forEach(assertFixture)
    }

    @Test func rendersTruecolorFixtures() {
        let fixture = Fixture(
            name: "truecolor foreground and background",
            bytes: bytes("\u{1B}[38;2;12;34;56;48;2;210;180;140mrgb"),
            text: "rgb",
            runs: [
                ExpectedRun(
                    text: "rgb",
                    foreground: RGB(12, 34, 56),
                    background: RGB(210, 180, 140))
            ])

        assertFixture(fixture)
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

    @Test func filtersDecorativeBoxLinesAndPreservesMultibyteContent() {
        let fixture = Fixture(
            name: "box drawing CJK emoji and newlines",
            bytes: [
                0xE2, 0x94, 0x8C, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x90, 0x0A,
                0xE2, 0x94, 0x82, 0x1B, 0x5B, 0x33, 0x32, 0x6D,
                0xE4, 0xBD, 0xA0, 0xF0, 0x9F, 0x90, 0x9D,
                0x1B, 0x5B, 0x30, 0x6D, 0xE2, 0x94, 0x82, 0x0A,
                0xE2, 0x94, 0x94, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x98,
            ],
            text: "│你🐝│",
            runs: [
                ExpectedRun(text: "│"),
                ExpectedRun(text: "你🐝", foreground: RGB(0x00, 0x80, 0x00)),
                ExpectedRun(text: "│"),
            ])

        assertFixture(fixture)
    }

    @Test func removesDecorationOnlyBoxDrawingLines() {
        let rendered = ANSISnapshotRenderer.render(
            "before\r\n────────────────\r\n│ useful content │\r\n└──────────────┘\r\nafter")

        #expect(String(rendered.characters) == "before\n│ useful content │\nafter")
    }

    @Test func trimsLongDecorativeEdgesFromContentLines() {
        let rendered = ANSISnapshotRenderer.render(
            "──── heading\r\n─ Worked for 1m 33s ─────────────\r\n│ useful content │")

        #expect(
            String(rendered.characters)
                == "heading\n─ Worked for 1m 33s\n│ useful content │")
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
        #expect(
            runs[1].background
                == Color(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 8.0 / 255.0))
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
            let expectedForeground = expected.foreground.map {
                expected.foregroundOpacity < 1 ? $0.color.opacity(0.5) : $0.color
            } ?? (expected.foregroundOpacity < 1 ? Color.primary.opacity(0.5) : nil)
            #expect(
                actual.foreground == expectedForeground,
                "\(fixture.name): \(expected.text) foreground")
            #expect(
                actual.background == expected.background?.color,
                "\(fixture.name): \(expected.text) background")

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

    private func bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }
}
