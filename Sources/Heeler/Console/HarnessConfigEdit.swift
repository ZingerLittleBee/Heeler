import CryptoKit
import Foundation

/// A harness configuration file changes only when the user accepts that one
/// change, shown exactly, and every such change can be undone (ADR 0033). This is
/// the one module those edits go through: an edit says what it wants the file to
/// become, and this reads, shows, writes and undoes.
struct HarnessConfigEdit: Sendable {
    /// What a file's bytes, or their absence, want to become.
    enum Transform: Equatable, Sendable {
        case change(to: Data)
        case alreadyApplied
        /// `manualInstruction` says what to do by hand when this file's case differs
        /// from the edit's own.
        case refused(reason: String, manualInstruction: String? = nil)
    }

    /// Stable across launches, for what the Host's detail lists.
    let id: String
    let harness: String
    let path: String
    let transform: @Sendable (Data?) -> Transform
    /// A folder of Heeler's own that the change names, placed before the file
    /// says so and removed after it no longer does.
    var folder: HarnessConfigFolder? = nil
    /// The list entry the change is, so undoing can take it out of a file the user
    /// has changed since. Without one, undoing needs the file as Heeler left it.
    var listEntry: HarnessConfigListEntry? = nil
    /// What to do by hand where Heeler won't change this file. It says what this
    /// edit would have written, so it goes with the edit.
    var manualInstruction: String? = nil
    /// What the edit still won't bring on the release it's for, said before the user
    /// agrees and after.
    var limitation: String? = nil
}

/// A folder of Heeler's own beside a harness's configuration, with what goes in it.
struct HarnessConfigFolder: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let name: String
        let contents: Data
    }

    let path: String
    let files: [File]

    func filePath(_ name: String) -> String { RemoteFilePath.join(path, name) }
    var filePaths: [String] { files.map { filePath($0.name) } }
}

/// What this device remembers of such a folder, to remove it again.
struct HarnessConfigAppliedFolder: Codable, Equatable, Sendable {
    let path: String
    let fileNames: [String]

    var filePaths: [String] { fileNames.map { RemoteFilePath.join(path, $0) } }
}

/// One contiguous run of bytes that differs, cut at whole lines. Holds only what
/// changed, so what this device keeps of an edit holds nothing else of the file,
/// which may carry a harness's tokens.
struct HarnessConfigHunk: Codable, Equatable, Sendable {
    let offset: Int
    let removed: Data
    let added: Data

    init(before: Data, after: Data) {
        let old = Self.lines(before)
        let new = Self.lines(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        offset = old[..<prefix].reduce(0) { $0 + $1.count }
        removed = Data(old[prefix..<(old.count - suffix)].joined())
        added = Data(new[prefix..<(new.count - suffix)].joined())
    }

    private init(offset: Int, removed: Data, added: Data) {
        self.offset = offset
        self.removed = removed
        self.added = added
    }

    /// What this device keeps of the change. Writing after a last line with no
    /// newline reads as changing that line, though its bytes stay, so they are
    /// left out: `reverted(from:)` still restores the file byte for byte.
    var remembered: HarnessConfigHunk {
        guard !removed.isEmpty, removed.last != UInt8(ascii: "\n"), added.starts(with: removed) else {
            return self
        }
        return HarnessConfigHunk(
            offset: offset + removed.count, removed: Data(), added: Data(added.dropFirst(removed.count)))
    }

    /// `base` with this change made.
    func applied(to base: Data) -> Data {
        var result = base.prefix(offset)
        result.append(added)
        result.append(base.dropFirst(offset + removed.count))
        return Data(result)
    }

    /// `base`, which holds this change, as it was before it.
    func reverted(from base: Data) -> Data {
        var result = base.prefix(offset)
        result.append(removed)
        result.append(base.dropFirst(offset + added.count))
        return Data(result)
    }

    /// Each line with its terminator.
    static func lines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == UInt8(ascii: "\n") {
            lines.append(Data(data[start...index]))
            start = data.index(after: index)
        }
        if start < data.endIndex { lines.append(Data(data[start...])) }
        return lines
    }
}

/// The lines a change shows: exactly what goes away and what comes, nothing around them.
struct HarnessConfigShownLine: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case removed
        case added
    }

    let kind: Kind
    /// Without its terminator.
    let text: String
    /// The file's last line, with no newline. Adding one is a change too.
    let endsWithoutNewline: Bool

    static func lines(of hunk: HarnessConfigHunk) -> [HarnessConfigShownLine] {
        shown(hunk.removed, as: .removed) + shown(hunk.added, as: .added)
    }

    private static func shown(_ data: Data, as kind: Kind) -> [HarnessConfigShownLine] {
        HarnessConfigHunk.lines(data).map { line in
            var bytes = line[...]
            let endsWithNewline = bytes.last == UInt8(ascii: "\n")
            if endsWithNewline { bytes = bytes.dropLast() }
            if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
            return HarnessConfigShownLine(
                kind: kind, text: String(decoding: bytes, as: UTF8.self),
                endsWithoutNewline: !endsWithNewline)
        }
    }
}

/// An edit read and waiting for the user's word: the bytes it read, the bytes it
/// would write, and the change between them, which is what the user sees.
struct HarnessConfigPendingChange: Equatable, Sendable {
    let editID: String
    let harness: String
    let path: String
    /// Nil when there is no file yet.
    let before: Data?
    let after: Data
    var folder: HarnessConfigFolder? = nil
    var listEntry: HarnessConfigListEntry? = nil

    var hunk: HarnessConfigHunk { HarnessConfigHunk(before: before ?? Data(), after: after) }
    var shownLines: [HarnessConfigShownLine] { HarnessConfigShownLine.lines(of: hunk) }
    var createsFile: Bool { before == nil }
}

/// What this device remembers of an edit it wrote, to list it and undo it.
struct HarnessConfigAppliedEdit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let editID: String
    let harness: String
    let path: String
    let hunk: HarnessConfigHunk
    /// Heeler created the file, so undoing removes it.
    let createdFile: Bool
    /// What Heeler wrote. Undo touches a file only while it still holds this.
    let writtenDigest: Data
    let appliedAt: Date
    var folder: HarnessConfigAppliedFolder? = nil
    var listEntry: HarnessConfigListEntry? = nil

    var shownLines: [HarnessConfigShownLine] { HarnessConfigShownLine.lines(of: hunk) }

    /// Files besides its own that the harness itself may come to name its folder
    /// in, which its folder's last undo cleans before the folder goes.
    var otherListings: [HarnessConfigListing] {
        guard editID == OpenCodePluginEdit.id, let folder else { return [] }
        return OpenCodePluginEdit.listings(of: folder.path).filter { $0.path != path }
    }
}

/// A file whose list may name a folder of Heeler's, and the entry that would.
struct HarnessConfigListing: Equatable, Sendable {
    let path: String
    let entry: HarnessConfigListEntry
}

enum HarnessConfigProposal: Equatable, Sendable {
    case change(HarnessConfigPendingChange)
    /// The file already says this, so nothing is left to write.
    case alreadyApplied(path: String)
    case refused(path: String, reason: String, manualInstruction: String?)
}

/// A refusal the user is told about, with nothing written.
enum HarnessConfigEditError: Error, Equatable, LocalizedError {
    case changedSinceRead
    case changedSinceWritten
    case tooLarge
    case unreadable
    case unresolvedPath
    case agentEnvironmentUnavailable
    case openCodeVersionUnknown
    /// The file no longer names the folder by then, so this can't say nothing was written:
    /// a file in the folder, or another that names it, changed while it was going.
    case folderChangedDuringUndo

    var errorDescription: String? {
        switch self {
        case .changedSinceRead:
            "The file changed after Heeler read it, so nothing was written. Review the change again."
        case .changedSinceWritten:
            "The file changed after Heeler edited it, so nothing was written. Undo the edit by hand if you still want to."
        case .tooLarge:
            "The file is too large for Heeler to edit, so nothing was written."
        case .unreadable:
            "Heeler couldn't read the whole file, so nothing was written."
        case .unresolvedPath:
            "This Agent's configuration folder isn't an absolute path, so Heeler can't tell which file to change."
        case .agentEnvironmentUnavailable:
            "Heeler couldn't read this Agent's environment, so it can't tell which file to change. Nothing was written."
        case .openCodeVersionUnknown:
            "Heeler couldn't read which OpenCode this Agent runs, so it can't tell which file to change. Nothing was written. \(OpenCodePluginEdit.manualInstructionForEitherRelease)"
        case .folderChangedDuringUndo:
            "Heeler took its change out of the file, but a file changed while Heeler was removing its folder, so the folder stays. Undo again to finish."
        }
    }
}

/// Reads, writes and undoes harness edits over a Host's services.
struct HarnessConfigEditor: Sendable {
    /// A configuration file past this is no file Heeler should be rewriting.
    static let maximumFileSize = 1_048_576

    let files: any HostServices
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUID() }
    /// Folders another applied edit's file still names, which this one leaves in
    /// place: two files can name the one folder, after an upgrade for one.
    var foldersInUse: Set<String> = []

    /// Reads the file and works out the change. Writes nothing.
    func propose(_ edit: HarnessConfigEdit) async throws -> HarnessConfigProposal {
        let before = try await read(edit.path)
        switch edit.transform(before) {
        case .alreadyApplied:
            return .alreadyApplied(path: edit.path)
        case .refused(let reason, let manualInstruction):
            return .refused(
                path: edit.path, reason: reason, manualInstruction: manualInstruction ?? edit.manualInstruction)
        case .change(let after):
            return .change(
                HarnessConfigPendingChange(
                    editID: edit.id, harness: edit.harness, path: edit.path, before: before,
                    after: after, folder: edit.folder, listEntry: edit.listEntry))
        }
    }

    /// Writes exactly what was shown, if the file still holds what was read. A
    /// folder goes first, so the file never names one that isn't there, and comes
    /// away again if the file turns out to have changed.
    func apply(_ change: HarnessConfigPendingChange) async throws -> HarnessConfigAppliedEdit {
        if let folder = change.folder {
            guard try await read(change.path) == change.before else {
                throw HarnessConfigEditError.changedSinceRead
            }
            do {
                try await place(folder)
            } catch {
                await takeBack(folder)
                throw error
            }
        }
        do {
            try await files.replaceHostTextFile(
                path: change.path, expected: change.before, contents: change.after)
        } catch HostTextFileError.changedSinceRead {
            if let folder = change.folder { await takeBack(folder) }
            throw HarnessConfigEditError.changedSinceRead
        }
        return record(of: change)
    }

    /// What a leftover from an earlier attempt holds gets replaced, against what was read.
    private func place(_ folder: HarnessConfigFolder) async throws {
        try await files.createHostFolder(path: folder.path)
        for file in folder.files {
            let path = folder.filePath(file.name)
            let existing = try await read(path)
            guard existing != file.contents else { continue }
            try await files.replaceHostTextFile(path: path, expected: existing, contents: file.contents)
        }
    }

    /// Only for a folder this attempt placed and the file doesn't name. Whatever
    /// this can't remove stays, unnamed and doing nothing.
    private func takeBack(_ folder: HarnessConfigFolder) async {
        guard !foldersInUse.contains(folder.path) else { return }
        try? await remove(HarnessConfigAppliedFolder(path: folder.path, fileNames: folder.files.map(\.name)))
    }

    /// Its listed files, and then the folder if nothing else has come to be in it.
    private func remove(_ folder: HarnessConfigAppliedFolder) async throws {
        for path in folder.filePaths {
            guard let existing = try await read(path) else { continue }
            try await files.replaceHostTextFile(path: path, expected: existing, contents: nil)
        }
        try await files.removeEmptyHostFolder(path: folder.path)
    }

    /// What a write whose answer never came would have been, if the file now
    /// holds it. Nil if it holds anything else.
    func record(ofWritten change: HarnessConfigPendingChange) async throws -> HarnessConfigAppliedEdit? {
        guard try await read(change.path) == change.after else {
            if let folder = change.folder { await takeBack(folder) }
            return nil
        }
        return record(of: change)
    }

    private func record(of change: HarnessConfigPendingChange) -> HarnessConfigAppliedEdit {
        HarnessConfigAppliedEdit(
            id: makeID(), editID: change.editID, harness: change.harness, path: change.path,
            hunk: change.hunk.remembered, createdFile: change.createsFile,
            writtenDigest: Self.digest(change.after), appliedAt: now(),
            folder: change.folder.map { folder in
                HarnessConfigAppliedFolder(path: folder.path, fileNames: folder.files.map(\.name))
            },
            listEntry: change.listEntry)
    }

    /// Puts the file back exactly as it was, if it still holds what Heeler wrote.
    /// An edit that is one list entry can also take that entry out of a file changed
    /// since, against what it read now. Its folder goes after the entry, so a failure
    /// in between leaves a folder nothing names, and undoing again finishes the job.
    func undo(_ applied: HarnessConfigAppliedEdit) async throws {
        let current = try await read(applied.path)
        do {
            if let current, Self.digest(current) == applied.writtenDigest {
                try await files.replaceHostTextFile(
                    path: applied.path, expected: current,
                    contents: applied.createdFile ? nil : applied.hunk.reverted(from: current))
            } else if let entry = applied.listEntry {
                if let current { try await removeEntry(entry, of: applied.path, holding: current) }
            } else {
                throw HarnessConfigEditError.changedSinceWritten
            }
        } catch HostTextFileError.changedSinceRead {
            throw HarnessConfigEditError.changedSinceWritten
        }
        guard let folder = applied.folder, !foldersInUse.contains(folder.path) else { return }
        do {
            for listing in applied.otherListings { try await takeOut(listing) }
            try await remove(folder)
        } catch HostTextFileError.changedSinceRead, HarnessConfigEditError.tooLarge, HarnessConfigEditError.unreadable {
            throw HarnessConfigEditError.folderChangedDuringUndo
        }
    }

    /// The entry, from a file that holds it and that this can read with
    /// certainty. A harness that writes the file between the read and the write
    /// gets one more read; past that the folder stays, so nothing names one that
    /// isn't there.
    private func takeOut(_ listing: HarnessConfigListing) async throws {
        for attempt in 1...2 {
            let current: Data?
            do {
                current = try await read(listing.path)
            } catch HarnessConfigEditError.tooLarge, HarnessConfigEditError.unreadable {
                return
            }
            guard let current, case .changed(let after) = HarnessConfigJSONCList.removing(listing.entry, from: current)
            else { return }
            do {
                try await files.replaceHostTextFile(path: listing.path, expected: current, contents: after)
                return
            } catch HostTextFileError.changedSinceRead where attempt == 1 {
                continue
            }
        }
    }

    private func removeEntry(_ entry: HarnessConfigListEntry, of path: String, holding current: Data) async throws {
        switch HarnessConfigJSONCList.removing(entry, from: current) {
        case .changed(let after):
            try await files.replaceHostTextFile(path: path, expected: current, contents: after)
        case .notThere:
            break
        case .unreadable, .notAList:
            throw HarnessConfigEditError.changedSinceWritten
        }
    }

    private func read(_ path: String) async throws -> Data? {
        let slice = try await files.readHostFileRange(
            RemoteFileRange(path: path, offset: 0, maxBytes: Self.maximumFileSize))
        guard let length = slice.length else { return nil }
        guard length <= UInt64(Self.maximumFileSize) else { throw HarnessConfigEditError.tooLarge }
        guard UInt64(slice.data.count) == length else { throw HarnessConfigEditError.unreadable }
        return slice.data
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
