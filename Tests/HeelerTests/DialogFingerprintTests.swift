import Foundation
import Testing

@testable import Heeler

@Suite("Dialog fingerprint")
struct DialogFingerprintTests {
    private func fingerprint(_ stem: String) throws -> DialogFingerprint {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        return try #require(result.dialog?.fingerprint, "\(stem) parsed as \(result)")
    }

    private func bashFingerprint(
        program: ChatProgram = .claude, kind: BlockedDialogKind = .claudeBash, sourceSuffix: String? = nil,
        body: [String] = ["touch a.txt"], progress: String? = nil, options: [DialogOption]? = nil
    ) -> DialogFingerprint {
        DialogFingerprint(
            program: program, kind: kind, title: "Bash command", sourceSuffix: sourceSuffix, body: body,
            progress: progress,
            options: options ?? [
                DialogOption(ordinal: 1, number: 1, label: "Yes", role: .approve),
                DialogOption(ordinal: 2, number: 2, label: "No", role: .decline),
            ])
    }

    @Test(
        "Focus, notes, checks and typed text keep a dialog's fingerprint",
        arguments: [
            ("claude-02-c1-bash-blocked", "claude-03-c1-focus-no"),
            ("claude-02-c1-bash-blocked", "claude-05-c1-pasted-feedback"),
            ("claude-08-c4-auq-q1", "claude-10-c4-focus-next"),
            ("claude-16-c6-exitplan-1", "claude-18-c6-pasted"),
            ("codex-05-x3-q2", "codex-07-x3-q2-pasted"),
        ])
    func unchanged(first: String, second: String) throws {
        #expect(try fingerprint(first) == fingerprint(second))
    }

    @Test(
        "Another request, plan or page changes the fingerprint",
        arguments: [
            ("claude-30-par-first", "claude-31-par-second"),
            ("codex-13-par-first", "codex-14-par-second"),
            ("claude-16-c6-exitplan-1", "claude-19-c6-exitplan-2"),
            ("claude-08-c4-auq-q1", "claude-11-c4-q2"),
            ("codex-04-x3-q1", "codex-05-x3-q2"),
            ("codex-09-x4-expanded", "codex-10-x4-after-digit"),
        ])
    func changed(first: String, second: String) throws {
        #expect(try fingerprint(first) != fingerprint(second))
    }

    @Test("Whitespace and apostrophe style do not count")
    func normalization() {
        let plain = bashFingerprint(options: [
            DialogOption(ordinal: 1, number: 1, label: "Yes, and don't ask again", role: .approvePersistent)
        ])
        let typographic = bashFingerprint(
            body: ["touch  a.txt"],
            options: [
                DialogOption(
                    ordinal: 1, number: 1, label: "Yes, and don\u{2019}t ask\u{00A0}again", role: .approvePersistent)
            ])
        #expect(plain == typographic)
        #expect(bashFingerprint(body: ["touch a.txt"]) != bashFingerprint(body: ["touch b.txt"]))
    }

    @Test("Program, kind, source, progress and numbering count")
    func identity() {
        let base = bashFingerprint()
        #expect(base == bashFingerprint())
        #expect(base != bashFingerprint(program: .codex))
        #expect(base != bashFingerprint(kind: .claudeFileEdit))
        #expect(base != bashFingerprint(sourceSuffix: "from the Explore agent"))
        #expect(base != bashFingerprint(progress: "Size"))
        #expect(
            base
                != bashFingerprint(options: [
                    DialogOption(ordinal: 1, number: 1, label: "Yes", role: .approve),
                    DialogOption(ordinal: 2, number: 3, label: "No", role: .decline),
                ]))
    }

    @Test("A text field reads the same empty or typed")
    func textFields() {
        func question(_ input: InputRowState) -> DialogFingerprint {
            bashFingerprint(
                kind: .claudeQuestion,
                options: [
                    DialogOption(ordinal: 1, number: 1, label: "Small", role: .answer),
                    DialogOption(
                        ordinal: 2, number: 2, label: "Type something.", role: .otherText, input: input),
                ])
        }
        #expect(question(.placeholder("Type something.")) == question(.text("Medium")))
    }

    @Test("The description is the digest's first twelve hex digits")
    func description() throws {
        let fingerprint = try fingerprint("claude-02-c1-bash-blocked")
        #expect(fingerprint.value.count == 64)
        #expect(fingerprint.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(fingerprint.description == String(fingerprint.value.prefix(12)))
    }

    @Test("The same dialog wrapped at another width keeps its fingerprint (synthetic)")
    func width() throws {
        let wide = ClaudeDialogRows.screen(
            title: "Bash command", options: ["Yes", "Yes, and always allow access to /tmp/project from this project", "No"],
            width: 100)
        let narrow = ClaudeDialogRows.screen(
            title: "Bash command",
            options: ["Yes", "Yes, and always allow access to\r\n      /tmp/project from this project", "No"],
            width: 40)
        let wideDialog = try #require(ClaudeDialogParser.parse(wide).dialog)
        let narrowDialog = try #require(ClaudeDialogParser.parse(narrow).dialog)
        #expect(narrowDialog.options[1].label == wideDialog.options[1].label)
        #expect(narrowDialog.fingerprint == wideDialog.fingerprint)
    }
}
