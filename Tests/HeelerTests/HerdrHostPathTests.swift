import Foundation
import Testing

@testable import Heeler

@Suite("Herdr host PATH")
struct HerdrHostPathTests {
    @Test func extraPATHIncludesHomebrewAndLinuxbrewPrefixes() {
        #expect(HerdrHostPath.extraPATH.contains("$HOME/.local/bin"))
        #expect(HerdrHostPath.extraPATH.contains("/opt/homebrew/bin"))
        #expect(HerdrHostPath.extraPATH.contains("/home/linuxbrew/.linuxbrew/bin"))
        #expect(HerdrHostPath.extraPATH.contains("$HOME/.linuxbrew/bin"))
    }

    @Test func discoveryIgnoresLoginShellNoiseAroundItsMarker() {
        let noise = Data(
            """
            Last login: Tue Aug 18
            __HEELER_HERDR_BIN__=/home/linuxbrew/.linuxbrew/bin/herdr
            motd leftover
            """.utf8)
        #expect(HerdrHostPath.path(from: noise) == "/home/linuxbrew/.linuxbrew/bin/herdr")
    }

    @Test func discoveryRejectsARelativeOrUnquotableMarker() {
        #expect(HerdrHostPath.path(from: Data("__HEELER_HERDR_BIN__=herdr\n".utf8)) == nil)
        #expect(
            HerdrHostPath.path(
                from: Data("__HEELER_HERDR_BIN__=/tmp/it's-herdr\n".utf8)) == nil)
    }

    @Test func bareHerdrIsTheUnpathedCommandWord() {
        #expect(HerdrHostPath.containsBareHerdr("herdr agent attach"))
        #expect(HerdrHostPath.containsBareHerdr("herdr session list --json"))
        #expect(
            HerdrHostPath.containsBareHerdr(
                "/bin/sh -c 'printf \"%s\" \"$(herdr plugin config-dir x)\"'"))
        #expect(!HerdrHostPath.containsBareHerdr("/opt/herdr-wake --foreground"))
        #expect(!HerdrHostPath.containsBareHerdr("/nonexistent/herdr plugin list --json"))
        #expect(!HerdrHostPath.containsBareHerdr("/bin/sh /tmp/fake-attach.sh"))
    }

    @Test func substitutingRewritesOnlyTheBareCommandWord() throws {
        let linuxbrew = "/home/linuxbrew/.linuxbrew/bin/herdr"
        #expect(
            HerdrHostPath.substituting("herdr agent attach", herdrPath: linuxbrew)
                == "\(linuxbrew) agent attach")
        #expect(
            HerdrHostPath.substituting(
                "herdr plugin list --json", herdrPath: linuxbrew)
                == "\(linuxbrew) plugin list --json")
        #expect(
            HerdrHostPath.substituting(
                "herdr agent attach", herdrPath: "/home/u/My herdr/bin/herdr") == nil)

        let configDir = "/bin/sh -c 'printf \"%s\" \"$(herdr plugin config-dir x)\"'"
        #expect(
            HerdrHostPath.substituting(configDir, herdrPath: linuxbrew)
                == "/bin/sh -c 'printf \"%s\" \"$(\(linuxbrew) plugin config-dir x)\"'")
        // The replacement itself ends in `herdr`; that must not match again.
        #expect(
            HerdrHostPath.substituting(
                "\(linuxbrew) agent attach", herdrPath: "/opt/homebrew/bin/herdr")
                == "\(linuxbrew) agent attach")
    }

    @Test func prefixedWrapsAQuoteFreeCommand() {
        let wrapped = HerdrHostPath.prefixed("herdr session list --json")
        #expect(wrapped.contains(HerdrHostPath.pathExport))
        #expect(wrapped.contains("herdr session list --json"))
        #expect(HerdrHostPath.prefixed("printf 'no wrap'") == "printf 'no wrap'")
    }

    @Test func attachExecExportsTheExtraPATHBeforeExec() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        #expect(command.contains(HerdrHostPath.pathExport))
        #expect(command.contains("/home/linuxbrew/.linuxbrew/bin"))
        #expect(command.contains("exec herdr agent attach"))
    }

    @Test func attachExecKeepsAResolvedAbsoluteBinary() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "/home/linuxbrew/.linuxbrew/bin/herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        #expect(
            command.contains("exec /home/linuxbrew/.linuxbrew/bin/herdr agent attach"))
    }
}
