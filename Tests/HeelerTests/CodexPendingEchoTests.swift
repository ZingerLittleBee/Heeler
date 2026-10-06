import Foundation
import Testing

@testable import Heeler

/// Matching prompts Heeler sent to the prompts Codex recorded
/// (docs/research/codex-rollout-format.md, "Prompt recording and echo
/// matching").
@Suite("Codex pending echo")
struct CodexPendingEchoTests {
    @Test("The key undoes what the TUI changes in a paste", arguments: CodexEchoKeyCase.allCases)
    func echoKey(_ keyCase: CodexEchoKeyCase) {
        #expect(codexEchoKey(keyCase.sent) == keyCase.key)
    }

    @Test("Sends match recorded prompts first in, first out, one to one")
    func fifoWithRepeats() {
        let cursor = CodexEchoCursor(rolloutID: "r1", offset: 100)
        let sends = ["again ", "again ", "other "].map { CodexPendingSend(text: $0, cursor: cursor) }
        let recorded = [Self.prompt("other", at: 120), Self.prompt("again", at: 150), Self.prompt("again", at: 180)]

        #expect(Self.match(sends, recorded) == [Self.id(150), Self.id(180), Self.id(120)])
        // With one copy recorded so far, the second send is still pending.
        #expect(Self.match(sends, Array(recorded[..<2])) == [Self.id(150), nil, Self.id(120)])
    }

    @Test("Only prompts recorded after the send count")
    func cursor() {
        let send = CodexPendingSend(text: "hello", cursor: CodexEchoCursor(rolloutID: "r1", offset: 500))

        #expect(Self.match([send], [Self.prompt("hello", at: 400)]) == [nil])
        #expect(Self.match([send], [Self.prompt("hello", at: 400), Self.prompt("hello", at: 500)]) == [Self.id(500)])
        // A revert continues in a new file, whose offsets start over.
        #expect(Self.match([send], [Self.prompt("hello", at: 40, rollout: "r2")]) == [Self.id(40)])
    }

    @Test("An image path sent alone matches the [Image #1] prompt carrying it", arguments: CodexImageSendCase.allCases)
    func imageOnly(_ imageCase: CodexImageSendCase) {
        let send = CodexPendingSend(text: imageCase.sent, cursor: CodexEchoCursor(rolloutID: "r1", offset: 0))
        let candidates = [
            Self.prompt("[Image #1]", at: 10, images: ["/Users/me/other.png"]),
            Self.prompt("[Image #1]", at: 20, images: [imageCase.path]),
        ]
        #expect(Self.match([send], candidates) == [Self.id(20)])
    }

    @Test("Matching never falls back to prefixes, case or near misses")
    func neverFuzzy() {
        let cursor = CodexEchoCursor(rolloutID: "r1", offset: 0)
        let send = CodexPendingSend(text: "hello world", cursor: cursor)
        for text in ["hello world!", "hello", "Hello world", "hello  world", "hello world and more"] {
            #expect(Self.match([send], [Self.prompt(text, at: 10)]) == [nil], "recorded \(text)")
        }

        // A prompt is never a compaction's echo, nor a compaction a prompt's.
        let compaction = CodexEchoCandidate(rolloutID: "r1", offset: 10, entryID: Self.id(10), kind: .compaction)
        #expect(Self.match([send], [compaction]) == [nil])
        #expect(
            Self.match([CodexPendingSend(text: "/compact", cursor: cursor)], [Self.prompt("/compact", at: 10)]) == [nil])

        // A path with other words is text, not an image paste.
        let sentence = CodexPendingSend(text: "see /Users/me/shot.png", cursor: cursor)
        #expect(
            Self.match([sentence], [Self.prompt("[Image #1]", at: 10, images: ["/Users/me/shot.png"])]) == [nil])
    }

    @Test("P2's first prompt is the echo of the text Heeler sent")
    func probeEcho() throws {
        let probe = try CodexProbe.probe2()
        let projection = probe.reducer().projection(ChatProjectionContext(activity: .idle))
        let send = CodexPendingSend(
            text: "Run the shell command: touch x1.txt in the current directory ",
            cursor: CodexEchoCursor(rolloutID: CodexProbe.probe2ID, offset: probe.offset(2)))

        let first = try #require(projection.transcript.entries.first)
        #expect(CodexPendingEcho.match(pending: [send], candidates: projection.echoCandidates) == [first.id])
        // The async reply at L78 is an Answered row, not a candidate.
        #expect(projection.echoCandidates.map(\.offset) == [10, 27, 44, 61, 93, 106].map(probe.offset))
    }

    private static func prompt(
        _ text: String, at offset: UInt64, images: [String] = [], rollout: String = "r1"
    ) -> CodexEchoCandidate {
        CodexEchoCandidate(
            rolloutID: rollout, offset: offset, entryID: id(offset), kind: .prompt(text: text, localImagePaths: images))
    }

    private static func id(_ offset: UInt64) -> ChatEntryID {
        ChatEntryID("entry@\(offset)")
    }

    private static func match(_ sends: [CodexPendingSend], _ candidates: [CodexEchoCandidate]) -> [ChatEntryID?] {
        CodexPendingEcho.match(pending: sends, candidates: candidates)
    }
}

/// Sent text and the key it compares on.
enum CodexEchoKeyCase: CaseIterable, CustomTestStringConvertible {
    case trailingSpace
    case lineEndings
    case tabsAndNewlines
    case csiSequence
    case unterminatedCSI
    case loneEscape
    case c0Controls
    case c1Controls
    case invisibleCharacters
    case surroundingWhitespace

    var testDescription: String {
        switch self {
        case .trailingSpace: "Heeler's trailing space"
        case .lineEndings: "CRLF and CR"
        case .tabsAndNewlines: "tabs and newlines kept"
        case .csiSequence: "CSI sequences"
        case .unterminatedCSI: "unterminated CSI"
        case .loneEscape: "lone ESC"
        case .c0Controls: "C0 controls and DEL"
        case .c1Controls: "C1 controls"
        case .invisibleCharacters: "invisible characters"
        case .surroundingWhitespace: "surrounding whitespace"
        }
    }

    var sent: String {
        switch self {
        case .trailingSpace: "hello "
        case .lineEndings: "a\r\nb\rc"
        case .tabsAndNewlines: "a\tb\nc"
        case .csiSequence: "red \u{1B}[31mtext\u{1B}[0m"
        case .unterminatedCSI: "cut \u{1B}[12"
        case .loneEscape: "a\u{1B}b"
        case .c0Controls: "bell\u{07}\u{00}\u{7F}!"
        case .c1Controls: "x\u{85}\u{9B}y"
        case .invisibleCharacters: "\u{FEFF}zero\u{200B}width\u{2060}"
        case .surroundingWhitespace: "\n\n  text  \n"
        }
    }

    var key: String {
        switch self {
        case .trailingSpace: "hello"
        case .lineEndings: "a\nb\nc"
        case .tabsAndNewlines: "a\tb\nc"
        case .csiSequence: "red text"
        case .unterminatedCSI: "cut"
        case .loneEscape: "ab"
        case .c0Controls: "bell!"
        case .c1Controls: "xy"
        case .invisibleCharacters: "zerowidth"
        case .surroundingWhitespace: "text"
        }
    }
}

/// Ways one image path can be sent (`normalize_pasted_path`).
enum CodexImageSendCase: CaseIterable, CustomTestStringConvertible {
    case plain
    case singleQuoted
    case escapedSpace
    case fileURL
    case quotedFileURL

    var testDescription: String {
        switch self {
        case .plain: "plain path"
        case .singleQuoted: "single-quoted path"
        case .escapedSpace: "backslash-escaped space"
        case .fileURL: "file URL"
        case .quotedFileURL: "quoted file URL"
        }
    }

    var sent: String {
        switch self {
        case .plain: "/Users/me/shot.png "
        case .singleQuoted: "'/Users/me/my shot.png'"
        case .escapedSpace: #"/Users/me/my\ shot.png"#
        case .fileURL: "file:///Users/me/url%20shot.png"
        case .quotedFileURL: "\"file:///Users/me/quoted.png\""
        }
    }

    var path: String {
        switch self {
        case .plain: "/Users/me/shot.png"
        case .singleQuoted, .escapedSpace: "/Users/me/my shot.png"
        case .fileURL: "/Users/me/url shot.png"
        case .quotedFileURL: "/Users/me/quoted.png"
        }
    }
}
