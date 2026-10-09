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
        // mise shims resolve the data dir the way mise does, default last (#293).
        #expect(
            HerdrHostPath.extraPATH.contains(
                "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"))
        // User prefixes take priority over existing PATH entries so updated
        // binaries take precedence over stale system installations.
        #expect(HerdrHostPath.pathExport.hasPrefix("export PATH=\"$HOME/.local/bin:"))
        #expect(HerdrHostPath.pathExport.hasSuffix(":$PATH\""))
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
        #expect(HerdrHostPath.pathExport.contains(":$PATH\""))
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

    /// Today's full strings for a Host without a herdr endpoint, so the
    /// endpoint branch cannot drift them (ADR 0021).
    @Test func defaultHerdrCommandsKeepTheirFullStrings() {
        #expect(
            HerdrHostPath.wrappingBareHerdr(SSHTransportSettings.defaultSessionListCommand)
                == "/bin/sh -c '\(HerdrHostPath.pathExport); exec herdr session list --json'")
        #expect(
            HerdrHostPath.wrappingBareHerdr(SSHTransportSettings.defaultPluginListCommand)
                == "/bin/sh -c '\(HerdrHostPath.pathExport); exec herdr plugin list --json'")
        #expect(
            SSHTransportSettings.defaultNotificationConfigDirCommand
                == #"/bin/sh -c '\#(HerdrHostPath.pathExport); "#
                + #"printf "__HEELER_PLUGIN_CONFIG_DIR__=%s\n" "#
                + #""$(herdr plugin config-dir __HEELER_PLUGIN_ID__)"'"#)
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
        #expect(command.contains("export PATH=\"$HOME/.local/bin:"))
        #expect(command.contains(":$PATH\""))
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

/// The launcher of a Pairing Code v2 herdr endpoint (ADR 0021). Paths carry
/// spaces, as a macOS app's Application Support directory does.
@Suite("Herdr endpoint launcher")
struct HerdrLauncherTests {
    private static let launcherPath = "/Users/ada/Library/Application Support/Example/bin/herdr"
    private static let socketPath =
        "/Users/ada/Library/Application Support/Example/herdr/herdr.sock"
    private static let quotedArguments =
        "'/Users/ada/Library/Application Support/Example/bin/herdr' "
        + "'/Users/ada/Library/Application Support/Example/herdr/herdr.sock'"

    private func makeLauncher() throws -> HerdrLauncher {
        try #require(
            HerdrLauncher(executablePath: Self.launcherPath, socketPath: Self.socketPath))
    }

    private func makeSettings(for host: Host) -> SSHTransportSettings {
        SSHTransportSettings(
            host: host,
            credentials: .password("unused"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false })
    }

    @Test func keepsBothPathsAsGiven() throws {
        let launcher = try makeLauncher()
        #expect(launcher.executablePath == Self.launcherPath)
        #expect(launcher.socketPath == Self.socketPath)
    }

    @Test func refusesPathsThatAreNotOneAbsoluteShellWord() {
        let invalid: [(executablePath: String, socketPath: String)] = [
            ("bin/herdr", Self.socketPath),
            (Self.launcherPath, "herdr/herdr.sock"),
            ("", Self.socketPath),
            ("/opt/it's/herdr", Self.socketPath),
            (#"/opt/back\slash/herdr"#, Self.socketPath),
            ("/opt/new\nline/herdr", Self.socketPath),
            (Self.launcherPath, "/tmp/it's/herdr/herdr.sock"),
            (Self.launcherPath, "/tmp/tab\t/herdr/herdr.sock"),
        ]
        for paths in invalid {
            #expect(
                HerdrLauncher(executablePath: paths.executablePath, socketPath: paths.socketPath)
                    == nil,
                "\(paths)")
        }
    }

    @Test func sessionListRunsTheLauncherAgainstTheEndpointSocket() throws {
        let launcher = try makeLauncher()
        #expect(
            launcher.sessionListCommand
                == #"/bin/sh -c 'export HERDR_SOCKET_PATH="$2"; exec "$1" session list --json' "#
                + "herdr \(Self.quotedArguments)")
    }

    @Test func pluginListRunsTheLauncherAgainstTheEndpointSocket() throws {
        let launcher = try makeLauncher()
        #expect(
            launcher.pluginListCommand
                == #"/bin/sh -c 'export HERDR_SOCKET_PATH="$2"; exec "$1" plugin list --json' "#
                + "herdr \(Self.quotedArguments)")
    }

    @Test func pluginConfigDirRunsTheLauncherInsideTheMarkerPrintf() throws {
        let command = try makeLauncher().notificationConfigDirCommand
        #expect(
            command
                == #"/bin/sh -c 'export HERDR_SOCKET_PATH="$2"; "#
                + #"printf "__HEELER_PLUGIN_CONFIG_DIR__=%s\n" "#
                + #""$("$1" plugin config-dir __HEELER_PLUGIN_ID__)"' "#
                + "herdr \(Self.quotedArguments)")
        // The probe swaps the token for the matched plugin id, as it does for
        // the default command.
        #expect(command.contains(SSHTransportSettings.notificationPluginIDToken))
    }

    /// No PATH export and no PATH fallback: the launcher is the only herdr,
    /// and the exec sites must not wrap it as a bare `herdr`.
    @Test func launcherCommandsNeverReachForPATH() throws {
        let launcher = try makeLauncher()
        for command in [
            launcher.sessionListCommand,
            launcher.pluginListCommand,
            launcher.notificationConfigDirCommand,
        ] {
            #expect(!command.contains("export PATH="))
            #expect(!command.contains(HerdrHostPath.extraPATH))
            #expect(!HerdrHostPath.isBareHerdrCommand(command))
            #expect(HerdrHostPath.wrappingBareHerdr(command) == command)
        }
    }

    @Test func launcherExit126Or127IsAMissingLauncherWhateverTheCommandWord() throws {
        let launcher = try makeLauncher()
        for exitStatus: Int32 in [126, 127] {
            #expect(
                HerdrHostPath.missingBinaryError(
                    exitStatus: exitStatus, command: launcher.sessionListCommand,
                    launcher: launcher)
                    == .herdrLauncherNotFound(path: Self.launcherPath))
            #expect(
                HerdrHostPath.missingBinaryError(
                    exitStatus: exitStatus, command: "herdr session list --json",
                    launcher: launcher)
                    == .herdrLauncherNotFound(path: Self.launcherPath))
        }
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 1, command: launcher.sessionListCommand, launcher: launcher)
                == nil)
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 0, command: launcher.sessionListCommand, launcher: launcher)
                == nil)
    }

    @Test func withoutALauncherOnlyBareHerdrExit127IsAMissingBinary() throws {
        let launcherCommand = try makeLauncher().sessionListCommand
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 127, command: launcherCommand, launcher: nil)
                == nil)
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 126, command: "herdr session list --json", launcher: nil)
                == nil)
        #expect(
            HerdrHostPath.missingBinaryError(
                exitStatus: 127, command: "herdr session list --json", launcher: nil)
                == .herdrBinaryNotFound)
    }

    @Test func endpointHostSettingsRunTheLauncher() throws {
        let endpoint = try #require(
            HerdrEndpoint(socketPath: Self.socketPath, executablePath: Self.launcherPath))
        // The endpoint wins over a leftover session name.
        let host = Host(
            address: "mac.example", username: "ada", sessionName: "work",
            herdrEndpoint: endpoint)
        let launcher = try makeLauncher()

        let settings = makeSettings(for: host)

        #expect(settings.socket == .absolutePath(Self.socketPath))
        #expect(settings.herdrLauncher == launcher)
        #expect(settings.sessionListCommand == launcher.sessionListCommand)
        #expect(settings.pluginListCommand == launcher.pluginListCommand)
        #expect(settings.notificationConfigDirCommand == launcher.notificationConfigDirCommand)
    }

    @Test func hostWithoutAnEndpointKeepsEveryDefaultCommand() {
        let settings = makeSettings(
            for: Host(address: "box.example", username: "dev", sessionName: "work"))

        #expect(settings.socket == .namedSession("work"))
        #expect(settings.herdrLauncher == nil)
        #expect(settings.wakeCommand == SSHTransportSettings.defaultWakeCommand)
        #expect(settings.sessionListCommand == SSHTransportSettings.defaultSessionListCommand)
        #expect(
            settings.agentDiscoveryCommand == SSHTransportSettings.defaultAgentDiscoveryCommand)
        #expect(settings.attachCommand == SSHTransportSettings.defaultAttachCommand)
        #expect(
            settings.terminalAttachCommand == SSHTransportSettings.defaultTerminalAttachCommand)
        #expect(settings.homeCommand == SSHTransportSettings.defaultHomeCommand)
        #expect(
            settings.stageDirectoryCommand == SSHTransportSettings.defaultStageDirectoryCommand)
        #expect(settings.pluginListCommand == SSHTransportSettings.defaultPluginListCommand)
        #expect(
            settings.notificationConfigDirCommand
                == SSHTransportSettings.defaultNotificationConfigDirCommand)
    }
}
