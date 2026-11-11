import Foundation
import Testing

@testable import Heeler

/// The 2026-11-10 input measurements on tmux 3.3a and 3.7b (ADR 0043's
/// Evidence), from `plugin/test-vectors/tmux-input-v1.json`: what Heeler sends
/// for each key and text, and what the Pane's program read for it, per
/// version, `extended-keys` setting and program keyboard mode.
struct TmuxInputVectorTests {
    private let vector: TmuxInputVectorFile

    init() throws {
        vector = try TmuxInputVectorFile.load()
    }

    private static func expected(_ key: TmuxInputVectorFile.Key) -> TmuxInput? {
        if let text = key.text { return .text(text) }
        guard let name = key.key else { return nil }
        return .key(TmuxKey(name: name, isExtended: key.extended ?? false))
    }

    /// The same key in kitty's CSI u form, for one in xterm's
    /// modifyOtherKeys form.
    private static func csiU(_ desktop: Data) -> Data? {
        let text = String(decoding: desktop, as: UTF8.self)
        guard text.hasPrefix("\u{1B}[27;"), text.hasSuffix("~") else { return nil }
        let fields = text.dropFirst(5).dropLast().split(separator: ";")
        guard fields.count == 2 else { return nil }
        return Data("\u{1B}[\(fields[1]);\(fields[0])u".utf8)
    }

    @Test func theVectorHoldsBothVersionsAndEveryKeyMode() {
        #expect(vector.keys.count == 71)
        #expect(Set(vector.runs.map(\.version)) == ["3.3a", "3.7b"])
        #expect(Set(vector.runs.map(\.paneKeyMode)) == ["", "VT10x", "Ext 1", "Ext 2"])
        #expect(vector.runs.filter { $0.version == "3.3a" }.allSatisfy { $0.paneKeyMode.isEmpty })
        for run in vector.runs {
            #expect(Set(run.read.keys) == Set(vector.keys.map(\.name)), "\(run.version) \(run.extendedKeys)")
            #expect(!run.sources.isEmpty)
        }
    }

    /// A desktop terminal's bytes for a key, legacy or modifyOtherKeys, and
    /// their CSI u form read as the name Heeler sends.
    @Test func eachKeyReadsAsHeelersName() throws {
        for key in vector.keys {
            let expected = try #require(Self.expected(key), "\(key.name)")
            let desktop = TmuxInputVectorFile.bytes(key.desktop)
            #expect(TmuxKeyReader.read(desktop) == [expected], "\(key.name)")
            if let csiU = Self.csiU(desktop) {
                #expect(TmuxKeyReader.read(csiU) == [expected], "\(key.name) as CSI u")
            }
            for alternate in key.alternates ?? [] {
                #expect(TmuxKeyReader.read(TmuxInputVectorFile.bytes(alternate)) == [expected], "\(key.name) as \(alternate)")
            }
        }
    }

    /// Where Heeler sends a key, the program reads what a desktop terminal's
    /// key gives it: `C-BTab` and `C-S-A` where `C-S-Tab` and `C-S-a` would
    /// differ, and a key with no legacy encoding only in an extended mode.
    @Test func whatHeelerSendsReachesTheProgramAsTheDesktopsKeyDoes() throws {
        for run in vector.runs {
            let label = "\(run.version) \(run.extendedKeys) \(run.extendedKeysFormat ?? "-") \(run.program)"
            for key in vector.keys {
                guard case .key(let tmuxKey) = try #require(Self.expected(key)) else {
                    #expect(run.heelerRead[key.name] == nil, "\(key.name) in \(label)")
                    continue
                }
                if tmuxKey.isSent(whilePaneKeyModeReads: run.paneKeyMode) {
                    #expect(
                        run.heelerRead[key.name] == nil,
                        "\(tmuxKey.name) in \(label) read \(run.heelerRead[key.name] ?? "") for \(run.read[key.name] ?? "")")
                }
            }
        }
    }

    /// tmux typed some keys into the Pane as their names, where the desktop
    /// sent nothing: each is one Heeler drops outside an extended mode.
    @Test func aKeyTmuxTypedAsItsNameHasNoLegacyEncoding() throws {
        var typed: Set<String> = []
        for run in vector.runs {
            for key in vector.keys {
                guard let name = key.key, let read = run.heelerRead[key.name] else { continue }
                guard TmuxInputVectorFile.bytes(read) == Data(name.utf8) else { continue }
                typed.insert(name)
                #expect(key.extended == true, "\(name) in \(run.version) \(run.extendedKeys) \(run.program)")
                #expect(!TmuxKey(name: name, isExtended: true).isSent(whilePaneKeyModeReads: run.paneKeyMode))
            }
        }
        #expect(typed == ["S-Enter", "S-Space", "C-S-A", "C-S-V", "C-BSpace"])
    }

    /// A desktop terminal sends Ctrl with `@`, `[` and `?` as NUL, ESC and
    /// DEL, which tmux reads as C-Space, Escape and Backspace. tmux's own
    /// names for them encode as Ctrl with the character in an extended mode,
    /// so Heeler sends the control character's key in every form.
    @Test func ctrlWithAControlCharacterGoesAsThatCharactersKey() throws {
        var differs: Set<String> = []
        for run in vector.runs {
            for (name, read) in run.otherNameRead where read != run.read[name] {
                differs.insert(name)
                #expect(["Ext 1", "Ext 2"].contains(run.paneKeyMode), "\(name) in \(run.version) \(run.program)")
            }
        }
        #expect(differs == ["C-@", "C-[", "C-?"])
        let names = Dictionary(uniqueKeysWithValues: vector.keys.map { ($0.name, $0.key) })
        #expect(names["C-@"] == "C-Space" && names["C-["] == "Escape" && names["C-?"] == "BSpace")
        #expect(names[#"C-\"#] == #"C-\"# && names["C-]"] == "C-]" && names["C-^"] == "C-^")
    }

    @Test func extendedKeysGoOnlyInAnExtendedMode() {
        let extended = TmuxKey(name: "S-Enter", isExtended: true)
        #expect(extended.isSent(whilePaneKeyModeReads: "Ext 1"))
        #expect(extended.isSent(whilePaneKeyModeReads: "Ext 2\n"))
        #expect(!extended.isSent(whilePaneKeyModeReads: "VT10x"))
        #expect(!extended.isSent(whilePaneKeyModeReads: ""))
        #expect(TmuxKey(name: "Enter", isExtended: false).isSent(whilePaneKeyModeReads: ""))
    }

    /// Heeler's quoting is the one the measurements sent.
    @Test func textIsQuotedAsMeasured() {
        for text in vector.texts + vector.pasteTexts {
            #expect(TmuxArgument.quoted(text.text) == text.argument, "\(text.name)")
        }
    }

    /// Text without a control character arrived exactly on both versions;
    /// a line feed did not on 3.7b, so Heeler sends one as a key.
    @Test func textWithoutAControlCharacterArrivesExactly() throws {
        for arrival in vector.literal {
            let text = try #require(vector.texts.first { $0.name == arrival.name }).text
            let hasControl = text.unicodeScalars.contains { $0.value < 0x20 }
            if !hasControl {
                #expect(arrival.exact, "\(arrival.name) on \(arrival.version) \(arrival.extendedKeys)")
            } else {
                let read = TmuxKeyReader.read(Data(text.utf8))
                #expect(read.contains { if case .key = $0 { true } else { false } }, "\(arrival.name)")
            }
        }
        #expect(vector.literal.contains { $0.name == "x LF y" && $0.version == "3.7b" && !$0.exact })
    }

    /// `paste-buffer -p -r` pastes a buffer exactly, line feeds included,
    /// bracketed or not; `-p` alone turns line feeds into carriage returns.
    @Test func aPasteFromABufferArrivesExactly() {
        for paste in vector.pastes where paste.flags == "-p -r" {
            #expect(paste.exact, "\(paste.name) on \(paste.version), bracketed \(paste.bracketedPaste)")
        }
        #expect(vector.pastes.contains { $0.flags == "-p" && !$0.exact })
    }

    /// A one-shot command's argv word arrives as Heeler meant it: tmux took an
    /// unescaped trailing `;` as the end of the command.
    @Test func aOneShotArgumentArrivesAsTheText() throws {
        for version in ["3.3a", "3.7b"] {
            let cases = vector.oneShot.filter { $0.version == version }
            for text in ["abc ;", #"abc \;"#, "a;b", #""q" $HOME ~ #{pane_id} {x}"#] {
                let argument = TmuxArgument.oneShot(text)
                let arrival = try #require(cases.first { $0.argument == argument }, "\(text) on \(version)")
                #expect(arrival.received == text, "\(text) on \(version)")
            }
            #expect(cases.contains { $0.argument == "abc ;" && $0.received == "abc " })
        }
    }
}
