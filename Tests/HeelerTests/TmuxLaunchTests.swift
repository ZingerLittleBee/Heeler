import Foundation
import Testing

@testable import Heeler

/// The tmux commands New Agent, New Workspace, New Terminal, Rename Workspace
/// and Close run (ADR 0042, ADR 0043). The script is the contract: a detached
/// window in the chosen session, a session that inherits the server or, on
/// Linux with none, starts through the login shell, and an Agent that replaces
/// the user's shell with ADR 0034's flags.
@Suite("tmux launches", .timeLimit(.minutes(1)))
struct TmuxLaunchTests {
    private static let paths: TmuxPaths = {
        guard let paths = TmuxPaths(executable: "/opt/homebrew/bin/tmux", socket: "/tmp/heeler-t693/sock") else {
            preconditionFailure("The launch tests' paths are quotable")
        }
        return paths
    }()

    private static let paneFormat = "#{pane_id} #{window_id}"
    private static let sessionFormat = "#{pane_id} #{window_id} #{session_id} #{session_name}"
    private static var uuid: Regex<Substring> {
        #/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/#
    }
    private static var openCodeID: Regex<Substring> {
        #/ses_[0-9a-f]{12}[0-9A-Za-z]{14}/#
    }

    private func server(
        shell: String = "/bin/zsh", kernel: String? = "Darwin", running: Bool = true,
        openCodeVersion: String? = nil
    ) -> TmuxLaunch.Server {
        TmuxLaunch.Server(
            paths: Self.paths, shell: shell, kernel: kernel, running: running,
            openCodeVersion: openCodeVersion)
    }

    private func text(_ command: TmuxLaunch.Command) -> String {
        String(decoding: command.script, as: UTF8.self)
    }

    /// The stored-path script: two assignments and the exec line, as `/bin/sh`
    /// must be given them. The exec line is the caller's literal.
    private func script(_ exec: String) -> String {
        """
        t='/opt/homebrew/bin/tmux'
        s='/tmp/heeler-t693/sock'
        \(exec)

        """
    }

    // MARK: New Agent

    @Test func anAgentOpensADetachedWindowAndReplacesTheShell() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "claude", name: "claude", arguments: ["--resume", "abc"],
                workspaceID: "$0", cwd: "/work"),
            on: server())

        let expected = script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -e 'CLAUDE_CODE_CHILD_SESSION=' -e 'CLAUDE_CODE_SKIP_PROMPT_HISTORY=' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' claude --resume abc"
        )
        #expect(text(command) == expected)
        #expect(!command.throughLoginShell)
    }

    @Test func aFreshAgentGetsOneSessionFlag() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$0", cwd: "/work"),
            on: server())

        let normalized = text(command).replacing(Self.uuid, with: "UUID")
        let expected = script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -e 'CLAUDE_CODE_CHILD_SESSION=' -e 'CLAUDE_CODE_SKIP_PROMPT_HISTORY=' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' claude --session-id UUID"
        )
        #expect(normalized == expected)
        #expect(text(command).matches(of: Self.uuid).count == 1)
    }

    @Test func codexStartsWithNoDaemonAndNoBlankedVariables() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: "codex", name: "codex", workspaceID: "$0", cwd: "/work"),
            on: server())
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' codex --no-daemon"
        ))
    }

    @Test func grokBlanksTheMultiplexerVariables() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: "grok", name: "grok", workspaceID: "$0", cwd: "/work"),
            on: server())
        let normalized = text(command).replacing(Self.uuid, with: "UUID")
        #expect(normalized == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -e 'STY=' -e 'TMUX=' -e 'ZELLIJ=' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' grok -s UUID"
        ))
    }

    @Test func openCodeNamesASessionOnlyFromRelease2_1() throws {
        let unnamed = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: "opencode", name: "opencode", workspaceID: "$0", cwd: "/work"),
            on: server())
        #expect(text(unnamed) == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' opencode"
        ))

        let named = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: "opencode", name: "opencode", workspaceID: "$0", cwd: "/work"),
            on: server(openCodeVersion: "opencode v2.2.2"))
        let normalized = text(named).replacing(Self.openCodeID, with: "SES")
        #expect(normalized == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' opencode -s SES"
        ))
        #expect(text(named).matches(of: Self.openCodeID).count == 1)

        let continued = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "opencode", name: "opencode", arguments: ["-s", "ses_existing"],
                workspaceID: "$0", cwd: "/work"),
            on: server(openCodeVersion: "opencode v2.2.2"))
        #expect(text(continued).contains("opencode -s ses_existing"))
        #expect(text(continued).matches(of: Self.openCodeID).isEmpty)
    }

    @Test func aLaunchPresetWinsOverABlankedVariable() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "claude", name: "claude", arguments: ["--resume", "abc"],
                workspaceID: "$0", cwd: "/work",
                environment: ["FOO": "bar baz", "CLAUDE_CODE_CHILD_SESSION": "keep"]),
            on: server())
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -e 'CLAUDE_CODE_CHILD_SESSION=keep' -e 'CLAUDE_CODE_SKIP_PROMPT_HISTORY=' -e 'FOO=bar baz' -P -F '\(Self.paneFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' claude --resume abc"
        ))
    }

    @Test func aFishShellReplacesItselfWithTheAgent() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "claude", name: "claude", arguments: ["--resume", "abc"],
                workspaceID: "$0", cwd: "/work"),
            on: server(shell: "/usr/local/bin/fish"))
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -e 'CLAUDE_CODE_CHILD_SESSION=' -e 'CLAUDE_CODE_SKIP_PROMPT_HISTORY=' -P -F '\(Self.paneFormat)' -- '/usr/local/bin/fish' -ic 'exec $argv[2..]' fish claude --resume abc"
        ))
    }

    @Test func aWindowNeedsASessionAndADirectory() {
        #expect(throws: TmuxLaunch.Refusal.missingTarget) {
            try TmuxLaunch.agentWindow(
                AgentLaunchRequest(kind: "claude", name: "claude", cwd: "/work"), on: server())
        }
        #expect(throws: TmuxLaunch.Refusal.missingTarget) {
            try TmuxLaunch.agentWindow(
                AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$0"), on: server())
        }
    }

    // MARK: New Terminal and New Workspace

    @Test func aShellWindowRunsNoProgram() throws {
        let command = try TmuxLaunch.shellWindow(
            ShellTerminalCreationRequest(workspaceID: "$0", cwd: "/work"), on: server())
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" new-window -d -t '$0' -c '/work' -P -F '\(Self.paneFormat)'"
        ))
        #expect(!command.throughLoginShell)
    }

    @Test func aDirectoryWithAQuoteStaysOneArgument() throws {
        let command = try TmuxLaunch.shellWindow(
            ShellTerminalCreationRequest(workspaceID: "$0", cwd: "/work/o'brien"), on: server())
        #expect(text(command).contains("-c '/work/o'\\''brien'"))
    }

    @Test func aNewSessionOnARunningServerInheritsTheServerEnvironment() throws {
        let command = try TmuxLaunch.shellSession(
            NewWorkspaceSpec(directory: "/work", label: "work"), on: server())
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" new-session -d -E -s work -c '/work' -P -F '\(Self.sessionFormat)'"
        ))
        #expect(!command.throughLoginShell)
    }

    @Test func anEmptyWorkspaceNameLetsTmuxNumberTheSession() throws {
        let command = try TmuxLaunch.shellSession(
            NewWorkspaceSpec(directory: "/work", label: ""), on: server())
        #expect(!text(command).contains(" -s "))
        #expect(text(command).contains("new-session -d -E -c '/work'"))
    }

    @Test func anAgentInANewWorkspaceOnARunningServerUsesNewSession() throws {
        let command = try TmuxLaunch.agentSession(
            AgentLaunchRequest(
                kind: "claude", name: "claude", arguments: ["--resume", "abc"], cwd: "/ignored"),
            workspace: NewWorkspaceSpec(directory: "/work", label: "work"),
            on: server())
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" new-session -d -E -s work -c '/work' -e 'CLAUDE_CODE_CHILD_SESSION=' -e 'CLAUDE_CODE_SKIP_PROMPT_HISTORY=' -P -F '\(Self.sessionFormat)' -- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' claude --resume abc"
        ))
    }

    @Test func linuxStartsAServerThroughTheLoginShell() throws {
        let command = try TmuxLaunch.shellSession(
            NewWorkspaceSpec(directory: "/work"), on: server(kernel: "Linux", running: false))
        #expect(command.throughLoginShell)
        #expect(text(command) == #"""
        __heeler_tmux_start='t='\''/opt/homebrew/bin/tmux'\''
        s='\''/tmp/heeler-t693/sock'\''
        exec "$t" -S "$s" new-session -d -c '\''/work'\'' -P -F '\''#{pane_id} #{window_id} #{session_id} #{session_name}'\'''
        export __heeler_tmux_start
        "$SHELL" -lic 'exec /bin/sh -c "$__heeler_tmux_start"'

        """#)
    }

    @Test func linuxStartsAnAgentWithTheServer() throws {
        let command = try TmuxLaunch.agentSession(
            AgentLaunchRequest(
                kind: "claude", name: "claude", arguments: ["--resume", "abc"], cwd: "/ignored"),
            workspace: NewWorkspaceSpec(directory: "/work", label: "work"),
            on: server(kernel: "Linux", running: false))
        #expect(command.throughLoginShell)
        #expect(text(command) == #"""
        __heeler_tmux_start='t='\''/opt/homebrew/bin/tmux'\''
        s='\''/tmp/heeler-t693/sock'\''
        exec "$t" -S "$s" new-session -d -s work -c '\''/work'\'' -e '\''CLAUDE_CODE_CHILD_SESSION='\'' -e '\''CLAUDE_CODE_SKIP_PROMPT_HISTORY='\'' -P -F '\''#{pane_id} #{window_id} #{session_id} #{session_name}'\'' -- '\''/bin/zsh'\'' -ic '\''exec "$@"'\'' '\''/bin/zsh'\'' claude --resume abc'
        export __heeler_tmux_start
        "$SHELL" -lic 'exec /bin/sh -c "$__heeler_tmux_start"'

        """#)
    }

    @Test func macOSWithNoServerDoesNotStartOne() {
        #expect(throws: TmuxLaunch.Refusal.startTmuxOnMac) {
            try TmuxLaunch.shellSession(
                NewWorkspaceSpec(directory: "/work", label: "work"),
                on: server(kernel: "Darwin", running: false))
        }
        #expect(throws: TmuxLaunch.Refusal.startTmuxOnMac) {
            try TmuxLaunch.agentSession(
                AgentLaunchRequest(kind: "claude", name: "claude"),
                workspace: NewWorkspaceSpec(directory: "/work"),
                on: server(kernel: "Darwin", running: false))
        }
    }

    @Test func aNewWindowWithNoServerDoesNotStartOne() {
        #expect(throws: TmuxLaunch.Refusal.serverNotRunning) {
            try TmuxLaunch.agentWindow(
                AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$0", cwd: "/work"),
                on: server(kernel: "Linux", running: false))
        }
        #expect(throws: TmuxLaunch.Refusal.serverNotRunning) {
            try TmuxLaunch.shellWindow(
                ShellTerminalCreationRequest(workspaceID: "$0", cwd: "/work"),
                on: server(kernel: "Darwin", running: false))
        }
    }

    @Test func anUnknownKernelDoesNotStartAServer() {
        for kernel in [String?(nil), "FreeBSD"] {
            #expect(throws: TmuxLaunch.Refusal.serverNotRunning) {
                try TmuxLaunch.shellSession(
                    NewWorkspaceSpec(directory: "/work"), on: server(kernel: kernel, running: false))
            }
        }
    }

    // MARK: Rename and close

    @Test func renameAndCloseNameTheirTargets() {
        let renamed = TmuxLaunch.renameSession(id: "$0", label: "My Work", paths: Self.paths)
        #expect(text(renamed) == script("exec \"$t\" -N -S \"$s\" rename-session -t '$0' 'My Work'"))
        let pane = TmuxLaunch.killPane("%7", paths: Self.paths)
        #expect(text(pane) == script("exec \"$t\" -N -S \"$s\" kill-pane -t '%7'"))
        let window = TmuxLaunch.killWindow("@4", paths: Self.paths)
        #expect(text(window) == script("exec \"$t\" -N -S \"$s\" kill-window -t @4"))
    }

    // MARK: What tmux prints

    @Test func createdReadsThePrintedIds() {
        #expect(
            TmuxLaunch.created(from: Data("noise\n%3 @2\n".utf8))
                == TmuxLaunch.Created(paneID: "%3", windowID: "@2", sessionID: nil, sessionName: nil))
        #expect(
            TmuxLaunch.created(from: Data("%3 @2 $1 My Work\n".utf8))
                == TmuxLaunch.Created(paneID: "%3", windowID: "@2", sessionID: "$1", sessionName: "My Work"))
        #expect(TmuxLaunch.created(from: Data("not a pane\n".utf8)) == nil)
    }
}
