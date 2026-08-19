import Testing

@testable import Heeler

@Suite("Terminal title glyphs")
struct TerminalTitleGlyphsTests {
    @Test(arguments: [
        ("◑ lockscreen-agent-live-activity", "lockscreen-agent-live-activity"),
        ("⠋ tail the build logs", "tail the build logs"),
        ("✳ Thinking about the diff", "Thinking about the diff"),
        ("● ◑ doubled glyphs", "doubled glyphs"),
        ("  leading whitespace", "leading whitespace"),
        ("refactor transport queue", "refactor transport queue"),
        ("锁屏显示 agent 状态", "锁屏显示 agent 状态"),
        ("◑", ""),
    ])
    func stripsLeadingStatusGlyphs(_ input: String, _ expected: String) {
        #expect(TerminalTitleGlyphs.strip(input) == expected)
    }

    @Test func keepsGlyphsAfterRealText() {
        #expect(TerminalTitleGlyphs.strip("build ◑ done") == "build ◑ done")
    }
}
