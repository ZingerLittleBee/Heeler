import Foundation
import Testing

@testable import Heeler

/// The contributor's recognizer tests, moved with the recognizer and calling
/// it directly, for "Agents and their status on herdr-core" to absorb.
@Suite struct HerdrCoreAgentRuleTests {
    private func record(arguments: [String], foreground: [String]? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
            "argv": .array(arguments.map(JSONValue.string)), "status": .null,
        ]
        if let foreground {
            fields["foreground"] = .object([
                "name": .string(foreground.first ?? ""),
                "argv": .array(foreground.map(JSONValue.string)),
            ])
        }
        return .object(fields)
    }

    @Test func unreportedAgentsAreRecognizedButOrdinaryProgramsAreNot() throws {
        let terminals = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"address":"t1","cwd":"/a","state":"live","argv":["/bin/zsh"],"status":null,"foreground":{"name":"codex","argv":["/opt/bin/codex"],"cwd":"/b"}},{"address":"t2","cwd":"/a","state":"live","argv":["/bin/sh"],"status":{"app":"build","state":"working"}},{"address":"t3","cwd":"/a","state":"live","argv":["/opt/bin/pi"],"status":null}]"#.utf8))
        guard case .array(let records) = terminals else {
            Issue.record("fixture is not an array")
            return
        }
        #expect(records.map(HerdrCoreAgentRule.kind(of:)) == ["codex", nil, "pi"])
    }

    @Test func interpreterEntrypointsIdentifyUnreportedDesktopAgents() {
        let cases: [([String], String)] = [
            (["node", "/opt/bin/gemini.js"], "gemini"),
            (["node", "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js"], "claude"),
            (["node", "/opt/lib/node_modules/@google/gemini-cli/dist/index.js"], "gemini"),
            (["node", "/opt/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"], "pi"),
            (["node", "/opt/bin/pi-cli.js"], "pi"),
            (["/opt/bin/pi-cli"], "pi"),
            (["node", "--enable-source-maps", "/opt/bin/gemini.js"], "gemini"),
            (["node", "--require", "loader.js", "/opt/bin/gemini.js"], "gemini"),
            (["bun", "--", "/opt/bin/pi-cli"], "pi"),
        ]
        for (arguments, expected) in cases {
            #expect(
                HerdrCoreAgentRule.kind(of: record(arguments: ["/bin/zsh"], foreground: arguments)) == expected,
                "\(arguments)")
        }
    }

    @Test func exactDesktopShellWrappersRevealTheCommandPosition() {
        let local = ["/bin/zsh", "-ic", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "node", "/opt/bin/gemini.js", "task"]
        let remote = ["sh", "-c", "\"$@\"; exec \"${SHELL:-sh}\" -i", "sh", "pi", "task"]
        #expect(HerdrCoreAgentRule.kind(of: record(arguments: local)) == "gemini")
        #expect(HerdrCoreAgentRule.kind(of: record(arguments: remote)) == "pi")
        // A wrapper that returned to its shell no longer hosts the Agent.
        #expect(HerdrCoreAgentRule.kind(of: record(arguments: local, foreground: ["/bin/zsh", "-i"])) == nil)
    }

    @Test func staleReportsCannotKeepAnAgentInAPositivelyIdentifiedPlainShell() {
        let wrapper = ["/bin/zsh", "-ic", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "claude"]
        for foreground in [
            ["/bin/sh", "-i"], ["-zsh"], ["bash", "--noprofile", "--norc", "-il"], ["fish"],
        ] {
            let record: JSONValue = .object([
                "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
                "argv": .array(wrapper.map(JSONValue.string)),
                "foreground": .object(["argv": .array(foreground.map(JSONValue.string))]),
                "status": .object(["app": .string("claude-code"), "state": .string("idle")]),
            ])
            #expect(HerdrCoreAgentRule.kind(of: record) == nil, "\(foreground)")
        }
        // A shell still executing a command/script is not a known returned shell.
        for foreground in [wrapper, ["sh", "-c", "custom-agent-wrapper"], ["sh", "/opt/agent.sh"], []] {
            let record: JSONValue = .object([
                "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
                "argv": .array(wrapper.map(JSONValue.string)),
                "foreground": .object(["name": .string("sh"), "argv": .array(foreground.map(JSONValue.string))]),
                "status": .object(["app": .string("claude-code"), "state": .string("idle")]),
            ])
            #expect(HerdrCoreAgentRule.kind(of: record) == "claude")
        }
    }

    @Test func unrelatedArgumentsAndEvaluatedCodeDoNotCreateAgents() {
        for arguments in [
            ["echo", "claude"],
            ["node", "server.js", "claude"],
            ["node", "-e", "claude", "/opt/bin/gemini.js"],
            ["node", "--eval=claude", "/opt/bin/gemini.js"],
            ["node", "--require", "/opt/bin/gemini.js", "server.js"],
            ["python3", "-c", "gemini", "claude"],
            ["sh", "-c", "echo \"$@\"", "sh", "claude"],
            ["node", "/tmp/unrelated/cli.js", "@anthropic-ai/claude-code"],
        ] {
            #expect(HerdrCoreAgentRule.kind(of: record(arguments: arguments)) == nil, "\(arguments)")
        }
    }

    @Test func recognizedWrappersDoNotDependOnAKnownStatus() {
        let record: JSONValue = .object([
            "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
            "argv": .array(["node", "/opt/bin/gemini.js"].map(JSONValue.string)),
            "status": .object(["state": .string("future-state")]),
        ])
        #expect(HerdrCoreAgentRule.kind(of: record) == "gemini")
    }
}
