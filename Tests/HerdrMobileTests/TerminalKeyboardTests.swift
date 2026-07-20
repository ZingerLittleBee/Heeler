import Foundation
import SwiftTerm
import Testing

@testable import HerdrMobile

@Suite("Terminal keyboard")
struct TerminalKeyboardTests {
    @Test func defaultsToInputMethodAndTypingPage() {
        let state = TerminalKeyboardState()

        #expect(state.mode == .inputMethod)
        #expect(state.page == .typing)
        #expect(state.activeModifiers.isEmpty)
    }

    @Test func oneShotModifiersCombineAndAreConsumedTogether() {
        var state = TerminalKeyboardState()
        state.toggle(.control)
        state.toggle(.shift)

        #expect(state.activeModifiers == [.control, .shift])
        #expect(state.phase(of: .control) == .armed)
        #expect(state.phase(of: .shift) == .armed)

        state.consumeOneShotModifiers()

        #expect(state.activeModifiers.isEmpty)
    }

    @Test func shiftCanLockWhileOtherModifiersRemainOneShot() {
        var state = TerminalKeyboardState()
        state.toggle(.shift)
        state.toggle(.shift, locks: true)
        state.toggle(.alt)

        #expect(state.phase(of: .shift) == .locked)
        #expect(state.phase(of: .alt) == .armed)

        state.consumeOneShotModifiers()

        #expect(state.activeModifiers == [.shift])
        state.toggle(.shift)
        #expect(state.activeModifiers.isEmpty)
    }

    @Test func switchingModesClearsModifiersButKeepsThePage() {
        var state = TerminalKeyboardState()
        state.selectPage(.navigation)
        state.toggle(.control)
        state.selectMode(.terminal)

        #expect(state.mode == .terminal)
        #expect(state.page == .navigation)
        #expect(state.activeModifiers.isEmpty)
    }

    @MainActor
    @Test func closingRemembersTheAttachModeAndPageButClearsModifiers() {
        let session = TerminalKeyboardSession()
        session.selectMode(.terminal)
        session.selectPage(.navigation)
        session.tapModifier(.control)

        session.close()

        #expect(session.state.mode == .terminal)
        #expect(session.state.page == .navigation)
        #expect(session.state.activeModifiers.isEmpty)
    }

    @Test func typingLayoutContainsEveryDecidedPrintableKey() {
        let keys = TerminalKeyboardPage.typing.rows.flatMap { $0 }
        let baseCharacters = Set(
            keys.compactMap { key -> Character? in
                guard case .character(let base, _) = key else { return nil }
                return base
            })

        #expect(baseCharacters.isSuperset(of: Set("abcdefghijklmnopqrstuvwxyz")))
        #expect(baseCharacters.isSuperset(of: Set("1234567890")))
        #expect(baseCharacters.isSuperset(of: Set("`-=[]\\;',./ ")))
        #expect(keys.contains(.backspace))
        #expect(keys.contains(.enter))
    }

    @Test func navigationLayoutContainsFunctionsAndNavigationKeys() {
        let keys = Set(TerminalKeyboardPage.navigation.rows.flatMap { $0 })

        for function in TerminalFunctionKey.allCases {
            #expect(keys.contains(.function(function)))
        }
        for key in [
            TerminalKey.insert, .delete, .home, .end, .pageUp, .pageDown,
            .up, .down, .left, .right,
        ] {
            #expect(keys.contains(key))
        }
    }

    @Test func plainAndShiftedTextUseUtf8WithoutEnhancements() {
        let key = TerminalKey.character(base: "a", shifted: "A")

        #expect(text(encode(key)) == "a")
        #expect(text(encode(key, modifiers: [.shift])) == "A")
        #expect(
            text(encode(.character(base: "1", shifted: "!"), modifiers: [.shift]))
                == "!")
    }

    @Test func legacyControlAndAltTextUseControlBytesAndEscapePrefix() {
        let key = TerminalKey.character(base: "c", shifted: "C")

        #expect(Array(encode(key, modifiers: [.control])) == [0x03])
        #expect(Array(encode(key, modifiers: [.alt])) == [0x1B, 0x63])
        #expect(Array(encode(key, modifiers: [.control, .alt])) == [0x1B, 0x03])
    }

    @Test func legacyControlUsesTheShiftedSymbolForAsciiControlCodes() {
        #expect(
            Array(encode(
                .character(base: "2", shifted: "@"),
                modifiers: [.control, .shift]))
                == [0x00])
        #expect(
            Array(encode(
                .character(base: "6", shifted: "^"),
                modifiers: [.control, .shift]))
                == [0x1E])
        #expect(
            Array(encode(
                .character(base: "-", shifted: "_"),
                modifiers: [.control, .shift]))
                == [0x1F])
    }

    @Test func kittyTextReportsShiftedAndModifiedKeysWithoutAmbiguity() {
        let context = TerminalKeyEncodingContext(
            kittyFlags: [.disambiguate, .reportEvents, .reportAlternates])

        #expect(
            text(encode(
                .character(base: "a", shifted: "A"), modifiers: [.shift], context: context))
                == "\u{1B}[97:65;2u")
        #expect(
            text(encode(
                .character(base: "p", shifted: "P"),
                modifiers: [.control, .shift], context: context))
                == "\u{1B}[112:80;6u")
        #expect(
            text(encode(
                .character(base: "x", shifted: "X"), modifiers: [.alt], context: context))
                == "\u{1B}[120;3u")
    }

    @Test func cursorKeysRespectApplicationModeAndKittyModifiers() {
        #expect(text(encode(.up)) == "\u{1B}[A")
        #expect(
            text(encode(
                .up, context: TerminalKeyEncodingContext(applicationCursor: true)))
                == "\u{1B}OA")

        let context = TerminalKeyEncodingContext(kittyFlags: [.disambiguate])
        #expect(text(encode(.left, modifiers: [.control], context: context)) == "\u{1B}[1;5D")
    }

    @Test func characterLikeSpecialKeysUseKittyOnlyWhenNeeded() {
        let context = TerminalKeyEncodingContext(kittyFlags: [.disambiguate])

        #expect(Array(encode(.enter, context: context)) == [0x0D])
        #expect(text(encode(.enter, modifiers: [.shift], context: context)) == "\u{1B}[13;2u")
        #expect(text(encode(.tab, modifiers: [.shift], context: context)) == "\u{1B}[9;2u")
        #expect(text(encode(.escape, context: context)) == "\u{1B}[27u")
    }

    @Test func functionsAndEditingKeysUseXtermModifierParameters() {
        let context = TerminalKeyEncodingContext(kittyFlags: [.disambiguate])

        #expect(text(encode(.function(.f1))) == "\u{1B}OP")
        #expect(
            text(encode(.function(.f1), modifiers: [.control], context: context))
                == "\u{1B}[1;5P")
        #expect(
            text(encode(.function(.f12), modifiers: [.alt], context: context))
                == "\u{1B}[24;3~")
        #expect(text(encode(.delete, modifiers: [.shift], context: context)) == "\u{1B}[3;2~")
    }

    private func encode(
        _ key: TerminalKey,
        modifiers: Set<TerminalModifier> = [],
        context: TerminalKeyEncodingContext = TerminalKeyEncodingContext()
    ) -> Data {
        TerminalKeyEncoder.encode(key, modifiers: modifiers, context: context)
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
