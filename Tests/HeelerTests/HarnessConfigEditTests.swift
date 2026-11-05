import Foundation
import Testing

@testable import Heeler

/// The one module harness configuration edits go through (ADR 0033), through a
/// made-up edit: what is shown is what is written, nothing is written before the
/// user's word, and undo restores the file byte for byte.
@Suite struct HarnessConfigEditTests {
    private static let path = "/home/dev/.tool/config"
    private static let original = Data("alpha\nsecret = \"t0ken\"\n\nomega\n".utf8)
    private static let edited = Data("alpha\nsecret = \"t0ken\"\nadded = 1\n\nomega\n".utf8)

    private static func edit(to after: Data = edited) -> HarnessConfigEdit {
        HarnessConfigEdit(id: "tool.setting", harness: "Tool", path: path) { _ in .change(to: after) }
    }

    private func pending(
        _ files: InMemoryHostFiles, edit: HarnessConfigEdit = edit()
    ) async throws -> HarnessConfigPendingChange {
        let proposal = try await HarnessConfigEditor(files: files).propose(edit)
        guard case .change(let change) = proposal else {
            Issue.record("expected a change, got \(proposal)")
            throw HarnessConfigEditError.unreadable
        }
        return change
    }

    @Test func proposingWritesNothing() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        _ = try await pending(files)
        #expect(await files.replaceCalls == 0)
        #expect(await files.files[Self.path] == Self.original)
    }

    @Test func theShownChangeIsExactlyWhatGetsWritten() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let change = try await pending(files)

        #expect(
            change.shownLines == [.init(kind: .added, text: "added = 1", endsWithoutNewline: false)])
        // The hunk the screen is drawn from makes the file, from what was read.
        #expect(change.hunk.applied(to: Self.original) == Self.edited)

        _ = try await HarnessConfigEditor(files: files).apply(change)
        #expect(await files.writes == [.init(path: Self.path, contents: Self.edited)])
    }

    @Test func aChangedLineShowsBothSides() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Data("a\nb = 1 # c\nd\n".utf8)])
        let change = try await pending(files, edit: Self.edit(to: Data("a\nb = 2 # c\nd\n".utf8)))
        #expect(
            change.shownLines == [
                .init(kind: .removed, text: "b = 1 # c", endsWithoutNewline: false),
                .init(kind: .added, text: "b = 2 # c", endsWithoutNewline: false),
            ])
    }

    @Test func aMissingLastNewlineIsPartOfTheChange() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Data("a\nb".utf8)])
        let change = try await pending(files, edit: Self.edit(to: Data("a\nb\nc\n".utf8)))
        #expect(
            change.shownLines == [
                .init(kind: .removed, text: "b", endsWithoutNewline: true),
                .init(kind: .added, text: "b", endsWithoutNewline: false),
                .init(kind: .added, text: "c", endsWithoutNewline: false),
            ])
    }

    @Test func undoRestoresTheFileExactly() async throws {
        // No last newline, a blank line and CRLF, none of them normalized.
        let before = Data("a\r\n\r\n  b \t\n\nc".utf8)
        let after = Data("a\r\n\r\nnew\r\n  b \t\n\nc".utf8)
        let files = InMemoryHostFiles(files: [Self.path: before])
        let editor = HarnessConfigEditor(files: files)
        let applied = try await editor.apply(try await pending(files, edit: Self.edit(to: after)))
        #expect(await files.files[Self.path] == after)

        try await editor.undo(applied)
        #expect(await files.files[Self.path] == before)
    }

    @Test func undoOfACreatedFileRemovesIt() async throws {
        let files = InMemoryHostFiles()
        let editor = HarnessConfigEditor(files: files)
        let change = try await pending(files)
        #expect(change.createsFile)
        let applied = try await editor.apply(change)
        #expect(await files.files[Self.path] == Self.edited)

        try await editor.undo(applied)
        #expect(await files.files[Self.path] == nil)
    }

    /// The file may carry a harness's tokens, and this goes in device storage.
    @Test func whatIsRememberedHoldsOnlyTheChangedBytes() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let applied = try await HarnessConfigEditor(files: files).apply(try await pending(files))
        #expect(applied.hunk.removed.isEmpty)
        #expect(applied.hunk.added == Data("added = 1\n".utf8))
        let stored = try JSONEncoder().encode(applied)
        #expect(try JSONDecoder().decode(HarnessConfigAppliedEdit.self, from: stored) == applied)
    }

    /// A file with no last newline: appending adds one to its last line, which
    /// reads as a change of that line and may be where a token sits.
    @Test func whatIsRememberedLeavesOutALastLineWithNoNewline() async throws {
        let original = Data("[agent]\nsecret = \"t0ken\"".utf8)
        let files = InMemoryHostFiles(files: [Self.path: original])
        let editor = HarnessConfigEditor(files: files)
        let edit = HarnessConfigEdit(id: "a", harness: "Tool", path: Self.path) { before in
            var after = before ?? Data()
            after.append(Data("\n\n[ui]\nx = 1\n".utf8))
            return .change(to: after)
        }
        let token = Data("t0ken".utf8)

        let applied = try await editor.apply(try await pending(files, edit: edit))

        #expect(applied.hunk.removed.isEmpty)
        #expect(applied.hunk.added.range(of: token) == nil)
        #expect(applied.hunk.added == Data("\n\n[ui]\nx = 1\n".utf8))
        let stored = try JSONEncoder().encode(applied)
        #expect(try JSONDecoder().decode(HarnessConfigAppliedEdit.self, from: stored).hunk == applied.hunk)

        try await editor.undo(applied)
        #expect(await files.files[Self.path] == original)
    }

    // MARK: Compare and swap

    @Test func applyRefusesWhenTheFileChangedAfterItWasRead() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let editor = HarnessConfigEditor(files: files)
        let change = try await pending(files)
        let theirs = Data("theirs\n".utf8)
        await files.set(Self.path, theirs)

        await #expect(throws: HarnessConfigEditError.changedSinceRead) { _ = try await editor.apply(change) }
        #expect(await files.files[Self.path] == theirs)
        #expect(await files.writes.isEmpty)
    }

    @Test func applyRefusesWhenAFileAppearedAfterNoneWasRead() async throws {
        let files = InMemoryHostFiles()
        let editor = HarnessConfigEditor(files: files)
        let change = try await pending(files)
        await files.set(Self.path, Data())

        await #expect(throws: HarnessConfigEditError.changedSinceRead) { _ = try await editor.apply(change) }
        #expect(await files.files[Self.path] == Data())
    }

    @Test func undoRefusesWhenTheFileChangedAfterHeelerWroteIt() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let editor = HarnessConfigEditor(files: files)
        let applied = try await editor.apply(try await pending(files))
        let theirs = Self.edited + Data("mine = 2\n".utf8)
        await files.set(Self.path, theirs)

        await #expect(throws: HarnessConfigEditError.changedSinceWritten) { try await editor.undo(applied) }
        #expect(await files.files[Self.path] == theirs)
        #expect(await files.writes.count == 1)
    }

    @Test func undoRefusesWhenTheFileIsGone() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let editor = HarnessConfigEditor(files: files)
        let applied = try await editor.apply(try await pending(files))
        await files.set(Self.path, nil)

        await #expect(throws: HarnessConfigEditError.changedSinceWritten) { try await editor.undo(applied) }
        #expect(await files.files[Self.path] == nil)
    }

    @Test func undoRefusesWhenTheFileChangesBetweenItsReadAndItsWrite() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let editor = HarnessConfigEditor(files: files)
        let applied = try await editor.apply(try await pending(files))
        let theirs = Data("theirs\n".utf8)
        await files.onNextReplace { await $0.set(Self.path, theirs) }

        await #expect(throws: HarnessConfigEditError.changedSinceWritten) { try await editor.undo(applied) }
        #expect(await files.files[Self.path] == theirs)
    }

    @Test func theUserIsToldWhy() {
        #expect(
            HarnessConfigEditError.changedSinceRead.errorDescription
                == "The file changed after Heeler read it, so nothing was written. Review the change again.")
        #expect(
            HarnessConfigEditError.changedSinceWritten.errorDescription
                == "The file changed after Heeler edited it, so nothing was written. Undo the edit by hand if you still want to.")
    }

    // MARK: What an edit can answer

    @Test func anEditAlreadyMadeOrRefusedProposesNoChange() async throws {
        let files = InMemoryHostFiles(files: [Self.path: Self.original])
        let editor = HarnessConfigEditor(files: files)
        let done = HarnessConfigEdit(id: "a", harness: "Tool", path: Self.path) { _ in .alreadyApplied }
        let no = HarnessConfigEdit(id: "a", harness: "Tool", path: Self.path) { _ in .refused(reason: "No.") }
        #expect(try await editor.propose(done) == .alreadyApplied(path: Self.path))
        #expect(try await editor.propose(no) == .refused(path: Self.path, reason: "No.", manualInstruction: nil))
    }

    @Test func aFilePastTheLimitIsRefused() async throws {
        let big = Data(repeating: 0x61, count: HarnessConfigEditor.maximumFileSize + 1)
        let files = InMemoryHostFiles(files: [Self.path: big])
        await #expect(throws: HarnessConfigEditError.tooLarge) {
            _ = try await HarnessConfigEditor(files: files).propose(Self.edit())
        }
    }

    @Test func aHostWithoutFilesWritesNothingAndSaysSo() async throws {
        struct Bare: HostServices {}
        await #expect(
            throws: TransportError.hostFeatureUnavailable(feature: "Editing Host files")
        ) {
            try await Bare().replaceHostTextFile(path: Self.path, expected: nil, contents: Data())
        }
    }

    // MARK: Grok Build end to end

    @Test func theGrokBuildEditWritesAndUndoesThroughTheModule() async throws {
        let before = Data("[ui.notifications]\nmethod = \"auto\"\n".utf8)
        let path = "/home/dev/.grok/config.toml"
        let files = InMemoryHostFiles(files: [path: before])
        let editor = HarnessConfigEditor(files: files)
        let change = try await pending(files, edit: GrokBuildProgramStatusEdit.edit(path: path))
        #expect(
            change.shownLines == [
                .init(kind: .added, text: #"program_status = "on""#, endsWithoutNewline: false)
            ])
        let applied = try await editor.apply(change)
        #expect(
            await files.files[path]
                == Data("[ui.notifications]\nprogram_status = \"on\"\nmethod = \"auto\"\n".utf8))
        try await editor.undo(applied)
        #expect(await files.files[path] == before)
    }
}
