import Foundation
import Testing

@testable import Heeler

/// Heeler's Claude Code hook entries (ADR 0044): the command and entries the
/// shared vector names, and the edits that add them to a configuration root's
/// `settings.json` and take them out again, keeping every other byte.
@Suite struct ClaudeCodeHooksTests {
    struct VectorFile: Decodable {
        struct Command: Decodable {
            let name: String
            let script: String
            let command: String
        }

        struct Entry: Decodable {
            let event: String
            let matcher: String?
        }

        let marker: String
        let timeout: Int
        let commands: [Command]
        let entries: [Entry]
        let group: String
    }

    private final class BundleToken {}

    private static func vectors() throws -> VectorFile {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "claude-code-hooks-v1", withExtension: "json"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private static let script = "/home/ana/.local/share/heeler/claude-code/hook.sh"
    private static let root = "/home/ana/.claude"
    private static let path = "/home/ana/.claude/settings.json"

    private static func added(_ before: String?) throws -> String {
        let transform = ClaudeCodeHooks.adding(script: script)(before.map { Data($0.utf8) })
        guard case .change(let after) = transform else {
            Issue.record("expected a change, got \(transform)")
            throw HarnessConfigEditError.unreadable
        }
        return String(decoding: after, as: UTF8.self)
    }

    private static func removed(_ before: String) throws -> String {
        let transform = ClaudeCodeHooks.removing(Data(before.utf8))
        guard case .change(let after) = transform else {
            Issue.record("expected a change, got \(transform)")
            throw HarnessConfigEditError.unreadable
        }
        return String(decoding: after, as: UTF8.self)
    }

    private static func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Each event's handlers' commands, in order.
    private static func commands(_ text: String) throws -> [String: [String]] {
        let hooks = try object(text)["hooks"] as? [String: Any] ?? [:]
        var commands: [String: [String]] = [:]
        for (event, groups) in hooks {
            for group in groups as? [[String: Any]] ?? [] {
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    commands[event, default: []].append(handler["command"] as? String ?? "")
                }
            }
        }
        return commands
    }

    private static var heelers: String { ClaudeCodeHooks.command(script: script) }

    // MARK: The vector

    @Test func theCommandIsTheVectorsForEveryScriptPath() throws {
        for vector in try Self.vectors().commands {
            #expect(ClaudeCodeHooks.command(script: vector.script) == vector.command, "\(vector.name)")
        }
    }

    @Test func theEntriesAreTheVectors() throws {
        let vectors = try Self.vectors()
        #expect(ClaudeCodeHooks.marker == vectors.marker)
        #expect(ClaudeCodeHooks.timeout == vectors.timeout)
        #expect(ClaudeCodeHooks.entries.map(\.event) == vectors.entries.map(\.event))
        #expect(ClaudeCodeHooks.entries.map(\.matcher) == vectors.entries.map(\.matcher))
        for vector in vectors.commands {
            #expect(vector.script.hasSuffix(ClaudeCodeHooks.marker))
        }
    }

    @Test func eachEventIsOneLineHoldingTheVectorsGroup() throws {
        let vectors = try Self.vectors()
        let script = try #require(vectors.commands.first).script
        #expect(ClaudeCodeHooks.group(ClaudeCodeHooks.entries[0], script: script) == vectors.group)
        let created = String(decoding: ClaudeCodeHooks.launchSettings(script: script), as: UTF8.self)
        let lines = created.split(separator: "\n").map(String.init)
        for entry in ClaudeCodeHooks.entries {
            let line = "\"\(entry.event)\": [\(ClaudeCodeHooks.group(entry, script: script))]"
            #expect(lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(line) }, "\(entry.event)")
        }
    }

    @Test func theLaunchSettingsAreTheFileAnAdditionCreates() throws {
        let launch = String(decoding: ClaudeCodeHooks.launchSettings(script: Self.script), as: UTF8.self)
        #expect(try Self.added(nil) == launch)
        let commands = try Self.commands(launch)
        #expect(commands.count == ClaudeCodeHooks.entries.count)
        for entry in ClaudeCodeHooks.entries {
            #expect(commands[entry.event] == [Self.heelers])
        }
        let hooks = try #require(try Self.object(launch)["hooks"] as? [String: [[String: Any]]])
        #expect(hooks["SessionStart"]?.first?["matcher"] as? String == "startup|resume|clear")
        #expect(hooks["Notification"]?.first?["matcher"] as? String == "permission_prompt|idle_prompt")
        #expect(hooks["Stop"]?.first?["matcher"] == nil)
        let handler = try #require((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        #expect(handler["timeout"] as? Int == 5)
    }

    // MARK: Adding

    @Test func anAdditionKeepsEveryOtherSettingByteForByte() throws {
        let before = """
            {
              "permissions": {
                "allow": ["Bash(ls)"]
              },
              "model": "opus"
            }

            """
        let after = try Self.added(before)
        let lines = ClaudeCodeHooks.entries.map { entry in
            "    \"\(entry.event)\": [\(ClaudeCodeHooks.group(entry, script: Self.script))]"
        }
        #expect(
            after == """
                {
                  "permissions": {
                    "allow": ["Bash(ls)"]
                  },
                  "model": "opus",
                  "hooks": {
                \(lines.joined(separator: ",\n"))
                  }
                }

                """)
    }

    @Test func existingHooksGetOnlyWhatIsMissing() throws {
        let before = """
            {
              "hooks": {
                "PreToolUse": [
                  {
                    "matcher": "Bash",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "~/bin/guard"
                      }
                    ]
                  }
                ],
                "Stop": [\(ClaudeCodeHooks.group(.init(event: "Stop", matcher: nil), script: Self.script))],
                "Notification": []
              }
            }

            """
        let after = try Self.added(before)
        let commands = try Self.commands(after)
        #expect(commands["PreToolUse"] == ["~/bin/guard", Self.heelers])
        for entry in ClaudeCodeHooks.entries where entry.event != "PreToolUse" {
            #expect(commands[entry.event] == [Self.heelers], "\(entry.event)")
        }
        // The user's group stays as it was, and Heeler's comes after it.
        let preToolUse = [
            "            \"command\": \"~/bin/guard\"",
            "          }",
            "        ]",
            "      },",
            "      \(ClaudeCodeHooks.group(.init(event: "PreToolUse", matcher: nil), script: Self.script))",
            "    ],",
        ]
        #expect(after.contains(preToolUse.joined(separator: "\n")))
        #expect(after.contains("\"Notification\": [\(ClaudeCodeHooks.group(ClaudeCodeHooks.entries[6], script: Self.script))]"))
    }

    @Test func aFileWithEveryHookAlreadyHasThem() throws {
        let created = try Self.added(nil)
        #expect(ClaudeCodeHooks.adding(script: Self.script)(Data(created.utf8)) == .alreadyApplied)
        #expect(ClaudeCodeHooks.presence(in: Data(created.utf8), script: Self.script) == .on)
    }

    @Test func aHookRunningAnotherPathGetsTheCurrentOne() throws {
        let stale = ClaudeCodeHooks.launchSettings(script: "/old/data/heeler/claude-code/hook.sh")
        #expect(ClaudeCodeHooks.presence(in: stale, script: Self.script) == .partly)
        let after = try Self.added(String(decoding: stale, as: UTF8.self))
        for entry in ClaudeCodeHooks.entries {
            #expect(try Self.commands(after)[entry.event]?.last == Self.heelers)
        }
    }

    @Test func aFileOnOneLineGrowsOnOneLine() throws {
        let after = try Self.added(#"{"model": "opus"}"#)
        #expect(after.hasPrefix(#"{"model": "opus", "hooks": {"SessionStart": ["#))
        #expect(!after.contains("\n"))
        #expect(try Self.commands(after).count == ClaudeCodeHooks.entries.count)
    }

    @Test func anEmptyFileOrObjectGetsTheWholeBlock() throws {
        let launch = String(decoding: ClaudeCodeHooks.launchSettings(script: Self.script), as: UTF8.self)
        #expect(try Self.added("") == launch)
        #expect(try Self.added("{}\n") == launch)
    }

    @Test func crlfStaysCrlf() throws {
        let after = try Self.added("{\r\n  \"model\": \"opus\"\r\n}\r\n")
        #expect(!after.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(try Self.commands(after).count == ClaudeCodeHooks.entries.count)
    }

    @Test(arguments: [
        "{ // a comment\n}",
        "[]",
        "{\"hooks\": []}",
        "{\"hooks\": {\"Stop\": {}}}",
        "{\"hooks\": {}, \"hooks\": {}}",
        "{\"model\": \"opus\",}",
        "not json",
    ])
    func aFileHeelerCanNotReadSafelyIsRefused(_ before: String) {
        guard case .refused = ClaudeCodeHooks.adding(script: Self.script)(Data(before.utf8)) else {
            Issue.record("expected a refusal of \(before)")
            return
        }
    }

    // MARK: Removing

    @Test func removingTakesOutOnlyHeelersHandlers() throws {
        let ours = #"{"type": "command", "command": "f='/x/heeler/claude-code/hook.sh'; [ ! -r \"$f\" ] || exec /bin/sh \"$f\"", "timeout": 5}"#
        let before = """
            {
              "model": "opus",
              "hooks": {
                "PreToolUse": [
                  {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard"}, \(ours)]},
                  {"hooks": [\(ours)]}
                ],
                "Stop": [{"hooks": [\(ours)]}],
                "PostToolUse": [{"hooks": [{"type": "command", "command": "~/bin/log"}]}, {"hooks": [\(ours)]}]
              }
            }

            """
        let after = try Self.removed(before)
        #expect(
            after == """
                {
                  "model": "opus",
                  "hooks": {
                    "PreToolUse": [
                      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard"}]}
                    ],
                    "PostToolUse": [{"hooks": [{"type": "command", "command": "~/bin/log"}]}]
                  }
                }

                """)
    }

    @Test func removingEveryHookTakesTheHooksOut() throws {
        let before = """
            {
              "model": "opus"
            }

            """
        #expect(try Self.removed(try Self.added(before)) == before)
        let partial = """
            {
              "hooks": {
                "PreToolUse": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "~/bin/guard"
                      }
                    ]
                  }
                ]
              },
              "model": "opus"
            }

            """
        #expect(try Self.removed(try Self.added(partial)) == partial)
        #expect(try Self.removed(try Self.added(nil)) == "{}\n")
    }

    @Test(arguments: [nil, "", "{}", "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"~/bin/x\"}]}]}}"])
    func aFileWithoutHeelersHooksHasNothingToRemove(_ before: String?) {
        #expect(ClaudeCodeHooks.removing(before.map { Data($0.utf8) }) == .alreadyApplied)
        #expect(ClaudeCodeHooks.presence(in: before.map { Data($0.utf8) }, script: Self.script) == .off)
    }

    @Test func removingFromAFileHeelerCanNotReadIsRefused() {
        guard case .refused = ClaudeCodeHooks.removing(Data("{ // hooks\n}".utf8)) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(ClaudeCodeHooks.presence(in: Data("{ // hooks\n}".utf8), script: Self.script) == nil)
    }

    // MARK: Through the harness configuration edit module

    @Test func theAdditionIsProposedThenAppliedExactlyAsShown() async throws {
        let before = Data("{\n  \"model\": \"opus\"\n}\n".utf8)
        let files = InMemoryHostFiles(files: [Self.path: before])
        let edit = ClaudeCodeHooks.addition(root: Self.root + "/", script: Self.script)
        #expect(edit.path == Self.path)
        #expect(edit.harness == "Claude Code")
        let proposal = try await HarnessConfigEditor(files: files).propose(edit)
        guard case .change(let change) = proposal else {
            Issue.record("expected a change, got \(proposal)")
            return
        }
        #expect(await files.replaceCalls == 0)
        #expect(change.shownLines.contains { $0.kind == .added && $0.text.contains(Self.heelers.replacingOccurrences(of: "\"", with: "\\\"")) })
        _ = try await HarnessConfigEditor(files: files).apply(change)
        #expect(await files.files[Self.path] == change.after)
    }

    @Test func anotherDeviceUndoesItByRemovingHeelersEntries() async throws {
        let before = Data("{\n  \"model\": \"opus\"\n}\n".utf8)
        let files = InMemoryHostFiles(files: [Self.path: before])
        let addition = try await HarnessConfigEditor(files: files).propose(
            ClaudeCodeHooks.addition(root: Self.root, script: Self.script))
        guard case .change(let added) = addition else {
            Issue.record("expected a change, got \(addition)")
            return
        }
        _ = try await HarnessConfigEditor(files: files).apply(added)
        // The user changes the file afterwards; the other device knows nothing of the edit.
        let changed = try #require(await files.files[Self.path])
        let edited = String(decoding: changed, as: UTF8.self).replacingOccurrences(
            of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
        await files.set(Self.path, Data(edited.utf8))

        let removal = try await HarnessConfigEditor(files: files).propose(ClaudeCodeHooks.removal(root: Self.root))
        guard case .change(let removed) = removal else {
            Issue.record("expected a change, got \(removal)")
            return
        }
        #expect(removed.shownLines.allSatisfy { $0.kind == .removed || $0.text == "  \"model\": \"sonnet\"" })
        _ = try await HarnessConfigEditor(files: files).apply(removed)
        #expect(await files.files[Self.path] == Data("{\n  \"model\": \"sonnet\"\n}\n".utf8))
        let again = try await HarnessConfigEditor(files: files).propose(ClaudeCodeHooks.removal(root: Self.root))
        #expect(again == .alreadyApplied(path: Self.path))
    }
}
