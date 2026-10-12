import Foundation
import Testing

@testable import Heeler

@Suite("Dialog row scanner")
struct DialogRowScannerTests {
    private func row(_ ansi: String) throws -> ScreenRow {
        try #require(ANSIScreenDecoder.decode(ansi).rows.first)
    }

    @Test("Numbered option rows, with and without the pointer")
    func numberedOptions() throws {
        let pointed =
            " " + SGR.claudeAccent + "❯ " + SGR.claudeInactive + "1. " + SGR.claudeAccent + "Yes" + SGR.reset
        let claude = try #require(
            DialogRowScanner.numberedOption(in: try row(pointed), pointer: DialogRowScanner.claudePointer))
        #expect(claude.number == 1)
        #expect(claude.pointerColumn == 1)
        #expect(claude.numberColumn == 3)
        #expect(claude.labelColumn == 6)
        #expect(claude.numberStyle.foreground == .rgb(153, 153, 153))

        let unpointed = try #require(
            DialogRowScanner.numberedOption(in: try row("   2. No"), pointer: DialogRowScanner.claudePointer))
        #expect(!unpointed.isPointed)
        #expect(unpointed.numberColumn == 3)
        #expect(unpointed.labelColumn == 6)

        let codex = try #require(
            DialogRowScanner.numberedOption(in: try row("› 12. Twelve"), pointer: DialogRowScanner.codexPointer))
        #expect(codex.number == 12)
        #expect(codex.pointerColumn == 0)
        #expect(codex.labelColumn == 6)
    }

    @Test(
        "Rows that only look numbered",
        arguments: [
            "1.Yes", "❯1. Yes", "123. Many", "0. Zero", "- 1. Bullet", "1) Yes", "\u{0661}. Arabic-Indic digit", "1.",
            "Text before ❯ 1. Yes", "› 1. The other program's pointer",
        ])
    func notNumbered(text: String) throws {
        #expect(DialogRowScanner.numberedOption(in: try row(text), pointer: DialogRowScanner.claudePointer) == nil)
    }

    @Test("Runs from a column cut a run that starts earlier")
    func runsFromColumn() throws {
        let option = try row("   " + SGR.claudeInactive + "3. Type something." + SGR.reset)
        let label = DialogRowScanner.runs(of: option, from: 6)
        #expect(label.map(\.text) == ["Type something."])
        #expect(label.first?.column == 6)
        #expect(label.first?.style.foreground == .rgb(153, 153, 153))
        #expect(DialogRowScanner.runs(of: option, from: 21).isEmpty)

        // A wide character straddling the column is dropped.
        let wide = DialogRowScanner.runs(of: try row("ab中文"), from: 3)
        #expect(wide.map(\.text) == ["文"])
        #expect(wide.first?.column == 4)
    }

    @Test("Rules of one glyph, indented or not")
    func rules() throws {
        let rule = String(repeating: "─", count: 20)
        #expect(DialogRowScanner.isRule(try row("  " + rule), of: "─", minimumWidth: 20))
        #expect(!DialogRowScanner.isRule(try row(String(rule.dropFirst())), of: "─", minimumWidth: 20))
        #expect(!DialogRowScanner.isRule(try row(rule + "x" + rule), of: "─", minimumWidth: 20))
        #expect(!DialogRowScanner.isRule(try row("    "), of: "─", minimumWidth: 0))
    }

    @Test("Wrapped rows join with or without a space")
    func join() throws {
        func join(_ previous: String, _ tail: String, _ wrap: TextWrapStyle, columns: Int = 40) throws -> String {
            DialogRowScanner.join(
                previous, tail, wrap: wrap, previousRow: try row(previous), columns: columns, boxColumn: 2)
        }
        // Claude leaves the separating space at the end of the row.
        #expect(
            try join("  Yes, and always allow access to ", "/tmp from this project", .claude)
                == "Yes, and always allow access to /tmp from this project")
        // A word longer than the box is cut at its edge.
        #expect(
            try join("  /private/tmp/heeler-tmp-chat2/probe-cl", "aude from this project", .claude)
                == "/private/tmp/heeler-tmp-chat2/probe-claude from this project")
        // At the edge, but the next word would have fit there: two words.
        #expect(
            try join("  Yes, and always allow access to the", "project", .claude, columns: 37)
                == "Yes, and always allow access to the project")
        // Claude breaks only at spaces; Codex also after a hyphen.
        #expect(try join("  well-", "known", .claude) == "well- known")
        #expect(try join("    $ touch x5-", "narrow-probe-file.txt", .codex) == "$ touch x5-narrow-probe-file.txt")
        #expect(
            try join("  Yes, and don't ask again for commands that", "start with", .codex, columns: 60)
                == "Yes, and don't ask again for commands that start with")
        #expect(try join("   ", "tail", .codex) == "tail")
        #expect(try join("  head", "  ", .claude) == "head")
    }

    @Test("Whether the next row's first word would have fit after a row")
    func wouldFit() throws {
        #expect(DialogRowScanner.wouldFit(firstWordOf: "next words", after: try row("  Short line"), columns: 20))
        #expect(!DialogRowScanner.wouldFit(firstWordOf: "abcdefgh", after: try row("  Short line"), columns: 20))
        // A row that ends in a blank needs no separating space.
        #expect(DialogRowScanner.wouldFit(firstWordOf: "abcdefgh", after: try row("  Short line "), columns: 20))
    }

    @Test(
        "Key hints come off option labels",
        arguments: [
            ("Yes, proceed (y)", "Yes, proceed", "y"),
            ("No, and tell Codex what to do differently (esc)", "No, and tell Codex what to do differently", "esc"),
            ("Yes, allow all edits this session (shift+tab)", "Yes, allow all edits this session", "shift+tab"),
            ("Use defaults (recommended)", "Use defaults (recommended)", nil),
            ("Pick (A)", "Pick (A)", nil),
            ("Yes(y)", "Yes(y)", nil),
            ("Skip (ctrl+])", "Skip (ctrl+])", nil),
        ] as [(String, String, String?)])
    func shortcuts(label: String, expectedLabel: String, shortcut: String?) {
        let split = DialogRowScanner.splitShortcut(label)
        #expect(split.label == expectedLabel)
        #expect(split.shortcut == shortcut)
    }

    @Test(
        "Permission roles from option labels",
        arguments: [
            ("Yes", nil, DialogOptionRole.approve),
            ("Yes, proceed", "y", .approve),
            ("No", nil, .decline),
            ("No, and tell Claude what to do differently", "esc", .decline),
            ("Yes, and don\u{2019}t ask again for example.com", nil, .approvePersistent),
            ("Yes, and always allow access to /tmp from this project", nil, .approvePersistent),
            ("Yes, remember this host", "p", .approvePersistent),
            ("Yes, and switch to auto mode", nil, .approveModeSwitch),
            ("Maybe later", nil, nil),
            ("Nothing", nil, nil),
            ("Yesterday", nil, nil),
        ] as [(String, String?, DialogOptionRole?)])
    func permissionRoles(label: String, shortcut: String?, role: DialogOptionRole?) {
        #expect(DialogRowScanner.permissionRole(for: label, shortcut: shortcut) == role)
    }

    @Test("Comparable text drops every blank and straightens apostrophes")
    func comparable() {
        #expect(DialogRowScanner.comparable(" Don\u{2019}t  ask\u{00A0}again\n") == "Don'taskagain")
        #expect(
            DialogRowScanner.comparable("Medium, but only if the larger one is\nout of stock")
                == DialogRowScanner.comparable("Medium, but only if the larger one is out of stock"))
    }
}
