import Testing

@testable import Heeler

/// The expected text is what Claude Code 2.1.319's input box showed for
/// the paste, with each `[Image #N]` back as its path: most shapes were
/// pasted live (2026-11-10), the rest follow its paste handler.
@Suite("Claude image paste")
struct ClaudeImagePasteTests {
    @Test func aPathAloneOnItsLineRunsIntoTheTextBelowIt() {
        #expect(ClaudeImagePaste.recordedText("/tmp/a.png \nwhat changed here ") == "/tmp/a.pngwhat changed here")
        #expect(ClaudeImagePaste.recordedText("/tmp/a.png\nwhat changed here") == "/tmp/a.pngwhat changed here")
    }

    @Test func aPathWithWordsAfterItOnItsLineStaysText() {
        #expect(ClaudeImagePaste.recordedText("/tmp/a.png what changed here ") == nil)
        #expect(ClaudeImagePaste.recordedText("see /tmp/a.png\nhere") == nil)
        #expect(ClaudeImagePaste.recordedText("no image\nat all") == nil)
    }

    @Test func imagesGoBeforeTheTextJoinedBySpaces() {
        #expect(ClaudeImagePaste.recordedText("intro line\n/tmp/a.png\nafter line") == "/tmp/a.pngintro line\nafter line")
        #expect(ClaudeImagePaste.recordedText("hello line\n/tmp/a.png ") == "/tmp/a.pnghello line")
        #expect(ClaudeImagePaste.recordedText("/tmp/a.png \n/tmp/b.jpg \nhello") == "/tmp/a.png /tmp/b.jpghello")
        #expect(ClaudeImagePaste.recordedText("/tmp/a.png /tmp/b.jpg\nhello") == "/tmp/a.png /tmp/b.jpghello")
    }

    @Test func blankLinesGoAndOtherLinesKeepTheirIndent() {
        #expect(
            ClaudeImagePaste.recordedText("/tmp/a.png\n\nhello line\n\n  indented line ")
                == "/tmp/a.pnghello line\n  indented line")
    }

    @Test func anotherPathOnAnImageLineBecomesALineOfText() {
        #expect(ClaudeImagePaste.recordedText("/tmp/a.png /tmp/notes.txt\nhello") == "/tmp/a.png/tmp/notes.txt\nhello")
    }

    @Test func aQuotedOrEscapedPathIsRecordedAsTheFileItNames() {
        #expect(ClaudeImagePaste.recordedText("'/tmp/a shot.png'\nhello") == "/tmp/a shot.pnghello")
        #expect(ClaudeImagePaste.recordedText(#"/tmp/a\ shot.PNG"# + "\nhello") == "/tmp/a shot.PNGhello")
    }
}
