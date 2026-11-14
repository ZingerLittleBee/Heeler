import Foundation
import Testing

@testable import Heeler

/// Arguments as Heeler writes them to tmux (ADR 0045): in tmux's double-quoted
/// form on a line tmux parses, and as they are, a trailing `;` escaped, in a
/// one-shot command's argv.
@Suite("tmux argument")
struct TmuxArgumentTests {
    @Test func tmuxSyntaxIsEscaped() {
        #expect(
            TmuxArgument.quoted(#"it's "a" $HOME ~/x #{pane_id} ; {a} back\slash"#)
                == ##""it's \"a\" \$HOME \~/x \#\{pane_id\} \; \{a\} back\\slash""##)
    }

    @Test func controlCharactersAreWrittenAsEscapes() {
        #expect(TmuxArgument.quoted("a\nb\rc\td") == #""a\nb\rc\td""#)
        #expect(TmuxArgument.quoted("\u{1B}[1m\u{7F}\u{0}\u{1F}") == #""\033[1m\177\000\037""#)
    }

    @Test func otherTextIsWrittenAsItIs() {
        #expect(TmuxArgument.quoted("中文 café 👍🏽 👨‍👩‍👧 %1 @2 =x: 'q'") == "\"中文 café 👍🏽 👨‍👩‍👧 %1 @2 =x: 'q'\"")
        #expect(TmuxArgument.quoted("") == #""""#)
        #expect(TmuxArgument.quoted(#"ends with \"#) == #""ends with \\""#)
    }

    @Test func aQuotedArgumentNeverHoldsALineBreak() {
        let quoted = TmuxArgument.quoted("a\nb\r\u{85}\u{2028}c")
        #expect(!quoted.unicodeScalars.contains { $0 == "\n" || $0 == "\r" })
    }

    /// What tmux's parser reads back is the text, whatever it holds.
    @Test func tmuxReadsTheTextBack() {
        let texts = [
            "plain", "", " ", "-l", #"it's "q" $HOME ~ ~user #{pane_id} ; \; {a} }{ %1 back\slash"#,
            "中文 café é 👍🏽 👨‍👩‍👧", "a\tb\nc\r\u{1B}\u{7F}\u{0}", #"ends with \"#, "#", "~", "$", "abc ;",
        ]
        for text in texts {
            #expect(ScriptedTmuxHost.words(of: "x " + TmuxArgument.quoted(text)) == ["x", text], "\(text)")
        }
    }

    /// tmux takes an argv word that ends in `;` as the end of a command, and
    /// one that ends in `\;` as ending in `;`.
    @Test func aOneShotArgumentEscapesOnlyATrailingSemicolon() {
        #expect(TmuxArgument.oneShot("abc ;") == #"abc \;"#)
        #expect(TmuxArgument.oneShot(";") == #"\;"#)
        #expect(TmuxArgument.oneShot(#"abc \;"#) == #"abc \\;"#)
        #expect(TmuxArgument.oneShot("a;b") == "a;b")
        #expect(TmuxArgument.oneShot(#""q" $HOME ~ #{x} {y}"#) == #""q" $HOME ~ #{x} {y}"#)
        #expect(TmuxArgument.oneShot("") == "")
    }
}
