import Foundation
import Testing

@testable import Heeler

/// What Grok Build's `config.toml` becomes. Expected files are written out in full,
/// so every byte around the setting is asserted to stay.
@Suite struct GrokBuildProgramStatusEditTests {
    private func changed(_ before: String) throws -> String {
        guard case .change(let after) = GrokBuildProgramStatusEdit.transform(Data(before.utf8)) else {
            Issue.record("expected a change to \(before)")
            return ""
        }
        return String(decoding: after, as: UTF8.self)
    }

    private func refuses(_ before: String) -> Bool {
        if case .refused = GrokBuildProgramStatusEdit.transform(Data(before.utf8)) { return true }
        return false
    }

    @Test func noFileBecomesTheSetting() {
        #expect(
            GrokBuildProgramStatusEdit.transform(nil)
                == .change(to: Data("[ui.notifications]\nprogram_status = \"on\"\n".utf8)))
    }

    @Test func anEmptyFileTakesTheSetting() throws {
        #expect(try changed("") == "[ui.notifications]\nprogram_status = \"on\"\n")
    }

    @Test func aFileWithoutTheTableGainsItAtItsEnd() throws {
        #expect(
            try changed("# mine\n[agent]\nname = \"a\"  # kept\n")
                == """
                # mine
                [agent]
                name = "a"  # kept

                [ui.notifications]
                program_status = "on"

                """)
    }

    @Test func aFileWithNoLastNewlineGainsOneFirst() throws {
        #expect(
            try changed("[agent]\nname = \"a\"")
                == "[agent]\nname = \"a\"\n\n[ui.notifications]\nprogram_status = \"on\"\n")
    }

    @Test func theTableTakesTheSettingFirst() throws {
        #expect(
            try changed("[ui.notifications]\nmethod = \"auto\"\n\n[ui.notifications.title]\nenabled = true\n")
                == "[ui.notifications]\nprogram_status = \"on\"\nmethod = \"auto\"\n\n[ui.notifications.title]\nenabled = true\n")
    }

    @Test func aHeaderWrittenAnotherWayIsTheSameTable() throws {
        #expect(
            try changed("[ ui . \"notifications\" ]  # mine\nmethod = \"auto\"\n")
                == "[ ui . \"notifications\" ]  # mine\nprogram_status = \"on\"\nmethod = \"auto\"\n")
    }

    @Test func aHeaderOnTheLastLineWithNoNewlineStillTakesIt() throws {
        #expect(
            try changed("[ui.notifications]")
                == "[ui.notifications]\nprogram_status = \"on\"\n")
    }

    @Test func aSubtableAloneLeavesItsParentToAdd() throws {
        #expect(
            try changed("[ui.notifications.title]\nenabled = true\n")
                == "[ui.notifications.title]\nenabled = true\n\n[ui.notifications]\nprogram_status = \"on\"\n")
    }

    @Test func aValueInPlaceChangesAndNothingElseDoes() throws {
        #expect(
            try changed("[ui.notifications]\nmethod = \"auto\"\nprogram_status = 'auto'   # was this\nprogress_bar = true\n")
                == "[ui.notifications]\nmethod = \"auto\"\nprogram_status = \"on\"   # was this\nprogress_bar = true\n")
        #expect(
            try changed("[ui.notifications]\nprogram_status = \"off\"")
                == "[ui.notifications]\nprogram_status = \"on\"")
    }

    @Test func aDottedKeyInPlaceChanges() throws {
        #expect(
            try changed("ui.notifications.program_status = \"auto\"\n")
                == "ui.notifications.program_status = \"on\"\n")
        #expect(
            try changed("[ui]\nnotifications.program_status = \"auto\"\n")
                == "[ui]\nnotifications.program_status = \"on\"\n")
    }

    @Test func alreadyOnWritesNothing() {
        for config in [
            "[ui.notifications]\nprogram_status = \"on\"\n",
            "[ui.notifications]\nprogram_status = 'on' # yes\n",
            "[ui.notifications.program_status]\nmode = \"on\"\n",
        ] {
            #expect(GrokBuildProgramStatusEdit.transform(Data(config.utf8)) == .alreadyApplied)
        }
    }

    /// `program_status = "on"` beside this table would be a duplicate key.
    @Test func theTableFormChangesItsMode() throws {
        #expect(
            try changed("[ui.notifications.program_status]\nmode = \"auto\" # m\nquery = false\n")
                == "[ui.notifications.program_status]\nmode = \"on\" # m\nquery = false\n")
        #expect(
            try changed("[ui.notifications.program_status]\nquery = false\n")
                == "[ui.notifications.program_status]\nmode = \"on\"\nquery = false\n")
        #expect(
            try changed("[ui.notifications]\nprogram_status.mode = \"auto\"\n")
                == "[ui.notifications]\nprogram_status.mode = \"on\"\n")
    }

    @Test func crlfStaysCRLF() throws {
        #expect(
            try changed("[ui.notifications]\r\nmethod = \"auto\"\r\n")
                == "[ui.notifications]\r\nprogram_status = \"on\"\r\nmethod = \"auto\"\r\n")
        #expect(
            try changed("[agent]\r\nname = \"a\"\r\n")
                == "[agent]\r\nname = \"a\"\r\n\r\n[ui.notifications]\r\nprogram_status = \"on\"\r\n")
    }

    /// None of these holds a header, whatever its lines look like.
    @Test func multiLineValuesHideWhatLooksLikeATable() throws {
        let tail = "\n\n[ui.notifications]\nprogram_status = \"on\"\n"
        for config in [
            "note = \"\"\"\n[ui.notifications]\nprogram_status = \"off\"\n\"\"\"",
            "note = '''\n[ui.notifications]\n'''",
            "note = \"\"\"ends with quotes\"\"\"\"\"",
            "list = [\n  \"[ui.notifications]\", # [ui.notifications]\n  [1, 2],\n]",
            "t = { a = \"]\", b = [1] } # }",
            "when = 1979-05-27 07:32:00 # [ui.notifications]",
            "# [ui.notifications]\n# program_status = \"off\"",
        ] {
            #expect(try changed(config) == config + tail)
        }
    }

    @Test func aFormItWillNotChangeIsRefused() {
        for config in [
            // The setting's value is no string.
            "[ui.notifications]\nprogram_status = { mode = \"auto\" }\n",
            "[ui.notifications]\nprogram_status = true\n",
            // A header here would redefine a table.
            "ui = { theme = \"dark\" }\n",
            "[ui]\nnotifications = { method = \"auto\" }\n",
            "ui.notifications.method = \"auto\"\n",
            "[ui]\nnotifications.method = \"auto\"\n",
            // Both forms at once, and tables an array of tables holds.
            "[ui.notifications]\nprogram_status = \"auto\"\n[ui.notifications.program_status]\nmode = \"on\"\n",
            "[ui.notifications]\nprogram_status.query = false\n",
            "[[ui.notifications]]\nmethod = \"auto\"\n",
            "[[ui]]\ntheme = \"dark\"\n",
            // Broken files.
            "[ui.notifications]\n[ui.notifications]\n",
            "[ui.notifications\n",
            "this is not toml\n",
            "note = \"\"\"never closed\n[ui.notifications]\n",
            "list = [1, 2\n",
            "a = 1 b = 2\n",
            "\"quoted\\nkey\" = 1\n",
        ] {
            #expect(refuses(config), "\(config)")
        }
    }

    @Test func aFileThatIsNotUTF8IsRefused() {
        guard case .refused = GrokBuildProgramStatusEdit.transform(Data([0x61, 0xFF, 0x0A])) else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func theConfigFileFollowsGrokHome() {
        #expect(
            GrokBuildProgramStatusEdit.configPath(grokHome: nil, home: "/home/dev")
                == "/home/dev/.grok/config.toml")
        #expect(
            GrokBuildProgramStatusEdit.configPath(grokHome: "", home: "/home/dev/")
                == "/home/dev/.grok/config.toml")
        #expect(
            GrokBuildProgramStatusEdit.configPath(grokHome: "/opt/grok/", home: "/home/dev")
                == "/opt/grok/config.toml")
        #expect(GrokBuildProgramStatusEdit.configPath(grokHome: "~/grok", home: "/home/dev") == nil)
    }
}
