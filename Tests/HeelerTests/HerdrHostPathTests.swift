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
        #expect(HerdrHostPath.extraPATH.contains("$HOME/.cargo/bin"))
        #expect(HerdrHostPath.extraPATH.contains("$HOME/.bun/bin"))
        #expect(HerdrHostPath.extraPATH.contains("/usr/local/bin"))
        // Existing PATH entries keep priority over the extra prefixes.
        #expect(HerdrHostPath.pathExport.hasPrefix("export PATH=\"$PATH:"))
    }

    @Test func agentDiscoveryExportsExtraPATHBeforeProbing() {
        let command = SSHTransportSettings.defaultAgentDiscoveryCommand
        #expect(command.hasPrefix("/bin/sh -c '\(HerdrHostPath.pathExport); "))
    }

    @Test func bareHerdrIsOnlyTheCommandWord() {
        #expect(HerdrHostPath.isBareHerdrCommand("herdr agent attach"))
        #expect(HerdrHostPath.isBareHerdrCommand("herdr session list --json"))
        #expect(HerdrHostPath.isBareHerdrCommand("herdr plugin list --json"))
        #expect(HerdrHostPath.isBareHerdrCommand("  herdr remote-client-bridge"))
        #expect(HerdrHostPath.isBareHerdrCommand("HERDR_X=1 herdr session list --json"))
        #expect(HerdrHostPath.isBareHerdrCommand("FOO=bar BAZ=qux herdr plugin list --json"))
        #expect(HerdrHostPath.isBareHerdrCommand("herdr --config '/tmp/x y' session list"))
        #expect(!HerdrHostPath.isBareHerdrCommand("/opt/herdr-wake --foreground"))
        #expect(!HerdrHostPath.isBareHerdrCommand("/nonexistent/herdr plugin list --json"))
        #expect(!HerdrHostPath.isBareHerdrCommand("/bin/sh /tmp/fake-attach.sh"))
        // Assignment whose *value* is "herdr", then a different command word.
        #expect(!HerdrHostPath.isBareHerdrCommand("ENV=herdr /bin/sh -c 'true'"))
        #expect(!HerdrHostPath.isBareHerdrCommand("herdr=1 session list --json"))
        // Quoted literals must not count as the command word (#206 review).
        #expect(!HerdrHostPath.isBareHerdrCommand("printf '%s' 'herdr: not json'"))
        #expect(
            !HerdrHostPath.isBareHerdrCommand(
                SSHTransportSettings.defaultNotificationConfigDirCommand))
    }

    @Test func wrappingBareHerdrUsesPOSIXShAndLeavesInjectablesAlone() {
        let wrapped = HerdrHostPath.wrappingBareHerdr("herdr session list --json")
        #expect(wrapped.hasPrefix("/bin/sh -c '\(HerdrHostPath.pathExport); exec herdr "))
        #expect(wrapped.contains("exec herdr session list --json"))

        #expect(
            HerdrHostPath.wrappingBareHerdr("/opt/herdr-wake --foreground")
                == "/opt/herdr-wake --foreground")
        #expect(
            HerdrHostPath.wrappingBareHerdr("/nonexistent/herdr plugin list --json")
                == "/nonexistent/herdr plugin list --json")
        #expect(
            HerdrHostPath.wrappingBareHerdr("printf '%s' 'herdr: not json'")
                == "printf '%s' 'herdr: not json'")
    }

    @Test func wrappingKeepsAQuotedOverrideOnThePATHFix() {
        let wrapped = HerdrHostPath.wrappingBareHerdr(
            "herdr --config '/tmp/x y' session list --json")
        #expect(wrapped.hasPrefix("/bin/sh -c '\(HerdrHostPath.pathExport); exec herdr "))
        #expect(wrapped.contains(#"exec herdr --config '\''/tmp/x y'\'' session list --json"#))
    }

    @Test func wrappingKeepsLeadingEnvironmentAssignments() {
        let wrapped = HerdrHostPath.wrappingBareHerdr("HERDR_X=1 herdr session list --json")
        #expect(wrapped.contains("exec HERDR_X=1 herdr session list --json"))
        #expect(wrapped.contains(HerdrHostPath.pathExport))
    }

    @Test func wrappingUsesPOSIXShBecauseFishTreatsPATHAsAList() {
        // fish joins `"$PATH"` with spaces, not colons. The wrap therefore
        // never lets the account shell expand PATH: POSIX sh does it.
        let wrapped = HerdrHostPath.wrappingBareHerdr("herdr session list --json")
        #expect(wrapped.hasPrefix("/bin/sh -c '"))
        #expect(HerdrHostPath.pathExport.contains("\"$PATH:"))
        #expect(!wrapped.hasPrefix("PATH="))
        #expect(!wrapped.hasPrefix("export PATH="))
    }

    @Test func missingBinaryErrorIsOnlyBareHerdrExit127() {
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 127, command: "herdr session list --json")
                == .herdrBinaryNotFound)
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 127, command: "HERDR_X=1 herdr session list --json")
                == .herdrBinaryNotFound)
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 127, command: "/nonexistent/herdr plugin list --json")
                == nil)
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 1, command: "herdr session list --json")
                == nil)
    }

    @Test func notificationConfigDirDefaultExportsTheExtraPATH() {
        let command = SSHTransportSettings.defaultNotificationConfigDirCommand
        #expect(command.contains(HerdrHostPath.pathExport))
        #expect(command.contains("/home/linuxbrew/.linuxbrew/bin"))
        // Command substitution would swallow a 127; do not pretend to classify it.
        #expect(!HerdrHostPath.isBareHerdrCommand(command))
        #expect(HerdrHostPath.wrappingBareHerdr(command) == command)
    }

    @Test func attachExecExportsTheExtraPATHBeforeExec() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        #expect(command.contains(HerdrHostPath.pathExport))
        #expect(command.contains("/home/linuxbrew/.linuxbrew/bin"))
        #expect(command.contains("export PATH=\"$PATH:"))
        #expect(command.contains("exec herdr agent attach"))
    }

    @Test func attachExecKeepsAnInjectableAbsoluteCommand() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "/home/linuxbrew/.linuxbrew/bin/herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        #expect(
            command.contains("exec /home/linuxbrew/.linuxbrew/bin/herdr agent attach"))
        #expect(
            !HerdrHostPath.isBareHerdrCommand(
                "/home/linuxbrew/.linuxbrew/bin/herdr agent attach"))
    }
}
