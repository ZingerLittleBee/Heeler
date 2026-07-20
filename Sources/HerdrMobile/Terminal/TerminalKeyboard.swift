import Foundation
import SwiftTerm

enum TerminalKeyboardMode: Hashable, Sendable {
    case inputMethod
    case terminal
}

enum TerminalKeyboardPage: Int, CaseIterable, Hashable, Sendable {
    case typing
    case navigation
}

enum TerminalModifier: CaseIterable, Hashable, Sendable {
    case control
    case shift
    case alt
}

enum TerminalModifierPhase: Equatable, Sendable {
    case inactive
    case armed
    case locked
}

struct TerminalKeyboardState: Equatable, Sendable {
    private(set) var mode: TerminalKeyboardMode = .inputMethod
    private(set) var page: TerminalKeyboardPage = .typing
    private(set) var armedModifiers: Set<TerminalModifier> = []
    private(set) var lockedModifiers: Set<TerminalModifier> = []

    var activeModifiers: Set<TerminalModifier> {
        armedModifiers.union(lockedModifiers)
    }

    func phase(of modifier: TerminalModifier) -> TerminalModifierPhase {
        if lockedModifiers.contains(modifier) { return .locked }
        if armedModifiers.contains(modifier) { return .armed }
        return .inactive
    }

    mutating func selectMode(_ mode: TerminalKeyboardMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        clearModifiers()
    }

    mutating func selectPage(_ page: TerminalKeyboardPage) {
        self.page = page
    }

    mutating func toggle(_ modifier: TerminalModifier, locks: Bool = false) {
        switch phase(of: modifier) {
        case .inactive:
            if modifier == .shift, locks {
                lockedModifiers.insert(modifier)
            } else {
                armedModifiers.insert(modifier)
            }
        case .armed:
            armedModifiers.remove(modifier)
            if modifier == .shift, locks {
                lockedModifiers.insert(modifier)
            }
        case .locked:
            lockedModifiers.remove(modifier)
        }
    }

    mutating func consumeOneShotModifiers() {
        armedModifiers.removeAll()
    }

    mutating func clearModifiers() {
        armedModifiers.removeAll()
        lockedModifiers.removeAll()
    }
}

enum TerminalFunctionKey: Int, CaseIterable, Hashable, Sendable {
    case f1 = 1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
}

enum TerminalKey: Hashable, Sendable {
    case character(base: Character, shifted: Character)
    case escape
    case tab
    case backspace
    case enter
    case insert
    case delete
    case home
    case end
    case pageUp
    case pageDown
    case up
    case down
    case left
    case right
    case function(TerminalFunctionKey)

    var isRepeatable: Bool {
        switch self {
        case .backspace, .delete, .up, .down, .left, .right:
            true
        default:
            false
        }
    }

    var id: String {
        switch self {
        case .character(let base, _): "character-\(base)"
        case .escape: "escape"
        case .tab: "tab"
        case .backspace: "backspace"
        case .enter: "enter"
        case .insert: "insert"
        case .delete: "delete"
        case .home: "home"
        case .end: "end"
        case .pageUp: "page-up"
        case .pageDown: "page-down"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .function(let function): "f\(function.rawValue)"
        }
    }

    var width: Double {
        switch self {
        case .backspace:
            1.35
        case .enter:
            1.65
        case .character(let base, _) where base == " ":
            2.7
        default:
            1
        }
    }
}

extension TerminalKeyboardPage {
    var rows: [[TerminalKey]] {
        switch self {
        case .typing:
            [
                [
                    .character(base: "`", shifted: "~"),
                    .character(base: "-", shifted: "_"),
                    .character(base: "=", shifted: "+"),
                    .character(base: "[", shifted: "{"),
                    .character(base: "]", shifted: "}"),
                    .character(base: "\\", shifted: "|"),
                    .character(base: ";", shifted: ":"),
                    .character(base: "'", shifted: "\""),
                    .character(base: ",", shifted: "<"),
                    .character(base: ".", shifted: ">"),
                    .character(base: "/", shifted: "?"),
                ],
                "1234567890".map { key(for: $0) },
                "qwertyuiop".map { key(for: $0) },
                "asdfghjkl".map { key(for: $0) } + [.backspace],
                "zxcvbnm".map { key(for: $0) }
                    + [.character(base: " ", shifted: " "), .enter],
            ]
        case .navigation:
            [
                TerminalFunctionKey.allCases.prefix(6).map(TerminalKey.function),
                TerminalFunctionKey.allCases.suffix(6).map(TerminalKey.function),
                [.insert, .home, .pageUp],
                [.delete, .end, .pageDown],
                [.left, .down, .up, .right],
            ]
        }
    }

    private func key(for character: Character) -> TerminalKey {
        let shiftedCharacters: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        ]
        if let shifted = shiftedCharacters[character] {
            return .character(base: character, shifted: shifted)
        }
        return .character(
            base: character,
            shifted: Character(String(character).uppercased()))
    }
}

struct TerminalKeyEncodingContext {
    var kittyFlags: KittyKeyboardFlags = []
    var applicationCursor = false
    var backspaceSendsControlH = false
}

enum TerminalKeyEncoder {
    static func encode(
        _ key: TerminalKey,
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> Data {
        Data(bytes(for: key, modifiers: modifiers, context: context))
    }

    private static func bytes(
        for key: TerminalKey,
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> [UInt8] {
        if case .character(let base, let shifted) = key {
            return textBytes(
                base: base, shifted: shifted, modifiers: modifiers, context: context)
        }

        let disambiguates = context.kittyFlags.contains(.disambiguate)
            || context.kittyFlags.contains(.reportAllKeys)
        let modifierValue = kittyModifierValue(modifiers)

        switch key {
        case .escape:
            if disambiguates {
                return csiU(codepoint: 27, modifiers: modifierValue)
            }
            return legacy(bytes: EscapeSequences.cmdEsc, modifiers: modifiers)
        case .enter:
            return characterLikeSpecialKey(
                codepoint: 13,
                legacy: EscapeSequences.cmdRet,
                modifiers: modifiers,
                context: context)
        case .tab:
            let legacyBytes = modifiers.contains(.shift)
                ? EscapeSequences.cmdBackTab : EscapeSequences.cmdTab
            return characterLikeSpecialKey(
                codepoint: 9,
                legacy: legacyBytes,
                modifiers: modifiers,
                context: context)
        case .backspace:
            let byte: UInt8 = modifiers.contains(.control) || context.backspaceSendsControlH
                ? 0x08 : 0x7F
            return characterLikeSpecialKey(
                codepoint: 127,
                legacy: [byte],
                modifiers: modifiers,
                context: context)
        case .up:
            return cursorBytes(
                letter: "A", appBytes: EscapeSequences.moveUpApp,
                normalBytes: EscapeSequences.moveUpNormal,
                modifiers: modifiers, context: context)
        case .down:
            return cursorBytes(
                letter: "B", appBytes: EscapeSequences.moveDownApp,
                normalBytes: EscapeSequences.moveDownNormal,
                modifiers: modifiers, context: context)
        case .right:
            return cursorBytes(
                letter: "C", appBytes: EscapeSequences.moveRightApp,
                normalBytes: EscapeSequences.moveRightNormal,
                modifiers: modifiers, context: context)
        case .left:
            return cursorBytes(
                letter: "D", appBytes: EscapeSequences.moveLeftApp,
                normalBytes: EscapeSequences.moveLeftNormal,
                modifiers: modifiers, context: context)
        case .home:
            return cursorBytes(
                letter: "H", appBytes: EscapeSequences.moveHomeApp,
                normalBytes: EscapeSequences.moveHomeNormal,
                modifiers: modifiers, context: context)
        case .end:
            return cursorBytes(
                letter: "F", appBytes: EscapeSequences.moveEndApp,
                normalBytes: EscapeSequences.moveEndNormal,
                modifiers: modifiers, context: context)
        case .insert:
            return tildeBytes(
                number: 2, legacyBytes: EscapeSequences.cmdInsert,
                modifiers: modifiers, context: context)
        case .delete:
            return tildeBytes(
                number: 3, legacyBytes: EscapeSequences.cmdDelKey,
                modifiers: modifiers, context: context)
        case .pageUp:
            return tildeBytes(
                number: 5, legacyBytes: EscapeSequences.cmdPageUp,
                modifiers: modifiers, context: context)
        case .pageDown:
            return tildeBytes(
                number: 6, legacyBytes: EscapeSequences.cmdPageDown,
                modifiers: modifiers, context: context)
        case .function(let function):
            return functionBytes(function, modifiers: modifiers, context: context)
        case .character:
            return []
        }
    }

    private static func textBytes(
        base: Character,
        shifted: Character,
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> [UInt8] {
        let output = modifiers.contains(.shift) ? shifted : base
        guard let baseScalar = String(base).unicodeScalars.first,
              let outputScalar = String(output).unicodeScalars.first else {
            return Array(String(output).utf8)
        }

        let reportsAll = context.kittyFlags.contains(.reportAllKeys)
        let disambiguates = context.kittyFlags.contains(.disambiguate) || reportsAll
        let reportsAlternates = context.kittyFlags.contains(.reportAlternates)
        let hasControlOrAlt = modifiers.contains(.control) || modifiers.contains(.alt)

        if disambiguates
            && (reportsAll || hasControlOrAlt
                || (reportsAlternates && modifiers.contains(.shift)))
        {
            let shiftedScalar = modifiers.contains(.shift) ? outputScalar : nil
            return csiU(
                codepoint: Int(baseScalar.value),
                shiftedCodepoint: shiftedScalar.map { Int($0.value) },
                modifiers: kittyModifierValue(modifiers))
        }

        var bytes: [UInt8] = modifiers.contains(.alt) ? EscapeSequences.cmdEsc : []
        if modifiers.contains(.control), let control = controlByte(for: outputScalar) {
            bytes.append(control)
        } else {
            bytes.append(contentsOf: String(output).utf8)
        }
        return bytes
    }

    private static func characterLikeSpecialKey(
        codepoint: Int,
        legacy: [UInt8],
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> [UInt8] {
        let reportsAll = context.kittyFlags.contains(.reportAllKeys)
        let disambiguates = context.kittyFlags.contains(.disambiguate) || reportsAll
        if reportsAll || (disambiguates && !modifiers.isEmpty) {
            return csiU(codepoint: codepoint, modifiers: kittyModifierValue(modifiers))
        }
        return self.legacy(bytes: legacy, modifiers: modifiers)
    }

    private static func cursorBytes(
        letter: Character,
        appBytes: [UInt8],
        normalBytes: [UInt8],
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> [UInt8] {
        let disambiguates = context.kittyFlags.contains(.disambiguate)
            || context.kittyFlags.contains(.reportAllKeys)
        if disambiguates || !modifiers.isEmpty {
            return csi(number: 1, modifiers: kittyModifierValue(modifiers), terminator: letter)
        }
        return context.applicationCursor ? appBytes : normalBytes
    }

    private static func tildeBytes(
        number: Int,
        legacyBytes: [UInt8],
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> [UInt8] {
        let disambiguates = context.kittyFlags.contains(.disambiguate)
            || context.kittyFlags.contains(.reportAllKeys)
        if disambiguates || !modifiers.isEmpty {
            return csi(number: number, modifiers: kittyModifierValue(modifiers), terminator: "~")
        }
        return legacyBytes
    }

    private static func functionBytes(
        _ function: TerminalFunctionKey,
        modifiers: Set<TerminalModifier>,
        context: TerminalKeyEncodingContext
    ) -> [UInt8] {
        let disambiguates = context.kittyFlags.contains(.disambiguate)
            || context.kittyFlags.contains(.reportAllKeys)
        let modifierValue = kittyModifierValue(modifiers)
        switch function {
        case .f1, .f2, .f3, .f4:
            let letters: [Character] = ["P", "Q", "R", "S"]
            if disambiguates || !modifiers.isEmpty {
                return csi(
                    number: 1, modifiers: modifierValue,
                    terminator: letters[function.rawValue - 1])
            }
            return EscapeSequences.cmdF[function.rawValue - 1]
        case .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            let numbers = [15, 17, 18, 19, 20, 21, 23, 24]
            if disambiguates || !modifiers.isEmpty {
                return csi(
                    number: numbers[function.rawValue - 5],
                    modifiers: modifierValue, terminator: "~")
            }
            return EscapeSequences.cmdF[function.rawValue - 1]
        }
    }

    private static func legacy(
        bytes: [UInt8], modifiers: Set<TerminalModifier>
    ) -> [UInt8] {
        modifiers.contains(.alt) ? EscapeSequences.cmdEsc + bytes : bytes
    }

    private static func kittyModifierValue(_ modifiers: Set<TerminalModifier>) -> Int {
        var value = 0
        if modifiers.contains(.shift) { value |= 1 }
        if modifiers.contains(.alt) { value |= 2 }
        if modifiers.contains(.control) { value |= 4 }
        return value
    }

    private static func csiU(
        codepoint: Int,
        shiftedCodepoint: Int? = nil,
        modifiers: Int
    ) -> [UInt8] {
        var payload = "\(codepoint)"
        if let shiftedCodepoint {
            payload += ":\(shiftedCodepoint)"
        }
        if modifiers != 0 {
            payload += ";\(modifiers + 1)"
        }
        return Array("\u{1B}[\(payload)u".utf8)
    }

    private static func csi(
        number: Int,
        modifiers: Int,
        terminator: Character
    ) -> [UInt8] {
        let modifierField = modifiers == 0 ? "" : ";\(modifiers + 1)"
        return Array("\u{1B}[\(number)\(modifierField)\(terminator)".utf8)
    }

    private static func controlByte(for scalar: UnicodeScalar) -> UInt8? {
        let lower = Character(String(scalar).lowercased())
        if let ascii = lower.asciiValue, ascii >= 0x61, ascii <= 0x7A {
            return ascii - 0x60
        }
        let mapping: [UnicodeScalar: UInt8] = [
            " ": 0, "@": 0, "[": 27, "\\": 28, "]": 29,
            "^": 30, "_": 31, "?": 127,
        ]
        return mapping[scalar]
    }
}
