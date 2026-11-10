import Testing

@testable import Heeler

@Suite("tmux agent rule")
struct TmuxAgentRuleTests {
    private func kind(_ arguments: [String]?, command: String, isDead: Bool = false) -> String? {
        TmuxAgentRule.agentKind(in: .make(command: command, isDead: isDead, arguments: arguments))
    }

    @Test(arguments: [
        (["claude", "--resume"], "claude", "claude"),
        (["/opt/homebrew/bin/codex"], "codex", "codex"),
        // An interpreter running the program's entry point.
        (["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"], "node", "claude"),
        (["node", "--no-warnings", "/usr/local/bin/gemini"], "node", "gemini"),
        // `sh -c` lines and launch wrappers.
        (["sh", "-c", "cd /srv/app && exec claude --resume"], "sh", "claude"),
        (["/bin/zsh", "-lc", "exec \"$@\"", "zsh", "codex", "--yolo"], "zsh", "codex"),
        // A wrapper that goes on as a shell is its program while that runs.
        (["sh", "-c", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "claude"], "sh", "claude"),
        // `npx`, as its arguments and as the title npm gives its process.
        (["npx", "-y", "@openai/codex"], "node", "codex"),
        (["npm exec @anthropic-ai/claude-code"], "npm exec @anthropic-ai/claude-code", "claude"),
        // A native install running from a versioned path is known by its name.
        (["/home/dev/.local/share/claude/versions/2.1.87"], "claude", "claude"),
    ])
    func aKnownAgentProgramInTheForegroundIsAnAgent(arguments: [String], command: String, expected: String) {
        #expect(kind(arguments, command: command) == expected)
    }

    @Test(arguments: [
        (["-zsh"], "zsh"), (["bash", "-l"], "bash"), (["fish"], "fish"), (["/bin/sh", "-i"], "sh"),
        // What a wrapper that goes on as a shell has become once its program left.
        (["/bin/zsh", "-i"], "zsh"),
    ])
    func aShellInTheForegroundIsNone(arguments: [String], command: String) {
        #expect(kind(arguments, command: command) == nil)
    }

    @Test(arguments: [
        (["vim", "claude.md"], "vim"), (["python3", "server.py", "claude"], "python3"),
        (["node", "server.js"], "node"), (["sh", "-c", "echo claude"], "sh"), (["npx", "vitest"], "node"),
        (["ssh", "box", "claude"], "ssh"),
    ])
    func anUnknownProgramIsNeverAnAgent(arguments: [String], command: String) {
        #expect(kind(arguments, command: command) == nil)
        // Whatever its status says: on tmux only Heeler's integrations for known programs write one.
        var pane = TmuxInventory.Pane.make(command: command, status: "state=working:app=aider", arguments: arguments)
        #expect(TmuxAgentRule.agentKind(in: pane) == nil)
        pane.status = "state=working:app=claude-code"
        #expect(TmuxAgentRule.agentKind(in: pane) == nil)
    }

    @Test func aDeadPaneHostsNone() {
        #expect(kind(["claude"], command: "claude", isDead: true) == nil)
        #expect(kind(nil, command: "claude", isDead: true) == nil)
    }

    @Test func aForegroundWhoseArgumentsCouldNotBeReadGoesByItsCommand() {
        #expect(kind(nil, command: "claude") == "claude")
        #expect(kind(nil, command: "codex") == "codex")
        #expect(kind(nil, command: "zsh") == nil)
        #expect(kind(nil, command: "node") == nil)
        #expect(kind(nil, command: "") == nil)
        #expect(kind([], command: "claude") == "claude")
    }
}
