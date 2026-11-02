import Foundation
import Testing

@testable import Heeler

/// What OpenCode's configuration file becomes, and what undoing makes of it.
/// Expected files are written out in full, so every byte around the entry is
/// asserted to stay.
@Suite struct OpenCodePluginEditTests {
    private static let directory = "/home/dev/.config/opencode"
    private static let folder = "/home/dev/.config/opencode/heeler-opencode"
    private static let plugin = OpenCodePluginEdit.fileNames.map {
        HarnessConfigFolder.File(name: $0, contents: Data("// \($0)\n".utf8))
    }

    private func transformed(_ before: String?, _ form: OpenCodePluginEdit.ConfigForm) -> HarnessConfigEdit.Transform {
        OpenCodePluginEdit.transform(form: form, folderPath: Self.folder, fileName: "tui.json")(before.map { Data($0.utf8) })
    }

    private func changed(
        _ before: String?, _ form: OpenCodePluginEdit.ConfigForm = .tuiConfig,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> String {
        guard case .change(let after) = transformed(before, form) else {
            Issue.record("expected a change to \(before ?? "nil")", sourceLocation: sourceLocation)
            return ""
        }
        return String(decoding: after, as: UTF8.self)
    }

    // MARK: Where it goes

    @Test(arguments: [
        ("1.19.5", "plugin"), ("opencode v1.0.0", "plugin"), ("opencode v2.0.32", "plugins"), ("2.2.5", "plugins"),
        ("opencode v2.10.0-beta.1", "plugins"),
    ])
    func theTargetFollowsTheProbedVersion(_ version: String, _ key: String) throws {
        #expect(try #require(OpenCodePluginEdit.ConfigForm.of(version: version)).listKey == key)
    }

    @Test func eachReleaseEditsItsOwnFile() {
        #expect(OpenCodePluginEdit.ConfigForm.of(version: "1.19.5")?.fileNames == ["tui.json", "tui.jsonc"])
        #expect(OpenCodePluginEdit.ConfigForm.of(version: "2.2.5")?.fileNames == ["cli.json"])
    }

    /// A list in the wrong file does nothing and looks as if it did.
    @Test(arguments: [nil, "", "opencode", "not a version", "0.9.1", "3.0.0"] as [String?])
    func aVersionNobodyHasLookedAtHasNoTarget(_ version: String?) {
        #expect(OpenCodePluginEdit.ConfigForm.of(version: version) == nil)
    }

    @Test func theConfigDirectoryFollowsTheAgentsEnvironment() {
        #expect(OpenCodePluginEdit.configDirectory(xdgConfigHome: nil, home: "/home/dev") == Self.directory)
        #expect(OpenCodePluginEdit.configDirectory(xdgConfigHome: "", home: "/home/dev/") == Self.directory)
        #expect(OpenCodePluginEdit.configDirectory(xdgConfigHome: "/srv/cfg/", home: "/home/dev") == "/srv/cfg/opencode")
        #expect(OpenCodePluginEdit.configDirectory(xdgConfigHome: "cfg", home: "/home/dev") == nil)
    }

    @Test func theEditNamesTheFileTheEntryAndTheFolder() {
        let edit = OpenCodePluginEdit.edit(
            configDirectory: Self.directory, fileName: "cli.json", form: .cliConfig, files: Self.plugin)
        #expect(edit.id == "opencode.plugin")
        #expect(edit.path == "/home/dev/.config/opencode/cli.json")
        #expect(edit.listEntry == HarnessConfigListEntry(key: "plugins", value: "./heeler-opencode"))
        #expect(edit.folder?.path == Self.folder)
        #expect(
            edit.folder?.filePaths == [
                "\(Self.folder)/package.json", "\(Self.folder)/index.js", "\(Self.folder)/tui.js",
            ])
    }

    /// The app carries the plugin in the Helper's bundle, with the manifest over it.
    @Test func theBundleCarriesThePlugin() throws {
        let bundle = try HostHelperBundle.load()
        let files = try OpenCodePluginEdit.pluginFiles(from: bundle)

        #expect(files.map(\.name) == OpenCodePluginEdit.fileNames)
        #expect(files.allSatisfy { !$0.contents.isEmpty })
        for name in OpenCodePluginEdit.fileNames {
            #expect(bundle.manifest.files.contains { $0.path == "extensions/opencode/\(name)" })
        }
    }

    // MARK: Adding the entry

    @Test func noFileGetsOneThatHoldsOnlyTheEntry() {
        #expect(
            changed(nil, .tuiConfig) == """
                {
                  "$schema": "https://opencode.ai/tui.json",
                  "plugin": ["./heeler-opencode"]
                }

                """)
        #expect(
            changed(nil, .cliConfig) == """
                {
                  "$schema": "https://opencode.ai/v2/cli.json",
                  "plugins": ["./heeler-opencode"]
                }

                """)
    }

    @Test func anEmptyFileReadsAsNoFile() {
        #expect(changed(" \n", .cliConfig) == changed(nil, .cliConfig))
    }

    @Test func aNewLineIsTheOnlyChangeToAListOnItsOwnLines() {
        #expect(
            changed("""
                {
                  // my plugins
                  "plugin": [
                    /* first */
                    "other.plugin",
                    ["with.options", { "a": 1 }],
                  ],
                  "theme": "dark"
                }

                """) == """
                {
                  // my plugins
                  "plugin": [
                    /* first */
                    "./heeler-opencode",
                    "other.plugin",
                    ["with.options", { "a": 1 }],
                  ],
                  "theme": "dark"
                }

                """)
    }

    @Test func aListOnOneLineStaysOnOne() {
        #expect(
            changed(#"{"plugin": ["a", "b"], "theme": "dark"}"#)
                == #"{"plugin": ["./heeler-opencode", "a", "b"], "theme": "dark"}"#)
    }

    @Test func anEmptyListGetsTheEntry() {
        #expect(changed(#"{ "plugin": [] }"#) == #"{ "plugin": ["./heeler-opencode"] }"#)
    }

    @Test func aFileWithNoListGetsOneLine() {
        #expect(
            changed("""
                {
                  "$schema": "https://opencode.ai/tui.json",
                  "theme": "dark"
                }
                """, .tuiConfig) == """
                {
                  "plugin": ["./heeler-opencode"],
                  "$schema": "https://opencode.ai/tui.json",
                  "theme": "dark"
                }
                """)
        #expect(changed(#"{"theme": "dark"}"#) == #"{"plugin": ["./heeler-opencode"], "theme": "dark"}"#)
        #expect(changed("{}") == #"{"plugin": ["./heeler-opencode"]}"#)
    }

    @Test func windowsLineEndingsStay() {
        #expect(
            changed("{\r\n  \"plugin\": [\r\n    \"a\"\r\n  ]\r\n}\r\n")
                == "{\r\n  \"plugin\": [\r\n    \"./heeler-opencode\",\r\n    \"a\"\r\n  ]\r\n}\r\n")
    }

    @Test func theKeyOfTheOtherReleaseIsNotThisOnesList() {
        #expect(
            changed(#"{"plugin": ["a"]}"#, .cliConfig) == #"{"plugins": ["./heeler-opencode"], "plugin": ["a"]}"#)
    }

    /// `//` or a comma in a string, or a brace in a comment, is no structure.
    @Test func whatLooksLikeStructureInsideAStringOrCommentIsNot() {
        let before = """
            {
              "note": "// not a comment, ] nor } this",
              /* "plugin": ["commented out"], */
              "plugin": [
                "https://example.test/a,b"
              ]
            }
            """
        #expect(
            changed(before) == """
                {
                  "note": "// not a comment, ] nor } this",
                  /* "plugin": ["commented out"], */
                  "plugin": [
                    "./heeler-opencode",
                    "https://example.test/a,b"
                  ]
                }
                """)
    }

    @Test(arguments: [
        #"{"plugin": ["./heeler-opencode"]}"#,
        #"{"plugin": ["/home/dev/.config/opencode/heeler-opencode"]}"#,
        #"{"plugin": ["file:///home/dev/.config/opencode/heeler-opencode"]}"#,
    ])
    func aFileThatAlreadyListsTheFolderIsAlreadyApplied(_ file: String) {
        #expect(transformed(file, .tuiConfig) == .alreadyApplied)
    }

    /// The file is the user's, so one Heeler can't read with certainty stays theirs.
    @Test(arguments: [
        "not json", "[]", "{", #"{"a": 1,, }"#, #"{"plugin": ["a"]} trailing"#, #"{"a": tru}"#, "// only a comment",
        "{ /* unclosed", "\u{FEFF}{}", #"{"plugin": ["a"], "plugin": ["b"]}"#, "{\"a\": \"line\nbreak\"}",
    ])
    func aFileItCantReadIsRefused(_ file: String) {
        guard case .refused = transformed(file, .tuiConfig) else {
            Issue.record("expected a refusal of \(file)")
            return
        }
    }

    @Test func invalidUTF8IsRefused() {
        let edit = OpenCodePluginEdit.transform(form: .tuiConfig, folderPath: Self.folder, fileName: "tui.json")
        guard case .refused = edit(Data([0x7B, 0xFF, 0x7D])) else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func aListInAnotherShapeIsRefused() {
        guard case .refused = transformed(#"{"plugin": "a"}"#, .tuiConfig) else {
            Issue.record("expected a refusal")
            return
        }
    }

    /// OpenCode 1.x flattens a nested `tui`, where a top-level list would replace
    /// the one inside it (`config/tui.ts`, v1.19.5).
    @Test func aNestedTuiSectionIsRefusedOnThatRelease() {
        guard case .refused = transformed(#"{"tui": {"plugin": ["a"]}}"#, .tuiConfig) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(changed(#"{"tui": 1}"#, .cliConfig) == #"{"plugins": ["./heeler-opencode"], "tui": 1}"#)
    }

    // MARK: Taking it out of a file changed since

    private func removed(_ file: String) -> HarnessConfigJSONCList.Removal {
        HarnessConfigJSONCList.removing(
            HarnessConfigListEntry(key: "plugin", value: "./heeler-opencode"), from: Data(file.utf8))
    }

    private func removedText(_ file: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        guard case .changed(let after) = removed(file) else {
            Issue.record("expected a removal from \(file)", sourceLocation: sourceLocation)
            return ""
        }
        return String(decoding: after, as: UTF8.self)
    }

    @Test func removingItsOwnLineTakesOnlyThatLine() {
        #expect(
            removedText("""
                {
                  "plugin": [
                    "./heeler-opencode",
                    "a"
                  ],
                  "theme": "light"
                }
                """) == """
                {
                  "plugin": [
                    "a"
                  ],
                  "theme": "light"
                }
                """)
    }

    @Test func removingTheLastLeavesNoCommaBehind() {
        #expect(
            removedText("""
                {
                  "plugin": [
                    "a",
                    "./heeler-opencode"
                  ]
                }
                """) == """
                {
                  "plugin": [
                    "a"
                  ]
                }
                """)
    }

    @Test func removingFromOneLineLeavesTheRest() {
        #expect(removedText(#"{"plugin": ["./heeler-opencode", "a"]}"#) == #"{"plugin": ["a"]}"#)
        #expect(removedText(#"{"plugin": ["a", "./heeler-opencode"]}"#) == #"{"plugin": ["a"]}"#)
        #expect(removedText(#"{"plugin": ["a", "./heeler-opencode", "b"]}"#) == #"{"plugin": ["a", "b"]}"#)
        #expect(removedText(#"{"plugin": ["./heeler-opencode"]}"#) == #"{"plugin": []}"#)
    }

    @Test func nothingToRemoveSaysSo() {
        #expect(removed(#"{"plugin": ["a"]}"#) == .notThere)
        #expect(removed(#"{"theme": "dark"}"#) == .notThere)
        #expect(removed(#"{"plugin": "a"}"#) == .notAList)
        #expect(removed("not json") == .unreadable)
    }
}

/// The edit with its folder, through the one edit module and a Host's services:
/// compare-and-swap against what was read, and undo in its order.
@Suite struct OpenCodePluginEditWriteTests {
    private static let directory = "/home/dev/.config/opencode"
    private static let config = "/home/dev/.config/opencode/tui.json"
    private static let folder = "/home/dev/.config/opencode/heeler-opencode"
    private static let original = Data("{\n  \"theme\": \"dark\"\n}\n".utf8)
    private static let edited = Data("{\n  \"plugin\": [\"./heeler-opencode\"],\n  \"theme\": \"dark\"\n}\n".utf8)
    private static let plugin = OpenCodePluginEdit.fileNames.map {
        HarnessConfigFolder.File(name: $0, contents: Data("// \($0)\n".utf8))
    }
    private static let pluginPaths = OpenCodePluginEdit.fileNames.map { "\(folder)/\($0)" }

    private static var edit: HarnessConfigEdit {
        OpenCodePluginEdit.edit(configDirectory: directory, fileName: "tui.json", form: .tuiConfig, files: plugin)
    }

    private func pending(_ files: InMemoryHostFiles) async throws -> HarnessConfigPendingChange {
        let proposal = try await HarnessConfigEditor(files: files).propose(Self.edit)
        guard case .change(let change) = proposal else {
            Issue.record("expected a change, got \(proposal)")
            throw HarnessConfigEditError.unreadable
        }
        return change
    }

    private func applied(_ files: InMemoryHostFiles) async throws -> HarnessConfigAppliedEdit {
        try await HarnessConfigEditor(files: files).apply(try await pending(files))
    }

    @Test func proposingWritesNothing() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let change = try await pending(files)

        #expect(change.folder?.path == Self.folder)
        #expect(change.shownLines == [.init(kind: .added, text: #"  "plugin": ["./heeler-opencode"],"#, endsWithoutNewline: false)])
        #expect(await files.journal.isEmpty)
    }

    /// Exactly what was shown: the file with the one line, and the folder's files.
    @Test func acceptingWritesTheFolderFirstThenOnlyTheShownEntry() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let change = try await pending(files)

        let record = try await HarnessConfigEditor(files: files).apply(change)

        #expect(change.hunk.applied(to: Self.original) == Self.edited)
        #expect(await files.files[Self.config] == Self.edited)
        #expect(
            await files.journal == [
                "mkdir \(Self.folder)",
                "write \(Self.pluginPaths[0])", "write \(Self.pluginPaths[1])", "write \(Self.pluginPaths[2])",
                "write \(Self.config)",
            ])
        for file in Self.plugin {
            #expect(await files.files["\(Self.folder)/\(file.name)"] == file.contents)
        }
        #expect(record.folder == HarnessConfigAppliedFolder(path: Self.folder, fileNames: OpenCodePluginEdit.fileNames))
        #expect(record.listEntry == HarnessConfigListEntry(key: "plugin", value: "./heeler-opencode"))
    }

    @Test func aFileChangedSinceItWasReadIsRefusedWithNothingWritten() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let change = try await pending(files)
        await files.set(Self.config, Data("{ \"theme\": \"light\" }\n".utf8))

        await #expect(throws: HarnessConfigEditError.changedSinceRead) {
            try await HarnessConfigEditor(files: files).apply(change)
        }

        #expect(await files.files[Self.config] == Data("{ \"theme\": \"light\" }\n".utf8))
        #expect(await files.journal.isEmpty)
        #expect(await files.folders.isEmpty)
    }

    /// The window past the first comparison: the file changes once the folder is
    /// there, and the folder goes again.
    @Test func aFileChangedWhileTheFolderWentInTakesTheFolderBack() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let change = try await pending(files)
        let changed = Data("{ \"theme\": \"light\" }\n".utf8)
        await files.onReplace(of: Self.config) { await $0.set(Self.config, changed) }

        await #expect(throws: HarnessConfigEditError.changedSinceRead) {
            try await HarnessConfigEditor(files: files).apply(change)
        }

        #expect(await files.files == [Self.config: changed])
        #expect(await files.folders.isEmpty)
    }

    @Test func aFolderThatWouldNotGoInLeavesTheFileAlone() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let change = try await pending(files)
        await files.setFolderFailure(TransportError.hostFileTimedOut)

        await #expect(throws: TransportError.hostFileTimedOut) {
            try await HarnessConfigEditor(files: files).apply(change)
        }

        #expect(await files.files == [Self.config: Self.original])
    }

    /// What an interrupted attempt left is Heeler's own, and comes up to date.
    @Test func aLeftoverFolderIsBroughtUpToDate() async throws {
        let stale = "\(Self.folder)/tui.js"
        let files = InMemoryHostFiles(files: [Self.config: Self.original, stale: Data("old".utf8)])

        _ = try await applied(files)

        #expect(await files.files[stale] == Data("// tui.js\n".utf8))
    }

    @Test func undoRemovesTheEntryThenTheFolderAndRestoresTheFile() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        await files.clearJournal()

        try await HarnessConfigEditor(files: files).undo(record)

        #expect(await files.files == [Self.config: Self.original])
        #expect(await files.folders.isEmpty)
        #expect(
            await files.journal == [
                "write \(Self.config)",
                "remove \(Self.pluginPaths[0])", "remove \(Self.pluginPaths[1])", "remove \(Self.pluginPaths[2])",
                "rmdir \(Self.folder)",
            ])
    }

    @Test func undoOfAFileHeelerCreatedRemovesIt() async throws {
        let files = InMemoryHostFiles()
        let record = try await applied(files)
        #expect(record.createdFile)

        try await HarnessConfigEditor(files: files).undo(record)

        #expect(await files.files.isEmpty)
        #expect(await files.folders.isEmpty)
    }

    /// The user changed another setting since. The entry still comes out, and their
    /// change stays, against what undo read.
    @Test func undoOfAChangedFileTakesOnlyTheEntry() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        await files.set(
            Self.config, Data("{\n  \"plugin\": [\"./heeler-opencode\"],\n  \"theme\": \"light\"\n}\n".utf8))

        try await HarnessConfigEditor(files: files).undo(record)

        #expect(await files.files == [Self.config: Data("{\n  \"plugin\": [],\n  \"theme\": \"light\"\n}\n".utf8)])
        #expect(await files.folders.isEmpty)
    }

    @Test func undoWritesCompareAndSwapAgainstWhatItRead() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        let changedAgain = Data("{ \"theme\": \"light\" }\n".utf8)
        await files.onReplace(of: Self.config) { await $0.set(Self.config, changedAgain) }

        await #expect(throws: HarnessConfigEditError.changedSinceWritten) {
            try await HarnessConfigEditor(files: files).undo(record)
        }

        #expect(await files.files[Self.config] == changedAgain)
        // The entry didn't go, so neither does what it names.
        #expect(await files.folders.contains(Self.folder))
    }

    @Test func undoOfAFileItCantReadLeavesEverything() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        await files.set(Self.config, Data("broken {".utf8))

        await #expect(throws: HarnessConfigEditError.changedSinceWritten) {
            try await HarnessConfigEditor(files: files).undo(record)
        }

        #expect(await files.files[Self.config] == Data("broken {".utf8))
        #expect(await files.folders.contains(Self.folder))
    }

    @Test func undoWithTheEntryOrFileAlreadyGoneStillRemovesTheFolder() async throws {
        for leftover in [Self.original, nil] {
            let files = InMemoryHostFiles(files: [Self.config: Self.original])
            let record = try await applied(files)
            await files.set(Self.config, leftover)

            try await HarnessConfigEditor(files: files).undo(record)

            #expect(await files.folders.isEmpty)
            #expect(await files.files[Self.config] == leftover)
        }
    }

    /// Something of the user's that came to be in the folder stays, and the folder with it.
    @Test func aFileOfTheUsersKeepsTheFolder() async throws {
        let mine = "\(Self.folder)/notes.txt"
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        await files.set(mine, Data("mine".utf8))

        try await HarnessConfigEditor(files: files).undo(record)

        #expect(await files.files == [Self.config: Self.original, mine: Data("mine".utf8)])
        #expect(await files.folders.contains(Self.folder))
    }

    /// A folder step that failed leaves the entry gone, and undoing again finishes.
    @Test func undoingAgainFinishesAFolderThatFailed() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        await files.setFolderFailure(TransportError.hostFileTimedOut)

        await #expect(throws: TransportError.hostFileTimedOut) {
            try await HarnessConfigEditor(files: files).undo(record)
        }
        #expect(await files.files[Self.config] == Self.original)

        await files.setFolderFailure(nil)
        try await HarnessConfigEditor(files: files).undo(record)
        #expect(await files.files == [Self.config: Self.original])
        #expect(await files.folders.isEmpty)
    }

    /// The entry comes out first, so a refusal in the folder can't say nothing was written.
    @Test func aFolderFileChangedDuringUndoIsItsOwnRefusal() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let record = try await applied(files)
        let plugin = Self.pluginPaths[1]
        await files.onReplace(of: plugin) { await $0.set(plugin, Data("changed".utf8)) }

        await #expect(throws: HarnessConfigEditError.folderChangedDuringUndo) {
            try await HarnessConfigEditor(files: files).undo(record)
        }

        #expect(await files.files[Self.config] == Self.original)
        #expect(await files.folders.contains(Self.folder))
    }

    /// A record from before folders existed, as this device may hold for Grok Build.
    @Test func anOlderRecordStillDecodesAndUndoesAsItDid() async throws {
        let older = #"""
            {"id":"2F8B5A3E-9F39-4E7D-8E0B-6F7F2C9F8A11","editID":"grok-build.program-status","harness":"Grok Build",
            "path":"/x","hunk":{"offset":0,"removed":"","added":"YQo="},"createdFile":false,
            "writtenDigest":"AQ==","appliedAt":0}
            """#
        let record = try JSONDecoder().decode(HarnessConfigAppliedEdit.self, from: Data(older.utf8))
        #expect(record.folder == nil && record.listEntry == nil)

        let files = InMemoryHostFiles(files: ["/x": Data("a\n".utf8)])
        await #expect(throws: HarnessConfigEditError.changedSinceWritten) {
            try await HarnessConfigEditor(files: files).undo(record)
        }
        #expect(await files.journal.isEmpty)
    }
}
