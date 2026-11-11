import Foundation
import Testing

@testable import Heeler

/// Names from tmux `show-environment` (ADR 0043). A listing is `NAME=value`
/// or `-NAME` for a session removal. The value never leaves the parse.
@Suite("tmux environment names", .timeLimit(.minutes(1)))
struct TmuxEnvironmentTests {
    @Test func showEnvironmentKeepsNamesAndDropsValues() {
        let stdout = Data(
            """
            CLAUDECODE=secret-child-token
            CLAUDE_CONFIG_DIR=
            PATH=/usr/bin
            -HEELER_REMOVED
            not a variable
            =has-no-name
            %hidden=secret-hidden
            HERDR_SESSION=also-secret
            CODEX_HOME=/Users/someone/.codex=extra
            1BAD=no
            -not a name

            """.utf8)

        let scope = TmuxEnvironment.parse(stdout)

        #expect(scope.assigned == ["CLAUDECODE", "CLAUDE_CONFIG_DIR", "PATH", "HERDR_SESSION", "CODEX_HOME"])
        #expect(scope.removed == ["HEELER_REMOVED"])
        let kept = scope.assigned.union(scope.removed).sorted().joined(separator: "\n")
        #expect(!kept.contains("secret"))
        #expect(!kept.contains("/usr/bin"))
        #expect(!kept.contains("/Users"))
    }

    @Test func aSessionInheritsGlobalNamesExceptOnesItRemoved() {
        let global = TmuxEnvironment.parse(
            Data(
                """
                CLAUDECODE=secret-child
                CLAUDE_CONFIG_DIR=/secret/claude
                PATH=/usr/bin
                TMUX=/tmp/secret.sock
                """.utf8))
        let session = TmuxEnvironment.parse(
            Data(
                """
                CODEX_HOME=/secret/codex
                -CLAUDE_CONFIG_DIR
                TMUX=/tmp/secret-session.sock
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

    /// A multi-line value is more than one line. A continuation that looks
    /// like `NAME=` or `-NAME` counts as that name.
    @Test func aContinuationLineThatLooksLikeANameCountsAsThatName() {
        let stdout = Data(
            """
            HTTPS_PROXY=http://example.test/a
            CLAUDECODE=not-a-real-assignment
            -TMUX
            """.utf8)

        let scope = TmuxEnvironment.parse(stdout)

        #expect(scope.assigned == ["HTTPS_PROXY", "CLAUDECODE"])
        #expect(scope.removed == ["TMUX"])
    }

    @Test func aHostNoticeKeepsAGlobalLeakAndASessionsOwn() {
        let global = TmuxEnvironment.parse(
            Data(
                """
                CLAUDECODE=secret-child
                CLAUDE_CONFIG_DIR=/secret/claude
                XDG_CONFIG_HOME=/secret/xdg
                PATH=/usr/bin
                """.utf8))
        let removed = TmuxEnvironment.parse(
            Data(
                """
                CODEX_THREAD_ID=secret-thread
                CODEX_HOME=/secret/codex
                -CLAUDE_CONFIG_DIR
                -CLAUDECODE
                """.utf8))
        let plain = TmuxEnvironment.Scope(assigned: [], removed: [])

        let reading = TmuxEnvironment.reading(global: global, sessions: ["$0": removed, "$2": plain])

        #expect(reading == ["CLAUDECODE", "CODEX_THREAD_ID"])
    }
}
