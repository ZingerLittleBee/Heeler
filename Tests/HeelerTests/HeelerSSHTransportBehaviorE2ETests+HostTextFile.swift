import Foundation
import Testing

@testable import Heeler

/// `replaceHostTextFile` over real SFTP. `InMemoryHostFiles` does its own comparison,
/// so only these prove the Host service member refuses.
extension HeelerSSHTransportBehaviorE2ETests {
    @Test("a Host text file that no longer holds what was read is refused before anything is written")
    func hostTextFileRefusesAStaleRead() async throws {
        let host = try await HostTextFileHost.open()
        defer { Task { await host.close() } }
        let theirs = Data("them\n".utf8)
        let ours = Data("ours\n".utf8)
        #expect(theirs.count == ours.count)
        try await host.seed("config.toml", theirs, mode: "640")
        // Nothing can be created here, so a comparison that only came after trying
        // to write would surface as a write failure and not as this refusal.
        try await host.makeDirectoryReadOnly()
        let config = host.path("config.toml")
        let replacements: [(path: String, expected: Data?, contents: Data?)] = [
            (config, ours, Data("new\n".utf8)),
            (config, Data("a different size\n".utf8), Data("new\n".utf8)),
            (config, nil, Data("new\n".utf8)),
            (config, ours, nil),
            (host.path("absent.toml"), ours, Data("new\n".utf8)),
            (host.path("absent.toml"), ours, nil),
        ]

        for replacement in replacements {
            await #expect(throws: HostTextFileError.changedSinceRead) {
                try await host.transport.replaceHostTextFile(
                    path: replacement.path, expected: replacement.expected, contents: replacement.contents)
            }
        }

        #expect(try await host.contents("config.toml") == theirs)
        #expect(try await host.listing("config.toml") == "-rw-r-----")
        #expect(try await host.entries() == ["config.toml"])
    }

    @Test("a Host text file changed while the new bytes are written is refused at the rename")
    func hostTextFileRefusesAChangeDuringTheWrite() async throws {
        let host = try await HostTextFileHost.open()
        defer { Task { await host.close() } }
        let ours = Data("ours\n".utf8)
        let theirs = Data("them\n".utf8)
        try await host.seed("config.toml", ours, mode: "640")

        try await host.expectRefusalAtTheRename(
            of: "config.toml", expected: ours, changedTo: theirs, mode: "640")
        #expect(try await host.entries() == ["config.toml"])

        // Read as absent, and created by someone else while Heeler wrote.
        try await host.expectRefusalAtTheRename(
            of: "appeared.toml", expected: nil, changedTo: theirs, mode: "644")
        #expect(try await host.entries() == ["appeared.toml", "config.toml"])
    }

    @Test("a harness edit over SFTP writes what was shown, and its undo restores the file and its mode")
    func harnessEditWritesAndUndoesOverSFTP() async throws {
        let host = try await HostTextFileHost.open()
        defer { Task { await host.close() } }
        let original = Data("[agent]\nname = \"a\"\n".utf8)
        let edited = Data("[agent]\nname = \"a\"\n\n[ui.notifications]\nprogram_status = \"on\"\n".utf8)
        try await host.seed("config.toml", original, mode: "640")
        let editor = HarnessConfigEditor(files: host.transport)
        let edit = GrokBuildProgramStatusEdit.edit(path: host.path("config.toml"))

        let change = try await host.pendingChange(editor, edit)
        #expect(change.after == edited)
        #expect(try await host.contents("config.toml") == original)

        let applied = try await editor.apply(change)
        #expect(try await host.contents("config.toml") == edited)
        #expect(try await host.listing("config.toml") == "-rw-r-----")
        #expect(try await host.entries() == ["config.toml"])

        try await editor.undo(applied)
        #expect(try await host.contents("config.toml") == original)
        #expect(try await host.listing("config.toml") == "-rw-r-----")
        #expect(try await host.entries() == ["config.toml"])

        // The refusals the user reads, from the real member.
        let stale = try await host.pendingChange(editor, edit)
        let theirs = Data("# theirs\n".utf8)
        try await host.seed("config.toml", theirs, mode: "640")
        await #expect(throws: HarnessConfigEditError.changedSinceRead) {
            _ = try await editor.apply(stale)
        }
        #expect(try await host.contents("config.toml") == theirs)

        let fresh = try await host.pendingChange(editor, edit)
        let reapplied = try await editor.apply(fresh)
        let appended = fresh.after + Data("# mine\n".utf8)
        try await host.seed("config.toml", appended, mode: "640")
        await #expect(throws: HarnessConfigEditError.changedSinceWritten) {
            try await editor.undo(reapplied)
        }
        #expect(try await host.contents("config.toml") == appended)
        #expect(try await host.entries() == ["config.toml"])
    }

    /// The folder steps, which go over exec, beside the file's over SFTP.
    @Test("a harness edit with a folder places it first, and its undo takes the entry and then the folder")
    func harnessEditPlacesAndRemovesItsFolderOverTheHost() async throws {
        let host = try await HostTextFileHost.open()
        defer { Task { await host.close() } }
        let original = Data("{\n  \"theme\": \"dark\"\n}\n".utf8)
        try await host.seed("tui.json", original, mode: "640")
        let editor = HarnessConfigEditor(files: host.transport)
        let edit = OpenCodePluginEdit.edit(
            configDirectory: host.directory, fileName: "tui.json", form: .tuiConfig,
            files: OpenCodePluginEdit.fileNames.map { .init(name: $0, contents: Data("// \($0)\n".utf8)) })

        let change = try await host.pendingChange(editor, edit)
        #expect(try await host.entries() == ["tui.json"])

        let applied = try await editor.apply(change)
        #expect(try await host.entries() == ["heeler-opencode", "tui.json"])
        #expect(try await host.contents("heeler-opencode/tui.js") == Data("// tui.js\n".utf8))
        #expect(try await host.listing("heeler-opencode") == "drwx------")
        #expect(
            try await host.contents("tui.json")
                == Data("{\n  \"plugin\": [\"./heeler-opencode\"],\n  \"theme\": \"dark\"\n}\n".utf8))

        // A file of the user's keeps the folder, and undoing again takes it once it goes.
        try await host.seed("heeler-opencode/notes", Data("mine".utf8), mode: "600")
        try await editor.undo(applied)
        #expect(try await host.contents("tui.json") == original)
        #expect(try await host.listing("tui.json") == "-rw-r-----")
        #expect(try await host.shell("ls -A \"$d/heeler-opencode\"") == "notes\n")

        try await host.shell("rm \"$d/heeler-opencode/notes\"")
        try await editor.undo(applied)
        #expect(try await host.entries() == ["tui.json"])
        #expect(try await host.contents("tui.json") == original)

        // A file changed between the first comparison and the file's write takes the folder back.
        let stale = try await host.pendingChange(editor, edit)
        let theirs = Data("{ \"theme\": \"light\" }\n".utf8)
        try await host.seed("tui.json", theirs, mode: "640")
        await #expect(throws: HarnessConfigEditError.changedSinceRead) {
            _ = try await editor.apply(stale)
        }
        #expect(try await host.entries() == ["tui.json"])
        #expect(try await host.contents("tui.json") == theirs)
    }

    @Test("a harness edit over SFTP keeps a link a link, and removes the file it created")
    func harnessEditFollowsALinkAndCreatesAFileOverSFTP() async throws {
        let host = try await HostTextFileHost.open()
        defer { Task { await host.close() } }
        let original = Data("[agent]\nname = \"a\"\n".utf8)
        let edited = Data("[agent]\nname = \"a\"\n\n[ui.notifications]\nprogram_status = \"on\"\n".utf8)
        let editor = HarnessConfigEditor(files: host.transport)

        try await host.seed("target.toml", original, mode: "604")
        try await host.shell("ln -s target.toml \"$d/link.toml\"")
        let viaLink = try await host.pendingChange(
            editor, GrokBuildProgramStatusEdit.edit(path: host.path("link.toml")))
        let appliedViaLink = try await editor.apply(viaLink)
        #expect(try await host.contents("target.toml") == edited)
        #expect(try await host.listing("link.toml").hasPrefix("l"))
        #expect(try await host.listing("target.toml") == "-rw----r--")
        try await editor.undo(appliedViaLink)
        #expect(try await host.contents("target.toml") == original)
        #expect(try await host.listing("link.toml").hasPrefix("l"))
        #expect(try await host.listing("target.toml") == "-rw----r--")
        #expect(try await host.entries() == ["link.toml", "target.toml"])

        let created = try await host.pendingChange(
            editor, GrokBuildProgramStatusEdit.edit(path: host.path("absent.toml")))
        #expect(created.createsFile)
        let appliedCreate = try await editor.apply(created)
        #expect(try await host.contents("absent.toml") == created.after)
        #expect(try await host.listing("absent.toml") == "-rw-------")
        try await editor.undo(appliedCreate)
        #expect(try await host.contents("absent.toml") == nil)
        #expect(try await host.entries() == ["link.toml", "target.toml"])
    }
}

/// One test's directory on the fixture Host, the connection under test, and a second
/// connection that plays whoever else changes the file.
private struct HostTextFileHost {
    let transport: HeelerSSHTransport
    let outside: HeelerSSHTransport
    let directory: String

    static func open() async throws -> HostTextFileHost {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let host = HostTextFileHost(
            transport: try await HeelerSSHTransport.connect(settings: environment.directSettings()),
            outside: try await HeelerSSHTransport.connect(settings: environment.directSettings()),
            directory: "\(environment.homePath)/.heeler-ci/host-text-\(UUID().uuidString.lowercased())")
        try await host.shell("mkdir -p \"$d\"")
        return host
    }

    func close() async {
        _ = try? await shell("chmod -R u+rwx \"$d\"; rm -rf \"$d\"")
        try? await transport.close()
        try? await outside.close()
    }

    func path(_ name: String) -> String {
        "\(directory)/\(name)"
    }

    /// One script on the Host, with `$d` the test's directory. Its stdout.
    @discardableResult
    func shell(_ script: String) async throws -> String {
        let quoted = try #require(RemoteShellPath.quotedAbsolute(directory))
        let result = try await outside.runGitScript(Data("{\nd=\(quoted)\n\(script)\n} </dev/null\n".utf8))
        try #require(
            result.exitStatus == 0,
            "\(script) failed: \(String(decoding: result.stderr, as: UTF8.self))")
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Whoever else writes, in place, the way an editor without a temporary file does.
    func seed(_ name: String, _ contents: Data, mode: String) async throws {
        let text = String(decoding: contents, as: UTF8.self)
        try #require(!text.contains("'"))
        try await shell("""
            f="$d/\(name)"
            printf '%s' '\(text)' > "$f"
            chmod \(mode) "$f"
            """)
    }

    func makeDirectoryReadOnly() async throws {
        try await shell("chmod 500 \"$d\"")
        // A fixture that ignored the mode would prove nothing.
        let probe = try await shell("if touch \"$d/.probe\" 2>/dev/null; then echo writable; else echo refused; fi")
        try #require(probe.contains("refused"))
    }

    func contents(_ name: String) async throws -> Data? {
        try await outside.readRemoteFileForTesting(at: path(name))
    }

    /// The type and mode `ls -l` shows.
    func listing(_ name: String) async throws -> String {
        String(try await shell("ls -ld \"$d/\(name)\"").prefix(10))
    }

    /// Everything in the directory, dotfiles included, sorted.
    func entries() async throws -> [String] {
        try await shell("ls -A \"$d\"").split(separator: "\n").map(String.init).sorted()
    }

    func pendingChange(
        _ editor: HarnessConfigEditor, _ edit: HarnessConfigEdit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> HarnessConfigPendingChange {
        let proposal = try await editor.propose(edit)
        guard case .change(let change) = proposal else {
            Issue.record("expected a change, got \(proposal)", sourceLocation: sourceLocation)
            throw TransportError.cancelled
        }
        return change
    }

    /// The first comparison has passed once the write is under way, so this change
    /// is one only the comparison before the rename can see.
    func expectRefusalAtTheRename(
        of name: String, expected: Data?, changedTo theirs: Data, mode: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        await transport.delayNextNotificationSFTPWriteForTesting(.seconds(5))
        let replace = Task {
            try await transport.replaceHostTextFile(
                path: path(name), expected: expected, contents: Data("new\n".utf8))
        }
        let deadline = ContinuousClock.now + .seconds(3)
        var state = await transport.notificationFileStateForTesting()
        while !state.writeIsDelayed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            state = await transport.notificationFileStateForTesting()
        }
        try #require(state.writeIsDelayed, sourceLocation: sourceLocation)
        // The temporary file is really there, so its absence afterwards says something.
        let during = try await entries()
        #expect(
            during.contains { $0.hasPrefix("\(name).heeler-") }, "\(during)", sourceLocation: sourceLocation)

        try await seed(name, theirs, mode: mode)
        let written = try await contents(name)
        let stillDelayed = await transport.notificationFileStateForTesting().writeIsDelayed
        try #require(stillDelayed, "the outside change must land during the write", sourceLocation: sourceLocation)

        await #expect(throws: HostTextFileError.changedSinceRead, sourceLocation: sourceLocation) {
            try await replace.value
        }
        #expect(written == theirs, sourceLocation: sourceLocation)
        #expect(try await contents(name) == theirs, sourceLocation: sourceLocation)
        let settled = await transport.notificationFileStateForTesting()
        #expect(settled.temporaryPaths.isEmpty, sourceLocation: sourceLocation)
    }
}
