import Foundation
import Testing

@testable import Heeler

/// Names from tmux `show-environment -s` after the Host strips values
/// (ADR 0045). Each line crossing SSH is `NAME` or `-NAME` for a session
/// removal; any line carrying `=` or a non-POSIX name is ignored.
@Suite("tmux environment names", .timeLimit(.minutes(1)))
struct TmuxEnvironmentTests {
    @Test func showEnvironmentReadsFilteredNamesAndRejectsUnfilteredAssignments() {
        let stdout = Data(
            """
            CLAUDECODE
            CLAUDE_CONFIG_DIR
            PATH
            -HEELER_REMOVED
            not a variable
            =has-no-name
            LEAKED_WITH_EQUALS=secret-value
            %hidden
            HERDR_SESSION
            CODEX_HOME
            1BAD
            -not a name

            """.utf8)

        let scope = TmuxEnvironment.parse(stdout)

        #expect(scope.assigned == ["CLAUDECODE", "CLAUDE_CONFIG_DIR", "PATH", "HERDR_SESSION", "CODEX_HOME"])
        #expect(scope.removed == ["HEELER_REMOVED"])
        let kept = scope.assigned.union(scope.removed).sorted().joined(separator: "\n")
        #expect(!kept.contains("secret"))
        #expect(!kept.contains("LEAKED_WITH_EQUALS"))
    }

    @Test func aSessionInheritsGlobalNamesExceptOnesItRemoved() {
        let global = TmuxEnvironment.parse(
            Data(
                """
                CLAUDECODE
                CLAUDE_CONFIG_DIR
                PATH
                TMUX
                """.utf8))
        let session = TmuxEnvironment.parse(
            Data(
                """
                CODEX_HOME
                -CLAUDE_CONFIG_DIR
                TMUX
                """.utf8))

        #expect(
            TmuxEnvironment.inherited(global: global, session: session)
                == ["CLAUDECODE", "PATH", "CODEX_HOME", "TMUX"])
    }

    @Test func leakedNamesAreTheCoreCheckAndTheHerdrPrefix() {
        let names: Set<String> = [
            "CLAUDECODE", "TMUX", "HERDR_SESSION", "PATH", "CODEX_THREAD_ID", "HOME",
        ]
        #expect(TmuxEnvironment.leaked(in: names) == ["CLAUDECODE", "TMUX", "HERDR_SESSION", "CODEX_THREAD_ID"])
    }

    @Test func aHostNoticeKeepsAGlobalLeakAndASessionsOwn() {
        let global = TmuxEnvironment.parse(
            Data(
                """
                CLAUDECODE
                CLAUDE_CONFIG_DIR
                XDG_CONFIG_HOME
                PATH
                """.utf8))
        let removed = TmuxEnvironment.parse(
            Data(
                """
                CODEX_THREAD_ID
                CODEX_HOME
                -CLAUDE_CONFIG_DIR
                -CLAUDECODE
                """.utf8))
        let plain = TmuxEnvironment.Scope(assigned: [], removed: [])

        let reading = TmuxEnvironment.reading(global: global, sessions: ["$0": removed, "$2": plain])

        #expect(reading == ["CLAUDECODE", "CODEX_THREAD_ID"])
    }

    @Test func showEnvironmentOverScriptedHostSendsFilteredCommandAndReceivesNoValues() async throws {
        let paths = ScriptedTmuxHost.paths()
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(session: 0, sessionName: "main", pane: 1)])
        await tmux.setGlobalEnvironment([
            "CLAUDECODE=secret-global-token",
            "ANTHROPIC_API_KEY=sk-ant-secret=value",
            "EMPTY_VAR=",
            "MULTI_VAR=line1=secret-line\nHERDR_FAKE=planted\n-TMUX",
            "-DASH=secret-dash",
            "A;B=secret-semi",
            "BASH_FUNC_mod%%=() {\nCLAUDECODE=planted\n}",
        ])
        await tmux.setSessionEnvironment(
            [
                "CODEX_THREAD_ID=secret-session-thread",
                "-CLAUDECODE",
                "-A;B",
            ],
            session: "$0")

        let transport = await tmux.transport(socketName: "default", storedPaths: paths)
        defer { Task { try? await transport.close() } }

        let globalCommand = TmuxLaunch.showEnvironment(paths: paths)
        let globalResult = try await transport.runTmuxScript(
            globalCommand.script, throughLoginShell: globalCommand.throughLoginShell)
        #expect(globalResult.exitStatus == 0)
        let globalText = String(decoding: globalResult.stdout, as: UTF8.self)
        #expect(!globalText.contains("secret"))
        #expect(!globalText.contains("sk-ant"))
        #expect(!globalText.contains("planted"))
        #expect(!globalText.contains("="))
        #expect(
            TmuxEnvironment.parse(globalResult.stdout)
                == TmuxEnvironment.Scope(
                    assigned: ["ANTHROPIC_API_KEY", "CLAUDECODE", "EMPTY_VAR", "MULTI_VAR"],
                    removed: []))

        let sessionCommand = TmuxLaunch.showEnvironment(session: "$0", paths: paths)
        let sessionResult = try await transport.runTmuxScript(
            sessionCommand.script, throughLoginShell: sessionCommand.throughLoginShell)
        #expect(sessionResult.exitStatus == 0)
        let sessionText = String(decoding: sessionResult.stdout, as: UTF8.self)
        #expect(!sessionText.contains("secret"))
        #expect(!sessionText.contains("="))
        #expect(
            TmuxEnvironment.parse(sessionResult.stdout)
                == TmuxEnvironment.Scope(assigned: ["CODEX_THREAD_ID"], removed: ["CLAUDECODE"]))

        let commands = await tmux.commands
        #expect(commands.count == 2)
        #expect(commands[0].contains("t='\(paths.executable)'"))
        #expect(commands[0].contains("s='\(paths.socket)'"))
        #expect(commands[0].contains("e=$(\"$t\" -N -S \"$s\" -u show-environment -g -s) || exit \"$?\""))
        #expect(commands[0].contains("LC_ALL=C awk "))
        #expect(commands[1].contains("e=$(\"$t\" -N -S \"$s\" -u show-environment -t '$0' -s) || exit \"$?\""))
        #expect(commands[1].contains("LC_ALL=C awk "))

        let missingSession = TmuxLaunch.showEnvironment(session: "$99", paths: paths)
        let missingResult = try await transport.runTmuxScript(
            missingSession.script, throughLoginShell: missingSession.throughLoginShell)
        #expect(missingResult.exitStatus != 0)
        #expect(missingResult.stdout.isEmpty)

        await tmux.stopServer()
        let noServerResult = try await transport.runTmuxScript(
            globalCommand.script, throughLoginShell: globalCommand.throughLoginShell)
        #expect(noServerResult.exitStatus != 0)
        #expect(noServerResult.stdout.isEmpty)
    }
}
