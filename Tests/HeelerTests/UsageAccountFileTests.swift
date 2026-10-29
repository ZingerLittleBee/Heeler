import Foundation
import Testing

@testable import Heeler

@Suite("Usage Account file")
struct UsageAccountFileTests {
    private func file(_ json: String) throws -> UsageAccountFile {
        try UsageAccountFile.decode(Data(json.utf8))
    }

    private func json(_ file: UsageAccountFile) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
    }

    /// Returns `values` in order, then repeats the last, so ids can collide.
    private struct ScriptedGenerator: RandomNumberGenerator {
        var values: [UInt64]
        mutating func next() -> UInt64 {
            values.count > 1 ? values.removeFirst() : values[0]
        }
    }

    @Test func readsTheDesignDocExample() throws {
        let file = try file(#"""
            {"version": 1, "claude": {"defaultName": null,
              "accounts": [{"id": "7f3c9a2e", "directory": "/home/u/.claude-2", "name": "claude-2"}],
              "ignored": ["/home/u/.claude-backup"]}}
            """#)
        #expect(file.defaultName == nil)
        #expect(file.defaultDisplayName == "Default")
        #expect(file.accounts == [UsageAccountFile.Account(id: "7f3c9a2e", directory: "/home/u/.claude-2", name: "claude-2")])
        #expect(file.ignored == ["/home/u/.claude-backup"])
    }

    /// The plugin reads a missing or unreadable file as no added Accounts.
    @Test(arguments: [nil, "not json", "[1]", #"{"claude": {"accounts": []}}"#, #"{"version": "1"}"#])
    func aMissingOrUnreadableFileReadsAsEmpty(json: String?) throws {
        #expect(try UsageAccountFile.decode(json.map { Data($0.utf8) }) == UsageAccountFile())
    }

    /// A newer app's file must not be rewritten by this one.
    @Test func anotherVersionIsNotRewritten() {
        #expect(throws: ClaudeAccountError.unsupportedFileVersion(2)) {
            try UsageAccountFile.decode(Data(#"{"version": 2, "claude": {"accounts": []}}"#.utf8))
        }
    }

    @Test func entriesThePluginWouldSkipAreDropped() throws {
        let file = try file(#"""
            {"version": 1, "claude": {"defaultName": "Personal", "accounts": [
              {"id": "short", "directory": "/a", "name": "a"},
              {"id": "toString", "directory": "/b", "name": "b"},
              {"id": "__proto__", "directory": "/c", "name": "c"},
              {"id": "has space!", "directory": "/d", "name": "d"},
              {"id": "aaaaaaaa", "directory": "relative/.claude", "name": "e"},
              {"id": "bbbbbbbb", "directory": "/f", "name": "  "},
              {"id": "cccccccc", "directory": "/g", "name": "Personal"},
              {"id": "dddddddd", "directory": "/h", "name": "kept"},
              {"id": "dddddddd", "directory": "/i", "name": "same id"},
              {"id": "eeeeeeee", "directory": "/j", "name": "kept"},
              "not an object",
              {"id": "ffffffff_-", "directory": "/k", "name": "also kept"}
            ], "ignored": ["/x", "relative", 3]}}
            """#)
        #expect(file.defaultName == "Personal")
        #expect(file.accounts.map(\.id) == ["dddddddd", "ffffffff_-"])
        #expect(file.ignored == ["/x"])
    }

    @Test func aRewriteKeepsFieldsThisAppDoesNotKnow() throws {
        var file = try file(#"""
            {"version": 1, "note": "hand-edited", "claude": {"defaultName": null, "future": [1, 2],
              "accounts": [{"id": "7f3c9a2e", "directory": "/home/u/.claude-2", "name": "claude-2", "color": "blue"}],
              "ignored": []}}
            """#)
        try file.rename(accountID: "7f3c9a2e", to: "Max")
        let object = try json(file)
        #expect(object["version"] as? Int == 1)
        #expect(object["note"] as? String == "hand-edited")
        let claude = try #require(object["claude"] as? [String: Any])
        #expect(claude["defaultName"] is NSNull)
        #expect(claude["future"] as? [Int] == [1, 2])
        let entry = try #require((claude["accounts"] as? [[String: Any]])?.first)
        #expect(entry["name"] as? String == "Max")
        #expect(entry["color"] as? String == "blue")
        #expect(try UsageAccountFile.decode(file.encoded()) == file)
    }

    @Test func aNewAccountIsNamedForItsDirectoryAndGetsAnIDThePluginAccepts() throws {
        var file = UsageAccountFile()
        let added = try file.add(directory: "/Users/u/.claude-2", defaultDirectory: "/Users/u/.claude")
        #expect(added.name == "claude-2")
        #expect(added.directory == "/Users/u/.claude-2")
        #expect(UsageAccountFile.isValidID(added.id))
        #expect(added.id.count == 8)
        // A taken name gets a number; "Default" is the Default Account's.
        #expect(try file.add(directory: "/Volumes/T7/.claude-2", defaultDirectory: nil).name == "claude-2 2")
        #expect(try file.add(directory: "/srv/..Default", defaultDirectory: nil).name == "Default 2")
        #expect(file.accounts.count == 3)
        // Written as a file the plugin reads back the same.
        #expect(try UsageAccountFile.decode(file.encoded()) == file)
    }

    @Test func aSuggestionKeepsItsNameAndLeavesTheIgnoredList() throws {
        var file = UsageAccountFile()
        try file.ignore(directory: "/Users/u/.claude-work", defaultDirectory: nil)
        let added = try file.add(directory: "/Users/u/.claude-work", name: "claude-work", defaultDirectory: nil)
        #expect(added.name == "claude-work")
        #expect(file.ignored.isEmpty)
    }

    @Test func idsNeverRepeat() throws {
        var generator = ScriptedGenerator(values: [7, 7, 7, 9])
        var file = UsageAccountFile()
        let first = try file.add(directory: "/a/.claude-1", defaultDirectory: nil, using: &generator)
        let second = try file.add(directory: "/a/.claude-2", defaultDirectory: nil, using: &generator)
        #expect(first.id != second.id)
        #expect([first, second].allSatisfy { UsageAccountFile.isValidID($0.id) })
    }

    @Test func addingRefusesWhatCannotCount() throws {
        var file = UsageAccountFile()
        try file.add(directory: "/Users/u/.claude-2", defaultDirectory: nil)
        #expect(throws: ClaudeAccountError.notAbsolute) {
            try file.add(directory: "Users/u/.claude-3", defaultDirectory: nil)
        }
        #expect(throws: ClaudeAccountError.alreadyListed) {
            try file.add(directory: "/Users/u/.claude-2", defaultDirectory: nil)
        }
        #expect(throws: ClaudeAccountError.alreadyListed) {
            try file.add(directory: "/Users/u/.claude-2/", defaultDirectory: nil)
        }
        #expect(throws: ClaudeAccountError.alreadyListed) {
            try file.add(directory: "/Users/u/.claude", defaultDirectory: "/Users/u/.claude")
        }
        try file.add(directory: "/Users/u/.claude-3", defaultDirectory: nil)
        try file.add(directory: "/Users/u/.claude-4", defaultDirectory: nil)
        #expect(throws: ClaudeAccountError.limitReached) {
            try file.add(directory: "/Users/u/.claude-5", defaultDirectory: nil)
        }
        // Dismissing a suggestion stays possible at the limit.
        try file.ignore(directory: "/Users/u/.claude-5", defaultDirectory: nil)
        #expect(file.ignored == ["/Users/u/.claude-5"])
    }

    @Test func namesStayUniqueOnTheHost() throws {
        var file = UsageAccountFile()
        let added = try file.add(directory: "/Users/u/.claude-2", defaultDirectory: nil)
        let other = try file.add(directory: "/Users/u/.claude-3", defaultDirectory: nil)
        try file.rename(accountID: UsageAccountFile.defaultAccountID, to: "  Personal ")
        #expect(file.defaultName == "Personal")
        #expect(throws: ClaudeAccountError.nameTaken("claude-2")) {
            try file.rename(accountID: UsageAccountFile.defaultAccountID, to: "claude-2")
        }
        #expect(throws: ClaudeAccountError.nameTaken("Personal")) {
            try file.rename(accountID: added.id, to: "Personal")
        }
        #expect(throws: ClaudeAccountError.nameTaken("claude-3")) {
            try file.rename(accountID: added.id, to: "claude-3")
        }
        #expect(throws: ClaudeAccountError.emptyName) {
            try file.rename(accountID: added.id, to: " ")
        }
        #expect(throws: ClaudeAccountError.accountNotFound) {
            try file.rename(accountID: "zzzzzzzz", to: "Max")
        }
        try file.rename(accountID: added.id, to: "claude-2")
        try file.rename(accountID: added.id, to: "Max")
        // An empty name gives the Default Account back its own label…
        try file.rename(accountID: UsageAccountFile.defaultAccountID, to: "")
        #expect(file.defaultName == nil)
        // …which no added Account can then take.
        #expect(throws: ClaudeAccountError.nameTaken("Default")) {
            try file.rename(accountID: other.id, to: "Default")
        }
        #expect(file.accounts.map(\.name) == ["Max", "claude-3"])
        #expect(try json(file)["claude"].flatMap { ($0 as? [String: Any])?["defaultName"] } is NSNull)
    }

    @Test func removingAndIgnoring() throws {
        var file = UsageAccountFile()
        let added = try file.add(directory: "/Users/u/.claude-2", defaultDirectory: nil)
        file.remove(accountID: "zzzzzzzz")
        #expect(file.accounts.count == 1)
        #expect(file.ignored.isEmpty)
        file.remove(accountID: added.id)
        #expect(file.accounts.isEmpty)
        // A removed Account's directory is not suggested again right away;
        // adding it back takes it off the list.
        #expect(file.ignored == ["/Users/u/.claude-2"])
        try file.add(directory: "/Users/u/.claude-2/", defaultDirectory: nil)
        #expect(file.ignored.isEmpty)
        try file.ignore(directory: "/Users/u/.claude-backup", defaultDirectory: nil)
        try file.ignore(directory: "/Users/u/.claude-backup/", defaultDirectory: nil)
        #expect(file.ignored == ["/Users/u/.claude-backup"])
        #expect(throws: ClaudeAccountError.notAbsolute) {
            try file.ignore(directory: "~/.claude-x", defaultDirectory: nil)
        }
    }

    /// A suggestion row shown before its directory was added cannot
    /// dismiss a directory that counts, the Default Account's included.
    @Test func ignoringAnAccountsDirectoryChangesNothing() throws {
        var file = UsageAccountFile()
        try file.add(directory: "/Users/u/.claude-2", defaultDirectory: nil)
        let before = file
        try file.ignore(directory: "/Users/u/.claude-2/", defaultDirectory: "/Users/u/.claude")
        try file.ignore(directory: "/Users/u/.claude", defaultDirectory: "/Users/u/.claude/")
        #expect(file == before)
    }

    @Test(arguments: [
        ("7f3c9a2e", true), ("A-b_C-d_E", true), (String(repeating: "a", count: 32), true),
        ("7f3c9a2", false), (String(repeating: "a", count: 33), false), ("default", false),
        ("constructor", false), ("hasOwnProperty", false), ("toString", false), ("__proto__", false),
        ("valueOf1", true), ("7f3c 9a2e", false), ("7f3c9a2é", false),
    ])
    func idsFollowThePluginsRule(id: String, valid: Bool) {
        #expect(UsageAccountFile.isValidID(id) == valid)
    }
}
