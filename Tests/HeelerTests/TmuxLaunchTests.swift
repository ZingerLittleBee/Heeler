import Foundation
import Testing

@testable import Heeler

/// The tmux commands New Agent, New Workspace, New Terminal, Rename Workspace
/// and Close run (ADR 0044, ADR 0045). The script is the contract: a detached
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

    /// Characters a shell would split, expand, or substitute, plus non-ASCII.
    /// Each one has to survive `/bin/sh` as the same bytes.
    private static let userText = [
        "a b",
        "it's",
        "say \"hi\"",
        "$HOME",
        "`date`",
        "line\nbreak",
        "日本語",
        "😀",
    ]

    private static let paneFormat = "#{pane_id} #{window_id}"
    private static let sessionFormat = "#{pane_id} #{window_id} #{session_id} #{q:session_name} ."
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

    // MARK: Heeler's Claude Code hooks (ADR 0046)

    private static let hookSettings = "/Users/dev/Library/Application Support/heeler/claude-code/hooks.json"

    /// The program after `--`, as tmux parses the exec line's words.
    private func program(_ command: TmuxLaunch.Command) throws -> [String] {
        let line = try #require(text(command).split(separator: "\n").first { $0.hasPrefix("exec ") })
        let words = ScriptedTmuxHost.words(of: String(line))
        let separator = try #require(words.firstIndex(of: "--"))
        return Array(words[(separator + 1)...])
    }

    @Test func aClaudeCodeLaunchCarriesHeelersHooksBeforeItsOwnArguments() throws {
        let request = AgentLaunchRequest(
            kind: "claude", name: "claude", arguments: ["--resume", "abc"], workspaceID: "$0", cwd: "/work")
        let window = try TmuxLaunch.agentWindow(request, on: server(), hookSettings: Self.hookSettings)
        let session = try TmuxLaunch.agentSession(
            request, workspace: NewWorkspaceSpec(directory: "/work", label: "work"), on: server(),
            hookSettings: Self.hookSettings)
        let expected = ["/bin/zsh", "-ic", "exec \"$@\"", "/bin/zsh", "claude", "--settings", Self.hookSettings, "--resume", "abc"]
        #expect(try program(window) == expected)
        #expect(try program(session) == expected)
        #expect(try program(TmuxLaunch.agentWindow(request, on: server())).contains("--settings") == false)
    }

    @Test func aFreshClaudeCodeKeepsItsSessionFlagBesideTheHooks() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "$0", cwd: "/work"),
            on: server(), hookSettings: Self.hookSettings)
        let words = try program(command)
        #expect(Array(words.prefix(6)) == ["/bin/zsh", "-ic", "exec \"$@\"", "/bin/zsh", "claude", "--session-id"])
        #expect(Array(words.suffix(2)) == ["--settings", Self.hookSettings])
    }

    @Test(arguments: ["codex", "pi", "my-tool"])
    func anotherProgramIgnoresTheHooks(_ kind: String) throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(kind: kind, name: kind, workspaceID: "$0", cwd: "/work"),
            on: server(), hookSettings: Self.hookSettings)
        #expect(!(try program(command)).contains("--settings"))
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
        exec "$t" -S "$s" new-session -d -c '\''/work'\'' -P -F '\''#{pane_id} #{window_id} #{session_id} #{q:session_name} .'\'''
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
        exec "$t" -S "$s" new-session -d -s work -c '\''/work'\'' -e '\''CLAUDE_CODE_CHILD_SESSION='\'' -e '\''CLAUDE_CODE_SKIP_PROMPT_HISTORY='\'' -P -F '\''#{pane_id} #{window_id} #{session_id} #{q:session_name} .'\'' -- '\''/bin/zsh'\'' -ic '\''exec "$@"'\'' '\''/bin/zsh'\'' claude --resume abc'
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

    @Test(arguments: ["-x", "--", "-t other"])
    func aRenameLabelIsNotATmuxFlag(_ label: String) {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@_-")
        let word = label.unicodeScalars.allSatisfy(plain.contains) ? label : HerdrCoreLocator.quoted(label)
        let renamed = TmuxLaunch.renameSession(id: "$0", label: label, paths: Self.paths)
        #expect(text(renamed).contains("rename-session -t '$0' -- \(word)"))
    }

    @Test func anAgentArgumentThatLooksLikeAFlagStaysAfterTheSeparator() throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "tool", name: "tool", arguments: ["-x", "--", "-t other"],
                workspaceID: "$0", cwd: "/work"),
            on: server())
        #expect(text(command).contains("-- '/bin/zsh' -ic 'exec \"$@\"' '/bin/zsh' tool -x -- '-t other'"))
    }

    @Test func renameAndCloseNameTheirTargets() {
        let renamed = TmuxLaunch.renameSession(id: "$0", label: "My Work", paths: Self.paths)
        #expect(text(renamed) == script("exec \"$t\" -N -S \"$s\" rename-session -t '$0' -- 'My Work'"))
        let pane = TmuxLaunch.killPane("%7", paths: Self.paths)
        #expect(text(pane) == script("exec \"$t\" -N -S \"$s\" kill-pane -t '%7'"))
        let window = TmuxLaunch.killWindow("@4", paths: Self.paths)
        #expect(text(window) == script("exec \"$t\" -N -S \"$s\" kill-window -t @4"))
    }

    @Test func showEnvironmentAsksTheGlobalListAndASessionById() throws {
        let global = TmuxLaunch.showEnvironment(paths: Self.paths)
        #expect(text(global).hasPrefix(
            """
            t='/opt/homebrew/bin/tmux'
            s='/tmp/heeler-t693/sock'
            e=$("$t" -N -S "$s" -u show-environment -g -s) || exit "$?"
            [ -n "$e" ] || exit 0
            printf '%s\\n' "$e" | LC_ALL=C awk '
            """
        ))
        #expect(!global.throughLoginShell)
        #expect(
            try Self.posixArgv(of: global).map { String(decoding: $0, as: UTF8.self) }
                == ["-N", "-S", Self.paths.socket, "-u", "show-environment", "-g", "-s"])

        let session = TmuxLaunch.showEnvironment(session: "$0", paths: Self.paths)
        #expect(text(session).hasPrefix(
            """
            t='/opt/homebrew/bin/tmux'
            s='/tmp/heeler-t693/sock'
            e=$("$t" -N -S "$s" -u show-environment -t '$0' -s) || exit "$?"
            [ -n "$e" ] || exit 0
            printf '%s\\n' "$e" | LC_ALL=C awk '
            """
        ))
        #expect(!session.throughLoginShell)
        #expect(
            try Self.posixArgv(of: session).map { String(decoding: $0, as: UTF8.self) }
                == ["-N", "-S", Self.paths.socket, "-u", "show-environment", "-t", "$0", "-s"])
    }

    @Test func showEnvironmentFiltersValuesOnTheHostAndKeepsExitStatus() throws {
        let globalSample = #"""
            -DASH="secret-dash"; export -DASH;
             LEAD_SPACE="secret-space"; export  LEAD_SPACE;
            1BAD="secret-digit"; export 1BAD;
            A"B="secret-quote"; export A"B;
            A\$B="secret-dollar-34"; export A\$B;
            A;B="secret-semi"; export A;B;
            ANTHROPIC_API_KEY="sk-ant-secret=token"; export ANTHROPIC_API_KEY;
            BASH_FUNC_mod%%="() {
            CLAUDECODE=\"planted\"; export CLAUDECODE;
            unset TMUX;
            }"; export BASH_FUNC_mod%%;
            CLAUDECODE="secret-claude-token"; export CLAUDECODE;
            EMPTY_VAR=""; export EMPTY_VAR;
            MULTI_VAR="line1=secret-line
            HERDR_FAKE=\"planted\"; export HERDR_FAKE;
            unset TMUX;
            MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A=
            end\\"; export MULTI_VAR;
            unset tricky="line1
            HERDR_TRICKY=\"planted\"; export HERDR_TRICKY"; export unset tricky;
            Z_LAST="secret-z"; export Z_LAST;

            """#
        let globalResult = try Self.runEnvironmentScript(
            TmuxLaunch.showEnvironment(paths: Self.paths), tmuxOutput: globalSample, tmuxStatus: 0)
        #expect(globalResult.status == 0)
        #expect(!globalResult.stdout.contains("secret"))
        #expect(!globalResult.stdout.contains("planted"))
        #expect(!globalResult.stdout.contains("MIIBIj"))
        #expect(!globalResult.stdout.contains("="))
        #expect(
            globalResult.stdout.split(separator: "\n").map(String.init)
                == ["ANTHROPIC_API_KEY", "CLAUDECODE", "EMPTY_VAR", "MULTI_VAR", "Z_LAST"])

        let sessionSample = """
            CODEX_THREAD_ID="secret-session-thread"; export CODEX_THREAD_ID;
            unset A;B;
            unset CLAUDECODE;
            unset unset foo;

            """
        let sessionResult = try Self.runEnvironmentScript(
            TmuxLaunch.showEnvironment(session: "$0", paths: Self.paths),
            tmuxOutput: sessionSample, tmuxStatus: 0)
        #expect(sessionResult.status == 0)
        #expect(!sessionResult.stdout.contains("secret"))
        #expect(!sessionResult.stdout.contains("="))
        #expect(
            sessionResult.stdout.split(separator: "\n").map(String.init)
                == ["CODEX_THREAD_ID", "-CLAUDECODE"])

        let emptyResult = try Self.runEnvironmentScript(
            TmuxLaunch.showEnvironment(session: "$0", paths: Self.paths), tmuxOutput: "", tmuxStatus: 0)
        #expect(emptyResult.status == 0)
        #expect(emptyResult.stdout.isEmpty)

        let failedResult = try Self.runEnvironmentScript(
            TmuxLaunch.showEnvironment(session: "$99", paths: Self.paths), tmuxOutput: "", tmuxStatus: 1)
        #expect(failedResult.status == 1)
        #expect(failedResult.stdout.isEmpty)
    }

    // MARK: Quoting

    @Test(arguments: userText)
    func anAgentArgumentRoundTrips(_ value: String) throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "tool", name: "tool", arguments: [value], workspaceID: "$0", cwd: "/work"),
            on: server())
        let argv = try Self.posixArgv(of: command)
        let found = try #require(argv.last)
        #expect(found == Data(value.utf8))
    }

    @Test(arguments: userText)
    func anEnvironmentValueRoundTrips(_ value: String) throws {
        let command = try TmuxLaunch.agentWindow(
            AgentLaunchRequest(
                kind: "tool", name: "tool", workspaceID: "$0", cwd: "/work",
                environment: ["HEELER_TEST": value]),
            on: server())
        let argv = try Self.posixArgv(of: command)
        #expect(argv.contains(Data("HEELER_TEST=\(value)".utf8)))
    }

    @Test(arguments: userText)
    func aWorkspaceNameRoundTrips(_ value: String) throws {
        let command = try TmuxLaunch.shellSession(
            NewWorkspaceSpec(directory: "/work", label: value), on: server())
        let argv = try Self.posixArgv(of: command)
        #expect(try #require(Self.argument(argv, after: "-s")) == Data(value.utf8))
    }

    @Test(arguments: userText + ["-x", "--", "-t other"])
    func aRenameLabelRoundTrips(_ value: String) throws {
        let command = TmuxLaunch.renameSession(id: "$0", label: value, paths: Self.paths)
        let argv = try Self.posixArgv(of: command)
        #expect(try #require(Self.argument(argv, after: "--")) == Data(value.utf8))
    }

    @Test(arguments: userText + ["docs 日本語"])
    func aWorkingDirectoryRoundTrips(_ directory: String) throws {
        let command = try TmuxLaunch.shellWindow(
            ShellTerminalCreationRequest(workspaceID: "$0", cwd: directory), on: server())
        let argv = try Self.posixArgv(of: command)
        #expect(try #require(Self.argument(argv, after: "-c")) == Data(directory.utf8))
    }

    /// tmux takes an argv word ending in `;` as the end of a command and reads
    /// one ending in `\;` as ending in `;` (ADR 0045), so a word of the user's
    /// that ends in `;` reaches tmux whole.
    @Test(arguments: ["ends;", #"ends\;"#, ";", "a;b"])
    func aWordEndingInASemicolonReachesTmuxWhole(_ value: String) throws {
        let expected = Data(value.utf8)
        let agent = try Self.posixArgv(
            of: try TmuxLaunch.agentWindow(
                AgentLaunchRequest(
                    kind: "tool", name: "tool", arguments: [value], workspaceID: "$0", cwd: value,
                    environment: ["HEELER_TEST": value]),
                on: server()))
        #expect(Self.tmuxWord(try #require(agent.last)) == expected)
        #expect(Self.tmuxWord(try #require(Self.argument(agent, after: "-c"))) == expected)
        let environment = try #require(agent.first { $0.starts(with: Data("HEELER_TEST=".utf8)) })
        #expect(Self.tmuxWord(environment) == Data("HEELER_TEST=\(value)".utf8))
        let workspace = try Self.posixArgv(
            of: try TmuxLaunch.shellSession(NewWorkspaceSpec(directory: "/work", label: value), on: server()))
        #expect(Self.tmuxWord(try #require(Self.argument(workspace, after: "-s"))) == expected)
        let renamed = try Self.posixArgv(of: TmuxLaunch.renameSession(id: "$0", label: value, paths: Self.paths))
        #expect(Self.tmuxWord(try #require(Self.argument(renamed, after: "--"))) == expected)
    }

    /// An argv word as tmux 3.3a's `cmd_parse_from_arguments` keeps it; nil
    /// when tmux takes its `;` as the end of a command.
    private static func tmuxWord(_ word: Data) -> Data? {
        guard word.last == UInt8(ascii: ";") else { return word }
        var kept = word.dropLast()
        guard kept.last == UInt8(ascii: "\\") else { return nil }
        kept[kept.index(before: kept.endIndex)] = UInt8(ascii: ";")
        return Data(kept)
    }

    /// The Linux start stores the whole script in one quoted assignment and
    /// runs it through `$SHELL -lic`. A stand-in shell skips the login files.
    @Test func theLoginShellStartRoundTripsUserText() throws {
        let argument = "it's $HOME `x`\n日本語 😀"
        let environment = "say \"hi\" $HOME"
        let name = "work `name`\n日本語"
        let directory = "docs 日本語"
        let command = try TmuxLaunch.agentSession(
            AgentLaunchRequest(
                kind: "tool", name: "tool", arguments: [argument],
                environment: ["HEELER_TEST": environment]),
            workspace: NewWorkspaceSpec(directory: directory, label: name),
            on: server(kernel: "Linux", running: false))
        #expect(command.throughLoginShell)
        let argv = try Self.posixArgv(of: command)
        #expect(try #require(Self.argument(argv, after: "-s")) == Data(name.utf8))
        #expect(try #require(Self.argument(argv, after: "-c")) == Data(directory.utf8))
        #expect(argv.contains(Data("HEELER_TEST=\(environment)".utf8)))
        #expect(argv.last == Data(argument.utf8))
        #expect(!argv.contains(Data("-N".utf8)))
    }

    // MARK: Worktree sessions

    @Test func aWorktreeSessionKeepsTheBranchAndNumbersWhenThatNameIsTaken() {
        #expect(TmuxLaunch.sessionName(forBranch: "feature/login", taken: []) == "feature/login")
        #expect(
            TmuxLaunch.sessionName(forBranch: "feature/login", taken: ["feature/login"])
                == "feature/login-2")
        #expect(
            TmuxLaunch.sessionName(
                forBranch: "feature/login", taken: ["feature/login", "feature/login-2", "other"])
                == "feature/login-3")
        #expect(
            TmuxLaunch.sessionName(
                forBranch: "feature/login", taken: ["feature/login", "feature/login-3"])
                == "feature/login-2")
    }

    /// tmux rejects `.` and `:` in a session name. A dotted branch such as
    /// `v1.2` is a branch git accepts, so the session name replaces those.
    @Test func aDottedBranchBecomesASessionNameTmuxAccepts() {
        #expect(TmuxLaunch.sessionName(forBranch: "v1.2", taken: []) == "v1-2")
        #expect(TmuxLaunch.sessionName(forBranch: "v1.2", taken: ["v1-2"]) == "v1-2-2")
        #expect(TmuxLaunch.sessionName(forBranch: "a:b", taken: []) == "a-b")
    }

    @Test func aWorktreeMarkAddressesTheSessionById() throws {
        let path = "/Users/dev/.heeler/worktrees/my app/feature-login"
        let command = TmuxLaunch.setWorktree(session: "$3", path: path, paths: Self.paths)
        #expect(text(command) == script(
            "exec \"$t\" -N -S \"$s\" set-option -t '$3' @heeler-worktree '/Users/dev/.heeler/worktrees/my app/feature-login'"
        ))
        #expect(!command.throughLoginShell)
        let argv = try Self.posixArgv(of: command)
        #expect(try #require(Self.argument(argv, after: "-t")) == Data("$3".utf8))
        #expect(argv.contains(Data("@heeler-worktree".utf8)))
        #expect(argv.last == Data(path.utf8))
    }

    @Test func endUnattachedAttachSessionChecksServerAttachedCountAndMarkOnSessionId() throws {
        let instance = TmuxServerInstance(pid: 4242, startTime: 1_700_000_000)
        #expect(TmuxLaunch.endUnattachedAttachSession(id: "heeler-attach-0a1b2c3d", instance: instance, paths: Self.paths) == nil)
        #expect(TmuxLaunch.endUnattachedAttachSession(id: "%3", instance: instance, paths: Self.paths) == nil)
        #expect(TmuxLaunch.endUnattachedAttachSession(id: "$", instance: instance, paths: Self.paths) == nil)

        let command = try #require(
            TmuxLaunch.endUnattachedAttachSession(id: "$9", instance: instance, paths: Self.paths))
        #expect(!command.throughLoginShell)
        let argv = try Self.posixArgv(of: command)
        let words = argv.map { String(decoding: $0, as: UTF8.self) }
        #expect(
            words == [
                "-N", "-S", Self.paths.socket,
                "if-shell", "-F", "-t", "$9",
                "#{&&:#{==:#{pid}:#{start_time},4242:1700000000},#{&&:#{==:#{session_attached},0},#{!=:#{@heeler-attach},}}}",
                "kill-session -t \"\\$9\"",
            ])
    }

    @Test func aBranchWithShellCharactersIsQuotedAsTheSessionName() throws {
        let branch = "a;b'c$(id)`x`"
        #expect(TmuxLaunch.sessionName(forBranch: branch, taken: []) == branch)
        let directory = "/Users/dev/.heeler/worktrees/my app/a-b-c-id-x"
        let command = try TmuxLaunch.agentSession(
            AgentLaunchRequest(kind: "claude", name: "claude", cwd: "/ignored"),
            workspace: NewWorkspaceSpec(directory: directory, label: branch),
            on: server())
        let argv = try Self.posixArgv(of: command)
        #expect(try #require(Self.argument(argv, after: "-s")) == Data(branch.utf8))
        #expect(try #require(Self.argument(argv, after: "-c")) == Data(directory.utf8))
    }

    // MARK: What tmux prints

    @Test func createdReadsThePrintedIds() {
        #expect(
            TmuxLaunch.created(from: Data("noise\n%3 @2\n".utf8))
                == TmuxLaunch.Created(paneID: "%3", windowID: "@2", sessionID: nil, sessionName: nil))
        #expect(
            TmuxLaunch.created(from: Data("%3 @2 $1 My\\ Work .\n".utf8))
                == TmuxLaunch.Created(paneID: "%3", windowID: "@2", sessionID: "$1", sessionName: "My Work"))
        #expect(
            TmuxLaunch.created(from: Data("%3 @2 $1 \\ My\\ \\\\$work\\037\\  .\n".utf8))
                == TmuxLaunch.Created(paneID: "%3", windowID: "@2", sessionID: "$1", sessionName: " My $work\u{001F} "))
        #expect(TmuxLaunch.created(from: Data("not a pane\n".utf8)) == nil)
    }

    /// Runs the real script under `/bin/sh` with the tmux executable replaced
    /// by a printer. Each argument is `printf '%s'`, so a newline stays inside
    /// one word. A login script gets a `SHELL` that ignores `-lic`.
    private static func posixArgv(of command: TmuxLaunch.Command) throws -> [Data] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heeler-quote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let out = root.appendingPathComponent("argv", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let printer = root.appendingPathComponent("printer")
        guard !printer.path.contains("'"), !printer.path.contains(paths.executable) else {
            throw ShellRoundTrip.unquotablePath
        }
        try Data(
            """
            #!/bin/sh
            if [ -z "$HEELER_ARGV_DIR" ]; then
              exit 97
            fi
            n=0
            for arg do
              printf '%s' "$arg" > "$HEELER_ARGV_DIR/$n" || exit 98
              n=$((n + 1))
            done
            """.utf8
        ).write(to: printer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: printer.path)

        var environment = ["HEELER_ARGV_DIR": out.path]
        if command.throughLoginShell {
            let shell = root.appendingPathComponent("shell")
            try Data("#!/bin/sh\nshift\nexec /bin/sh -c \"$1\"\n".utf8).write(to: shell)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
            environment["SHELL"] = shell.path
        }

        let executable = paths.executable
        var script = String(decoding: command.script, as: UTF8.self)
        guard script.contains(executable) else { throw ShellRoundTrip.missingExecutable }
        script = script.replacingOccurrences(of: executable, with: printer.path)
        guard !script.contains(executable) else { throw ShellRoundTrip.missingExecutable }
        let scriptFile = root.appendingPathComponent("launch.sh")
        try Data(script.utf8).write(to: scriptFile)

        let status = try HostShell.run("/bin/sh", arguments: [scriptFile.path], environment: environment)
        guard status == 0 else { throw ShellRoundTrip.exit(status) }

        let names = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        return try names.sorted {
            (Int($0.lastPathComponent) ?? 0) < (Int($1.lastPathComponent) ?? 0)
        }.map { try Data(contentsOf: $0) }
    }

    private static func runEnvironmentScript(
        _ command: TmuxLaunch.Command, tmuxOutput: String, tmuxStatus: Int32
    ) throws -> (status: Int32, stdout: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heeler-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stdoutFile = root.appendingPathComponent("stdout.txt")
        let stub = root.appendingPathComponent("tmux")
        guard !stub.path.contains("'"), !stub.path.contains(paths.executable),
            !stdoutFile.path.contains("'")
        else {
            throw ShellRoundTrip.unquotablePath
        }
        try Data(
            """
            #!/bin/sh
            if [ "$HEELER_TMUX_STATUS" != "0" ]; then
              printf 'tmux failed\\n' >&2
              exit "$HEELER_TMUX_STATUS"
            fi
            printf '%s' \(HerdrCoreLocator.quoted(tmuxOutput))
            """.utf8
        ).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        var script = String(decoding: command.script, as: UTF8.self)
        guard script.contains(paths.executable) else { throw ShellRoundTrip.missingExecutable }
        script = script.replacingOccurrences(of: paths.executable, with: stub.path)
        let runner = root.appendingPathComponent("runner.sh")
        let wrapped = "exec > '\(stdoutFile.path)'\n" + script
        try Data(wrapped.utf8).write(to: runner)

        let status = try HostShell.run(
            "/bin/sh",
            arguments: [runner.path],
            // A Host's own PATH for POSIX `awk`; the Simulator's has none of these.
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HEELER_TMUX_STATUS": String(tmuxStatus),
            ])
        let output = (try? Data(contentsOf: stdoutFile)) ?? Data()
        return (status, String(decoding: output, as: UTF8.self))
    }

    private static func argument(_ argv: [Data], after flag: String) -> Data? {
        let marker = Data(flag.utf8)
        guard let index = argv.firstIndex(of: marker) else { return nil }
        let next = argv.index(after: index)
        guard next < argv.endIndex else { return nil }
        return argv[next]
    }

    private enum ShellRoundTrip: Error, CustomStringConvertible {
        case exit(Int32)
        case unquotablePath
        case missingExecutable

        var description: String {
            switch self {
            case .exit(let code): "shell exited \(code)"
            case .unquotablePath: "printer path is not a single safe word"
            case .missingExecutable: "script is missing the tmux executable path"
            }
        }
    }
}
